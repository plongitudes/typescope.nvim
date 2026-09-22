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
    /// On an `expandable` node: the walker's own path to it, which the
    /// plugin sends back unchanged as `expand` to open it. Opaque to the
    /// plugin, so the two sides never have to agree on how paths are named.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<Vec<String>>,
    /// When `type.display` is the annotation the author wrote (an alias
    /// name kept as vocabulary) and the row has no structure of its own,
    /// what the checker resolved it to — the plugin draws it as `≈ T`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolved: Option<String>,
    /// Call-shape tokens of a function node (`a`, `b=…`, `*`, `/`), for the
    /// header line. Never serialized.
    #[serde(skip)]
    pub shape: Vec<String>,
    /// The `def`'s own name and the range of that name in its module, when
    /// the function has a source definition. Never serialized.
    #[serde(skip)]
    pub def_name: Option<String>,
    #[serde(skip)]
    pub def_range: Option<TextRange>,
    #[serde(skip)]
    pub def_handle: Option<Handle>,
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
            path: None,
            resolved: None,
            shape: Vec::new(),
            def_name: None,
            def_range: None,
            def_handle: None,
        }
    }
}

// ------------------------------------------------------------------ walker

pub struct Walker<'a> {
    pub tx: &'a Transaction<'a>,
    /// The handle the request came in on; the solver is asked from here.
    pub handle: &'a Handle,
    pub members: Members,
    /// The request's depth: a class walked with less than this is NESTED
    /// (the type of a member or an argument), not what the cursor is on.
    pub top: u32,
    /// The path of a node being expanded, as this walker emitted it in that
    /// node's `path`; nested third-party classes on it open instead of
    /// staying expandable.
    pub pierce: Option<Vec<String>>,
    /// Names from the walk's first node to the node being built, including
    /// the synthetic ones (`function`, `__init__`) that never become rows.
    pub path: std::cell::RefCell<Vec<String>>,
}

impl<'a> Walker<'a> {
    /// The node for `ty` presented under `name`/`kind`, nested `depth` levels.
    pub fn node(&self, name: &str, kind: &str, ty: &Type, depth: u32) -> Node {
        self.path.borrow_mut().push(name.to_owned());
        let built = self.node_inner(name, kind, ty, depth);
        self.path.borrow_mut().pop();
        built
    }

    /// Is the node being built an ancestor of, or itself, the expansion
    /// target?
    fn on_pierce_path(&self) -> bool {
        let path = self.path.borrow();
        self.pierce.as_ref().is_some_and(|p| p.len() >= path.len() && p[..path.len()] == path[..])
    }

