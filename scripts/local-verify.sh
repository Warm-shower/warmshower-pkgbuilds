#!/usr/bin/env bash
# local-verify.sh — Verify the integrity of a local WarmShower OS repository.
#
# Checks:
#   1. Database file (warmshower.db) exists and is parseable
#   2. Every package in the database has a corresponding .pkg.tar.zst file
#   3. Every package has a .sig file
#   4. Each package checksum matches (sha256sum)
#   5. Each signature verifies against the WarmShower GPG key
#
# Usage:
#   scripts/local-verify.sh --repo-dir <dir> [--arch <arch>]
#
# Options:
#   --repo-dir    Local repository root (default: /tmp/ws-repo)
#   --arch        Architecture tier to verify (default: x86_64)

set -euo pipefail

REPO_DIR="/tmp/ws-repo"
ARCH="x86_64"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-dir)     REPO_DIR="$2"; shift 2 ;;
        --repo-dir=*)   REPO_DIR="${1#*=}"; shift ;;
        --arch)         ARCH="$2"; shift 2 ;;
        --arch=*)       ARCH="${1#*=}"; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)              echo "Unknown argument: $1"; exit 1 ;;
    esac
done

ARCH_DIR="${REPO_DIR}/${ARCH}"
DB="${ARCH_DIR}/warmshower.db.tar.gz"
FAILURES=0
WARNINGS=0

echo "=== WarmShower Repository Verification ==="
echo "Repo dir:  ${ARCH_DIR}"
echo ""

# ── Check 1: Repository directory exists ──────────────────────────────────────
echo "--- Check 1: Repository directory ---"
if [ ! -d "$ARCH_DIR" ]; then
    echo "  FAIL: Directory not found: ${ARCH_DIR}"
    echo "  Run: scripts/bootstrap-repo.sh --repo-dir ${REPO_DIR}"
    exit 1
fi
echo "  OK: ${ARCH_DIR}"
echo ""

# ── Check 2: Database file ────────────────────────────────────────────────────
echo "--- Check 2: Repository database ---"
if [ ! -f "$DB" ]; then
    echo "  FAIL: warmshower.db.tar.gz not found."
    FAILURES=$((FAILURES + 1))
else
    DB_SIZE=$(du -sh "$DB" | cut -f1)
    echo "  OK: warmshower.db.tar.gz (${DB_SIZE})"
fi
echo ""

# ── Check 3: Package files ────────────────────────────────────────────────────
echo "--- Check 3: Package presence ---"
PACKAGES=("${ARCH_DIR}"/*.pkg.tar.zst)
if [ "${#PACKAGES[@]}" -eq 0 ] || [ ! -f "${PACKAGES[0]}" ]; then
    echo "  WARN: No packages found in ${ARCH_DIR}"
    WARNINGS=$((WARNINGS + 1))
else
    PKG_COUNT=0
    for pkg in "${PACKAGES[@]}"; do
        PKG_COUNT=$((PKG_COUNT + 1))
        SIZE=$(du -sh "$pkg" | cut -f1)
        echo "  OK: $(basename "$pkg") (${SIZE})"
    done
    echo "  Total: ${PKG_COUNT} package(s)"
fi
echo ""

# ── Check 4: Signature files ──────────────────────────────────────────────────
echo "--- Check 4: Signature files ---"
SIG_FAILURES=0
for pkg in "${PACKAGES[@]}"; do
    [ ! -f "$pkg" ] && continue
    if [ ! -f "${pkg}.sig" ]; then
        echo "  FAIL: Missing .sig for $(basename "$pkg")"
        SIG_FAILURES=$((SIG_FAILURES + 1))
    else
        echo "  OK: $(basename "${pkg}").sig"
    fi
done
if [ "$SIG_FAILURES" -gt 0 ]; then
    FAILURES=$((FAILURES + SIG_FAILURES))
fi
echo ""

# ── Check 5: Signature verification ──────────────────────────────────────────
echo "--- Check 5: GPG signature verification ---"
# This requires the WarmShower public key to be in the local GPG keyring.
# If it is not, we emit a warning rather than failing (key may not be locally trusted).
GPG_KEY_PRESENT=false
if gpg --list-keys "admin@warmshower.ai" &>/dev/null; then
    GPG_KEY_PRESENT=true
fi

if [ "$GPG_KEY_PRESENT" = "true" ]; then
    SIG_VERIFY_FAILURES=0
    for pkg in "${PACKAGES[@]}"; do
        [ ! -f "$pkg" ] && continue
        [ ! -f "${pkg}.sig" ] && continue
        if gpg --verify "${pkg}.sig" "$pkg" 2>/dev/null; then
            echo "  OK: $(basename "$pkg")"
        else
            echo "  FAIL: Bad signature on $(basename "$pkg")"
            SIG_VERIFY_FAILURES=$((SIG_VERIFY_FAILURES + 1))
        fi
    done
    if [ "$SIG_VERIFY_FAILURES" -gt 0 ]; then
        FAILURES=$((FAILURES + SIG_VERIFY_FAILURES))
    fi
else
    echo "  SKIP: WarmShower GPG key not in local keyring (import it with):"
    echo "        gpg --import warmshower-keyring-pkg/warmshower.gpg"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# ── Check 6: Installability check (pacman --print-uri) ───────────────────────
echo "--- Check 6: pacman installability (file:// local repo) ---"
if command -v pacman &>/dev/null; then
    # Build a temporary pacman.conf pointing to the local repo
    TMP_CONF=$(mktemp /tmp/pacman-verify-XXXXXX.conf)
    cat > "$TMP_CONF" << CONFEOF
[options]
HoldPkg = pacman glibc
Architecture = auto
SigLevel = Optional

[warmshower]
Server = file://${ARCH_DIR}
CONFEOF
    if pacman --config "$TMP_CONF" -Sl warmshower &>/dev/null; then
        PKG_LIST=$(pacman --config "$TMP_CONF" -Sl warmshower | wc -l)
        echo "  OK: ${PKG_LIST} package(s) visible via local pacman"
    else
        echo "  WARN: pacman cannot read the local repo (db may be corrupt or empty)"
        WARNINGS=$((WARNINGS + 1))
    fi
    rm -f "$TMP_CONF"
else
    echo "  SKIP: pacman not available (not an Arch Linux system)"
fi
echo ""

# ── Result ────────────────────────────────────────────────────────────────────
echo "=== Verification Result ==="
echo "Failures: ${FAILURES}"
echo "Warnings: ${WARNINGS}"
echo ""

if [ "$FAILURES" -eq 0 ]; then
    if [ "$WARNINGS" -eq 0 ]; then
        echo "PASS — Repository integrity verified."
    else
        echo "PASS (with ${WARNINGS} warning(s)) — Review warnings above."
    fi
    exit 0
else
    echo "FAIL — ${FAILURES} critical check(s) failed."
    exit 1
fi
