//! The structure walk: a pyrefly `Type` at a position → the JSON tree the
//! plugin renders (design/oracle.md §4). Port of the spike-3 probe's
//! `describe`, with the presentation policy factored into `policy.rs`.

use std::path::Path;

use dupe::Dupe;
use pyrefly::alt::attr::AttrDefinition;
use pyrefly::state::state::Transaction;
use pyrefly_build::handle::Handle;
use pyrefly_python::module_path::ModulePath;
use pyrefly_types::callable::Param;
use pyrefly_types::callable::Params;
use pyrefly_types::callable::Required;
use pyrefly_types::class::Class;
use pyrefly_types::class::ClassType;
use pyrefly_types::class::PrecomputedTParams;
use pyrefly_types::function::Function;
use pyrefly_types::literal::Lit;
use pyrefly_types::types::BoundMethodType;
use pyrefly_types::types::Forallable;
use pyrefly_types::types::OverloadType;
use pyrefly_types::types::TArgs;
use pyrefly_types::types::Type;
use ruff_python_ast::Expr;
use ruff_python_ast::Stmt;
use ruff_source_file::PositionEncoding;
use ruff_text_size::Ranged;
use ruff_text_size::TextRange;
use serde::Serialize;

use crate::policy;
use crate::policy::Category;
use crate::policy::MemberKind;
use crate::protocol::Members;

// ------------------------------------------------------------------ JSON

#[derive(Debug, Clone, Serialize)]
pub struct Location {
    pub uri: String,
    pub line: u32,
    pub character: u32,
}

#[derive(Debug, Clone, Serialize)]
pub struct TypeInfo {
    pub display: String,
    pub category: String,
}

/// `typescope.Node` on the wire. Fields the plugin owns (`id`, `state`,
/// `example`, `active`) never cross.
#[derive(Debug, Clone, Serialize)]
pub struct Node {
    pub name: String,
    pub kind: String,
    #[serde(rename = "type")]
    pub ty: TypeInfo,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub badge: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pass_mode: Option<String>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub inferred: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub location: Option<Location>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<Node>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub expandable: bool,
}

impl Node {
    fn leaf(name: impl Into<String>, kind: &str, display: String, category: &str) -> Self {
        Node {
            name: name.into(),
            kind: kind.to_owned(),
            ty: TypeInfo { display, category: category.to_owned() },
            default: None,
            badge: None,
            origin: None,
            pass_mode: None,
            inferred: false,
            location: None,
            children: Vec::new(),
            expandable: false,
        }
    }
}

// ------------------------------------------------------------------ walker

pub struct Walker<'a> {
    pub tx: &'a Transaction<'a>,
    /// The handle the request came in on; the solver is asked from here.
    pub handle: &'a Handle,
    pub members: Members,
}

impl<'a> Walker<'a> {
    /// The node for `ty` presented under `name`/`kind`, nested `depth` levels.
    pub fn node(&self, name: &str, kind: &str, ty: &Type, depth: u32) -> Node {
        let ty = unwrap_type(ty);
        match ty {
            Type::ClassType(_) | Type::ClassDef(_) | Type::TypedDict(_) | Type::SelfType(_) => {
                self.class_node(name, kind, ty, depth)
            }
            Type::Union(u) => {
                let mut node = Node::leaf(name, kind, display(ty), "union");
                if depth > 0 {
                    for member in u.members.iter() {
                        if member.is_none() {
                            continue; // `| None` is vocabulary in the display, not a variant to open
                        }
                        let child = self.node(&display(member), "variant", member, depth - 1);
                        if !child.children.is_empty() || child.expandable {
                            node.children.push(child);
                        }
                    }
                }
                node
            }
            Type::Function(f) => self.function_node(name, kind, f, None, depth),
            Type::Forall(fa) => match &fa.body {
                Forallable::Function(f) => self.function_node(name, kind, f, None, depth),
                _ => Node::leaf(name, kind, display(ty), leaf_category(ty)),
            },
            Type::BoundMethod(bm) => match &bm.func {
                BoundMethodType::Function(f) => self.function_node(name, kind, f, Some(&bm.obj), depth),
                BoundMethodType::Forall(fa) => self.function_node(name, kind, &fa.body, Some(&bm.obj), depth),
                BoundMethodType::Overload(o) => self.overload_node(name, kind, o.signatures.iter(), Some(&bm.obj), depth),
            },
            Type::Overload(o) => self.overload_node(name, kind, o.signatures.iter(), None, depth),
            other => Node::leaf(name, kind, display(other), leaf_category(other)),
        }
    }

