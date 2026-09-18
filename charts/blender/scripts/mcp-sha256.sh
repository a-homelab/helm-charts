#!/usr/bin/env bash
set -euo pipefail

version=${1:-}
version=${version#v}
if [[ $# -ne 1 || ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Usage: %s <version> (for example 1.0.3 or v1.0.3)\n' "$0" >&2
  exit 2
fi

url="https://projects.blender.org/lab/blender_mcp/releases/download/v${version}/mcp-${version}.zip"
checksum=$(curl --fail --silent --show-error --location --max-time 60 "$url" | shasum -a 256)
printf '%s\n' "${checksum%% *}"
