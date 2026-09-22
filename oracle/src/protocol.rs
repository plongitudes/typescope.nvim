//! The wire contract between the plugin and the oracle: `design/oracle.md` §3–§4.
//!
//! The oracle is an LSP server that advertises nothing but document sync, so
//! it never competes with the user's real Python language server for hover,
//! definition or diagnostics. The one thing it adds is the custom request
//! [`STRUCTURE`]. Both halves pin each other through [`PROTOCOL`], carried in
//! the `experimental` capability, so a plugin talking to the wrong binary
//! refuses with a health-style message instead of mis-rendering.

use lsp_types::InitializeResult;
use lsp_types::ServerCapabilities;
use lsp_types::ServerInfo;
use lsp_types::TextDocumentSyncCapability;
use lsp_types::TextDocumentSyncKind;
use serde::Deserialize;
use serde::Serialize;
use serde_json::json;

/// Bumped whenever the shape of a `typescope/structure` request or response
/// changes incompatibly. The plugin checks it at attach time.
pub const PROTOCOL: u32 = 1;

/// The custom request. Params are [`StructureParams`]; the result is a
/// `Scope` JSON object (design/oracle.md §4) or `null` when nothing under the
/// cursor is TypeScope's business.
pub const STRUCTURE: &str = "typescope/structure";

pub const SERVER_NAME: &str = "typescope-oracle";

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StructureParams {
    pub text_document: lsp_types::TextDocumentIdentifier,
    pub position: lsp_types::Position,
    /// How far to nest before returning `expandable` nodes. `config.depth`.
    #[serde(default = "default_depth")]
    pub depth: u32,
    /// `"data"` (fields, properties, enum members; methods grouped) or
    /// `"all"` (what expanding the methods group asks for). Decision 4.
    #[serde(default)]
    pub members: Members,
    /// The cursor sits on a *call* to whatever is under it. Set by the plugin
    /// from the buffer's syntax tree; a class under a call draws its
    /// constructor (decision 5).
    #[serde(default)]
    pub call: bool,
    /// An expansion: the names from the root row down to the node being
    /// opened. Third-party classes nested as member types stay `expandable`
    /// until asked for; along this path they open.
    #[serde(default)]
    pub expand: Option<Vec<String>>,
}

fn default_depth() -> u32 {
    2
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Members {
    #[default]
    Data,
    All,
}

/// Everything the plugin needs to decide whether it is talking to the right
/// binary: name, crate version, and the protocol number.
pub fn initialize_result() -> InitializeResult {
    InitializeResult {
        capabilities: ServerCapabilities {
            text_document_sync: Some(TextDocumentSyncCapability::Kind(TextDocumentSyncKind::FULL)),
            experimental: Some(json!({ "typescope": { "protocol": PROTOCOL } })),
            ..ServerCapabilities::default()
        },
        server_info: Some(ServerInfo {
            name: SERVER_NAME.to_owned(),
            version: Some(env!("CARGO_PKG_VERSION").to_owned()),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn advertises_only_document_sync_and_the_protocol() {
        let v = serde_json::to_value(initialize_result()).unwrap();
        let caps = &v["capabilities"];
        assert_eq!(caps["textDocumentSync"], json!(1), "full sync");
        assert_eq!(caps["experimental"]["typescope"]["protocol"], json!(PROTOCOL));
        // nothing that would fight basedpyright
        for forbidden in ["hoverProvider", "definitionProvider", "completionProvider", "diagnosticProvider", "signatureHelpProvider"] {
            assert!(caps.get(forbidden).is_none(), "{forbidden} must not be advertised");
        }
        assert_eq!(v["serverInfo"]["name"], json!(SERVER_NAME));
    }

    #[test]
    fn structure_params_default_depth_and_members() {
        let p: StructureParams = serde_json::from_value(json!({
            "textDocument": { "uri": "file:///x.py" },
            "position": { "line": 3, "character": 4 }
        }))
        .unwrap();
        assert_eq!(p.depth, 2);
        assert_eq!(p.members, Members::Data);
        assert!(!p.call);
        assert!(p.expand.is_none());
    }
}