    /// Bare params + returns for a function, `self`/`cls` dropped when bound
    /// or when the function is a method by position.
    pub fn function_node(&self, name: &str, kind: &str, f: &Function, bound_to: Option<&Type>, depth: u32) -> Node {
        let mut node = Node::leaf(name, kind, display_function(f), "function");
        let def = f.metadata.kind.as_func_def_id();
        let facts = def.map(|d| self.def_facts(d)).unwrap_or_default();
        node.location = facts.location;
        let flags = &f.metadata.flags;
        // the receiver is dropped by POSITION: a method's first parameter
        // whatever it is called, never a staticmethod's (the resolver's
        // binds_receiver rule, carried forward)
        let receiver_bound = bound_to.is_some() || (def.is_some_and(|d| d.cls.is_some()) && !flags.is_staticmethod);
        if let Params::List(list) = &f.signature.params {
            for (i, p) in list.items().iter().enumerate() {
                if i == 0 && receiver_bound {
                    continue;
                }
                match p {
                    Param::PosOnly(pname, ty, req) => {
                        let n = pname.as_ref().map(|n| n.as_str().to_owned()).unwrap_or_default();
                        let mut c = self.node(&n, "param", ty, depth);
                        c.pass_mode = Some("/".to_owned());
                        c.default = default_text(req);
                        node.children.push(c);
                    }
                    Param::Pos(pname, ty, req) => {
                        let mut c = self.node(pname.as_str(), "param", ty, depth);
                        c.default = default_text(req);
                        node.children.push(c);
                    }
                    Param::Varargs(pname, ty) => {
                        let n = format!("*{}", pname.as_ref().map(|n| n.as_str()).unwrap_or(""));
                        node.children.push(self.node(&n, "param", ty, depth));
                    }
                    Param::KwOnly(pname, ty, req) => {
                        let mut c = self.node(pname.as_str(), "param", ty, depth);
                        c.pass_mode = Some("*".to_owned());
                        c.default = default_text(req);
                        node.children.push(c);
                    }
                    Param::Kwargs(pname, ty) => {
                        let n = format!("**{}", pname.as_ref().map(|n| n.as_str()).unwrap_or(""));
                        node.children.push(self.node(&n, "param", ty, depth));
                    }
                }
            }
        }
                let ret = &f.signature.ret;
        let mut r = self.node("returns", "return", ret, depth);
        r.inferred = !facts.return_annotated;
        node.children.push(r);
        node
    }

    /// What only the `def` site knows: where it is, and whether the return
    /// was annotated (pyrefly infers returns and carries no flag for it).
    fn def_facts(&self, def: &pyrefly_types::function::FuncDefId) -> DefFacts {
        let module = def.qname.module();
        let handle = Handle::new(def.qname.module_name(), module.path().dupe(), self.handle.sys_info().dupe());
        let range = def.qname.range();
        let mut facts = DefFacts { location: None, return_annotated: true };
        if let Some(uri) = uri_of(module.path()) {
            let loc = module.lined_buffer().line_index().source_location(range.start(), module.contents(), PositionEncoding::Utf16);
            facts.location = Some(Location {
                uri,
                line: loc.line.to_zero_indexed() as u32,
                character: loc.character_offset.to_zero_indexed() as u32,
            });
        }
        if let Some(ast) = self.tx.get_ast(&handle)
            && let Some(fd) = find_function_def(&ast.body, range)
        {
            facts.return_annotated = fd.returns.is_some();
        }
        facts
    }

