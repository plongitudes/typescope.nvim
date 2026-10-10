#!/usr/bin/env bash
# Ralph loop over a beads epic: one fresh, sandboxed `claude -p` per ready
# child bead, in a beads worktree on an integration branch.
#
#   scripts/ralph/ralph.sh <epic-id> <branch> [max-iterations]   # run the loop
#   scripts/ralph/ralph.sh --probe <epic-id> <branch>              # sandbox smoke test, no ticket work
#
# Claude only commits. This script, running on the host (outside the
# sandbox), checks each iteration before trusting it — the bead is closed,
# the suites pass with nothing skipped — and only then pushes. The remote is
# SSH, which the macOS sandbox can't reach, so pushing has to live out here.
set -euo pipefail

probe=0
if [ "${1:-}" = "--probe" ]; then
  probe=1
  shift
fi
epic=${1:?usage: ralph.sh [--probe] <epic-id> <branch> [max-iterations]}
branch=${2:?usage: ralph.sh [--probe] <epic-id> <branch> [max-iterations]}
max=${3:-20}

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
here="$repo/scripts/ralph"
name="ralph-${epic##*-}"
wt="$repo/../$(basename "$repo")-$name"

# --- worktree -------------------------------------------------------------
# bd worktree create writes a redirect so the worktree shares this checkout's
# .beads database; a plain `git worktree add` would get its own empty one.
if [ ! -d "$wt" ]; then
  git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || git -C "$repo" branch "$branch" main
  (cd "$repo" && bd worktree create "$wt" --branch "$branch")
fi
# bd 0.48.1 writes the redirect relative to .beads/ but resolves it relative
# to the worktree root, so a sibling worktree points one directory too high.
# An absolute path reads the same either way.
printf '%s\n' "$repo/.beads" >"$wt/.beads/redirect"

# oracle/target is gitignored, so the worktree has no binary: the oracle
# suites would SKIP, and oracle.locate() would fall back to downloading the
# last release — so the host-side check would quietly test a stale oracle.
# Link this checkout's build where both of them look.
oracle="$repo/oracle/target/debug/typescope-oracle"
[ -x "$oracle" ] || { echo "no oracle at $oracle (scripts/build-oracle.sh)" >&2; exit 1; }
mkdir -p "$wt/oracle/target/debug"
ln -sf "$oracle" "$wt/oracle/target/debug/typescope-oracle"

# --- sandbox settings -----------------------------------------------------
# Generated per run because the shared .beads path is machine-specific.
# One scratch dir the sandbox may write: nvim's state (swap files; the e2e
# suites edit fixtures) and the temp dir tests/run.sh makes its XDG_DATA_HOME
# in. Without it nvim can't swap under ~/.local/state and mktemp hits the
# system temp dir, both outside the sandbox.
scratch=$(mktemp -d -t ralph)
mkdir -p "$scratch/state" "$scratch/tmp"
trap 'rm -rf "$scratch"' EXIT
settings="$scratch/settings.json"
export XDG_STATE_HOME="$scratch/state" TMPDIR="$scratch/tmp"
jq -n --arg beads "$repo/.beads" --arg scratch "$scratch" '{
  sandbox: {
    enabled: true,
    failIfUnavailable: true,
    allowUnsandboxedCommands: false,
    autoAllowBashIfSandboxed: true,
    filesystem: {
      allowWrite: [$beads, $scratch],
      denyRead: ["~/.ssh", "~/.aws", "~/.gnupg"]
    },
    network: {
      allowedDomains: [],
      allowUnixSockets: [($beads + "/bd.sock")],
      # test_oracle_download serves fake releases from a local http.server
      allowLocalBinding: true
    }
  }
}' >"$settings"

claude_run() { # <prompt> -> stream-json on stdout
  (cd "$wt" && claude -p "$1" \
    --settings "$settings" \
    --permission-mode dontAsk \
    --allowedTools "Read,Edit,Write,Bash,Skill,TodoWrite" \
    --verbose --output-format stream-json)
}
stream_text='select(.type == "assistant").message.content[]? | select(.type == "text").text // empty | . + "\n"'
final_result='select(.type == "result").result // empty'

