# Issue tracker: beads

Issues and specs for this repo live in beads (`bd`), stored in `.beads/` and committed with the repo. Do not use `gh issue`; GitHub Issues are not used here.

## Conventions

- **Create an issue**: `bd create --title "..." --type task|feature|bug|epic --priority 0-4 -d "..."`. Use `--body-file -` with a heredoc for multi-line bodies.
- **Spec → tickets**: a spec is an `epic`; each ticket is created with `--parent <epic-id>`.
- **Blocking**: `bd dep add <blocked> <blocker>`. Create blockers first so edges reference real ids. `bd ready` lists unblocked work.
- **Read an issue**: `bd show <id>`; comments via `bd comments <id>`.
- **List issues**: `bd list --status open`, filtered with `--label`, `--parent`, `--ready`.
- **Comment**: `bd comments add <id> "..."`
- **Labels**: `bd label add <id> <label>` / `bd label remove <id> <label>`, or `-l` on create.
- **Close**: `bd close <id> --reason "..."`. Always pass an explicit id.
- **Notes**: `bd update <id> --notes` replaces existing notes. Read them first and append.

## Pull requests as a triage surface

**PRs as a request surface: no.**

## When a skill says "publish to the issue tracker"

Create a bead as above.

## When a skill says "fetch the relevant ticket"

`bd show <id>`.

## Wayfinding operations

Used by `/wayfinder`.

- **Map**: an `epic` labelled `wayfinder:map`, holding Notes / Decisions-so-far / Fog in its description.
- **Child ticket**: `bd create --parent <map-id> -l wayfinder:<research|prototype|grilling|task>`.
- **Blocking**: `bd dep add <child> <blocker>`.
- **Frontier**: `bd list --parent <map-id> --ready`, skipping any with an assignee; first by id wins.
- **Claim**: `bd update <id> --claim`, the session's first write.
- **Resolve**: `bd comments add <id> "<answer>"`, `bd close <id>`, then append a context pointer to the map's Decisions-so-far.
