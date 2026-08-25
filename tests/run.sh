#!/usr/bin/env bash
# Run all TypeScope test suites headlessly. From the repo root:
#   ./tests/run.sh
# The python treesitter parser comes from the local nvim install's site dir;
# nvim-treesitter (queries) enables the injection-highlight paths in e2e.
set -uo pipefail
cd "$(dirname "$0")/.."

RTP="set rtp+=. rtp+=$HOME/.local/share/nvim/site rtp+=$HOME/.local/share/nvim/lazy/nvim-treesitter"
fail=0

for suite in tests/test_extract.lua tests/test_match.lua tests/test_render.lua tests/test_float.lua tests/test_examples.lua tests/e2e_phase3.lua; do
  echo "=== $suite"
  out=$(nvim --headless --clean --cmd "$RTP" -c "luafile $suite" -c "qa!" 2>&1)
  echo "$out" | grep -E "FAIL|ALL PASS|FAILURES"
  if ! echo "$out" | grep -q "ALL PASS"; then
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "=== ALL SUITES PASS" || echo "=== SUITE FAILURES"
exit $fail
