//! Fixture-driven tests: the markers in `tests/fixtures/shapes.py` are the
//! expectation (see that file's docstring), and `tests/fixtures/oracle.py`
//! holds the questions the syntax resolver could not answer.
//!
//! Each `typescope:` class marker is asserted against the oracle's answer for
//! the class name it precedes; a `typescope-oracle:` line directly below it
//! overrides the expectation for this reader. `typescope-params:` markers
//! assert the parameters a caller supplies for the `def` they precede.

use std::path::Path;
use std::path::PathBuf;
use std::sync::OnceLock;

use crate::oracle::Oracle;
use crate::scope::Scope;
use crate::protocol::Members;
use crate::walk::Node;

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../tests/fixtures").canonicalize().unwrap()
}

/// One State for every test in the process: building it is cheap, but
/// solving `shapes.py` with its stubs is the part worth sharing.
fn oracle() -> &'static Oracle {
    static ORACLE: OnceLock<Oracle> = OnceLock::new();
    ORACLE.get_or_init(Oracle::new)
}

fn structure(file: &str, line0: u32, col0: u32) -> Option<Scope> {
    oracle().structure(&fixtures().join(file), line0, col0, 2, Members::Data, false, None)
}

/// 0-based line of the first line starting with `prefix` in a fixture, so
/// tests survive edits above the target.
fn line_of(file: &str, prefix: &str) -> u32 {
    let source = std::fs::read_to_string(fixtures().join(file)).unwrap();
    source.lines().position(|l| l.starts_with(prefix)).unwrap_or_else(|| panic!("{prefix} not in {file}")) as u32
}

/// `key=value` pairs of a marker line; `fields=NONE` → empty list.
fn marker_values(line: &str, key: &str) -> Option<Vec<String>> {
    let needle = format!("{key}=");
    let start = line.find(&needle)? + needle.len();
    let rest = &line[start..];
    let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
    let raw = &rest[..end];
    Some(if raw == "NONE" { vec![] } else { raw.split(',').map(str::to_owned).collect() })
}

struct ClassExpectation {
    class: String,
    line0: u32,
    category: String,
    fields: Vec<String>,
    methods: Option<Vec<String>>,
}

/// Read every class marker, with `typescope-oracle:` overrides applied.
fn class_expectations(source: &str) -> Vec<ClassExpectation> {
    let lines: Vec<&str> = source.lines().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let l = lines[i].trim();
        if let Some(marker) = l.strip_prefix("# typescope:") {
            let mut category = marker_values(marker, "category").and_then(|v| v.into_iter().next()).unwrap();
            let mut fields = marker_values(marker, "fields").unwrap();
            let methods = marker_values(marker, "methods");
            let mut j = i + 1;
            if let Some(over) = lines.get(j).and_then(|s| s.trim().strip_prefix("# typescope-oracle:")) {
                if let Some(c) = marker_values(over, "category").and_then(|v| v.into_iter().next()) {
                    category = c;
                }
                if let Some(f) = marker_values(over, "fields") {
                    fields = f;
                }
                j += 1;
            }
            // skip decorators to the class statement
            while lines.get(j).is_some_and(|s| s.trim_start().starts_with('@')) {
                j += 1;
            }
            let class_line = lines[j];
            let class = class_line
                .trim_start()
                .strip_prefix("class ")
                .unwrap()
                .split(|c: char| c == '(' || c == ':')
                .next()
                .unwrap()
                .to_owned();
            out.push(ClassExpectation { class, line0: j as u32, category, fields, methods });
            i = j;
        }
        i += 1;
    }
    out
}

fn data_rows(node: &Node) -> Vec<String> {
    node.children
        .iter()
        .filter(|c| matches!(c.kind.as_str(), "field" | "property" | "enum_member"))
        .map(|c| c.name.clone())
        .collect()
}

fn method_rows(node: &Node) -> Vec<String> {
    let mut out: Vec<String> = node.children.iter().filter(|c| c.kind == "method").map(|c| c.name.clone()).collect();
    if let Some(group) = node.children.iter().find(|c| c.kind == "group") {
        out.extend(group.children.iter().map(|c| c.name.clone()));
    }
    out
}

