#!/bin/sh
set -eu
set -f

fail() { echo "Source sync failed: $*" >&2; exit 1; }
rc() { rclone --config /dev/null --retries 3 --contimeout 20s --timeout 5m --transfers 2 "$@"; }
verify() { rc checksum SHA-256 "$1" "$2" --exclude /SHA256SUMS; }

source_root=${SOURCE_ROOT:-/source}
state="$source_root/.source-sync"
pending="$state/pending"
revisions="$state/revisions"
target="$source_root/captures"
reserve=${MIN_FREE_BYTES:-10737418240}
case "$reserve" in ''|*[!0-9]*) fail 'MIN_FREE_BYTES must be a nonnegative integer';; esac
: "${BUCKET_NAME:?Missing bucket ConfigMap}" "${BUCKET_HOST:?Missing bucket host}" "${BUCKET_PORT:?Missing bucket port}"
export RCLONE_CONFIG_RGW_TYPE="${RCLONE_CONFIG_RGW_TYPE:-s3}"
export RCLONE_CONFIG_RGW_PROVIDER=Ceph
export RCLONE_CONFIG_RGW_ENDPOINT="http://$BUCKET_HOST:$BUCKET_PORT"
export RCLONE_CONFIG_RGW_REGION="${BUCKET_REGION:-us-east-1}"
export RCLONE_CONFIG_RGW_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:?Missing bucket Secret}"
export RCLONE_CONFIG_RGW_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?Missing bucket Secret}"
export RCLONE_CONFIG_RGW_FORCE_PATH_STYLE=true RCLONE_CONFIG_RGW_NO_CHECK_BUCKET=true
remote="rgw:$BUCKET_NAME/captures"

[ -d "$source_root" ] && [ ! -L "$source_root" ] || fail 'Source root must be a real directory initialized by Blender'
for directory in "$state" "$revisions"; do
    [ ! -L "$directory" ] || fail "Sync directory cannot be a symlink: $directory"
    mkdir -p "$directory"
done
[ ! -L "$state/lock" ] || fail 'Lock cannot be a symlink'
exec 9>"$state/lock"
flock -n 9 || fail 'Another source sync is running; retry after it finishes'
# Only the lock holder removes private staging left by an interrupted run.
[ ! -L "$pending" ] || fail 'Staging cannot be a symlink'
rm -rf "$pending"
mkdir "$pending"
trap 'rm -rf "$pending"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

previous=
if [ -L "$target" ]; then
    previous=$(readlink "$target")
    printf '%s\n' "$previous" | LC_ALL=C grep -Eq '^\.source-sync/revisions/[a-f0-9]{64}$' \
        || fail 'Capture link must reference a managed revision'
    previous="$source_root/$previous"
    [ -d "$previous" ] && [ ! -L "$previous" ] && [ ! -L "$previous/SHA256SUMS" ] \
        || fail 'Current revision must be a real directory with its checksum file'
    verify "$previous/SHA256SUMS" "$previous"
elif [ -e "$target" ]; then
    fail 'Existing captures directory preserved; move it aside during maintenance before using revision sync'
fi

rc cat "$remote/SHA256SUMS" > "$pending/SHA256SUMS"
[ -s "$pending/SHA256SUMS" ] || fail 'Empty root checksum inventory'
revision=$(sha256sum "$pending/SHA256SUMS")
revision=${revision%% *}
ready="$revisions/$revision"
if [ -e "$ready" ] || [ -L "$ready" ]; then
    [ -d "$ready" ] && [ ! -L "$ready" ] && [ ! -L "$ready/SHA256SUMS" ] \
        || fail 'Existing revision is not a real directory'
    cmp -s "$pending/SHA256SUMS" "$ready/SHA256SUMS" || fail 'Existing revision inventory changed'
    verify "$pending/SHA256SUMS" "$ready"
    staged="$ready"
else
    rc lsf "$remote" --recursive --files-only --format s > "$pending/sizes"
    required=$(awk '{total += $1} END {printf "%.0f", total}' "$pending/sizes")
    available=$(df -Pk "$source_root" | awk 'END {printf "%.0f", $4 * 1024}')
    [ "$available" -ge "$((required + reserve))" ] || fail 'Insufficient workspace space plus reserve'
    staged="$pending/captures"
    mkdir "$staged"
    rc copy "$remote" "$staged" --immutable --checksum --exclude /SHA256SUMS
    verify "$pending/SHA256SUMS" "$staged"
    cp "$pending/SHA256SUMS" "$staged/SHA256SUMS"
fi
if [ -n "$previous" ] && [ "$previous" != "$ready" ]; then
    # A new inventory can add captures, but cannot rewrite or remove published originals.
    rc checksum SHA-256 "$previous/SHA256SUMS" "$staged" --one-way --exclude /SHA256SUMS
fi
rc cat "$remote/SHA256SUMS" > "$pending/current"
cmp -s "$pending/SHA256SUMS" "$pending/current" || fail 'Remote checksums changed during sync'
if [ "$staged" != "$ready" ]; then
    mv -nT "$staged" "$ready"
    [ ! -d "$staged" ] || fail 'Revision appeared during sync'
fi
# A relative link resolves inside both the Job subPath and Blender's full PVC mount.
ln -s ".source-sync/revisions/$revision" "$pending/link"
mv -Tf "$pending/link" "$target"
echo "Verified captures revision $revision"
