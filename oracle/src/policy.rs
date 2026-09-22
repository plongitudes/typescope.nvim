//! Presentation policy: the rules that decide what a class SHOWS, stated once,
//! over pyrefly's types. design/oracle.md §4 and decision 4.
//!
//! Everything here is a pure function so it can be unit-tested without a
//! pyrefly State, and so a second language's oracle can state the same rules
//! in the same place.

use pyrefly_types::class::Class;
use pyrefly_types::literal::Lit;
use pyrefly_types::types::Type;

/// How a class is presented: the `type.category` of a node, and the header
/// vocabulary the plugin already knows (`(dataclass ← Base)`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Category {
    Class,
    Dataclass,
    Pydantic,
    TypedDict,
    NamedTuple,
    Protocol,
    Enum,
}

impl Category {
    pub fn as_str(self) -> &'static str {
        match self {
            Category::Class => "class",
            Category::Dataclass => "dataclass",
            Category::Pydantic => "pydantic",
            Category::TypedDict => "typeddict",
            Category::NamedTuple => "namedtuple",
            Category::Protocol => "protocol",
            Category::Enum => "enum",
        }
    }
}

/// One attribute as the solver reports it, reduced to what policy needs.
pub struct Attr<'a> {
    pub name: &'a str,
    pub ty: Option<&'a Type>,
    /// The class that defines it, when the solver resolved that.
    pub defined_on: Option<&'a Class>,
}

/// Classify a class from the attributes the solver lists for it — BEFORE any
/// filtering, because the fingerprints are dunders and inherited members:
/// a synthesized `__dataclass_fields__`, a member typed as an enum literal, a
/// defining class under `pydantic`, `typing.NamedTuple` in the ancestry.
pub fn classify(cls: &Class, attrs: &[Attr<'_>]) -> Category {
    if cls.is_protocol() {
        return Category::Protocol;
    }
    let mut dataclass = false;
    for a in attrs {
        if let Some(Type::Literal(lit)) = a.ty
            && let Lit::Enum(_) = &lit.value
        {
            return Category::Enum;
        }
        if let Some(owner) = a.defined_on {
            if is_pydantic_model_base(owner) {
                return Category::Pydantic;
            }
            // pyrefly grounds these constructs in typeshed's fallback classes
            match owner.name().as_str() {
                "NamedTupleFallback" => return Category::NamedTuple,
                "TypedDictFallback" => return Category::TypedDict,
                _ => {}
            }
        }
        if a.name == "__dataclass_fields__" {
            dataclass = true;
        }
    }
    if dataclass {
        Category::Dataclass
    } else {
        Category::Class
    }
}

/// A decorator's dotted text decides the category the way the treesitter
/// resolver's `classify` did: `@dataclass`, `@dataclasses.dataclass(frozen=True)`,
/// `@pydantic.dataclasses.dataclass`. pyrefly does not list the synthesized
/// dunders among a class's attributes, so the author's own declaration is
/// the signal.
pub fn category_from_decorator(text: &str) -> Option<Category> {
    let head = text.split('(').next().unwrap_or(text).trim();
    if !head.ends_with("dataclass") {
        return None;
    }
    if head.contains("pydantic") {
        Some(Category::Pydantic)
    } else {
        Some(Category::Dataclass)
    }
}

fn is_pydantic_model_base(cls: &Class) -> bool {
    cls.name().as_str() == "BaseModel" && cls.module_name().as_str().starts_with("pydantic")
}

/// The MRO cut: members defined on these classes are machinery, not shape.
/// This is the `MARKER_BASES` idea from the treesitter resolver, applied to the
/// solver's per-attribute defining class instead of to base names in source.
/// Anything inherited from the bundled typeshed is cut wholesale: `object`,
/// `tuple`, `Enum`, `dict` behind a TypedDict, `Mapping` — a user class's
/// shape is what the user (or their third-party package) declared.
pub fn is_cut_base(cls: &Class) -> bool {
    is_terminal_class(cls)
        || is_pydantic_model_base(cls)
        || cls.module_name().as_str().starts_with("pydantic")
}

/// A class from the bundled typeshed (stdlib and `typing`) is a terminal
/// leaf: `str`, `Path`, `TextIO` are vocabulary, not shape. Third-party
/// packages resolved from the filesystem (pydantic, SQLAlchemy) do expand —
/// that is where user-facing models live. The treesitter resolver's
/// typeshed guard, carried forward; explicit expansion may later pierce it.
pub fn is_terminal_class(cls: &Class) -> bool {
    matches!(
        cls.module_path().details(),
        pyrefly_python::module_path::ModulePathDetails::BundledTypeshed(_)
            | pyrefly_python::module_path::ModulePathDetails::BundledTypeshedThirdParty(_)
    )
}

/// Names the float never draws: private and dunder members.
pub fn is_hidden_name(name: &str) -> bool {
    name.starts_with('_')
}

/// What the plugin calls the row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemberKind {
    Field,
    Property,
    EnumMember,
    Method,
}

impl MemberKind {
    pub fn as_str(self) -> &'static str {
        match self {
            MemberKind::Field => "field",
            MemberKind::Property => "property",
            MemberKind::EnumMember => "enum_member",
            MemberKind::Method => "method",
        }
    }
}

/// Kind from the member's solved type. Properties are indistinguishable here
/// (the solver hands back the getter's result type); the walk upgrades a
/// Field to Property from the declaration site.
pub fn kind_of(ty: Option<&Type>) -> MemberKind {
    match ty {
        Some(Type::Literal(lit)) if matches!(&lit.value, Lit::Enum(_)) => MemberKind::EnumMember,
        Some(Type::Function(_) | Type::BoundMethod(_) | Type::Overload(_) | Type::Forall(_)) => MemberKind::Method,
        _ => MemberKind::Field,
    }
}

/// Is an inferred type worth a row? `None` is what every function without a
/// return infers, `Any`/`Unknown` is the checker saying it does not know.
/// Announcing those is worse than declining (the treesitter resolver's
/// `informative_inference`, carried forward).
pub fn informative_inference(ty: &Type) -> bool {
    !matches!(ty, Type::None | Type::Any(_) | Type::Never(_))
}

/// A checker-private notation rather than a Python type: pyrefly's `Self@C`
/// and `T@f` spellings never reach the float as something to exemplify.
pub fn is_checker_notation(display: &str) -> bool {
    display.contains('@')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hidden_names() {
        assert!(is_hidden_name("_private"));
        assert!(is_hidden_name("__dunder__"));
        assert!(!is_hidden_name("host"));
    }

    #[test]
    fn decorators() {
        assert_eq!(category_from_decorator("dataclass"), Some(Category::Dataclass));
        assert_eq!(category_from_decorator("dataclasses.dataclass(frozen=True)"), Some(Category::Dataclass));
        assert_eq!(category_from_decorator("pydantic.dataclasses.dataclass"), Some(Category::Pydantic));
        assert_eq!(category_from_decorator("functools.total_ordering"), None);
    }

    #[test]
    fn checker_notation() {
        assert!(is_checker_notation("Self@Response"));
        assert!(is_checker_notation("T@first"));
        assert!(!is_checker_notation("Recipe | None"));
    }
}
