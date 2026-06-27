#!/usr/bin/env bash
# local-build.sh — Build one or more WarmShower OS packages using the Docker container.
#
# This script wraps `docker run warmshower-builder build` and handles:
#   - Ensuring the builder image exists (builds it if not)
#   - Passing signing keys from the local environment
#   - Collecting output packages from the mounted workspace
#   - Optionally signing the built packages
#
# Usage:
#   scripts/local-build.sh <package_dir> [--sign] [--output-dir <dir>]
#
# Options:
#   --sign          Sign packages after building.
#                   Requires WS_SIGNING_KEY and WS_SIGNING_KEY_PASSPHRASE.
#   --output-dir    Copy built packages here after build (default: packages/).
#   --no-cache      Rebuild the Docker image from scratch.
#
# Examples:
#   scripts/local-build.sh warmshower-mirrorlist-pkg
#   scripts/local-build.sh warmshower-keyring-pkg --sign
#   scripts/local-build.sh warmshower-mirrorlist-pkg --output-dir /tmp/ws-pkgs

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_NAME="warmshower-builder"
OUTPUT_DIR="${REPO_ROOT}/packages"
SIGN=false
DOCKER_BUILD_FLAGS=""

# ── Argument parsing ──────────────────────────────────────────────────────────
PACKAGE_DIR="${1:-}"
shift || true

if [ -z "$PACKAGE_DIR" ]; then
    echo "Usage: local-build.sh <package_dir> [--sign] [--output-dir <dir>]"
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign)           SIGN=true; shift ;;
        --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
        --output-dir=*)   OUTPUT_DIR="${1#*=}"; shift ;;
        --no-cache)       DOCKER_BUILD_FLAGS="--no-cache"; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Ensure Docker image exists ────────────────────────────────────────────────
echo "=== WarmShower Local Build ==="
echo "Package:  ${PACKAGE_DIR}"
echo "Sign:     ${SIGN}"
echo "Output:   ${OUTPUT_DIR}"
echo ""

if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "--- Building Docker image (first run) ---"
    docker build $DOCKER_BUILD_FLAGS \
        -t "$IMAGE_NAME" \
        "${REPO_ROOT}/docker/arch-builder/"
    echo ""
fi

# ── Set up environment for signing ───────────────────────────────────────────
SIGN_FLAGS=""
ENV_FLAGS=""
if [ "$SIGN" = "true" ]; then
    if [ -z "${WS_SIGNING_KEY:-}" ]; then
        echo "ERROR: --sign requested but \$WS_SIGNING_KEY is not set."
        echo "       Generate and export your CI subkey with:"
        echo "       gpg --export-secret-subkeys --armor <FINGERPRINT>"
        exit 1
    fi
    SIGN_FLAGS="--sign"
    ENV_FLAGS="-e WS_SIGNING_KEY -e WS_SIGNING_KEY_PASSPHRASE"
fi

# ── Build ──────────────────────────────────────────────────────────────────────
echo "--- Running build ---"
mkdir -p "$OUTPUT_DIR"

# shellcheck disable=SC2086
docker run --rm \
    -v "${REPO_ROOT}:/workspace" \
    -v "${HOME}/.ccache:/ccache" \
    $ENV_FLAGS \
    "$IMAGE_NAME" \
    build "${PACKAGE_DIR}" $SIGN_FLAGS

echo ""
echo "--- Collecting output ---"
BUILT_PACKAGES=()
while IFS= read -r pkg; do
    BUILT_PACKAGES+=("$pkg")
done < <(find "${REPO_ROOT}/${PACKAGE_DIR}" -name "*.pkg.tar.zst" 2>/dev/null)

if [ "${#BUILT_PACKAGES[@]}" -eq 0 ]; then
    echo "ERROR: No packages found in ${REPO_ROOT}/${PACKAGE_DIR}"
    exit 1
fi

for pkg in "${BUILT_PACKAGES[@]}"; do
    cp "$pkg" "$OUTPUT_DIR/"
    echo "  copied: $(basename "$pkg") → ${OUTPUT_DIR}/"
    if [ -f "${pkg}.sig" ]; then
        cp "${pkg}.sig" "$OUTPUT_DIR/"
        echo "  copied: $(basename "${pkg}").sig → ${OUTPUT_DIR}/"
    fi
done

echo ""
echo "=== Build complete ==="
echo "Packages in: ${OUTPUT_DIR}"
ls -lh "${OUTPUT_DIR}"/*.pkg.tar.zst 2>/dev/null || true