#[test]
fn every_class_marker_in_shapes_py_holds() {
    let source = std::fs::read_to_string(fixtures().join("shapes.py")).unwrap();
    let expectations = class_expectations(&source);
    assert!(expectations.len() >= 20, "markers parsed: {}", expectations.len());
    let mut failures = Vec::new();
    for e in &expectations {
        let scope = structure("shapes.py", e.line0, 6);
        let Some(scope) = scope else {
            failures.push(format!("{}: no answer", e.class));
            continue;
        };
        let root = &scope.roots[0];
        if root.ty.category != e.category {
            failures.push(format!("{}: category {} != expected {}", e.class, root.ty.category, e.category));
        }
        let fields = data_rows(root);
        if fields != e.fields {
            failures.push(format!("{}: fields {:?} != expected {:?}", e.class, fields, e.fields));
        }
        if let Some(methods) = &e.methods {
            let got = method_rows(root);
            if &got != methods {
                failures.push(format!("{}: methods {:?} != expected {:?}", e.class, got, methods));
            }
        }
    }
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}

#[test]
fn every_params_marker_in_shapes_py_holds() {
    let source = std::fs::read_to_string(fixtures().join("shapes.py")).unwrap();
    let lines: Vec<&str> = source.lines().collect();
    let mut checked = 0;
    let mut failures = Vec::new();
    for (i, l) in lines.iter().enumerate() {
        let Some(marker) = l.trim().strip_prefix("# typescope-params:") else { continue };
        let expected = marker_values(marker, "params").unwrap();
        let mut j = i + 1;
        while lines[j].trim_start().starts_with('@') {
            j += 1;
        }
        let def = lines[j];
        let col = def.find("def ").unwrap() + 4;
        let name = def[col..].split('(').next().unwrap();
        let scope = structure("shapes.py", j as u32, col as u32).unwrap_or_else(|| panic!("{name}: no answer"));
        assert_eq!(scope.scope, "function", "{name}");
        let params: Vec<String> = scope.roots.iter().filter(|r| r.kind == "param").map(|r| r.name.clone()).collect();
        if params != expected {
            failures.push(format!("{name}: params {params:?} != expected {expected:?}"));
        }
        checked += 1;
    }
    assert_eq!(checked, 7);
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}

fn find<'a>(node: &'a Node, name: &str) -> &'a Node {
    node.children.iter().find(|c| c.name == name).unwrap_or_else(|| panic!("no child {name} under {}", node.name))
}

#[test]
fn a_generic_parameter_arrives_specialized() {
    // def use(b: Box[ServerConfig], c: Color, d: Derived) -> Response
    let scope = structure("oracle/oracle.py", line_of("oracle/oracle.py", "def use("), 4).unwrap();
    assert_eq!(scope.scope, "function");
    let b = &scope.roots[0];
    assert_eq!(b.ty.display, "Box[ServerConfig]");
    let item = find(b, "item");
    assert_eq!(item.ty.display, "ServerConfig", "T substituted");
    assert_eq!(item.ty.category, "dataclass");
    assert_eq!(data_rows(item), ["host", "port"]);
}

#[test]
fn an_enum_shows_its_members_and_nothing_else() {
    let scope = structure("oracle/oracle.py", line_of("oracle/oracle.py", "def use("), 4).unwrap();
    let c = &scope.roots[1];
    assert_eq!(c.ty.category, "enum");
    assert_eq!(data_rows(c), ["RED", "GREEN"]);
    let red = find(c, "RED");
    assert_eq!(red.kind, "enum_member");
    assert_eq!(red.default.as_deref(), Some("1"));
    assert!(c.children.iter().all(|m| m.kind == "enum_member"), "name/value/_missing_ are cut with Enum");
}

#[test]
fn inherited_fields_carry_their_origin() {
    let scope = structure("oracle/oracle.py", line_of("oracle/oracle.py", "def use("), 4).unwrap();
    let d = &scope.roots[2];
    assert_eq!(data_rows(d), ["debug", "host", "port"]);
    assert_eq!(find(d, "host").origin.as_deref(), Some("ServerConfig"));
    assert_eq!(find(d, "debug").origin, None);
}

