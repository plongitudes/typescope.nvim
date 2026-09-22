//! What is under the cursor, as a Scope (design/oracle.md §4): a function
//! (its params and return are the roots), a class (its shape), a declaration
//! (the symbol drawn as a root row with its type nested), a constructor (a
//! class under a call: what it takes, then what it makes), or `empty` — a
//! symbol that was understood and has nothing to draw, which the plugin
//! reports on the message line where silence would look like a miss.

use dupe::Dupe;
use pyrefly::state::state::Transaction;
use pyrefly_build::handle::Handle;
use pyrefly_python::module::Module;
use pyrefly_types::class::Class;
use pyrefly_types::types::Forallable;
use pyrefly_types::types::Type;
use ruff_python_ast::Expr;
use ruff_python_ast::Stmt;
use ruff_text_size::Ranged;
use ruff_text_size::TextRange;
use serde::Serialize;

use crate::policy;
use crate::protocol::Members;
use crate::walk::Cursor;
use crate::walk::Node;
use crate::walk::Walker;
use crate::walk::find_class_def;

/// The answer to `typescope/structure`.
#[derive(Debug, Clone, Serialize)]
pub struct Scope {
    pub scope: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub docstring: Option<String>,
    /// Overload sets: one header per group, in `roots` order.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub headers: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub overloads: Option<usize>,
    pub roots: Vec<Node>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

pub struct Request<'a> {
    pub tx: &'a Transaction<'a>,
    pub handle: &'a Handle,
    pub module: &'a Module,
    pub cursor: Cursor,
    pub depth: u32,
    pub members: Members,
    /// The cursor sits on a call to whatever is under it (decision 5).
    pub call: bool,
}

pub fn build(req: &Request<'_>, ty: &Type) -> Option<Scope> {
    let walker = Walker { tx: req.tx, handle: req.handle, members: req.members };
    match ty {
        Type::Module(_) => None, // `import os` — K's job
        Type::Function(_) | Type::BoundMethod(_) | Type::Overload(_) => Some(function_scope(req, &walker, ty)),
        Type::Forall(fa) if matches!(fa.body, Forallable::Function(_)) => Some(function_scope(req, &walker, ty)),
        Type::ClassDef(cls) if req.call => Some(constructor_scope(req, &walker, cls, ty)),
        Type::ClassDef(cls) => Some(class_scope(req, &walker, cls, ty)),
        _ => Some(declaration_scope(req, &walker, ty)),
    }
}

// ------------------------------------------------------------------ function

fn function_scope(req: &Request<'_>, walker: &Walker<'_>, ty: &Type) -> Scope {
    let node = walker.node("function", "function", ty, req.depth);
    let name = node.def_name.clone().unwrap_or_else(|| req.cursor.text.clone());
    let docstring = match (&node.def_handle, node.def_range) {
        (Some(handle), Some(range)) => docstring_of_def(req, handle, &name, range),
        _ => None,
    };

    if node.kind == "function" && node.children.iter().all(|c| c.kind == "overload") && !node.children.is_empty() {
        // an overload set: each signature is a group root, the plugin picks
        // the active one from signatureHelp / the written arguments
        let n = node.children.len();
        let mut roots = Vec::new();
        let mut headers = Vec::new();
        for (i, mut g) in node.children.into_iter().enumerate() {
            g.name = name.clone();
            g.badge = Some(format!("[{}/{}]", i + 1, n));
            g.ty.display = format!("({})", g.shape.join(", "));
            headers.push(header_of(&name, &g));
            roots.push(g);
        }
        return Scope {
            scope: "function".to_owned(),
            header: headers.first().cloned(),
            docstring,
            headers: Some(headers),
            overloads: Some(n),
            roots,
            reason: None,
        };
    }

    // a function with nothing a caller can supply and nothing it announces
    // it returns is understood, and declined: the plugin says so on the
    // message line rather than opening an empty float
    let has_params = node.children.iter().any(|c| c.kind == "param");
    let returns = node.children.iter().find(|c| c.kind == "return");
    let informative_return = returns.is_some_and(|r| !r.inferred || policy::informative_display(&r.ty.display));
    if !has_params && !informative_return {
        return Scope {
            scope: "empty".to_owned(),
            header: None,
            docstring,
            headers: None,
            overloads: None,
            roots: Vec::new(),
            reason: Some(format!("{name} has no parameters or return annotation")),
        };
    }
    let header = header_of(&name, &node);
    let roots = node
        .children
        .into_iter()
        .filter(|c| c.kind != "return" || informative_return)
        .collect();
    Scope { scope: "function".to_owned(), header: Some(header), docstring, headers: None, overloads: None, roots, reason: None }
}

/// `name(a, b=…, *, c) -> R`, the call-shape line the float is headed with.
fn header_of(name: &str, fn_node: &Node) -> String {
    let ret = fn_node
        .children
        .iter()
        .find(|c| c.kind == "return")
        .map(|r| format!(" -> {}", r.ty.display))
        .unwrap_or_default();
    format!("{name}({}){ret}", fn_node.shape.join(", "))
}

