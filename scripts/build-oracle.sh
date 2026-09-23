#!/usr/bin/env bash
# Build typescope-oracle from the vendored, patched pyrefly.
#
#   scripts/build-oracle.sh            # debug build (tests, local runs)
#   scripts/build-oracle.sh --release  # the binary that ships
#
# Steps: make sure oracle/vendor/pyrefly is a checkout of the commit pinned in
# oracle/pyrefly.rev, apply oracle/patches/*.patch if they are not already
# applied (idempotent), and cargo build. The patched tree is what CI builds
# too; there is no build-time patching magic and nothing here is hidden from
# `git -C oracle/vendor/pyrefly diff`.
#
# pyrefly is fetched here, shallow, rather than being a git submodule: plugin
# managers clone submodules, and pyrefly's history is ~1.9 GB (the pinned
# commit alone is ~35 MB). The checkout is gitignored and disposable — the pin
# and the patches are the source of truth, so a checkout at any other commit
# (a bump, or the old submodule) is deleted and fetched again.
set -euo pipefail
cd "$(dirname "$0")/.."

vendor=oracle/vendor/pyrefly
rev=$(tr -d '[:space:]' < oracle/pyrefly.rev)

if [ -e "$vendor" ] && { [ -f "$vendor/.git" ] || [ "$(git -C "$vendor" rev-parse HEAD 2>/dev/null)" != "$rev" ]; }; then
  echo "replacing $vendor: not a checkout of $rev"
  rm -rf "$vendor"
fi
if [ ! -d "$vendor" ]; then
  echo "fetching pyrefly $rev"
  git init -q "$vendor"
  git -C "$vendor" remote add origin https://github.com/facebook/pyrefly.git
  git -C "$vendor" fetch -q --depth 1 origin "$rev"
  git -C "$vendor" checkout -q FETCH_HEAD
fi

vendor=oracle/vendor/pyrefly
for patch in oracle/patches/*.patch; do
  if git -C "$vendor" apply --reverse --check "../../../$patch" 2>/dev/null; then
    echo "already applied: $patch"
  elif git -C "$vendor" apply --check "../../../$patch"; then
    git -C "$vendor" apply "../../../$patch"
    echo "applied: $patch"
  else
    echo "PATCH DOES NOT APPLY: $patch" >&2
    echo "oracle/pyrefly.rev moved and the patch needs re-basing onto $rev." >&2
    exit 1
  fi
done

cd oracle
cargo build "$@"