#[test]
fn an_unannotated_local_is_its_inferred_class() {
    // resp = fetch("x") — the syntax resolver drew the enclosing function here
    let scope = structure("oracle/oracle.py", line_of("oracle/oracle.py", "    resp = fetch"), 4).unwrap();
    assert_eq!(scope.scope, "declaration");
    let r = &scope.roots[0];
    assert_eq!(r.ty.display, "Response");
    assert_eq!(data_rows(r), ["status", "ok", "body", "parsed"]);
    assert_eq!(find(r, "ok").kind, "property");
    assert_eq!(find(r, "ok").ty.display, "bool");
    let parsed = find(r, "parsed");
    assert!(parsed.inferred, "no annotation → ≈");
    assert_eq!(parsed.ty.display, "dict[str, int]");
    assert!(!find(r, "body").inferred);
}

#[test]
fn a_typevar_is_solved_at_the_call_site_and_not_at_the_def() {
    let n = structure("oracle/oracle.py", line_of("oracle/oracle.py", "n = first"), 0).unwrap();
    assert_eq!(n.roots[0].ty.display, "int");
    let first = structure("oracle/oracle.py", line_of("oracle/oracle.py", "def first"), 4).unwrap();
    assert_eq!(first.scope, "function");
    assert_eq!(first.roots[0].ty.display, "list[T]");
}

#[test]
fn narrowing_is_honoured_at_the_use_site() {
    let before = structure("oracle/oracle.py", line_of("oracle/oracle.py", "maybe = fetch_maybe"), 0).unwrap();
    assert_eq!(before.roots[0].ty.display, "Response | None");
    assert_eq!(before.roots[0].ty.category, "union");
    let variants: Vec<&str> = before.roots[0].children.iter().map(|c| c.kind.as_str()).collect();
    assert_eq!(variants, ["variant"], "None is vocabulary, not a variant");
    let inside = structure("oracle/oracle.py", line_of("oracle/oracle.py", "    narrowed = maybe"), 4).unwrap();
    assert_eq!(inside.roots[0].ty.display, "Response");
}

#[test]
fn typeshed_classes_are_terminal_leaves() {
    let scope = structure("shapes.py", line_of("shapes.py", "class ServerConfig"), 6).unwrap();
    let host = find(&scope.roots[0], "host");
    assert_eq!(host.ty.category, "builtin");
    assert!(host.children.is_empty() && !host.expandable, "str is vocabulary, not shape");
}

#[test]
fn methods_are_grouped_for_data_and_flat_for_all() {
    // Response has no methods besides the property; use a class with one
    let source = "class Svc:\n    x: int\n    def run(self, n: int) -> str: ...\n";
    let dir = std::env::temp_dir().join("typescope-oracle-test");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("svc.py");
    std::fs::write(&file, source).unwrap();
    let data = oracle().structure(&file, 0, 6, 2, Members::Data, false, None).unwrap();
    let kinds: Vec<&str> = data.roots[0].children.iter().map(|c| c.kind.as_str()).collect();
    assert_eq!(kinds, ["field", "group"]);
    let group = &data.roots[0].children[1];
    assert_eq!(group.name, "methods");
    assert_eq!(group.children[0].name, "run");
    let all = oracle().structure(&file, 0, 6, 2, Members::All, false, None).unwrap();
    let kinds: Vec<&str> = all.roots[0].children.iter().map(|c| c.kind.as_str()).collect();
    assert_eq!(kinds, ["field", "method"]);
    let run = &all.roots[0].children[1];
    // a method row is its receiver-less signature, no children (the
    // resolver drew Protocol methods exactly so; parity gate 1mv)
    assert_eq!(run.ty.display, "(n: int) -> str", "self dropped by position, signature as the row");
    assert!(run.children.is_empty());
}