    fn node_inner(&self, name: &str, kind: &str, ty: &Type, depth: u32) -> Node {
        let ty = unwrap_type(ty);
        match ty {
            Type::ClassType(_) | Type::ClassDef(_) | Type::TypedDict(_) | Type::SelfType(_) => {
                self.class_node(name, kind, ty, depth)
            }
            Type::Union(u) => {
                // `int | Unknown` is how pyrefly types an unannotated
                // parameter from its default: the known members are the
                // type, the Unknown is the missing annotation, drawn ≈
                let known: Vec<&Type> = u.members.iter().filter(|m| !matches!(m, Type::Any(_))).collect();
                let partial = known.len() < u.members.len();
                // pyrefly's own display groups literals (`Literal['a', 'b']`);
                // only re-spell the union when a member was dropped
                let shown = match known.as_slice() {
                    _ if !partial => display(ty),
                    [] => "Any".to_owned(),
                    [one] => display(one),
                    many => many.iter().map(|m| display(m)).collect::<Vec<_>>().join(" | "),
                };
                let category = if partial && known.len() == 1 { leaf_category(known[0]) } else { "union" };
                let mut node = Node::leaf(name, kind, shown, category);
                node.inferred = partial;
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
            // an unannotated parameter is implicitly Any to Python; pyrefly
            // spells its ignorance `Unknown`, which is not a name a user wrote
            Type::Any(_) => Node::leaf(name, kind, "Any".to_owned(), "builtin"),
            other => Node::leaf(name, kind, display(other), leaf_category(other)),
        }
    }

    /// Bare params + returns for a function, `self`/`cls` dropped when bound
    /// or when the function is a method by position.
    pub fn function_node(&self, name: &str, kind: &str, f: &Function, bound_to: Option<&Type>, depth: u32) -> Node {
        let mut node = Node::leaf(name, kind, display_function(f), "function");
        let def = f.metadata.kind.as_func_def_id();
        let facts = def.map(|d| self.def_facts(d)).unwrap_or_default();
        node.location = facts.location.clone();
        if let Some(d) = def {
            node.def_name = Some(d.qname.id().as_str().to_owned());
            node.def_range = Some(d.qname.range());
            node.def_handle = Some(Handle::new(d.qname.module_name(), d.qname.module().path().dupe(), self.handle.sys_info().dupe()));
        }
        let flags = &f.metadata.flags;
        // the receiver is dropped by POSITION: a method's first parameter
        // whatever it is called, never a staticmethod's (the resolver's
        // binds_receiver rule, carried forward)
        let receiver_bound = bound_to.is_some() || (def.is_some_and(|d| d.cls.is_some()) && !flags.is_staticmethod);
        // shape tokens mirror the resolver's header: names, `name=…` for a
        // default, and the `/` and `*` separators the signature implies
        let mut shape: Vec<String> = Vec::new();
        let mut had_pos_only = false;
        let mut star_written = false;
        if let Params::List(list) = &f.signature.params {
            for (i, p) in list.items().iter().enumerate() {
                if i == 0 && receiver_bound {
                    continue;
                }
                if had_pos_only && !matches!(p, Param::PosOnly(..)) {
                    shape.push("/".to_owned());
                    had_pos_only = false;
                }
                match p {
                    Param::PosOnly(pname, ty, req) => {
                        let n = pname.as_ref().map(|n| n.as_str().to_owned()).unwrap_or_default();
                        let mut c = self.node(&n, "param", ty, depth);
                        keep_written(&mut c, facts.written.get(&n));
                        infer_from_default(&mut c, ty, req);
                        c.pass_mode = Some("/".to_owned());
                        c.default = default_text(req);
                        shape.push(token(&n, c.default.is_some()));
                        had_pos_only = true;
                        node.children.push(c);
                    }
                    Param::Pos(pname, ty, req) => {
                        let mut c = self.node(pname.as_str(), "param", ty, depth);
                        keep_written(&mut c, facts.written.get(pname.as_str()));
                        infer_from_default(&mut c, ty, req);
                        c.default = default_text(req);
                        shape.push(token(pname.as_str(), c.default.is_some()));
                        node.children.push(c);
                    }
                    Param::Varargs(pname, ty) => {
                        let n = format!("*{}", pname.as_ref().map(|n| n.as_str()).unwrap_or(""));
                        shape.push(n.clone());
                        star_written = true;
                        node.children.push(self.node(&n, "param", ty, depth));
                    }
                    Param::KwOnly(pname, ty, req) => {
                        if !star_written {
                            shape.push("*".to_owned());
                            star_written = true;
                        }
                        let mut c = self.node(pname.as_str(), "param", ty, depth);
                        keep_written(&mut c, facts.written.get(pname.as_str()));
                        infer_from_default(&mut c, ty, req);
                        c.pass_mode = Some("*".to_owned());
                        c.default = default_text(req);
                        shape.push(token(pname.as_str(), c.default.is_some()));
                        node.children.push(c);
                    }
                    Param::Kwargs(pname, ty) => {
                        let n = format!("**{}", pname.as_ref().map(|n| n.as_str()).unwrap_or(""));
                        shape.push(n.clone());
                        node.children.push(self.node(&n, "param", ty, depth));
                    }
                }
            }
            if had_pos_only {
                shape.push("/".to_owned());
            }
        }
        node.shape = shape;
        // an `async def` evaluates to Coroutine[_, _, X]; the float says what
        // the author declared, X, the way hover does
        let ret = if facts.is_async { unwrap_coroutine(&f.signature.ret) } else { &f.signature.ret };
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
        let mut facts = DefFacts::default();
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
            facts.is_async = fd.is_async;
            let text = module.contents();
            for p in fd.parameters.iter() {
                if let Some(ann) = p.annotation()
                    && let Some(w) = written_name(self.tx, &handle, ann, text)
                {
                    facts.written.insert(p.name().to_string(), w);
                }
            }
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
            if i == 0 {
                // the set is named and located by its first signature
                node.def_name = g.def_name.clone();
                node.def_range = g.def_range;
                node.def_handle = g.def_handle.clone();
                node.location = g.location.clone();
            }
            node.children.push(g);
        }
        node
    }

