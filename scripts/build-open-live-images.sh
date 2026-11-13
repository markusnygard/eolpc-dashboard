#!/usr/bin/env bash
# Build the versioned Open Live images used by the docker compose stacks.
#
# Bump the three version variables (or override via env) when new releases land:
#   STROM_VERSION            -> open-live-strom-ndi:<ver>   (from eyevinntechnology/strom-full:<ver> + NDI)
#   OPEN_LIVE_VERSION        -> open-live:<ver>             (backend/Dockerfile)
#   OPEN_LIVE_STUDIO_VERSION -> open-live-studio:<ver>      (frontend/Dockerfile)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EOLPC="${EOLPC_DIR:-$ROOT/../eolpc}"

STROM_VERSION="${STROM_VERSION:-0.7.1}"
OPEN_LIVE_VERSION="${OPEN_LIVE_VERSION:-0.5.0}"
OPEN_LIVE_STUDIO_VERSION="${OPEN_LIVE_STUDIO_VERSION:-0.5.0}"

echo "=== Building Open Live images ==="
echo "  open-live:${OPEN_LIVE_VERSION}"
echo "  open-live-studio:${OPEN_LIVE_STUDIO_VERSION}"
echo "  open-live-strom-ndi:${STROM_VERSION}"
echo

echo "--- open-live:${OPEN_LIVE_VERSION} (backend) ---"
docker build -t "open-live:${OPEN_LIVE_VERSION}" "$EOLPC/open-live"

echo "--- open-live-studio:${OPEN_LIVE_STUDIO_VERSION} (frontend) ---"
docker build -t "open-live-studio:${OPEN_LIVE_STUDIO_VERSION}" "$EOLPC/open-live-studio"

echo "--- open-live-strom-ndi:${STROM_VERSION} (strom + NDI) ---"
STROM_VERSION="$STROM_VERSION" "$ROOT/docker/ndi/build.sh"

echo
echo "=== Done ==="
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^open-live(|-studio|-strom-ndi):' | sort || true
