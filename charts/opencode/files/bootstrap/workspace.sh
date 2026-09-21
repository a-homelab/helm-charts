#!/bin/sh
set -eu

config=${1:-/opt/opencode/git.json}
root=${2:-/workspace}
state=${3:-/state}

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

staging=
cleanup() {
    if [ -n "$staging" ]; then
        rm -rf -- "$staging"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p -- "$state/config" "$state/data" "$state/cache" "$state/state" "$root"
enabled=$(jq -er '.enabled | tostring' "$config")
[ "$enabled" = true ] || exit 0

root=$(realpath -e -- "$root")
owner=$(jq -er '.owner' "$config")
repositories=$(jq -c '.repositories[]' "$config")
while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    name=$(printf '%s\n' "$repo" | jq -er '.name')
    relative=$(printf '%s\n' "$repo" | jq -er '.path')
    case "$relative" in
        ''|/*|.|..|../*|*/../*|*/..)
            fail 'Repository path must stay inside the workspace'
            ;;
    esac
    target=$(realpath -ms -- "$root/$relative")
    resolved=$(realpath -m -- "$target")
    case "$resolved" in
        "$root"/*) ;;
        *) fail 'Repository path escapes the workspace' ;;
    esac
    [ ! -L "$target" ] || fail 'Repository checkout cannot be a symlink'
    origin=https://github.com/$owner/$name.git
    if [ -e "$target" ]; then
        top=$(git -C "$target" rev-parse --show-toplevel)
        top=$(realpath -e -- "$top")
        existing_origin=$(git -C "$target" remote get-url origin)
        if [ "$top" != "$resolved" ] || [ "$existing_origin" != "$origin" ]; then
            fail 'Existing checkout does not match the configured repository'
        fi
        printf 'Preserved %s; no fetch, merge or reset\n' "$name"
        continue
    fi
    parent=$(dirname -- "$target")
    mkdir -p -- "$parent"
    staging=$(mktemp -d "$parent/.clone-XXXXXX")
    git clone --origin origin -- "$origin" "$staging"
    mv -T -- "$staging" "$target"
    staging=
    printf 'Cloned %s\n' "$name"
done <<EOF
$repositories
EOF
