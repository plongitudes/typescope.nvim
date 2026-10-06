//! What is under the cursor, as a Scope (design/oracle.md §4): a function
//! (its params and return are the roots), a class (its shape), a declaration
//! (the symbol drawn as a root row with its type nested), a constructor (a
//! class under a call: what it takes, then what it makes), or `empty` — a
//! symbol that was understood and has nothing to draw, which the plugin
//! reports on the message line where silence would look like a miss.

use dupe::Dupe;
use pyrefly::state::lsp::FindPreference;
use pyrefly::state::state::Transaction;
use pyrefly_build::handle::Handle;
use pyrefly_python::module::Module;
use pyrefly_python::symbol_kind::SymbolKind;
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
    /// An expansion's target path (see `StructureParams::expand`).
    pub expand: Option<Vec<String>>,
}

pub fn build(req: &Request<'_>, ty: &Type) -> Option<Scope> {
    let walker = Walker {
        tx: req.tx,
        handle: req.handle,
        members: req.members,
        top: req.depth,
        pierce: req.expand.clone(),
        path: std::cell::RefCell::new(Vec::new()),
    };
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
    // pyrefly's own definition first, as class_docstring does: it reaches the
    // runtime module behind one of pyrefly's bundled third-party stubs, which
    // has no `.py` beside it for our sibling search to find (`requests.get`).
    // Attribute: that is how pyrefly reports `get` reached through a module.
    // The sibling search stays as the fallback for a cursor that is not on
    // the function's name (`f = requests.get; f(`).
    let kinds = [SymbolKind::Function, SymbolKind::Method, SymbolKind::Attribute];
    let docstring = definition_docstring(req, &kinds).or_else(|| {
        match (&node.def_handle, node.def_range) {
            (Some(handle), Some(range)) => docstring_of_def(req, handle, &name, range),
            _ => None,
        }
    });

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
    let docstring = class_docstring(req, cls);
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
///
/// The parameters are the constructor Python runs: the first `__init__` along
/// the MRO, or one a construct synthesizes from the class's fields. Where it
/// comes from decides how it is drawn (typescope.nvim-pmy):
/// - dataclass, pydantic, NamedTuple, TypedDict: the checker's constructor at
///   the call says which parameters exist, in what order and how they are
///   passed (it leaves out `init=False`, keeps `InitVar`, puts a base class's
///   fields first). Each is drawn as the field it was made from, when one has
///   its name: the declared type (pyrefly types a pydantic field in
///   validation mode, `LaxInt`), the source default, the field's structure.
/// - a written `__init__`, on the class or inherited, stdlib or not: drawn as
///   that function, an overload set as groups. This used to go through the
///   member cut, which treats anything from the bundled typeshed as
///   machinery and so dropped `SMTP`'s own constructor.
/// - neither (a plain class, an enum): the checker's constructor. For a plain
///   class that is `object`'s, which takes nothing: annotated class
///   attributes are not parameters, and `Plain(x=1)` is a TypeError.
fn constructor_scope(req: &Request<'_>, walker: &Walker<'_>, cls: &Class, ty: &Type) -> Scope {
    let name = cls.name().as_str().to_owned();
    let instance = walker.node(&name, "return", ty, req.depth);
    let docstring = class_docstring(req, cls);
    let mut made = instance.clone();
    made.name = "returns".to_owned();
    made.kind = "return".to_owned();

    let synthesized = matches!(instance.ty.category.as_str(), "dataclass" | "pydantic" | "typeddict" | "namedtuple");
    let written_init = if synthesized || instance.ty.category == "enum" {
        None
    } else {
        req.tx
            .attributes_of_type(req.handle, ty.clone())
            .unwrap_or_default()
            .into_iter()
            .find(|a| a.name.as_str() == "__init__")
            .and_then(|a| a.ty)
    };
    let ctor = match written_init {
        Some(init_ty) => walker.node("__init__", "function", &init_ty, req.depth),
        None => match checked_constructor(req) {
            Some(c) => {
                let mut node = walker.callable_node("__init__", "function", &c, req.depth);
                if synthesized {
                    draw_as_fields(&mut node, &instance);
                    // pydantic's own `__init__(**data)` when the checker
                    // didn't synthesize one (no pydantic it recognises):
                    // nothing typed is left, and the fields say more
                    if !node.children.iter().any(|c| c.kind == "param") {
                        node = fields_as_params(&instance);
                    }
                }
                node
            }
            None => fields_as_params(&instance),
        },
    };

    if !ctor.children.is_empty() && ctor.children.iter().all(|c| c.kind == "overload") {
        // an overloaded `__init__` (`dict`, `subprocess.Popen`): one group per
        // signature, each returning the instance rather than `__init__`'s None
        let n = ctor.children.len();
        let mut roots = Vec::new();
        let mut headers = Vec::new();
        for (i, mut g) in ctor.children.into_iter().enumerate() {
            g.name = name.clone();
            g.badge = Some(format!("[{}/{}]", i + 1, n));
            g.ty.display = format!("({})", g.shape.join(", "));
            g.children.retain(|c| c.kind != "return");
            g.children.push(made.clone());
            headers.push(format!("{name}({}) -> {name}", g.shape.join(", ")));
            roots.push(g);
        }
        return Scope { scope: "constructor".to_owned(), header: headers.first().cloned(), docstring, headers: Some(headers), overloads: Some(n), roots, reason: None };
    }

    let header = format!("{name}({}) -> {name}", ctor.shape.join(", "));
    let mut roots: Vec<Node> = ctor.children.into_iter().filter(|c| c.kind == "param").collect();
    roots.push(made);
    Scope { scope: "constructor".to_owned(), header: Some(header), docstring, headers: None, overloads: None, roots, reason: None }
}

/// The constructor the checker resolved at the call: pyrefly types the
/// callee of `Recipe(...)` as the signature it checks the arguments against,
/// synthesized ones included.
fn checked_constructor(req: &Request<'_>) -> Option<pyrefly_types::callable::Callable> {
    match req.tx.get_type_at(req.handle, req.cursor.range.start())? {
        Type::Callable(c) => Some(*c),
        Type::Forall(fa) => match fa.body {
            Forallable::Callable(c) => Some(c),
            _ => None,
        },
        _ => None,
    }
}

/// A synthesized constructor's parameters drawn as the fields they were made
/// from, matched by name. The checker keeps the list and how each is passed;
/// a parameter with no field of its name (an `InitVar`, a pydantic alias)
/// stays as the checker typed it. The `**` pydantic adds for extra keys is
/// dropped: it is untyped and says nothing about the model.
fn draw_as_fields(ctor: &mut Node, instance: &Node) {
    for p in ctor.children.iter_mut().filter(|c| c.kind == "param") {
        let Some(field) = instance.children.iter().find(|f| f.kind == "field" && f.name == p.name) else {
            continue;
        };
        let mut drawn = field.clone();
        drawn.kind = "param".to_owned();
        drawn.origin = None;
        drawn.pass_mode = p.pass_mode.take();
        if drawn.default.is_none() {
            drawn.default = p.default.take();
        }
        // an `InitVar` is a pseudo-field the instance can't type; the
        // checker's parameter type is the real one
        if drawn.ty.display == "?" {
            drawn.ty = p.ty.clone();
            drawn.children = std::mem::take(&mut p.children);
        }
        *p = drawn;
    }
    let untyped_extra = |c: &Node| c.kind == "param" && c.name.starts_with("**") && c.ty.display == "Any";
    let dropped: Vec<String> = ctor.children.iter().filter(|c| untyped_extra(c)).map(|c| c.name.clone()).collect();
    ctor.children.retain(|c| !untyped_extra(c));
    ctor.shape.retain(|t| !dropped.contains(t));
}

/// No constructor the checker could name: the fields stand in, as they did
/// before the checker was asked.
fn fields_as_params(instance: &Node) -> Node {
    let mut node = instance.clone();
    node.children = Vec::new();
    node.shape = Vec::new();
    for field in instance.children.iter().filter(|c| c.kind == "field") {
        let mut p = field.clone();
        p.kind = "param".to_owned();
        p.origin = None;
        node.shape.push(if p.default.is_some() { format!("{}=…", p.name) } else { p.name.clone() });
        node.children.push(p);
    }
    node
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
    crate::walk::module_source(req.tx, &handle)
}

/// A function's docstring: from its own module, or — when it is defined in
/// a `.pyi` whose body is `...` — from the same-named `def` in the runtime
/// `.py` beside it. The treesitter resolver's "stub bodies are `...`; the
/// runtime docstring rides along", carried forward.
fn docstring_of_def(req: &Request<'_>, handle: &Handle, name: &str, name_range: TextRange) -> Option<String> {
    if let Some((ast, _)) = crate::walk::module_source(req.tx, handle)
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
/// A class's docstring, found the way pyrefly's hover finds one: follow the
/// name under the cursor to its class definition, preferring the runtime
/// `.py` over a stub (whose body is usually `...`), then the stub. When the
/// cursor is not on the class's name (`x` in `x = Widget`), the class's own
/// module is read at the class's range.
fn class_docstring(req: &Request<'_>, cls: &Class) -> Option<String> {
    definition_docstring(req, &[SymbolKind::Class]).or_else(|| {
        let (ast, _) = ast_of(req, cls)?;
        docstring_of_body(find_body(&ast.body, cls.range())?)
    })
}

/// The docstring pyrefly's hover would show for the name under the cursor,
/// when that name is defined as one of `kinds`: follow it to its definition,
/// preferring the runtime `.py` over a stub (whose body is usually `...`),
/// then the stub. None when the cursor is not on such a name.
fn definition_docstring(req: &Request<'_>, kinds: &[SymbolKind]) -> Option<String> {
    let from_definition = |prefer_pyi: bool| {
        let mut pref = FindPreference::default();
        pref.prefer_pyi = prefer_pyi;
        // `Recipe(`: the class's docstring, not `__init__`'s
        pref.resolve_call_dunders = false;
        let items = req.tx.find_definition(req.handle, req.cursor.range.start(), pref).ok()?;
        items.into_iter().find_map(|item| {
            if !item.metadata.symbol_kind().is_some_and(|k| kinds.contains(&k)) {
                return None;
            }
            // the range is the docstring statement; our own formatting, so
            // class and function docstrings read alike
            let text = item.module.code_at(item.docstring_range?);
            let ast = pyrefly_python::ast::Ast::parse(text, ruff_python_ast::PySourceType::Python).0;
            docstring_of_body(&ast.body)
        })
    };
    from_definition(false).or_else(|| from_definition(true))
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
