#!/usr/bin/env bash
# Build typescope-oracle from the vendored, patched pyrefly.
#
#   scripts/build-oracle.sh            # debug build (tests, local runs)
#   scripts/build-oracle.sh --release  # the binary that ships
#
# Steps: make sure the submodule is checked out at its pinned commit, apply
# oracle/patches/*.patch if they are not already applied (idempotent), and
# cargo build. The patched tree is what CI builds too; there is no build-time
# patching magic and nothing here is hidden from `git -C oracle/vendor/pyrefly
# diff`.
set -euo pipefail
cd "$(dirname "$0")/.."

git submodule update --init --depth 1 oracle/vendor/pyrefly

vendor=oracle/vendor/pyrefly
for patch in oracle/patches/*.patch; do
  if git -C "$vendor" apply --reverse --check "../../../$patch" 2>/dev/null; then
    echo "already applied: $patch"
  elif git -C "$vendor" apply --check "../../../$patch"; then
    git -C "$vendor" apply "../../../$patch"
    echo "applied: $patch"
  else
    echo "PATCH DOES NOT APPLY: $patch" >&2
    echo "The submodule moved (git -C $vendor log -1) and the patch needs re-basing." >&2
    exit 1
  fi
done

cd oracle
cargo build "$@"
