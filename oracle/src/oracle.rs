//! The pyrefly side: one `State` for the workspace, built the way
//! `pyrefly::query::Query::new` builds its own. Bead 1 only proves the crate
//! links against the vendored, patched pyrefly; the overlays (bead 3) and the
//! structure walk (beads 2 and 4) grow from here.

use std::collections::HashSet;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Mutex;

use pyrefly::library::library::library::library::default_config_finder;
use pyrefly::state::require::Require;
use pyrefly::state::state::State;
use pyrefly_build::handle::Handle;
use pyrefly_python::module_name::ModuleName;
use pyrefly_python::module_name::ModuleNameWithKind;
use pyrefly_python::module_path::ModulePath;
use pyrefly_util::thread_pool::ThreadCount;
use ruff_source_file::OneIndexed;
use ruff_source_file::PositionEncoding;
use ruff_source_file::SourceLocation;
use serde::Serialize;

use crate::protocol::Members;
use crate::walk::Node;
use crate::walk::Walker;

pub struct Oracle {
    state: State,
    /// Files already solved at Require::Everything. Bead 3 (overlays)
    /// replaces this with proper invalidation.
    loaded: Mutex<HashSet<PathBuf>>,
}

/// The answer to `typescope/structure` (design/oracle.md §4). Bead 4 fills
/// in scope classification and headers; until then `scope` is derived from
/// the type alone.
#[derive(Debug, Clone, Serialize)]
pub struct Scope {
    pub scope: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub docstring: Option<String>,
    pub roots: Vec<Node>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl Oracle {
    pub fn new() -> Self {
        // pyrefly's own config finder: it reads pyrefly.toml, pyproject.toml
        // and pyrightconfig.json, which is how spike 3 found the kitchen venv
        // with no configuration of its own.
        let state = State::new(default_config_finder(None), ThreadCount::AllThreads);
        Self { state, loaded: Mutex::new(HashSet::new()) }
    }

    /// The handle for a file on disk, named and configured the way pyrefly's
    /// own server would (its config finder walks up for pyrefly.toml,
    /// pyproject.toml, pyrightconfig.json and derives the module name from
    /// the search path).
    pub fn handle_for(&self, path: &Path) -> Handle {
        let module_path = ModulePath::filesystem(path.to_path_buf());
        let config = self
            .state
            .config_finder()
            .python_file(ModuleNameWithKind::guaranteed(ModuleName::unknown()), &module_path);
        config.handle_from_module_path(module_path)
    }

    /// Solve the file (and, lazily, what it imports) so the transaction can
    /// answer questions about it.
    pub fn ensure_loaded(&self, path: &Path) -> Handle {
        let handle = self.handle_for(path);
        let mut loaded = self.loaded.lock().unwrap();
        if !loaded.contains(path) {
            let mut committing = self.state.new_committable_transaction(Require::Exports, None);
            committing.as_mut().run(std::slice::from_ref(&handle), Require::Everything, None);
            self.state.commit_transaction(committing, None);
            loaded.insert(path.to_path_buf());
        }
        handle
    }

    /// The structure under (line, character) — 0-based, UTF-16 like LSP.
    pub fn structure(&self, path: &Path, line: u32, character: u32, depth: u32, members: Members) -> Option<Scope> {
        let handle = self.ensure_loaded(path);
        let tx = self.state.transaction();
        let module = tx.get_module_info(&handle)?;
        let offset = module.lined_buffer().line_index().offset(
            SourceLocation {
                line: OneIndexed::from_zero_indexed(line as usize),
                character_offset: OneIndexed::from_zero_indexed(character as usize),
            },
            module.contents(),
            PositionEncoding::Utf16,
        );
        // not on a name → not ours; K falls through to the real language server
        let ast = tx.get_ast(&handle)?;
        if !crate::walk::identifier_at(&ast.body, offset) {
            return None;
        }
        let ty = tx.get_type_at(&handle, offset)?;
        let walker = Walker { tx: &tx, handle: &handle, members };
        use pyrefly_types::types::Type;
        let (scope, name) = match &ty {
            Type::Function(_) | Type::Overload(_) | Type::BoundMethod(_) | Type::Forall(_) => ("function", "function"),
            Type::ClassDef(_) => ("class", "class"),
            _ => ("declaration", "declaration"),
        };
        let root = walker.node(name, if scope == "class" { "type" } else { "field" }, &ty, depth);
        // a function's params and returns ARE the roots; anything else is one root
        let roots = if scope == "function" { root.children } else { vec![root] };
        Some(Scope { scope: scope.to_owned(), header: None, docstring: None, roots, reason: None })
    }

    /// The vendored pyrefly's own version string, for `:checkhealth`.
    pub fn pyrefly_version() -> &'static str {
        // pyrefly exposes no version constant to library users; the crate
        // version is what `cargo metadata` would show and is what the pin is.
        PYREFLY_CRATE_VERSION
    }
}

/// Written by scripts/build-oracle.sh? No — kept in sync by hand with the
/// submodule pin, and asserted by the test below so a bump cannot forget it.
pub const PYREFLY_CRATE_VERSION: &str = "1.4.0-dev.1";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_state_can_be_built() {
        // links, constructs, and drops without panicking: the vendored tree
        // plus the patch compiles into something usable
        let _ = Oracle::new();
    }

    #[test]
    fn the_recorded_pyrefly_version_matches_the_vendored_manifest() {
        let manifest = include_str!("../vendor/pyrefly/pyrefly/Cargo.toml");
        let line = manifest
            .lines()
            .find(|l| l.starts_with("version = "))
            .expect("pyrefly/Cargo.toml has a version line");
        assert_eq!(line, format!("version = \"{PYREFLY_CRATE_VERSION}\""));
    }
}
