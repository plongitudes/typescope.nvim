//! typescope-oracle: a minimal LSP server over pyrefly that answers
//! `typescope/structure`. See `design/oracle.md`.
//!
//!   typescope-oracle --stdio
//!   typescope-oracle --probe FILE LINE COL [DEPTH] [data|all] [--call]
//!
//! Neovim's built-in LSP client spawns it, keeps it fed with document sync
//! (unsaved buffer contents), and sends the one custom request. Everything
//! else — hover, definition, diagnostics — stays with the user's real Python
//! language server; this one advertises nothing that would compete.

mod oracle;
mod policy;
mod protocol;
mod scope;
mod walk;
#[cfg(test)]
mod tests;

use anyhow::Result;
use lsp_server::Connection;
use lsp_server::ErrorCode;
use lsp_server::Message;
use lsp_server::Notification;
use lsp_server::Request;
use lsp_server::Response;
use lsp_types::notification::DidChangeTextDocument;
use lsp_types::notification::DidCloseTextDocument;
use lsp_types::notification::DidOpenTextDocument;
use lsp_types::notification::Notification as _;

fn main() -> Result<()> {
    // `--stdio` is the only transport; other flags are accepted and ignored
    // so an LSP client that passes its own conventions still starts us.
    if std::env::args().any(|a| a == "--version" || a == "-V") {
        println!(
            "{} {} (protocol {}, pyrefly {})",
            protocol::SERVER_NAME,
            env!("CARGO_PKG_VERSION"),
            protocol::PROTOCOL,
            oracle::Oracle::pyrefly_version()
        );
        return Ok(());
    }

    // `--probe FILE LINE COL [DEPTH] [data|all]`: answer one structure query
    // and print the JSON. Development and fixture tests; not used by the plugin.
    let args: Vec<String> = std::env::args().collect();
    if let Some(i) = args.iter().position(|a| a == "--probe") {
        let path = std::path::PathBuf::from(args.get(i + 1).expect("--probe FILE LINE COL")).canonicalize()?;
        let line: u32 = args.get(i + 2).expect("LINE").parse()?;
        let col: u32 = args.get(i + 3).expect("COL").parse()?;
        let depth: u32 = args.get(i + 4).and_then(|d| d.parse().ok()).unwrap_or(2);
        let members = match args.get(i + 5).map(String::as_str) {
            Some("all") => protocol::Members::All,
            _ => protocol::Members::Data,
        };
        let call = args.iter().any(|a| a == "--call");
        let oracle = oracle::Oracle::new();
        let scope = oracle.structure(&path, line, col, depth, members, call);
        println!("{}", serde_json::to_string_pretty(&scope)?);
        return Ok(());
    }

    let (connection, io_threads) = Connection::stdio();

    // initialize/initialized by hand rather than Connection::initialize, which
    // only sends capabilities: the plugin reads serverInfo too.
    let (init_id, _init_params) = connection.initialize_start()?;
    let init_result = serde_json::to_value(protocol::initialize_result())?;
    connection.initialize_finish(init_id, init_result)?;

    let oracle = oracle::Oracle::new();
    serve(&connection, oracle)?;

    io_threads.join()?;
    Ok(())
}

fn serve(connection: &Connection, oracle: oracle::Oracle) -> Result<()> {
    for msg in &connection.receiver {
        match msg {
            Message::Request(req) => {
                if connection.handle_shutdown(&req)? {
                    return Ok(());
                }
                let resp = handle_request(&oracle, req);
                connection.sender.send(Message::Response(resp))?;
            }
            Message::Notification(note) => handle_notification(&oracle, note),
            Message::Response(_) => {} // we send no requests, so nothing to match
        }
    }
    Ok(())
}

fn handle_request(oracle: &oracle::Oracle, req: Request) -> Response {
    match req.method.as_str() {
        protocol::STRUCTURE => match serde_json::from_value::<protocol::StructureParams>(req.params) {
            Ok(params) => match file_path(&params.text_document.uri) {
                Some(path) => {
                    let scope = oracle.structure(&path, params.position.line, params.position.character, params.depth, params.members, params.call);
                    // `null` is the contract's "nothing under the cursor"
                    Response::new_ok(req.id, serde_json::to_value(scope).unwrap_or(serde_json::Value::Null))
                }
                None => Response::new_err(req.id, ErrorCode::InvalidParams as i32, "textDocument.uri is not a file".to_owned()),
            },
            Err(e) => Response::new_err(req.id, ErrorCode::InvalidParams as i32, e.to_string()),
        },
        other => Response::new_err(req.id, ErrorCode::MethodNotFound as i32, format!("unsupported request: {other}")),
    }
}

/// `file:///a/b%20c.py` → `/a/b c.py`. lsp-types 0.97's `Uri` carries no
/// filesystem conversion of its own.
fn file_path(uri: &lsp_types::Uri) -> Option<std::path::PathBuf> {
    if uri.scheme().map(|s| s.as_str()) != Some("file") {
        return None;
    }
    let raw = uri.path().as_str();
    let mut out = Vec::with_capacity(raw.len());
    let bytes = raw.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len()
            && let Ok(h) = u8::from_str_radix(&raw[i + 1..i + 3], 16)
        {
            out.push(h);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    Some(std::path::PathBuf::from(String::from_utf8_lossy(&out).into_owned()))
}

fn handle_notification(oracle: &oracle::Oracle, note: Notification) {
    match note.method.as_str() {
        DidOpenTextDocument::METHOD => {
            if let Ok(p) = serde_json::from_value::<lsp_types::DidOpenTextDocumentParams>(note.params)
                && let Some(path) = file_path(&p.text_document.uri)
            {
                oracle.did_change(&path, p.text_document.text);
            }
        }
        DidChangeTextDocument::METHOD => {
            // full sync: the last change carries the whole document
            if let Ok(p) = serde_json::from_value::<lsp_types::DidChangeTextDocumentParams>(note.params)
                && let Some(path) = file_path(&p.text_document.uri)
                && let Some(change) = p.content_changes.into_iter().last()
            {
                oracle.did_change(&path, change.text);
            }
        }
        DidCloseTextDocument::METHOD => {
            if let Ok(p) = serde_json::from_value::<lsp_types::DidCloseTextDocumentParams>(note.params)
                && let Some(path) = file_path(&p.text_document.uri)
            {
                oracle.did_close(&path);
            }
        }
        // $/cancelRequest: requests are answered synchronously and in order,
        // so by the time a cancel arrives its request has been answered.
        // Accepted and ignored; revisit if a request ever takes long enough
        // to be worth threading.
        _ => {}
    }
}