#[test]
fn beyond_depth_a_class_is_expandable_and_located_at_its_declaration() {
    let use_line = line_of("oracle/oracle.py", "def use(");
    let scope = oracle().structure(&fixtures().join("oracle/oracle.py"), use_line, 4, 1, Members::Data, false, None).unwrap();
    let item = find(&scope.roots[0], "item");
    assert!(item.expandable);
    assert!(item.children.is_empty());
    // location is the member's DECLARATION (`item: T` in Box), for navigation.
    // Expansion re-asks the original position with a deeper depth: asking at
    // the declaration would answer with the unspecialized `T`.
    let loc = item.location.as_ref().expect("declaration location");
    assert!(loc.uri.ends_with("/oracle.py"));
    assert_eq!(loc.line, line_of("oracle/oracle.py", "    item: T"));
    // and a deeper ask at the same position grafts the children in
    let deeper = oracle().structure(&fixtures().join("oracle/oracle.py"), use_line, 4, 2, Members::Data, false, None).unwrap();
    assert_eq!(data_rows(find(&deeper.roots[0], "item")), ["host", "port"]);
}

#[test]
fn an_unsaved_edit_is_what_the_oracle_answers_with() {
    // a private State: overlays are global to it and must not leak into
    // the other tests' shared oracle
    let oracle = Oracle::new();
    let path = fixtures().join("oracle/oracle.py");
    let on_disk = std::fs::read_to_string(&path).unwrap();
    let line = line_of("oracle/oracle.py", "    resp = fetch");

    // as on disk
    let scope = oracle.structure(&path, line, 4, 2, Members::Data, false, None).unwrap();
    assert_eq!(find(&scope.roots[0], "status").ty.display, "int");

    // opened, then edited in memory without saving: status becomes a str
    oracle.did_change(&path, on_disk.clone());
    let edited = on_disk.replace("    status: int\n", "    status: str\n");
    assert_ne!(edited, on_disk);
    oracle.did_change(&path, edited);
    let scope = oracle.structure(&path, line, 4, 2, Members::Data, false, None).unwrap();
    assert_eq!(find(&scope.roots[0], "status").ty.display, "str", "the overlay, not the disk");

    // closed: the disk is the truth again
    oracle.did_close(&path);
    let scope = oracle.structure(&path, line, 4, 2, Members::Data, false, None).unwrap();
    assert_eq!(find(&scope.roots[0], "status").ty.display, "int");
}

// ---------------------------------------------------------------- scopes (12r)

fn probe(file: &str, prefix: &str, col: u32, call: bool) -> Scope {
    let line = line_of(file, prefix);
    oracle()
        .structure(&fixtures().join(file), line, col, 2, Members::Data, call, None)
        .unwrap_or_else(|| panic!("{prefix}: no answer"))
}

#[test]
fn a_function_scope_carries_the_call_shape_header_and_docstring() {
    let s = probe("shapes.py", "def takes_config", 4, false);
    assert_eq!(s.scope, "function");
    assert_eq!(s.header.as_deref(), Some("takes_config(config, timeout=…) -> User"));
    assert!(s.docstring.as_deref().unwrap_or("").starts_with("Hover the name: params expand"));
    let kinds: Vec<&str> = s.roots.iter().map(|r| r.kind.as_str()).collect();
    assert_eq!(kinds, ["param", "param", "return"]);

    let s = probe("oracle/oracle.py", "def separators", 4, false);
    assert_eq!(s.header.as_deref(), Some("separators(a, b=…, /, c=…, *, d, e=…) -> None"));
    assert_eq!(s.roots[0].pass_mode.as_deref(), Some("/"));
    assert_eq!(s.roots[3].pass_mode.as_deref(), Some("*"));
}

#[test]
fn an_async_def_shows_its_declared_return() {
    let s = probe("oracle/oracle.py", "async def fetch_async", 10, false);
    assert_eq!(s.header.as_deref(), Some("fetch_async(url) -> Response"));
    let ret = s.roots.iter().find(|r| r.kind == "return").unwrap();
    assert_eq!(ret.ty.display, "Response");
    assert!(!ret.inferred);
}

#[test]
fn an_overload_set_is_the_same_from_any_of_its_defs_or_a_call() {
    for (prefix, col) in [("def pick(key: int)", 4), ("def pick(key, default=None)", 4), ("x = pick(3)", 4)] {
        let s = probe("oracle/oracle.py", prefix, col, false);
        assert_eq!(s.scope, "function", "{prefix}");
        assert_eq!(s.overloads, Some(2), "{prefix}");
        assert_eq!(
            s.headers.as_deref(),
            Some(&["pick(key) -> int".to_owned(), "pick(key, default=…) -> str".to_owned()][..]),
            "{prefix}"
        );
        assert_eq!(s.header.as_deref(), Some("pick(key) -> int"));
        assert_eq!(s.roots.len(), 2);
        assert_eq!(s.roots[0].kind, "overload");
        assert_eq!(s.roots[0].badge.as_deref(), Some("[1/2]"));
        assert_eq!(s.roots[1].badge.as_deref(), Some("[2/2]"));
        assert_eq!(s.roots[1].children.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["key", "default", "returns"]);
    }
}

