#!/usr/bin/env bash
# Cut a release in two steps, either side of the release PR's merge.
#
#   scripts/release.sh prepare 0.4.0   # on a release branch: bump the version
#   scripts/release.sh tag             # on main, after the merge: tag it
#
# prepare writes the version everywhere it lives (oracle/Cargo.toml, its lock,
# M.RELEASE in lua/typescope/oracle.lua) and turns CHANGELOG.md's [Unreleased]
# into the dated section. It doesn't write the notes; [Unreleased] should
# already say what changed, and the release PR is where to finish it.
#
# tag reads the version back from M.RELEASE, checks every other place agrees
# and that the checkout is exactly origin/main, then asks before creating an
# annotated tag carrying the changelog section. It does not push. Pushing
# after tagging will publish, and release.yml will take it from there.
#
# scripts/release.sh prepare <version> runs on a release branch. It refuses
# a version that isn't in X.Y.Z form, one that's already tagged, one that
# isn't after the latest tag, a dirty working tree, and running on main. It
# then updates the version in Cargo.toml, Cargo.lock, M.RELEASE and the
# changelog heading.
#
# scripts/release.sh tag runs on main and requires the checkout to match
# origin/main. It stops if you're behind or ahead, and tells you by how many
# commits.
#
# release.yml now also fails if oracle/Cargo.toml doesn't match the tag.


set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

CARGO_TOML=oracle/Cargo.toml
CARGO_LOCK=oracle/Cargo.lock
ORACLE_LUA=lua/typescope/oracle.lua
CHANGELOG=CHANGELOG.md
REPO_URL=https://github.com/plongitudes/typescope.nvim

die() {
    echo "release: $*" >&2
    exit 1
}

require_clean() {
    [ -z "$(git status --porcelain --untracked-files=no)" ] || die "the working tree has uncommitted changes"
}

latest_tag() {
    git tag --list 'v*' --sort=-v:refname | head -n 1
}

# true when $1 sorts strictly after $2 as a version
version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

cargo_version() {
    sed -n 's/^version = "\(.*\)"$/\1/p' "$CARGO_TOML" | head -n 1
}

lock_version() {
    awk '/^name = "typescope-oracle"$/ { getline; gsub(/^version = "|"$/, ""); print; exit }' "$CARGO_LOCK"
}

release_tag() {
    sed -n 's/^M.RELEASE = "\(.*\)"$/\1/p' "$ORACLE_LUA"
}