// ------------------------------------------------------------------ class

fn class_scope(req: &Request<'_>, walker: &Walker<'_>, cls: &Class, ty: &Type) -> Scope {
    let mut root = walker.node(cls.name().as_str(), "type", ty, req.depth);
    let bases = source_bases(req, cls);
    let docstring = docstring_at(req, cls.range());
    if root.children.is_empty() && bases.is_empty() {
        return Scope {
            scope: "empty".to_owned(),
            header: None,
            docstring,
            headers: None,
            overloads: None,
            roots: Vec::new(),
            reason: Some(format!("{} has no fields, methods or bases to draw", cls.name())),
        };
    }
    // the root row IS the header: `Name  (pydantic ← UserBase)`
    root.ty.display = class_header(&root.ty.category, &bases);
    Scope { scope: "class".to_owned(), header: None, docstring, headers: None, overloads: None, roots: vec![root], reason: None }
}

fn class_header(category: &str, bases: &[String]) -> String {
    if bases.is_empty() {
        format!("({category})")
    } else {
        format!("({category} ← {})", bases.join(", "))
    }
}

/// The bases the author wrote, minus the construct markers (`BaseModel`,
/// `TypedDict`, `Protocol`, `Generic[T]`, `Enum`, `object`), which the
/// category already says. Source text, like the treesitter resolver's header.
fn source_bases(req: &Request<'_>, cls: &Class) -> Vec<String> {
    let Some((ast, module)) = ast_of(req, cls) else { return Vec::new() };
    let Some(cd) = find_class_def(&ast.body, cls.range()) else { return Vec::new() };
    let text = module.contents();
    let mut out = Vec::new();
    if let Some(args) = &cd.arguments {
        for base in args.args.iter() {
            let raw = &text[base.range()];
            let head = raw.split('[').next().unwrap_or(raw);
            let last = head.rsplit('.').next().unwrap_or(head);
            if !policy::is_marker_base(last) {
                out.push(raw.to_owned());
            }
        }
    }
    out
}

// ------------------------------------------------------------------ constructor

/// `Recipe(` under the cursor: what the call takes, then what it makes.
/// A written `__init__` supplies the parameters; without one (dataclass,
/// pydantic, NamedTuple, TypedDict) the instance's fields are the
/// parameters, which is exactly what those constructs synthesize.
fn constructor_scope(req: &Request<'_>, walker: &Walker<'_>, cls: &Class, ty: &Type) -> Scope {
    let name = cls.name().as_str().to_owned();
    let instance = walker.node(&name, "return", ty, req.depth);
    let docstring = docstring_at(req, cls.range());
    let mut roots = Vec::new();
    let mut shape = Vec::new();

    let init = req
        .tx
        .attributes_of_type(req.handle, ty.clone())
        .unwrap_or_default()
        .into_iter()
        .find(|a| a.name.as_str() == "__init__")
        .filter(|a| match &a.definition {
            pyrefly::alt::attr::AttrDefinition::FullyResolved { cls: owner, .. } => !policy::is_cut_base(owner),
            _ => false,
        })
        .and_then(|a| a.ty);
    if let Some(init_ty) = init {
        let init_node = walker.node("__init__", "function", &init_ty, req.depth);
        shape = init_node.shape.clone();
        roots.extend(init_node.children.into_iter().filter(|c| c.kind == "param"));
    } else {
        for field in instance.children.iter().filter(|c| matches!(c.kind.as_str(), "field")) {
            let mut p = field.clone();
            p.kind = "param".to_owned();
            p.origin = None;
            shape.push(if p.default.is_some() { format!("{}=…", p.name) } else { p.name.clone() });
            roots.push(p);
        }
    }
    let mut made = instance;
    made.name = "returns".to_owned();
    made.kind = "return".to_owned();
    let header = format!("{name}({}) -> {name}", shape.join(", "));
    roots.push(made);
    Scope { scope: "constructor".to_owned(), header: Some(header), docstring, headers: None, overloads: None, roots, reason: None }
}

// ------------------------------------------------------------------ declaration

