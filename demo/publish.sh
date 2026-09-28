#!/usr/bin/env bash
# Publishes demo/typescope.gif to the orphan `assets` branch, which the README
# links to. The gif stays out of main so installing the plugin doesn't download
# it: plugin managers clone the default branch, and vim-plug's shallow clones
# and lazy.nvim's partial ones never fetch this branch's blobs.
#
#   demo/encode.sh && demo/publish.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

git fetch -q origin assets 2>/dev/null || true # absent on the first publish
parent=$(git rev-parse -q --verify refs/remotes/origin/assets || true)

blob=$(git hash-object -w demo/typescope.gif)
tree=$(printf '100644 blob %s\ttypescope.gif\n' "$blob" | git mktree)
commit=$(git commit-tree "$tree" ${parent:+-p "$parent"} -m "typescope.gif from $(git rev-parse --short HEAD)")

git push origin "$commit:refs/heads/assets"