#[test]
fn a_class_scope_heads_with_its_category_and_written_bases() {
    let s = probe("shapes.py", "class DerivedConfig", 6, false);
    assert_eq!(s.scope, "class");
    assert_eq!(s.roots[0].name, "DerivedConfig");
    assert_eq!(s.roots[0].kind, "type");
    assert_eq!(s.roots[0].ty.display, "(class ← BaseConfig)");
    let s = probe("shapes.py", "class User", 6, false);
    assert_eq!(s.roots[0].ty.display, "(pydantic)", "BaseModel is a marker, not a listed base");
    assert!(s.docstring.is_none());
}

#[test]
fn a_class_under_a_call_draws_its_constructor() {
    // a dataclass: the fields are the parameters
    let s = probe("shapes.py", "class ServerConfig", 6, true);
    assert_eq!(s.scope, "constructor");
    assert_eq!(s.header.as_deref(), Some("ServerConfig(host, port=…, debug=…) -> ServerConfig"));
    let kinds: Vec<&str> = s.roots.iter().map(|r| r.kind.as_str()).collect();
    assert_eq!(kinds, ["param", "param", "param", "return"]);
    assert_eq!(s.roots[1].default.as_deref(), Some("8000"));
    // a written __init__: its parameters, receiver dropped
    let s = probe("shapes.py", "class InitAssigned", 6, true);
    let params: Vec<&str> = s.roots.iter().filter(|r| r.kind == "param").map(|r| r.name.as_str()).collect();
    assert_eq!(params, ["inflow"]);
    assert_eq!(data_rows(s.roots.last().unwrap()), ["strong", "ant"], "what it makes");
}

#[test]
fn understood_but_nothing_to_draw_is_empty_with_a_reason() {
    let s = probe("oracle/oracle.py", "class Empty", 6, false);
    assert_eq!(s.scope, "empty");
    assert_eq!(s.reason.as_deref(), Some("Empty has no fields, methods or bases to draw"));
    let s = probe("oracle/oracle.py", "    def n(self)", 8, false);
    assert_eq!(s.scope, "empty");
    assert_eq!(s.reason.as_deref(), Some("n has no parameters or return annotation"));
}

#[test]
fn a_self_attribute_in_a_method_is_the_declaration_it_names() {
    // `self.cfg: ServerConfig` — one class IS the annotation, so the class
    // heads the float (the resolver's olj decision, e2e_declarations)
    let s = probe("oracle/oracle.py", "        self.cfg", 13, false);
    assert_eq!(s.scope, "class");
    assert_eq!(s.roots[0].name, "ServerConfig");
    assert_eq!(data_rows(&s.roots[0]), ["host", "port"]);
    let s = probe("oracle/oracle.py", "        self.guess", 13, false);
    assert_eq!(s.roots[0].name, "self.guess");
    assert_eq!(s.roots[0].ty.display, "Response");
    assert!(s.roots[0].inferred, "no annotation → ≈");
}

#[test]
fn a_module_name_is_not_ours() {
    // `from typing import Generic, TypeVar` — hovering `typing` in an import
    // is a Module; K's job
    let line = line_of("oracle/oracle.py", "from typing import Generic");
    assert!(oracle().structure(&fixtures().join("oracle/oracle.py"), line, 5, 2, Members::Data, false, None).is_none());
}

// ---------------------------------------------------------------- parity gate (1mv)