/// The symbol drawn as its own row — `self.bar`, `resp`, a parameter name —
/// with its type's structure nested beneath. Always a row: a builtin
/// declaration still says what the symbol was declared as (the resolver's
/// "prefer a row over a decline").
fn declaration_scope(req: &Request<'_>, walker: &Walker<'_>, ty: &Type) -> Scope {
    // `self.bar: Bar` — one class IS the whole annotation, so the class is
    // the answer and heads the float as it would when hovered directly.
    // `dict[str, Bar]`, `Bar | None` and builtins keep the declaration as
    // the root row: collapsing to Bar there would head the float with a type
    // the symbol does not have (the resolver's olj decision).
    // An UNANNOTATED target (`resp = fetch()`) keeps its own row: the ≈ on
    // it says the type is the checker's inference, which a class float
    // would not.
    if !req.cursor.inferred
        && let Type::ClassType(ct) = ty
        && ct.targs().is_empty()
        && !policy::is_terminal_class(ct.class_object())
    {
        let cls = ct.class_object().dupe();
        let as_class = class_scope(req, walker, &cls, &Type::ClassDef(cls.dupe()));
        if as_class.scope == "class" {
            return as_class;
        }
    }
    let mut root = walker.node(&req.cursor.text, "field", ty, req.depth);
    root.inferred = root.inferred || req.cursor.inferred;
    Scope { scope: "declaration".to_owned(), header: None, docstring: None, headers: None, overloads: None, roots: vec![root], reason: None }
}

// ------------------------------------------------------------------ docstrings

fn ast_of<'a>(req: &Request<'a>, cls: &Class) -> Option<(std::sync::Arc<ruff_python_ast::ModModule>, Module)> {
    let handle = Handle::new(cls.module_name(), cls.module_path().dupe(), req.handle.sys_info().dupe());
    Some((req.tx.get_ast(&handle)?, req.tx.get_module_info(&handle)?))
}

/// A function's docstring: from its own module, or — when it is defined in
/// a `.pyi` whose body is `...` — from the same-named `def` in the runtime
/// `.py` beside it. The treesitter resolver's "stub bodies are `...`; the
/// runtime docstring rides along", carried forward.
fn docstring_of_def(req: &Request<'_>, handle: &Handle, name: &str, name_range: TextRange) -> Option<String> {
    if let Some(ast) = req.tx.get_ast(handle)
        && let Some(body) = find_body(&ast.body, name_range)
        && let Some(d) = docstring_of_body(body)
    {
        return Some(d);
    }
    let path = handle.path().as_path();
    if path.extension().and_then(|e| e.to_str()) == Some("pyi") {
        let runtime = path.with_extension("py");
        let text = std::fs::read_to_string(&runtime).ok()?;
        let ast = pyrefly_python::ast::Ast::parse(&text, ruff_python_ast::PySourceType::Python).0;
        let body = find_body_by_name(&ast.body, name)?;
        return docstring_of_body(body);
    }
    None
}

/// The docstring of the `def` or `class` whose NAME sits at `name_range`,
/// in the request's own module.
fn docstring_at(req: &Request<'_>, name_range: TextRange) -> Option<String> {
    let ast = req.tx.get_ast(req.handle)?;
    let body = find_body(&ast.body, name_range)?;
    docstring_of_body(body)
}

/// Quotes stripped and following lines dedented, as `docstring_of` did.
fn docstring_of_body(body: &[Stmt]) -> Option<String> {
    let first = body.first()?;
    let Stmt::Expr(e) = first else { return None };
    let Expr::StringLiteral(s) = &*e.value else { return None };
    let raw = s.value.to_str();
    let mut lines: Vec<&str> = raw.lines().collect();
    let indent = lines.iter().skip(1).filter(|l| !l.trim().is_empty()).map(|l| l.len() - l.trim_start().len()).min().unwrap_or(0);
    let mut out: Vec<String> = Vec::new();
    for (i, l) in lines.iter_mut().enumerate() {
        out.push(if i == 0 { l.trim().to_owned() } else { l.get(indent..).unwrap_or("").to_owned() });
    }
    let joined = out.join("\n").trim().to_owned();
    (!joined.is_empty()).then_some(joined)
}

/// The body of the last top-level or nested `def` called `name` (the
/// runtime module behind a stub; the last one wins, as an overload
/// implementation would).
fn find_body_by_name<'a>(body: &'a [Stmt], name: &str) -> Option<&'a [Stmt]> {
    let mut found = None;
    for stmt in body {
        match stmt {
            Stmt::FunctionDef(f) if f.name.as_str() == name => found = Some(f.body.as_slice()),
            Stmt::ClassDef(c) => {
                if let Some(b) = find_body_by_name(&c.body, name) {
                    found = Some(b);
                }
            }
            _ => {}
        }
    }
    found
}

/// The body of the `def`/`class` whose name is at `name_range`.
fn find_body(body: &[Stmt], name_range: TextRange) -> Option<&[Stmt]> {
    for stmt in body {
        match stmt {
            Stmt::FunctionDef(f) if f.name.range() == name_range => return Some(&f.body),
            Stmt::ClassDef(c) if c.name.range() == name_range => return Some(&c.body),
            Stmt::FunctionDef(f) => {
                if let Some(b) = find_body(&f.body, name_range) {
                    return Some(b);
                }
            }
            Stmt::ClassDef(c) => {
                if let Some(b) = find_body(&c.body, name_range) {
                    return Some(b);
                }
            }
            _ => {}
        }
    }
    None
}
