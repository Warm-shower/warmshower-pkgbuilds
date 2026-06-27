#!/usr/bin/env bash
# local-publish.sh — Add signed packages to the local WarmShower repository.
#
# This script:
#   1. Verifies all package signatures
#   2. Runs repo-add (inside Docker if needed) to update warmshower.db
#   3. Copies packages, .sig files, and the updated database to the local repo
#
# Usage:
#   scripts/local-publish.sh --repo-dir <dir> <package.pkg.tar.zst> [...]
#
# Options:
#   --repo-dir    Local repository root (created by bootstrap-repo.sh)
#   --arch        Architecture tier (default: x86_64)
#
# Examples:
#   scripts/local-publish.sh --repo-dir /tmp/ws-repo packages/*.pkg.tar.zst

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR=""
ARCH="${REPO_ARCH:-x86_64}"
IMAGE_NAME="warmshower-builder"
PACKAGES=()

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-dir)     REPO_DIR="$2"; shift 2 ;;
        --repo-dir=*)   REPO_DIR="${1#*=}"; shift ;;
        --arch)         ARCH="$2"; shift 2 ;;
        --arch=*)       ARCH="${1#*=}"; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *.pkg.tar.zst)  PACKAGES+=("$1"); shift ;;
        *)              echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [ -z "$REPO_DIR" ]; then
    echo "ERROR: --repo-dir is required."
    echo "Usage: local-publish.sh --repo-dir <dir> <packages...>"
    exit 1
fi

if [ "${#PACKAGES[@]}" -eq 0 ]; then
    echo "ERROR: No packages specified."
    exit 1
fi

ARCH_DIR="${REPO_DIR}/${ARCH}"
DB="${ARCH_DIR}/warmshower.db.tar.gz"

echo "=== WarmShower Local Publish ==="
echo "Repo dir:  ${ARCH_DIR}"
echo "Database:  ${DB}"
echo "Packages:  ${#PACKAGES[@]}"
echo ""

# ── Validate signatures ───────────────────────────────────────────────────────
echo "--- Verifying package signatures ---"
FAILURES=0
for pkg in "${PACKAGES[@]}"; do
    if [ ! -f "${pkg}.sig" ]; then
        echo "  FAIL (no .sig): $(basename "$pkg")"
        FAILURES=$((FAILURES + 1))
    else
        # Verify the signature with GPG
        if gpg --verify "${pkg}.sig" "$pkg" 2>/dev/null; then
            echo "  OK: $(basename "$pkg")"
        else
            echo "  WARN: Signature for $(basename "$pkg") could not be verified."
            echo "        (This is expected if the WS_SIGNING_KEY is not in your local keyring.)"
            echo "        The signature file exists and will be published."
        fi
    fi
done

if [ "$FAILURES" -gt 0 ]; then
    echo ""
    echo "ERROR: $FAILURES package(s) have missing .sig files."
    echo "Build and sign packages with: wsync build --sign <package_dir>"
    exit 1
fi
echo ""

# ── Ensure output directory exists ───────────────────────────────────────────
mkdir -p "$ARCH_DIR"

# ── Copy packages to repo dir ────────────────────────────────────────────────
echo "--- Copying packages ---"
for pkg in "${PACKAGES[@]}"; do
    cp "$pkg" "${ARCH_DIR}/"
    echo "  copied: $(basename "$pkg")"
    [ -f "${pkg}.sig" ] && cp "${pkg}.sig" "${ARCH_DIR}/" && echo "  copied: $(basename "${pkg}").sig"
done
echo ""

# ── Run repo-add ──────────────────────────────────────────────────────────────
echo "--- Updating repository database ---"

# Determine whether repo-add is available natively or needs Docker.
if command -v repo-add &>/dev/null; then
    REPO_PKG_ARGS=()
    for pkg in "${PACKAGES[@]}"; do
        REPO_PKG_ARGS+=("${ARCH_DIR}/$(basename "$pkg")")
    done
    repo-add "$DB" "${REPO_PKG_ARGS[@]}"
else
    echo "  repo-add not found locally — using Docker"
    # Ensure Docker image exists
    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        docker build -t "$IMAGE_NAME" "${REPO_ROOT}/docker/arch-builder/"
    fi

    REPO_PKG_LIST=()
    for pkg in "${PACKAGES[@]}"; do
        REPO_PKG_LIST+=("/repo/${ARCH}/$(basename "$pkg")")
    done

    docker run --rm \
        -v "${REPO_DIR}:/repo" \
        --entrypoint repo-add \
        "$IMAGE_NAME" \
        "/repo/${ARCH}/warmshower.db.tar.gz" "${REPO_PKG_LIST[@]}"
fi

echo "  Database updated: ${DB}"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Publish complete ==="
echo "Repository: ${ARCH_DIR}/"
echo ""
echo "Contents:"
ls -lh "${ARCH_DIR}/" | grep -v "^total"
echo ""
echo "Pacman config snippet (add to /etc/pacman.conf to test):"
echo ""
echo "  [warmshower]"
echo "  Server = file://${ARCH_DIR}"