    fn overload_node<'s>(
        &self,
        name: &str,
        kind: &str,
        sigs: impl Iterator<Item = &'s OverloadType>,
        bound_to: Option<&Type>,
        depth: u32,
    ) -> Node {
        let mut node = Node::leaf(name, kind, "overloaded".to_owned(), "function");
        for (i, sig) in sigs.enumerate() {
            let f = match sig {
                OverloadType::Function(f) => f,
                OverloadType::Forall(fa) => &fa.body,
            };
            let mut g = self.function_node(name, "overload", f, bound_to, depth);
            g.badge = Some(format!("[{}]", i + 1));
            node.children.push(g);
        }
        node
    }

    /// A class, an instance, a TypedDict: the members the policy admits.
    fn class_node(&self, name: &str, kind: &str, ty: &Type, depth: u32) -> Node {
        let (cls, query_ty) = match ty {
            Type::ClassType(ct) => (ct.class_object().dupe(), ty.clone()),
            Type::SelfType(ct) => (ct.class_object().dupe(), Type::ClassType(ct.clone())),
            Type::TypedDict(pyrefly_types::typed_dict::TypedDict::TypedDict(td)) => (td.class_object().dupe(), ty.clone()),
            // an anonymous TypedDict is how pyrefly types a dict literal:
            // `{"k": 1}` displays as `dict[str, int]` and is vocabulary, not shape
            Type::TypedDict(_) => return Node::leaf(name, kind, display(ty), "builtin"),
            Type::ClassDef(c) => (c.dupe(), instance_of(c).unwrap_or_else(|| ty.clone())),
            _ => unreachable!(),
        };
        if policy::is_terminal_class(&cls) {
            let mut leaf = Node::leaf(name, kind, display(ty), "builtin");
            leaf.location = class_location(&cls);
            return leaf;
        }
        let attrs = self.tx.attributes_of_type(self.handle, query_ty).unwrap_or_default();
        if std::env::var_os("TYPESCOPE_DEBUG_ATTRS").is_some() {
            for a in &attrs {
                let owner = match &a.definition {
                    AttrDefinition::FullyResolved { cls, .. } => format!("{}.{}", cls.module_name(), cls.name()),
                    other => format!("{other:?}").chars().take(40).collect(),
                };
                eprintln!("[attr] {}  owner={owner}  ty={}", a.name, a.ty.as_ref().map(|t| t.to_string()).unwrap_or_default());
            }
        }
        let policy_attrs: Vec<policy::Attr<'_>> = attrs
            .iter()
            .map(|a| policy::Attr {
                name: a.name.as_str(),
                ty: a.ty.as_ref(),
                defined_on: match &a.definition {
                    AttrDefinition::FullyResolved { cls, .. } => Some(cls),
                    _ => None,
                },
            })
            .collect();
        let mut category = policy::classify(&cls, &policy_attrs);
        let class_facts = self.class_def_facts(&cls);
        if category == Category::Class
            && let Some(c) = class_facts.decorator_category
        {
            category = c;
        }
        let mut node = Node::leaf(name, kind, display(ty), category.as_str());
        node.location = class_location(&cls);
        if depth == 0 {
            node.expandable = true;
            return node;
        }

        let mut methods = Vec::new();
        for a in &attrs {
            if policy::is_hidden_name(a.name.as_str()) {
                continue;
            }
            let owner = match &a.definition {
                AttrDefinition::FullyResolved { cls, .. } => Some(cls),
                _ => None,
            };
            if let Some(o) = owner
                && policy::is_cut_base(o)
            {
                continue;
            }
            let mut mk = policy::kind_of(a.ty.as_ref());
            if category == Category::Enum && mk != MemberKind::EnumMember {
                continue; // an enum's shape is its members; `name`/`value` are cut with Enum
            }
            if matches!(a.ty.as_ref(), Some(Type::ClassDef(_))) {
                continue; // a nested class (pydantic's `class Config`) is not data
            }
            let mut child = match (&a.ty, mk) {
                (Some(t), MemberKind::Method) => self.node(a.name.as_str(), "method", t, 0),
                (Some(t), MemberKind::EnumMember) => {
                    // `· RED  Color = 1`: the member's class as its type, the
                    // source value as its default, like any other field row
                    let mut c = Node::leaf(a.name.as_str(), "enum_member", display(t), "enum");
                    if let Type::Literal(lit) = t
                        && let Lit::Enum(e) = &lit.value
                    {
                        c.ty.display = e.class.name().as_str().to_owned();
                    }
                    c
                }
                (Some(t), _) => self.node(a.name.as_str(), "field", t, depth - 1),
                (None, _) => Node::leaf(a.name.as_str(), "field", "?".to_owned(), "unresolved"),
            };
            if let (Some(o), Some(range)) = (
                owner,
                match &a.definition {
                    AttrDefinition::FullyResolved { range, .. } => Some(*range),
                    _ => None,
                },
            ) {
                child.location = location_in(o, range);
                if o.name() != cls.name() {
                    child.origin = Some(o.name().as_str().to_owned());
                }
                let decl = self.declaration_facts(o, a.name.as_str(), range);
                if mk == MemberKind::Field && decl.property {
                    mk = MemberKind::Property;
                }
                if category == Category::TypedDict {
                    // explicit wrappers win; otherwise total=False makes every
                    // key NotRequired (the resolver's badge rule, carried forward)
                    child.badge = decl.wrapper.clone().or_else(|| {
                        (o.name() == cls.name() && !class_facts.total).then(|| "NotRequired".to_owned())
                    });
                }
                child.inferred = mk == MemberKind::Field && !decl.annotated;
                if child.default.is_none() {
                    child.default = decl.literal_default;
                }
                if mk == MemberKind::EnumMember {
                    child.default = decl.value_text;
                }
            }
            child.kind = mk.as_str().to_owned();
            if mk == MemberKind::Method {
                methods.push(child);
            } else {
                node.children.push(child);
            }
        }
        if !methods.is_empty() {
            match (self.members, category) {
                // a Protocol IS its methods; data-first everywhere else
                (Members::All, _) | (_, Category::Protocol) => node.children.extend(methods),
                (Members::Data, _) => {
                    let mut group = Node::leaf("methods", "group", format!("({})", methods.len()), "group");
                    group.children = methods;
                    node.children.push(group);
                }
            }
        }
        node
    }

    /// What only the declaration site knows: annotated or not, a property
    /// getter or a plain member, and a literal initializer's source text.
    fn declaration_facts(&self, owner: &Class, name: &str, range: TextRange) -> DeclFacts {
        let handle = handle_for(self.handle, owner);
        let mut facts = DeclFacts::default();
        let fields = self.tx.get_class_fields(&handle, owner);
        facts.annotated = fields
            .as_ref()
            .map(|f| f.is_field_annotated(&ruff_python_ast::name::Name::new(name)))
            .unwrap_or(true);
        if let Some(Type::Function(f)) = self.tx.get_type_at(&handle, range.start()) {
            facts.property = f.metadata.flags.property_metadata.is_some();
        }
        // the initializer: the RHS of the declaring statement, kept only when
        // it is a literal (a name or a call is noise, as the resolver decided)
        if let (Some(ast), Some(module)) = (self.tx.get_ast(&handle), self.tx.get_module_info(&handle)) {
            let text = module.contents();
            if let Some((value, annotation)) = find_declaration(&ast.body, range) {
                if let Some(value) = value {
                    let raw = &text[value.range()];
                    facts.value_text = Some(raw.to_owned());
                    facts.literal_default = literal_default(value, text);
                }
                if let Some(ann) = annotation
                    && let Expr::Subscript(sub) = ann
                {
                    let head = match &*sub.value {
                        Expr::Name(n) => n.id.as_str(),
                        Expr::Attribute(a) => a.attr.as_str(),
                        _ => "",
                    };
                    if head == "Required" || head == "NotRequired" {
                        facts.wrapper = Some(head.to_owned());
                    }
                }
            }
        }
        facts
    }

    /// What the `class` statement itself says: its decorators and, for a
    /// TypedDict, `total=`.
    fn class_def_facts(&self, cls: &Class) -> ClassDefFacts {
        let handle = handle_for(self.handle, cls);
        let mut facts = ClassDefFacts { decorator_category: None, total: true };
        if let (Some(ast), Some(module)) = (self.tx.get_ast(&handle), self.tx.get_module_info(&handle))
            && let Some(cd) = find_class_def(&ast.body, cls.range())
        {
            let text = module.contents();
            for d in &cd.decorator_list {
                if let Some(c) = policy::category_from_decorator(&text[d.expression.range()]) {
                    facts.decorator_category = Some(c);
                }
            }
            if let Some(args) = &cd.arguments {
                for kw in args.keywords.iter() {
                    if kw.arg.as_ref().is_some_and(|a| a.as_str() == "total")
                        && let Expr::BooleanLiteral(b) = &kw.value
                    {
                        facts.total = b.value;
                    }
                }
            }
        }
        facts
    }
}