if [ "$probe" -eq 1 ]; then
  claude_run "Sandbox smoke test. Don't change any tracked file. Run each of these with Bash and report, per line, the exit status and the first line of any error:
1. bd ready
2. bd show $epic
3. bd label add $epic ralph-probe && bd label remove $epic ralph-probe
4. touch ~/ralph-sandbox-probe   (EXPECTED to fail)
5. curl -sS --max-time 5 https://example.com -o /dev/null   (EXPECTED to fail)
6. ./tests/run.sh   (report every line that contains FAIL, SKIP or SUITE)
7. stylua --check lua tests
8. git status --short && git commit --allow-empty -m 'RALPH probe' && git reset --soft HEAD~1
Then summarise which of 1-3, 6-8 failed and why." | jq --unbuffered -rj "$stream_text"
  exit 0
fi

# --- loop -----------------------------------------------------------------
# A killed run leaves its bead claimed (in_progress), and bd ready skips
# claimed beads. With nothing uncommitted there is no half-done work to
# protect, so hand them back.
if [ -z "$(git -C "$wt" status --porcelain)" ]; then
  (cd "$repo" && bd list --status in_progress --json | jq -r --arg p "$epic." '.[] | select(.id | startswith($p)) | .id') |
    while read -r stale; do
      echo "=== reopening $stale (claimed by an earlier, interrupted run)"
      (cd "$repo" && bd update "$stale" --status open --assignee "" >/dev/null)
    done
else
  echo "=== $wt has uncommitted changes from an interrupted run; clean it up first" >&2
  exit 1
fi

for ((i = 1; i <= max; i++)); do
  # only beads triaged for an agent: iterations file follow-ups as
  # needs-triage, and those may need things the sandbox can't do
  id=$(cd "$repo" && bd ready --json | jq -r --arg p "$epic." \
    '[.[] | select((.id | startswith($p)) and ((.labels // []) | index("ready-for-agent")))][0].id // empty')
  if [ -z "$id" ]; then
    echo "=== no ready bead under $epic: done after $((i - 1)) iterations"
    exit 0
  fi
  echo "=== iteration $i: $id"
  head_before=$(git -C "$wt" rev-parse HEAD)
  log=$(mktemp -t "ralph-$id")
  claude_run "$(cat "$here/prompt.md")

Bead for this iteration: $id" | tee "$log" | jq --unbuffered -rj "$stream_text"
  result=$(jq -r "$final_result" "$log")

  if [[ "$result" != *"<promise>DONE</promise>"* ]]; then
    echo "=== $id did not finish (log: $log); stopping"
    exit 1
  fi
  # trust, but verify on the host
  status=$(cd "$repo" && bd show "$id" --json | jq -r '.[0].status')
  [ "$status" = "closed" ] || { echo "=== $id claims DONE but is $status; stopping"; exit 1; }
  [ "$(git -C "$wt" rev-parse HEAD)" != "$head_before" ] || { echo "=== $id committed nothing; stopping"; exit 1; }
  [ -z "$(git -C "$wt" status --porcelain)" ] || { echo "=== $id left uncommitted changes; stopping"; exit 1; }
  out=$(cd "$wt" && ./tests/run.sh 2>&1) || { echo "$out" | grep -E "FAIL|SUITE"; echo "=== suites fail on host after $id; stopping"; exit 1; }
  if echo "$out" | grep -q "^SKIP"; then
    echo "$out" | grep "^SKIP"
    echo "=== a suite skipped after $id; stopping"
    exit 1
  fi
  (cd "$wt" && stylua --check lua tests) || { echo "=== stylua diff after $id; stopping"; exit 1; }

  git -C "$wt" push -u origin "$branch"
  rm -f "$log"
done
echo "=== hit max iterations ($max)"
