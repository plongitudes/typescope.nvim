# Ralph iteration

You are one iteration of an unattended loop. You have a fresh context; everything you need is in the bead, the repo, and the branch history. Work exactly ONE bead: the one named at the end of this prompt.

Your Bash runs in a sandbox: you can write only inside this worktree (plus the shared `.beads` database), and you have no network. Don't try to push, open PRs, or install anything; the loop script does pushing after you finish.

## 1. Load the ticket

- `bd show <id>` — read the full body, the parent epic it names (`bd show` that too, it is the spec), and the notes of any closed sibling beads under the same epic that it depends on.
- `bd update <id> --claim`
- Read `AGENTS.md`, `GLOSSARY.md`, and `docs/adr/`. Use the glossary's vocabulary.
- `git log --oneline main..HEAD` shows what earlier iterations already landed on this branch.

## 2. Do the work

- Follow the ticket's "How to work" section. When it says test-first, use the `tdd` skill: write the failing test at the named seam, watch it fail, make it pass, repeat.
- Stay inside the ticket's scope. If you find other work, file it: `bd create --parent <epic> ... -l needs-triage` and keep going.
- Don't monkeypatch or hack around something to get green. If the honest path is blocked, abort (see 4).

## 3. Verify and commit

- `./tests/run.sh` must end with `=== ALL SUITES PASS`, and no suite may print a `SKIP` line (a skipped oracle suite means the e2e seam didn't run, which is not a pass).
- `stylua lua tests` must leave no diff.
- Stage explicit paths only (never `git add -A` / `commit -a`). Commit on the current branch. Message:

  ```
  RALPH(<id>): <ticket title>

  <key decisions, deviations from the ticket, gotchas — 3-8 lines>

  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```

## 4. Close or abort

- Success: append notes to the bead (`bd update <id> --notes` REPLACES notes — `bd show <id>` first, keep existing text, append yours: key decisions, gotchas, deviations, 5-10 bullets). Then `bd close <id> --reason "..."` with the explicit id. Then print `<promise>DONE</promise>`.
- Blocked (sandbox denial you can't work within, ambiguous spec, tests you can't make honest): leave the work uncommitted, `bd comments add <id> "<what blocked you and what you tried>"`, set it back with `bd update <id> --status open`, and print `<promise>ABORT</promise>`.

Print exactly one promise tag, as the last thing you output.