struct DefFacts {
    location: Option<Location>,
    return_annotated: bool,
}

impl Default for DefFacts {
    fn default() -> Self {
        DefFacts { location: None, return_annotated: true }
    }
}

#[derive(Default)]
struct DeclFacts {
    annotated: bool,
    property: bool,
    literal_default: Option<String>,
    value_text: Option<String>,
    /// `Required[...]` / `NotRequired[...]` around the annotation
    wrapper: Option<String>,
}

struct ClassDefFacts {
    decorator_category: Option<Category>,
    total: bool,
}

// ------------------------------------------------------------------ cursor

/// Is `offset` on an identifier a person would hover — a name, an
/// attribute, a `def`/`class` name, a parameter? Everything else (a string,
/// a number, an operator, whitespace) is not TypeScope's business and the
/// request answers `null`, which is what lets K fall through.
pub fn identifier_at(body: &[Stmt], offset: ruff_text_size::TextSize) -> bool {
    use ruff_python_ast::visitor::Visitor;
    struct Finder {
        offset: ruff_text_size::TextSize,
        hit: bool,
    }
    impl<'a> Visitor<'a> for Finder {
        fn visit_stmt(&mut self, stmt: &'a Stmt) {
            if self.hit || !stmt.range().contains_inclusive(self.offset) {
                return;
            }
            match stmt {
                Stmt::FunctionDef(f) if f.name.range().contains_inclusive(self.offset) => self.hit = true,
                Stmt::ClassDef(c) if c.name.range().contains_inclusive(self.offset) => self.hit = true,
                _ => ruff_python_ast::visitor::walk_stmt(self, stmt),
            }
        }
        fn visit_expr(&mut self, expr: &'a Expr) {
            if self.hit || !expr.range().contains_inclusive(self.offset) {
                return;
            }
            match expr {
                Expr::Name(_) => self.hit = true,
                Expr::Attribute(a) if a.attr.range().contains_inclusive(self.offset) => self.hit = true,
                _ => ruff_python_ast::visitor::walk_expr(self, expr),
            }
        }
        fn visit_parameter(&mut self, p: &'a ruff_python_ast::Parameter) {
            if p.name.range().contains_inclusive(self.offset) {
                self.hit = true;
            } else {
                ruff_python_ast::visitor::walk_parameter(self, p);
            }
        }
    }
    let mut f = Finder { offset, hit: false };
    ruff_python_ast::visitor::walk_body(&mut f, body);
    f.hit
}

