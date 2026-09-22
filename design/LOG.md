# Loop log

Newest at the bottom. One entry per tick: bead, what was done, what was verified, what is next, what is blocked.

## 2026-09-21 — tick 1 — `4te` oracle-crate

- Done: `oracle/` crate (protocol.rs, oracle.rs, main.rs) on `lsp-server` 0.10 / `lsp-types` 0.97; pyrefly vendored as a submodule pinned to tag `1.4.0-dev.1` (the exact rev spike 3 verified); `oracle/patches/0001-attributes-of-type.patch`; `scripts/build-oracle.sh` (idempotent patch apply, then cargo build); `tests/test_oracle_attach.lua` wired into `run.sh` with a self-skip when no binary.
- Verified: `cargo test` 4/4; `--version` prints `typescope-oracle 0.2.0 (protocol 1, pyrefly 1.4.0-dev.1)`; nvim attaches, reads serverInfo + `experimental.typescope.protocol == 1`, sees only full document sync, gets `null` from `typescope/structure` and MethodNotFound for an unknown method, shutdown honoured; `./tests/run.sh` ALL SUITES PASS; no leftover processes.
- Gotchas: the vendored tree lives *inside* `oracle/`, so cargo adopted it into our workspace and lost pyrefly's `workspace.lints` — `[workspace] exclude = ["vendor/pyrefly"]` fixes it. After a build `git status` shows the submodule as modified (the applied patch); that is expected and never committed into the submodule.
- Cost: debug build 1m33s warm cache / ~3.5 min cold; binary 30 MB debug.
- Next: `5f8` oracle-walk — port the probe walk to walk.rs + policy.rs, pydantic fixtures first.
