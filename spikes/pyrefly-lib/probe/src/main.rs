//! Spike 3 probe: pyrefly as a library, PUBLIC API ONLY, from outside the crate.
//!
//! Loads the spike-1 fixture, asks the type at each target, and for a class
//! reconstructs what structure the public surface allows: the class's OWN
//! field names (`Transaction::get_class_fields`), each re-queried at its
//! declaration position (`get_type_at`) and substituted with the class's type
//! args. What the public surface does NOT allow is marked in the output:
//! inherited members (the MRO is an answer behind `pub(crate)`), and the
//! solver's own member types (`ad_hoc_solve` / `Answers::get_idx`).
//!
//!   cargo run --release -- <fixture.py>

use std::path::PathBuf;
use std::time::Instant;

use dupe::Dupe;
use pyrefly::library::library::library::library::default_config_finder;
use pyrefly::state::require::Require;
use pyrefly::state::state::State;
use pyrefly_build::handle::Handle;
use pyrefly_python::module_name::ModuleName;
use pyrefly_python::module_path::ModulePath;
use pyrefly_python::sys_info::SysInfo;
use pyrefly_types::class::Class;
use pyrefly_types::types::Type;
use pyrefly_util::thread_pool::ThreadCount;
use ruff_text_size::TextSize;

struct Target {
    label: &'static str,
    needle: &'static str,
    skip: usize,
}

const TARGETS: &[Target] = &[
    Target { label: "def use(...) — function under cursor", needle: "def use(", skip: 4 },
    Target { label: "b: Box[ServerConfig] — generic with T substituted?", needle: "b: Box[ServerConfig]", skip: 0 },
    Target { label: "c: Color — enum members?", needle: "c: Color", skip: 0 },
    Target { label: "d: Derived — inherited fields?", needle: "d: Derived", skip: 0 },
    Target { label: "resp = fetch(\"x\") — unannotated local", needle: "resp = fetch", skip: 0 },
    Target { label: "return resp — use site", needle: "return resp", skip: 7 },
    Target { label: "n = first([1,2,3]) — TypeVar solved at call site?", needle: "n = first", skip: 0 },
    Target { label: "def first — TypeVar unsolved at the def", needle: "def first", skip: 4 },
    Target { label: "maybe = fetch_maybe() — union before narrowing", needle: "maybe = fetch_maybe", skip: 0 },
    Target { label: "narrowed = maybe — inside `if maybe is not None`", needle: "narrowed = maybe", skip: 11 },
    Target { label: "Response.ok — property", needle: "def ok(", skip: 4 },
];

// Spike 2's ten kitchen targets (targets.json), as (1-based line, needle, skip).
const KITCHEN: &[(usize, &str, usize)] = &[
    (88, "db: AsyncSession", 4),
    (95, "Recipe.ingredients", 7),
    (96, "selectinload(", 0),
    (114, "result = await", 0),
    (118, "def get_recipe_by_id", 4),
    (121, "Optional[Recipe]", 9),
    (137, "def create_recipe", 4),
    (144, "recipe = Recipe(", 9),
    (191, "ing_result = await", 0),
    (228, "RecipeService.get_recipe_by_id", 14),
];

fn footprint() -> (u32, u32) {
    let out = std::process::Command::new("footprint")
        .args(["-p", &std::process::id().to_string()])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let grab = |key: &str| -> u32 {
        out.lines()
            .find(|l| l.trim_start().starts_with(key))
            .and_then(|l| l.split(':').nth(1))
            .and_then(|v| v.trim().split_whitespace().next())
            .and_then(|v| v.parse::<f32>().ok())
            .map(|v| v.round() as u32)
            .unwrap_or(0)
    };
    (grab("phys_footprint:"), grab("phys_footprint_peak:"))
}