// ------------------------------------------------------------------ helpers

/// See through the wrappers that carry no shape of their own.
fn unwrap_type(ty: &Type) -> &Type {
    match ty {
        Type::Type(inner) => inner,
        Type::Annotated(inner, _) => inner,
        _ => ty,
    }
}

fn display(ty: &Type) -> String {
    ty.to_string()
}

fn display_function(f: &Function) -> String {
    Type::Function(Box::new(f.clone())).to_string()
}

fn leaf_category(ty: &Type) -> &'static str {
    match ty {
        Type::Any(_) => "unresolved",
        Type::Literal(_) | Type::LiteralString(_) => "literal",
        _ => "builtin",
    }
}

fn default_text(req: &Required) -> Option<String> {
    match req {
        Required::Required => None,
        Required::Optional(None) => Some("…".to_owned()),
        Required::Optional(Some(dv)) => Some(dv.display.clone().unwrap_or_else(|| dv.ty.to_string())),
    }
}

/// The instance type of a class object, when it takes no type arguments.
/// A generic class hovered by name keeps its class-object view: inventing
/// arguments would draw a specialization nobody wrote.
fn instance_of(cls: &Class) -> Option<Type> {
    match cls.precomputed_tparams() {
        PrecomputedTParams::NotGeneric => Some(Type::ClassType(ClassType::new(cls.dupe(), TArgs::default()))),
        _ => None,
    }
}

