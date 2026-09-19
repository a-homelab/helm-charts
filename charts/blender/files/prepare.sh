#!/usr/bin/env bash
set -euo pipefail

blender_python=/lsiopy/bin/python3
blender_build=/build_version
blender_workspace=/workspace

verify_archive() {
    printf '%s  %s\n' "$MCP_SHA256" "$1" | sha256sum --check --status
}

prepare_addon() {
    local bootstrap=$1 cache=$2 scripts=$3 cached pending extension
    [[ "$MCP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        printf 'MCP_VERSION must be a release version\n' >&2
        return 1
    }
    [[ "$MCP_SHA256" =~ ^[a-f0-9]{64}$ ]] || {
        printf 'MCP_SHA256 must be a SHA-256 digest\n' >&2
        return 1
    }
    mkdir -p -- "$cache"
    cached="$cache/$MCP_SHA256.zip"
    if [[ ! -f "$cached" ]] || ! verify_archive "$cached"; then
        pending="$cached.tmp"
        curl --fail --location --silent --show-error --max-time 60 \
            --output "$pending" \
            "https://projects.blender.org/lab/blender_mcp/releases/download/v$MCP_VERSION/mcp-$MCP_VERSION.zip"
        verify_archive "$pending"
        mv -f -- "$pending" "$cached"
    fi
    extension="$scripts/extensions/mcp"
    rm -rf -- "$extension"
    mkdir -p -- "$extension" "$scripts/startup"
    "$blender_python" - "$cached" "$extension" <<'PY'
import sys
import zipfile
from pathlib import Path

destination = Path(sys.argv[2]).resolve()
with zipfile.ZipFile(sys.argv[1]) as archive:
    for entry in archive.infolist():
        if not (destination / entry.filename).resolve().is_relative_to(destination):
            raise ValueError("Blender MCP archive contains an invalid path")
    archive.extractall(destination)
PY
    cp -- "$bootstrap/mcp_autostart.py" "$scripts/startup/mcp_autostart.py"
}

prepare_environment() {
    local bootstrap=$1 cache=$2 image=$3 fingerprint environment pending
    fingerprint=$(
        {
            printf '%s\0' "$image"
            "$blender_python" -c 'import platform, sys; print(sys.version); print(sys.executable); print(platform.machine())'
            sha256sum "$blender_build" "$bootstrap/requirements.txt" "$bootstrap/prepare.sh"
        } | sha256sum
    )
    environment="$cache/environments/${fingerprint%% *}"
    if [[ -f "$environment/.ready" && -x "$environment/bin/blender-mcp" ]]; then
        printf 'Reusing MCP environment %s\n' "${environment##*/}"
    else
        printf 'Preparing MCP environment %s\n' "${environment##*/}"
        rm -rf -- "$environment"
        mkdir -p -- "$cache/environments"
        "$blender_python" -m venv --copies "$environment"
        "$environment/bin/python" -m pip --isolated --disable-pip-version-check install \
            --no-input --cache-dir "$cache/pip-cache" -r "$bootstrap/requirements.txt"
        "$environment/bin/python" -m pip --isolated --no-cache-dir check
        "$environment/bin/python" -c 'from blmcp import main'
        test -x "$environment/bin/blender-mcp"
        touch "$environment/.ready"
    fi
    pending="$cache/current.pending"
    rm -f -- "$pending"
    ln -s -- "$environment" "$pending"
    mv -Tf -- "$pending" "$cache/current"
}

prepare() {
    local bootstrap
    bootstrap=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    [[ ! -L "$blender_workspace/source" ]] || {
        printf 'Workspace source directory cannot be a symlink\n' >&2
        return 1
    }
    mkdir -p -- "$blender_workspace/source"
    chown -- "$PUID:$PGID" "$blender_workspace" "$blender_workspace/source"
    if [[ "$MCP_ENABLED" != true ]]; then
        return
    fi
    export PYTHONDONTWRITEBYTECODE=1
    prepare_addon "$bootstrap" /config/blender-mcp-cache /opt/blender-user-scripts
    prepare_environment "$bootstrap" /config/blender-mcp-server "$MCP_IMAGE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    prepare
fi