# the body of one changelog section: everything after its heading, up to the
# next release heading or the link references at the bottom
changelog_section() {
    awk -v head="## [$1]" '
    $0 == head || index($0, head " ") == 1 { on = 1; next }
    on && (/^## \[/ || /^\[[^]]*\]: /) { exit }
    on && /./ { printf "%s", pending; pending = ""; print; started = 1; next }
    on && started { pending = pending "\n" }
  ' "$CHANGELOG"
}

prepare() {
    local version=${1:-}
    version=${version#v}
    [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
        || die "'${1:-}' is not a version; expected MAJOR.MINOR.PATCH, e.g. 0.4.0"

    local branch prev
    branch=$(git rev-parse --abbrev-ref HEAD)
    [ "$branch" != main ] || die "prepare runs on a release branch (git checkout -b release/v$version); the bump lands through a PR"
    require_clean

    git fetch --quiet --tags origin
    ! git rev-parse --quiet --verify "refs/tags/v$version" >/dev/null || die "v$version is already tagged"
    prev=$(latest_tag)
    [ -z "$prev" ] || version_gt "$version" "${prev#v}" || die "v$version is not after the latest tag, $prev"

    grep -q '^## \[Unreleased\]$' "$CHANGELOG" || die "$CHANGELOG has no [Unreleased] section to release"
    [ -n "$(changelog_section Unreleased)" ] || die "$CHANGELOG's [Unreleased] section is empty"

    local today
    today=$(date +%Y-%m-%d)
    export VERSION=$version TODAY=$today LINK
    LINK="[$version]: $REPO_URL/compare/$prev...v$version"
    [ -n "$prev" ] || LINK="[$version]: $REPO_URL/releases/tag/v$version"
    perl -0pi -e 's/^version = ".*?"$/version = "$ENV{VERSION}"/m' "$CARGO_TOML"
    perl -0pi -e 's/^(name = "typescope-oracle"\nversion = )".*?"$/$1"$ENV{VERSION}"/m' "$CARGO_LOCK"
    perl -pi -e 's/^M\.RELEASE = ".*"$/M.RELEASE = "v$ENV{VERSION}"/' "$ORACLE_LUA"
    perl -CSD -pi -e 's/^## \[Unreleased\]$/## [$ENV{VERSION}] \x{2014} $ENV{TODAY}/' "$CHANGELOG"
    # the compare link goes above the newest existing one
    perl -0pi -e 's/^(\[\d+\.\d+\.\d+\]: )/$ENV{LINK}\n$1/m' "$CHANGELOG"

    [ "$(cargo_version)" = "$version" ] || die "failed to set the version in $CARGO_TOML"
    [ "$(lock_version)" = "$version" ] || die "failed to set the version in $CARGO_LOCK"
    [ "$(release_tag)" = "v$version" ] || die "failed to set M.RELEASE in $ORACLE_LUA"

    git --no-pager diff --stat
    cat <<EOF

Prepared v$version (previous: ${prev:-none}).

Next:
  1. Read the [$version] section of $CHANGELOG and finish its notes.
  2. Commit, push this branch, and merge its PR.
  3. On an up-to-date main: scripts/release.sh tag
EOF
}

tag() {
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    [ "$branch" = main ] || die "tag runs on main, after the release PR merges (you are on $branch)"
    require_clean

    git fetch --quiet --tags origin main
    local head upstream
    head=$(git rev-parse HEAD)
    upstream=$(git rev-parse origin/main)
    if [ "$head" != "$upstream" ]; then
        local behind ahead
        behind=$(git rev-list --count HEAD..origin/main)
        ahead=$(git rev-list --count origin/main..HEAD)
        die "main is $behind behind and $ahead ahead of origin/main; tag exactly what origin/main has (pull, or move local commits off main)"
    fi

    local tag version
    tag=$(release_tag)
    version=${tag#v}
    [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
        || die "M.RELEASE in $ORACLE_LUA is '$tag', not a vMAJOR.MINOR.PATCH tag"
    [ "$(cargo_version)" = "$version" ] || die "$CARGO_TOML says $(cargo_version), M.RELEASE says $tag"
    [ "$(lock_version)" = "$version" ] || die "$CARGO_LOCK says $(lock_version), M.RELEASE says $tag"

    ! git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null || die "$tag is already tagged"
    [ -z "$(git ls-remote --tags origin "refs/tags/$tag")" ] || die "$tag already exists on origin"
    local prev
    prev=$(latest_tag)
    [ -z "$prev" ] || version_gt "$version" "${prev#v}" || die "$tag is not after the latest tag, $prev"

    local notes
    notes=$(changelog_section "$version")
    [ -n "$notes" ] || die "$CHANGELOG has no [$version] section, or it is empty"
    grep -q "^## \[$version\] — [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$" "$CHANGELOG" || die "$CHANGELOG's [$version] heading has no date"

    cat <<EOF
Version:  $tag   (previous: ${prev:-none})
Commit:   $(git log -1 --format='%h %s')

$notes

EOF
    local answer
    read -r -p "Create annotated tag $tag on $(git rev-parse --short HEAD)? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || die "not tagged"

    printf '%s\n\n%s\n' "$tag" "$notes" | git tag --annotate --cleanup=verbatim --file=- "$tag"
    cat <<EOF

Tagged $tag. Pushing it publishes the release (release.yml builds the binaries):

  git push origin $tag
EOF
}

case "${1:-}" in
    prepare) prepare "${2:-}" ;;
    tag) tag ;;
    *) die "usage: scripts/release.sh prepare <MAJOR.MINOR.PATCH> | scripts/release.sh tag" ;;
esac