fn handle_for(from: &Handle, cls: &Class) -> Handle {
    Handle::new(cls.module_name(), cls.module_path().dupe(), from.sys_info().dupe())
}

fn uri_of(path: &ModulePath) -> Option<String> {
    let p: &Path = path.as_path();
    p.is_absolute().then(|| format!("file://{}", p.display()))
}

fn class_location(cls: &Class) -> Option<Location> {
    location_in(cls, cls.range())
}

fn location_in(cls: &Class, range: TextRange) -> Option<Location> {
    let uri = uri_of(cls.module_path())?;
    let module = cls.module();
    let text = module.contents();
    let loc = module.lined_buffer().line_index().source_location(range.start(), text, PositionEncoding::Utf16);
    Some(Location {
        uri,
        line: loc.line.to_zero_indexed() as u32,
        character: loc.character_offset.to_zero_indexed() as u32,
    })
}

/// The `def` whose name sits at `name_range`, anywhere in the module.
fn find_function_def(body: &[Stmt], name_range: TextRange) -> Option<&ruff_python_ast::StmtFunctionDef> {
    for stmt in body {
        match stmt {
            Stmt::FunctionDef(f) if f.name.range() == name_range => return Some(f),
            Stmt::FunctionDef(f) => {
                if let Some(x) = find_function_def(&f.body, name_range) {
                    return Some(x);
                }
            }
            Stmt::ClassDef(c) => {
                if let Some(x) = find_function_def(&c.body, name_range) {
                    return Some(x);
                }
            }
            _ => {}
        }
    }
    None
}

/// The `class` whose name sits at `name_range`, anywhere in the module.
fn find_class_def(body: &[Stmt], name_range: TextRange) -> Option<&ruff_python_ast::StmtClassDef> {
    for stmt in body {
        match stmt {
            Stmt::ClassDef(c) if c.name.range() == name_range => return Some(c),
            Stmt::ClassDef(c) => {
                if let Some(x) = find_class_def(&c.body, name_range) {
                    return Some(x);
                }
            }
            Stmt::FunctionDef(f) => {
                if let Some(x) = find_class_def(&f.body, name_range) {
                    return Some(x);
                }
            }
            _ => {}
        }
    }
    None
}