    /// A class, an instance, a TypedDict: the members the policy admits.
    fn class_node(&self, name: &str, kind: &str, ty: &Type, depth: u32) -> Node {
        let (cls, query_ty) = match ty {
            Type::ClassType(ct) => (ct.class_object().dupe(), ty.clone()),
            Type::SelfType(ct) => (ct.class_object().dupe(), Type::ClassType(ct.clone())),
            // a TypedDict VALUE's attributes are dict's methods; its keys are
            // the class body's annotations, which the class instance lists
            Type::TypedDict(pyrefly_types::typed_dict::TypedDict::TypedDict(td)) => (
                td.class_object().dupe(),
                Type::ClassType(ClassType::new(td.class_object().dupe(), td.targs().clone())),
            ),
            // an anonymous TypedDict is how pyrefly types a dict literal:
            // `{"k": 1}` displays as `dict[str, int]` and is vocabulary, not shape
            Type::TypedDict(_) => return Node::leaf(name, kind, display(ty), "builtin"),
            Type::ClassDef(c) => {
                if std::env::var_os("TYPESCOPE_DEBUG_CLASSDEF").is_some() {
                    for a in self.tx.attributes_of_type(self.handle, ty.clone()).unwrap_or_default() {
                        eprintln!("[classdef attr] {}  ty={}", a.name, a.ty.as_ref().map(|t| t.to_string()).unwrap_or_default());
                    }
                }
                (c.dupe(), instance_of(c).unwrap_or_else(|| ty.clone()))
            }
            _ => unreachable!(),
        };
        // a third-party class as a nested type: on demand, not auto-walked
        if depth < self.top && depth > 0 && policy::is_third_party(&cls) && !self.on_pierce_path() {
            let attrs = self.tx.attributes_of_type(self.handle, query_ty).unwrap_or_default();
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
            let category = policy::classify(&cls, &policy_attrs);
            let mut node = Node::leaf(name, kind, display(ty), category.as_str());
            node.location = class_location(&cls);
            node.expandable = true;
            node.path = Some(self.path.borrow().clone());
            return node;
        }
        if policy::is_terminal_class(&cls) {
            let mut leaf = Node::leaf(name, kind, display(ty), "builtin");
            leaf.location = class_location(&cls);
            // `dict[str, Bar]`: the wrapper is vocabulary, but a user class
            // among its arguments is structure worth a variant row beneath
            // (the resolver's olj decision: the member class nests, the
            // declaration keeps its own type)
            if depth > 0
                && let Type::ClassType(ct) = ty
            {
                for arg in ct.targs().as_slice() {
                    if let Type::ClassType(inner) = arg
                        && !policy::is_terminal_class(inner.class_object())
                    {
                        leaf.children.push(self.node(&display(arg), "variant", arg, depth - 1));
                    }
                }
            }
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
            node.path = Some(self.path.borrow().clone());
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
                (Some(t), MemberKind::Method) => self.method_row(a.name.as_str(), t),
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
                if mk == MemberKind::Field {
                    keep_written(&mut child, decl.written.as_ref());
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

    /// A method as a row of its class: `(key: str) -> bytes`, the receiver
    /// dropped, and no children — inside a class shape a method's own
    /// parameters are noise, and the resolver drew it exactly this way.
    fn method_row(&self, name: &str, ty: &Type) -> Node {
        let full = self.node(name, "method", ty, 0);
        let sig = if full.children.iter().all(|c| c.kind == "overload") && !full.children.is_empty() {
            full.children.iter().map(signature_of).collect::<Vec<_>>().join(" | ")
        } else {
            signature_of(&full)
        };
        let mut row = Node::leaf(name, "method", sig, "function");
        row.location = full.location;
        row
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
                if let Some(ann) = annotation {
                    facts.written = written_name(self.tx, &handle, ann, text);
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
    is_async: bool,
    /// param name → the annotation as written, when it is a bare name or
    /// dotted name (an alias the author chose as vocabulary)
    written: std::collections::HashMap<String, String>,
}

impl Default for DefFacts {
    fn default() -> Self {
        DefFacts { location: None, return_annotated: true, is_async: false, written: Default::default() }
    }
}

/// The annotation text worth keeping as vocabulary: a name or a dotted name
/// (`Payload`, `pkg.Config`) that is NOT a type variable — `item: T` in a
/// specialized `Box[ServerConfig]` must read `ServerConfig`. `Optional[X]`
/// and friends are normalised better by the checker's own display.
fn written_name(tx: &Transaction<'_>, handle: &Handle, ann: &Expr, text: &str) -> Option<String> {
    match ann {
        Expr::Name(_) | Expr::Attribute(_) => {}
        _ => return None,
    }
    if let Some(t) = tx.get_type_at(handle, ann.range().start())
        && matches!(t, Type::TypeVar(_) | Type::Quantified(_) | Type::QuantifiedValue(_) | Type::ParamSpec(_) | Type::TypeVarTuple(_))
    {
        return None;
    }
    Some(text[ann.range()].to_owned())
}

#[derive(Default)]
struct DeclFacts {
    annotated: bool,
    property: bool,
    literal_default: Option<String>,
    value_text: Option<String>,
    /// `Required[...]` / `NotRequired[...]` around the annotation
    wrapper: Option<String>,
    /// the annotation as written, when it is a bare or dotted name
    written: Option<String>,
}

struct ClassDefFacts {
    decorator_category: Option<Category>,
    total: bool,
}

// ------------------------------------------------------------------ cursor

/// The identifier under the cursor, as the float would name it.
#[derive(Debug, Clone)]
pub struct Cursor {
    /// `resp`, `self.bar`, `get_recipe_by_id` — the full dotted text for an
    /// attribute, as the resolver's declaration rows were named.
    pub text: String,
    /// The identifier's own range (the attribute name for `self.bar`).
    pub range: TextRange,
    /// The cursor is on the target of an UNANNOTATED assignment: the
    /// declaration row is pyrefly's inference, drawn ≈.
    pub inferred: bool,
}

/// The identifier `offset` sits on — a name, an attribute, a `def`/`class`
/// name, a parameter — or `None` for anything else (a string, a number, an
/// operator, whitespace), which is not TypeScope's business: the request
/// answers `null` and K falls through.
pub fn identifier_at(body: &[Stmt], text: &str, offset: ruff_text_size::TextSize) -> Option<Cursor> {
    use ruff_python_ast::visitor::Visitor;
    struct Finder<'t> {
        text: &'t str,
        offset: ruff_text_size::TextSize,
        hit: Option<Cursor>,
        in_bare_assign_target: bool,
    }
    impl<'a, 't> Visitor<'a> for Finder<'t> {
        fn visit_stmt(&mut self, stmt: &'a Stmt) {
            if self.hit.is_some() || !stmt.range().contains_inclusive(self.offset) {
                return;
            }
            match stmt {
                Stmt::FunctionDef(f) if f.name.range().contains_inclusive(self.offset) => {
                    self.hit = Some(Cursor { text: f.name.to_string(), range: f.name.range(), inferred: false });
                }
                Stmt::ClassDef(c) if c.name.range().contains_inclusive(self.offset) => {
                    self.hit = Some(Cursor { text: c.name.to_string(), range: c.name.range(), inferred: false });
                }
                Stmt::Assign(a) => {
                    for t in &a.targets {
                        if t.range().contains_inclusive(self.offset) {
                            self.in_bare_assign_target = true;
                            self.visit_expr(t);
                            self.in_bare_assign_target = false;
                            return;
                        }
                    }
                    ruff_python_ast::visitor::walk_stmt(self, stmt);
                }
                // `from pkg import Name` / `import pkg`: the imported name is
                // as hoverable as any use of it
                Stmt::ImportFrom(i) => {
                    for alias in &i.names {
                        let target = alias.asname.as_ref().unwrap_or(&alias.name);
                        if target.range().contains_inclusive(self.offset) {
                            self.hit = Some(Cursor { text: target.to_string(), range: target.range(), inferred: false });
                        }
                    }
                }
                Stmt::Import(i) => {
                    for alias in &i.names {
                        let target = alias.asname.as_ref().unwrap_or(&alias.name);
                        if target.range().contains_inclusive(self.offset) {
                            self.hit = Some(Cursor { text: target.to_string(), range: target.range(), inferred: false });
                        }
                    }
                }
                _ => ruff_python_ast::visitor::walk_stmt(self, stmt),
            }
        }
        fn visit_expr(&mut self, expr: &'a Expr) {
            if self.hit.is_some() || !expr.range().contains_inclusive(self.offset) {
                return;
            }
            match expr {
                Expr::Name(n) => {
                    self.hit = Some(Cursor { text: n.id.to_string(), range: n.range(), inferred: self.in_bare_assign_target });
                }
                Expr::Attribute(a) if a.attr.range().contains_inclusive(self.offset) => {
                    self.hit = Some(Cursor {
                        text: self.text[a.range()].to_owned(),
                        range: a.attr.range(),
                        inferred: self.in_bare_assign_target,
                    });
                }
                _ => ruff_python_ast::visitor::walk_expr(self, expr),
            }
        }
        fn visit_parameter(&mut self, p: &'a ruff_python_ast::Parameter) {
            if p.name.range().contains_inclusive(self.offset) {
                self.hit = Some(Cursor { text: p.name.to_string(), range: p.name.range(), inferred: false });
            } else {
                ruff_python_ast::visitor::walk_parameter(self, p);
            }
        }
    }
    let mut f = Finder { text, offset, hit: None, in_bare_assign_target: false };
    ruff_python_ast::visitor::walk_body(&mut f, body);
    f.hit
}

/// For a `def` name at `name_range` that is one of several same-named defs
/// in its body (an `@overload` set), the name range of the LAST one — the
/// implementation, where pyrefly's type is the whole overload set.
pub fn overload_implementation(body: &[Stmt], name_range: TextRange) -> Option<TextRange> {
    fn in_body(body: &[Stmt], name_range: TextRange) -> Option<Option<TextRange>> {
        let mut found_name: Option<&str> = None;
        for stmt in body {
            match stmt {
                Stmt::FunctionDef(f) if f.name.range() == name_range => found_name = Some(f.name.as_str()),
                _ => {}
            }
        }
        if let Some(name) = found_name {
            let last = body
                .iter()
                .filter_map(|s| match s {
                    Stmt::FunctionDef(f) if f.name.as_str() == name => Some(f.name.range()),
                    _ => None,
                })
                .last();
            return Some(last.filter(|r| *r != name_range));
        }
        for stmt in body {
            for nested in nested_bodies(stmt) {
                if let Some(r) = in_body(nested, name_range) {
                    return Some(r);
                }
            }
        }
        None
    }
    in_body(body, name_range).flatten()
}

/// `self.x` inside a method, where pyrefly does not type the attribute
/// target itself: the enclosing class's view of `x`. The receiver is the
/// method's first parameter, whatever it is called.
pub fn self_attribute_type(tx: &Transaction<'_>, handle: &Handle, body: &[Stmt], text: &str, cursor: &Cursor) -> Option<Type> {
    let (obj, attr) = cursor.text.rsplit_once('.')?;
    fn enclosing(body: &[Stmt], at: TextRange, cls: Option<&ruff_python_ast::StmtClassDef>) -> Option<(Option<TextRange>, Option<String>)> {
        for stmt in body {
            if !stmt.range().contains_range(at) {
                continue;
            }
            match stmt {
                Stmt::ClassDef(c) => return enclosing(&c.body, at, Some(c)),
                Stmt::FunctionDef(f) => {
                    let receiver = f.parameters.iter().next().map(|p| p.name().to_string());
                    if let Some(inner) = enclosing(&f.body, at, cls) {
                        return Some(inner);
                    }
                    return Some((cls.map(|c| c.name.range()), receiver));
                }
                other => {
                    for nested in nested_bodies(other) {
                        if let Some(x) = enclosing(nested, at, cls) {
                            return Some(x);
                        }
                    }
                }
            }
        }
        None
    }
    let (class_name_range, receiver) = enclosing(body, cursor.range, None)?;
    if receiver.as_deref() != Some(obj) {
        return None;
    }
    let _ = text;
    let class_ty = tx.get_type_at(handle, class_name_range?.start())?;
    let instance = match &class_ty {
        Type::ClassDef(c) => instance_of(c)?,
        _ => return None,
    };
    tx.attributes_of_type(handle, instance)?
        .into_iter()
        .find(|a| a.name.as_str() == attr)
        .and_then(|a| a.ty)
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
        Type::Literal(_) | Type::LiteralString(_) => "literal",
        _ => "builtin",
    }
}

/// `(a: int, b: str = …) -> R` from a function node's param/return children.
fn signature_of(fn_node: &Node) -> String {
    let mut params = Vec::new();
    for c in fn_node.children.iter().filter(|c| c.kind == "param") {
        let mut p = format!("{}: {}", c.name, c.ty.display);
        if let Some(d) = &c.default {
            p.push_str(&format!(" = {d}"));
        }
        params.push(p);
    }
    let ret = fn_node.children.iter().find(|c| c.kind == "return").map(|r| r.ty.display.clone()).unwrap_or_else(|| "None".to_owned());
    format!("({}) -> {ret}", params.join(", "))
}

/// An alias the author wrote (`data: Payload`) stays the row's vocabulary;
/// the checker's resolution becomes the ≈ decoration when the row has no
/// structure of its own to show what it resolved to. The resolver's "alias
/// name kept as vocabulary" and "alias leaf decorated with evaluated type".
fn keep_written(node: &mut Node, written: Option<&String>) {
    if let Some(w) = written
        && *w != node.ty.display
        && w.rsplit('.').next() != Some(node.ty.display.as_str())
    {
        if node.children.is_empty() && !node.expandable {
            node.resolved = Some(std::mem::replace(&mut node.ty.display, w.clone()));
        } else {
            node.ty.display = w.clone();
        }
    }
}

/// An unannotated parameter with a default: pyrefly does not infer
/// parameter types, but it does type the default expression, and the type
/// of `3` widened to `int` is what pyright's default-based inference
/// reported and the float drew as `≈ int`. Presentation, not inference of
/// our own — the checker typed the value; the widening is Literal → class.
fn infer_from_default(node: &mut Node, ty: &Type, req: &Required) {
    if !matches!(ty, Type::Any(_)) {
        return;
    }
    if let Required::Optional(Some(dv)) = req {
        let widened = match &dv.ty {
            Type::Literal(lit) => match &lit.value {
                Lit::Int(_) => "int".to_owned(),
                Lit::Str(_) => "str".to_owned(),
                Lit::Bool(_) => "bool".to_owned(),
                Lit::Bytes(_) => "bytes".to_owned(),
                Lit::Enum(e) => e.class.name().as_str().to_owned(),
                _ => dv.ty.to_string(),
            },
            Type::None => return, // `= None` says nothing about the type
            other => other.to_string(),
        };
        if policy::informative_display(&widened) {
            node.ty.display = widened;
            node.inferred = true;
        }
    }
}

fn token(name: &str, has_default: bool) -> String {
    if has_default { format!("{name}=…") } else { name.to_owned() }
}

/// `Coroutine[Any, Any, X]` / `CoroutineType[…, X]` → `X`.
fn unwrap_coroutine(ret: &Type) -> &Type {
    if let Type::ClassType(ct) = ret
        && matches!(ct.class_object().name().as_str(), "Coroutine" | "CoroutineType")
        && let Some(last) = ct.targs().as_slice().last()
    {
        return last;
    }
    ret
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
pub fn find_class_def(body: &[Stmt], name_range: TextRange) -> Option<&ruff_python_ast::StmtClassDef> {
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