#[test]
fn a_written_alias_stays_the_vocabulary_and_resolves_beneath() {
    // sample.py: Payload = UserRecord; def send(data: Payload)
    let s = probe("sample.py", "def send", 4, false);
    let data = &s.roots[0];
    assert_eq!(data.ty.display, "Payload", "the alias the author wrote");
    assert_eq!(data.ty.category, "typeddict");
    assert_eq!(data_rows(data), ["email", "name", "age"], "TypedDict keys through the alias");
    assert_eq!(find(data, "email").badge.as_deref(), Some("NotRequired"), "total=False badges survive");
    assert!(data.resolved.is_none(), "a row with structure needs no ≈");
    // LoopMode = Literal["auto", "manual"]; def configure(mode: LoopMode)
    let s = probe("sample.py", "def configure", 4, false);
    let mode = &s.roots[0];
    assert_eq!(mode.ty.display, "LoopMode");
    assert_eq!(mode.resolved.as_deref(), Some("Literal['auto', 'manual']"), "a leaf alias is decorated with what it resolved to");
}

#[test]
fn a_typedict_parameter_lists_its_keys_not_dicts_methods() {
    let s = probe("sample.py", "def update_user", 4, false);
    assert_eq!(data_rows(&s.roots[0]), ["email", "name", "age"]);
    assert!(s.roots[0].children.iter().all(|c| c.kind != "group"), "dict's methods are cut");
}

#[test]
fn an_unannotated_parameter_reads_any_not_unknown() {
    let s = probe("shapes.py", "def free_function", 4, false);
    assert_eq!(s.roots[0].name, "numpy_test");
    assert_eq!(s.roots[0].ty.display, "Any");
    assert_eq!(s.roots[0].ty.category, "builtin");
}

#[test]
fn a_protocol_method_row_is_its_receiverless_signature() {
    let s = probe("shapes.py", "class Backend", 6, false);
    let read = find(&s.roots[0], "read");
    assert_eq!(read.kind, "method");
    assert_eq!(read.ty.display, "(key: str) -> bytes");
    assert!(read.children.is_empty() && !read.expandable);
}

#[test]
fn an_unannotated_parameter_with_a_default_is_typed_by_the_default() {
    // def configure(mode: LoopMode, count=3): pyrefly types count as
    // `int | Unknown`; the float shows `int ≈`, as pyright's default-based
    // inference did
    let s = probe("sample.py", "def configure", 4, false);
    let count = &s.roots[1];
    assert_eq!(count.ty.display, "int");
    assert!(count.inferred);
    assert_eq!(count.default.as_deref(), Some("3"));
}

#[test]
fn old_typing_spellings_display_as_modern_syntax() {
    let s = probe("oracle/oracle.py", "def legacy_spelling", 4, false);
    let by_name = |n: &str| s.roots.iter().find(|r| r.name == n).unwrap().ty.display.clone();
    assert_eq!(by_name("a"), "str | None");
    // pyrefly spells a bare Callable as its shape and orders union members
    // its own way; the point is the modern `|` spelling and the forward
    // reference resolved
    let b = by_name("b");
    assert!(b.contains("Response") && b.contains(" | ") && b.contains("str") && !b.contains("Union"), "{b}");
    assert_eq!(by_name("c"), "list[int]");
    assert_eq!(by_name("d"), "int | str | None");
}

#[test]
fn a_nested_third_party_class_waits_to_be_asked_for() {
    // widget: Widget — Widget comes from site-packages
    let s = probe("oracle/oracle.py", "class UsesThirdParty", 6, false);
    let widget = find(&s.roots[0], "widget");
    assert!(widget.expandable, "nested third-party class is expandable, not walked");
    assert!(widget.children.is_empty());
    assert_eq!(widget.ty.category, "class");
    // opened on demand: the expansion names its path and the class walks
    let line = line_of("oracle/oracle.py", "class UsesThirdParty");
    let opened = oracle()
        .structure(&fixtures().join("oracle/oracle.py"), line, 6, 3, Members::Data, false, Some(vec!["UsesThirdParty".into(), "widget".into()]))
        .unwrap();
    let widget = find(&opened.roots[0], "widget");
    assert_eq!(data_rows(widget), ["size", "label"]);
    // hovered directly it draws as any class
    let direct = probe("oracle/oracle.py", "from thirdparty import Widget", 23, false);
    assert_eq!(direct.scope, "class");
    assert_eq!(data_rows(&direct.roots[0]), ["size", "label"]);
}
