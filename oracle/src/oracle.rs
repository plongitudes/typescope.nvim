//! The pyrefly side: one `State` for the workspace, built the way
//! `pyrefly::query::Query::new` builds its own. Bead 1 only proves the crate
//! links against the vendored, patched pyrefly; the overlays (bead 3) and the
//! structure walk (beads 2 and 4) grow from here.

use pyrefly::library::library::library::library::default_config_finder;
use pyrefly::state::state::State;
use pyrefly_util::thread_pool::ThreadCount;

pub struct Oracle {
    #[allow(dead_code)] // read from bead 2 on
    state: State,
}

impl Oracle {
    pub fn new() -> Self {
        // pyrefly's own config finder: it reads pyrefly.toml, pyproject.toml
        // and pyrightconfig.json, which is how spike 3 found the kitchen venv
        // with no configuration of its own.
        let state = State::new(default_config_finder(None), ThreadCount::AllThreads);
        Self { state }
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