fn main() {
    let t_process = Instant::now();
    let fixture = PathBuf::from(std::env::args().nth(1).expect("usage: probe <fixture.py>"))
        .canonicalize()
        .unwrap();
    let source = std::fs::read_to_string(&fixture).unwrap();
    // optional: <module name> selects the kitchen targets and names the module
    let module_name = std::env::args().nth(2).unwrap_or_else(|| "probe_fixture".to_owned());
    let kitchen = module_name != "probe_fixture";

    // ---- state: mirrors pyrefly::query::Query::new + add_files -------------
    let t0 = Instant::now();
    let state = State::new(default_config_finder(None), ThreadCount::AllThreads);
    let sys_info = SysInfo::default();
    let handle = Handle::new(
        ModuleName::from_str(&module_name),
        ModulePath::filesystem(fixture.clone()),
        sys_info.dupe(),
    );
    let mut committing = state.new_committable_transaction(Require::Exports, None);
    committing.as_mut().run(std::slice::from_ref(&handle), Require::Everything, None);
    state.commit_transaction(committing, None);
    let tx = state.transaction();
    let (fp, _) = footprint();
    eprintln!(
        "state ready in {} ms ({} ms from process start); footprint {} MB\n",
        t0.elapsed().as_millis(),
        t_process.elapsed().as_millis(),
        fp
    );

    let handle_for = |cls: &Class| Handle::new(cls.module_name(), cls.module_path().dupe(), sys_info.dupe());

    // Public-surface reconstruction of a class's structure: own fields only.
    let describe_class = |cls: &Class, subst: Option<&pyrefly_types::types::Substitution>, indent: &str| {
        let owner = handle_for(cls);
        println!("{indent}class {}  @ {}:{:?}", cls.name(), cls.module_name(), cls.range().start());
        match tx.get_class_fields(&handle, cls) {
            None => println!("{indent}  <get_class_fields: none>"),
            Some(fields) => {
                for name in fields.names() {
                    if name.as_str().starts_with('_') {
                        continue;
                    }
                    let shown = match fields.field_decl_range(name) {
                        Some(range) => match tx.get_type_at(&owner, range.start()) {
                            Some(ty) => {
                                let ty = match subst {
                                    Some(s) => s.substitute_into(ty),
                                    None => ty,
                                };
                                format!("{ty}")
                            }
                            None => "<get_type_at: none>".to_owned(),
                        },
                        None => "<no decl range>".to_owned(),
                    };
                    let flags = if fields.is_field_annotated(name) { "" } else { "  [unannotated]" };
                    println!("{indent}  · {name}  {shown}{flags}");
                }
            }
        }
        println!("{indent}  <inherited members: MRO is behind pub(crate); not reachable>");
    };

    // PHASE 2 (patched checkout): the solver's own answer — every attribute
    // through the MRO, specialized, with a definition location.
    let describe_solved = |ty: &Type, indent: &str| {
        use pyrefly::alt::attr::AttrDefinition;
        let own = match ty {
            Type::ClassType(ct) => Some(ct.class_object().name().clone()),
            Type::ClassDef(c) => Some(c.name().clone()),
            _ => None,
        };
        match tx.attributes_of_type(&handle, ty.clone()) {
            None => println!("{indent}[solver] <none>"),
            Some(attrs) => {
                println!("{indent}[solver] {} attributes:", attrs.len());
                for a in attrs {
                    if a.name.as_str().starts_with('_') {
                        continue;
                    }
                    let (origin, loc) = match &a.definition {
                        AttrDefinition::FullyResolved { cls, range, .. } => (
                            if own.as_ref() == Some(cls.name()) { String::new() } else { format!(" ↑{}", cls.name()) },
                            format!("  @ {}:{:?}", cls.module_name(), range.start()),
                        ),
                        _ => (String::new(), String::new()),
                    };
                    let kind = match &a.ty {
                        Some(Type::Function(f)) if f.metadata.flags.property_metadata.is_some() => "  [property]",
                        Some(Type::Function(_)) | Some(Type::BoundMethod(_)) | Some(Type::Overload(_)) => "  [method]",
                        _ => "",
                    };
                    let shown = a.ty.as_ref().map(|t| t.to_string()).unwrap_or_else(|| "<no type>".to_owned());
                    println!("{indent}  · {}{origin}  {shown}{kind}{loc}", a.name);
                }
            }
        }
    };

    let describe = |ty: &Type, indent: &str| {
        match ty {
            Type::ClassType(ct) => {
                println!("{indent}instance of {}", ct);
                let subst = ct.substitution();
                describe_class(ct.class_object(), Some(&subst), indent);
            }
            Type::ClassDef(cls) => {
                println!("{indent}class object");
                describe_class(cls, None, indent);
            }
            Type::Union(u) => {
                let members = &u.members;
                println!("{indent}union of {}", members.len());
                for m in members.iter() {
                    match m {
                        Type::ClassType(ct) => {
                            println!("{indent}  instance of {}", ct);
                            describe_class(ct.class_object(), Some(&ct.substitution()), &format!("{indent}  "));
                        }
                        other => println!("{indent}  {other}"),
                    }
                }
            }
            Type::Function(f) => {
                println!("{indent}function  {}", ty);
                println!("{indent}  · returns  {}", f.signature.ret);
            }
            Type::Overload(o) => println!("{indent}overloaded x{}: {}", o.signatures.len(), ty),
            other => println!("{indent}{other}"),
        }
    };

    let mut timings = Vec::new();
    let line_offset = |line: usize| -> usize { source.lines().take(line - 1).map(|l| l.len() + 1).sum() };
    let resolved: Vec<(String, usize)> = if kitchen {
        KITCHEN
            .iter()
            .map(|(line, needle, skip)| {
                let text = source.lines().nth(line - 1).unwrap();
                let col = text.find(needle).unwrap_or_else(|| panic!("needle not on line {line}: {needle}"));
                (format!("{needle} (line {line})"), line_offset(*line) + col + skip)
            })
            .collect()
    } else {
        TARGETS
            .iter()
            .map(|t| (t.label.to_owned(), source.find(t.needle).unwrap_or_else(|| panic!("needle not found: {}", t.needle)) + t.skip))
            .collect()
    };
    for (label, idx) in resolved {
        let t = Target { label: "", needle: "", skip: 0 };
        let _ = &t;
        let q0 = Instant::now();
        let ty = tx.get_type_at(&handle, TextSize::try_from(idx).unwrap());
        let ms = q0.elapsed().as_micros() as f64 / 1000.0;
        timings.push(ms);
        println!("== {label}   (offset {idx}, {ms:.1} ms)");
        match ty {
            None => println!("  <no type>"),
            Some(ty) => {
                println!("  control (Display): {ty}");
                describe(&ty, "  ");
                if matches!(ty, Type::ClassType(_) | Type::ClassDef(_)) {
                    describe_solved(&ty, "  ");
                }
            }
        }
        println!();
    }
    let (fp, peak) = footprint();
    eprintln!("done; footprint {fp} MB (peak {peak}); queries ms: {timings:?}");
}
