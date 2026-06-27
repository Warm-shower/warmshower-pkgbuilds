#!/usr/bin/env bash
# bootstrap-repo.sh — Initialize a local WarmShower OS package repository.
#
# Creates the expected directory layout, initializes the pacman database,
# verifies permissions, and confirms the structure is ready for package
# publishing via wsync or build.sh.
#
# Usage:
#   scripts/bootstrap-repo.sh [--repo-dir <path>]
#
# Options:
#   --repo-dir   Local path for the repository root (default: /tmp/ws-repo)
#
# After running this script:
#   1. Build packages with:    wsync build warmshower-mirrorlist-pkg
#   2. Publish them with:      wsync publish --repo-dir <path>
#   3. Verify with:            wsync verify --repo-dir <path>
#
# The resulting layout mirrors the Cloudflare R2 bucket structure exactly
# so that local testing is identical to the published repository.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO_DIR="/tmp/ws-repo"
REPO_NAME="warmshower"
ARCHITECTURES=("x86_64" "x86_64_v3" "x86_64_v4" "znver4")

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-dir)
            REPO_DIR="$2"; shift 2 ;;
        --repo-dir=*)
            REPO_DIR="${1#*=}"; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "Unknown argument: $1"
            exit 1 ;;
    esac
done

# ── OS check ──────────────────────────────────────────────────────────────────
# repo-add is a pacman tool — only available on Arch Linux (or inside the
# WarmShower build container).  Detect and warn on non-Arch hosts.
IS_ARCH=false
if command -v repo-add &>/dev/null; then
    IS_ARCH=true
fi

echo "=== WarmShower Repository Bootstrap ==="
echo "Repo root:     ${REPO_DIR}"
echo "Repo name:     ${REPO_NAME}"
echo "Architectures: ${ARCHITECTURES[*]}"
echo "repo-add:      $(command -v repo-add 2>/dev/null || echo '(not found — use Docker)')"
echo ""

# ── Create directory layout ────────────────────────────────────────────────────
echo "--- Creating directory layout ---"
for arch in "${ARCHITECTURES[@]}"; do
    TARGET="${REPO_DIR}/${arch}"
    mkdir -p "$TARGET"
    echo "  created: ${TARGET}"
done
echo ""

# ── Initialize database files ─────────────────────────────────────────────────
if [ "$IS_ARCH" = "true" ]; then
    echo "--- Initializing repository databases ---"
    for arch in "${ARCHITECTURES[@]}"; do
        DB="${REPO_DIR}/${arch}/${REPO_NAME}.db.tar.gz"
        if [ -f "$DB" ]; then
            echo "  already exists (skipping): $DB"
        else
            # repo-add with an empty package list creates a valid empty database
            # shellcheck disable=SC2016
            repo-add "$DB" 2>&1 | grep -v "^$" || true
            echo "  initialized: $DB"
        fi
    done
else
    echo "--- Skipping database init (repo-add not available) ---"
    echo "    Run bootstrap inside the Docker container, or install pacman tools."
    echo ""
    echo "    To init inside Docker:"
    echo "    docker run --rm -v ${REPO_DIR}:/repo warmshower-builder repo /repo/x86_64"
fi
echo ""

# ── Verify permissions ────────────────────────────────────────────────────────
echo "--- Verifying permissions ---"
PERM_FAILURES=0
for arch in "${ARCHITECTURES[@]}"; do
    TARGET="${REPO_DIR}/${arch}"
    if [ ! -w "$TARGET" ]; then
        echo "  ERROR: Not writable: $TARGET"
        PERM_FAILURES=$((PERM_FAILURES + 1))
    else
        echo "  OK:     $TARGET"
    fi
done
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Bootstrap complete ==="
if [ "$PERM_FAILURES" -gt 0 ]; then
    echo "WARNING: $PERM_FAILURES permission problem(s) found."
    exit 1
fi

echo ""
echo "Repository layout:"
find "$REPO_DIR" -maxdepth 2 | sort | sed 's/^/  /'
echo ""
echo "Next steps:"
echo "  1. Build a package:   wsync build warmshower-mirrorlist-pkg"
echo "  2. Publish to repo:   wsync publish --repo-dir ${REPO_DIR} warmshower-mirrorlist-pkg"
echo "  3. Verify integrity:  wsync verify --repo-dir ${REPO_DIR}"
echo "  4. Test in QEMU:      scripts/vm-test.sh --repo-dir ${REPO_DIR}"
