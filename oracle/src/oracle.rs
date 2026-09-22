//! The pyrefly side: one `State` for the workspace, built the way
//! `pyrefly::query::Query::new` builds its own. Bead 1 only proves the crate
//! links against the vendored, patched pyrefly; the overlays (bead 3) and the
//! structure walk (beads 2 and 4) grow from here.

use std::collections::HashMap;
use std::collections::HashSet;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;

use pyrefly::library::library::library::library::default_config_finder;
use pyrefly::state::load::FileContents;
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

use crate::protocol::Members;
use crate::scope::Scope;

pub struct Oracle {
    state: State,
    /// Files on disk already solved at Require::Everything.
    loaded: Mutex<HashSet<PathBuf>>,
    /// Buffers the editor has open, with their current (possibly unsaved)
    /// contents. These are pyrefly memory overlays: a handle for an open
    /// file is a `ModulePath::memory` handle and reads from here, not disk.
    open: Mutex<HashMap<PathBuf, Arc<String>>>,
}

impl Oracle {
    pub fn new() -> Self {
        // pyrefly's own config finder: it reads pyrefly.toml, pyproject.toml
        // and pyrightconfig.json, which is how spike 3 found the kitchen venv
        // with no configuration of its own.
        let state = State::new(default_config_finder(None), ThreadCount::AllThreads);
        Self { state, loaded: Mutex::new(HashSet::new()), open: Mutex::new(HashMap::new()) }
    }

    /// The handle for a file, named and configured the way pyrefly's own
    /// server would (its config finder walks up for pyrefly.toml,
    /// pyproject.toml, pyrightconfig.json and derives the module name from
    /// the search path). An open buffer gets a memory handle so its unsaved
    /// contents are what gets analysed.
    pub fn handle_for(&self, path: &Path) -> Handle {
        let module_path = if self.open.lock().unwrap().contains_key(path) {
            ModulePath::memory(path.to_path_buf())
        } else {
            ModulePath::filesystem(path.to_path_buf())
        };
        let config = self
            .state
            .config_finder()
            .python_file(ModuleNameWithKind::guaranteed(ModuleName::unknown()), &module_path);
        config.handle_from_module_path(module_path)
    }

    /// Solve the file (and, lazily, what it imports) so the transaction can
    /// answer questions about it. Open buffers are solved on every change
    /// (`did_change`), so here only files read from disk need a first run.
    pub fn ensure_loaded(&self, path: &Path) -> Handle {
        let handle = self.handle_for(path);
        if self.open.lock().unwrap().contains_key(path) {
            return handle;
        }
        let mut loaded = self.loaded.lock().unwrap();
        if !loaded.contains(path) {
            let mut committing = self.state.new_committable_transaction(Require::Exports, None);
            committing.as_mut().run(std::slice::from_ref(&handle), Require::Everything, None);
            self.state.commit_transaction(committing, None);
            loaded.insert(path.to_path_buf());
        }
        handle
    }

    /// `textDocument/didOpen` and `didChange` (full sync): the buffer's
    /// current text becomes the overlay and every open file is re-solved,
    /// the way pyrefly's server validates its open files.
    pub fn did_change(&self, path: &Path, text: String) {
        let text = Arc::new(text);
        self.open.lock().unwrap().insert(path.to_path_buf(), text.clone());
        let mut committing = self.state.new_committable_transaction(Require::Exports, None);
        committing
            .as_mut()
            .set_memory(vec![(path.to_path_buf(), Some(Arc::new(FileContents::Source(text))))]);
        let handles = self.open_handles();
        committing.as_mut().run(&handles, Require::Everything, None);
        self.state.commit_transaction(committing, None);
    }

    /// `textDocument/didClose`: the overlay is dropped and the file is read
    /// from disk again on the next request.
    pub fn did_close(&self, path: &Path) {
        if self.open.lock().unwrap().remove(path).is_none() {
            return;
        }
        let mut committing = self.state.new_committable_transaction(Require::Exports, None);
        committing.as_mut().set_memory(vec![(path.to_path_buf(), None)]);
        committing.as_mut().invalidate_disk(&[path.to_path_buf()]);
        // a dirtied transaction must run before it commits (pyrefly asserts
        // it); the remaining open files are re-solved, an empty list is fine
        let handles = self.open_handles();
        committing.as_mut().run(&handles, Require::Everything, None);
        self.state.commit_transaction(committing, None);
        // whatever was solved from disk before the open is stale now
        self.loaded.lock().unwrap().remove(path);
    }

    fn open_handles(&self) -> Vec<Handle> {
        let paths: Vec<PathBuf> = self.open.lock().unwrap().keys().cloned().collect();
        paths.iter().map(|p| self.handle_for(p)).collect()
    }

    /// The structure under (line, character) — 0-based, UTF-16 like LSP.
    /// `call`: the cursor sits on a call to whatever is under it.
    pub fn structure(
        &self,
        path: &Path,
        line: u32,
        character: u32,
        depth: u32,
        members: Members,
        call: bool,
        expand: Option<Vec<String>>,
    ) -> Option<Scope> {
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
        let cursor = crate::walk::identifier_at(&ast.body, module.contents(), offset)?;
        // the declaration-preserving type: a callee in call position is the
        // function (or the whole overload set), not the chosen signature
        let mut ty = tx.get_type_at_preserving_declaration(&handle, offset);
        if let Some(pyrefly_types::types::Type::Function(f)) = &ty
            && f.metadata.flags.is_overload
            && let Some(impl_range) = crate::walk::overload_implementation(&ast.body, cursor.range)
        {
            ty = tx.get_type_at_preserving_declaration(&handle, impl_range.start());
        }
        if ty.is_none() {
            ty = crate::walk::self_attribute_type(&tx, &handle, &ast.body, module.contents(), &cursor);
        }
        let ty = ty?;
        let req = crate::scope::Request { tx: &tx, handle: &handle, module: &module, cursor, depth, members, call, expand };
        crate::scope::build(&req, &ty)
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