/// Does this assignment target declare the member whose name sits at
/// `decl`? A class-level `x` is the whole target; `self.x` in a method is
/// declared by its attribute name, which is what the solver reports.
fn target_declares(t: &Expr, decl: TextRange) -> bool {
    match t {
        Expr::Attribute(a) => a.attr.range() == decl || a.range() == decl,
        other => other.range() == decl,
    }
}

/// The value and annotation of the statement that declares `decl`:
/// `x: T = value`, `x = value`, or `self.x: T = value` inside a method.
fn find_declaration(body: &[Stmt], decl: TextRange) -> Option<(Option<&Expr>, Option<&Expr>)> {
    for stmt in body {
        match stmt {
            Stmt::AnnAssign(a) if target_declares(&a.target, decl) => {
                return Some((a.value.as_deref(), Some(&a.annotation)));
            }
            Stmt::Assign(a) if a.targets.iter().any(|t| target_declares(t, decl)) => {
                return Some((Some(&a.value), None));
            }
            other => {
                for body in nested_bodies(other) {
                    if let Some(v) = find_declaration(body, decl) {
                        return Some(v);
                    }
                }
            }
        }
    }
    None
}

/// The statement lists a compound statement owns, so a declaration inside
/// an `if` in `__init__` is found the way pyrefly found the field.
fn nested_bodies(stmt: &Stmt) -> Vec<&[Stmt]> {
    match stmt {
        Stmt::ClassDef(c) => vec![&c.body],
        Stmt::FunctionDef(f) => vec![&f.body],
        Stmt::If(i) => {
            let mut v: Vec<&[Stmt]> = vec![&i.body];
            v.extend(i.elif_else_clauses.iter().map(|c| c.body.as_slice()));
            v
        }
        Stmt::For(f) => vec![&f.body, &f.orelse],
        Stmt::While(w) => vec![&w.body, &w.orelse],
        Stmt::With(w) => vec![&w.body],
        Stmt::Try(t) => {
            let mut v: Vec<&[Stmt]> = vec![&t.body, &t.orelse, &t.finalbody];
            v.extend(t.handlers.iter().filter_map(|h| h.as_except_handler().map(|e| e.body.as_slice())));
            v
        }
        _ => vec![],
    }
}

/// A literal initializer's source text, unwrapping `field(default=…)` and
/// `Field(default=…)` the way the resolver's `unwrap_default` did.
/// `Field(...)` is the required-field sentinel, not a default.
fn literal_default(value: &Expr, text: &str) -> Option<String> {
    let literal = |e: &Expr| -> Option<String> {
        let ok = match e {
            Expr::StringLiteral(_)
            | Expr::BytesLiteral(_)
            | Expr::NumberLiteral(_)
            | Expr::BooleanLiteral(_)
            | Expr::NoneLiteral(_) => true,
            Expr::UnaryOp(u) => matches!(&*u.operand, Expr::NumberLiteral(_)),
            Expr::EllipsisLiteral(_) => return Some("…".to_owned()),
            _ => false,
        };
        ok.then(|| text[e.range()].to_owned())
    };
    match value {
        Expr::Call(call) => {
            let fname = match &*call.func {
                Expr::Name(n) => n.id.as_str(),
                Expr::Attribute(a) => a.attr.as_str(),
                _ => return None,
            };
            if fname != "Field" && fname != "field" {
                return None;
            }
            for kw in call.arguments.keywords.iter() {
                if kw.arg.as_ref().is_some_and(|a| a.as_str() == "default" || a.as_str() == "default_factory") {
                    return literal(&kw.value).or_else(|| Some(text[kw.value.range()].to_owned()));
                }
            }
            match call.arguments.args.first() {
                Some(Expr::EllipsisLiteral(_)) | None => None,
                Some(first) => literal(first),
            }
        }
        other => literal(other),
    }
}
