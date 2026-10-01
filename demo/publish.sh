#!/usr/bin/env bash
# Publishes the README's media to the orphan `assets` branch, which the README
# links to: demo/typescope.gif and the stills in demo/shots/. They stay out of
# main so installing the plugin doesn't download them: plugin managers clone
# the default branch, and vim-plug's shallow clones and lazy.nvim's partial
# ones never fetch this branch's blobs.
#
#   demo/encode.sh && demo/publish.sh      (after re-recording the gif)
#   vhs demo/shots.tape && demo/publish.sh (after re-shooting the stills)
#
# Files present locally replace their namesakes; the rest of the branch is kept,
# so re-shooting the stills doesn't need the gif on disk, and vice versa.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

git fetch -q origin assets 2>/dev/null || true # absent on the first publish
parent=$(git rev-parse -q --verify refs/remotes/origin/assets || true)

export GIT_INDEX_FILE
GIT_INDEX_FILE=$(mktemp)
trap 'rm -f "$GIT_INDEX_FILE"' EXIT
if [ -n "$parent" ]; then git read-tree "$parent"; else git read-tree --empty; fi

shopt -s nullglob
for f in demo/typescope.gif demo/shots/*.png; do
  [ -f "$f" ] || continue
  git update-index --add --cacheinfo "100644,$(git hash-object -w "$f"),$(basename "$f")"
done

tree=$(git write-tree)
if [ -n "$parent" ] && [ "$tree" = "$(git rev-parse "$parent^{tree}")" ]; then
  echo "assets is already up to date"
  exit 0
fi
commit=$(git commit-tree "$tree" ${parent:+-p "$parent"} -m "README media from $(git rev-parse --short HEAD)")
git push origin "$commit:refs/heads/assets"
