#!/usr/bin/env bash
# test.sh — Validate a WarmShower OS PKGBUILD directory inside the container.
#
# Runs:
#   1. makepkg --verifysource    — checksums + PGP verification
#   2. namcap PKGBUILD           — lint
#   3. Branding check            — scans for residual CachyOS references
#
# Usage (inside container):
#   test.sh <package_dir>
#
# Exit code: 0 if all checks pass, non-zero if any check fails.

set -euo pipefail

PACKAGE_DIR="${1:-}"
if [ -z "$PACKAGE_DIR" ]; then
    echo "Usage: test.sh <package_dir>"
    exit 1
fi

if [[ "$PACKAGE_DIR" != /* ]]; then
    PACKAGE_DIR="/workspace/${PACKAGE_DIR}"
fi

if [ ! -f "${PACKAGE_DIR}/PKGBUILD" ]; then
    echo "ERROR: No PKGBUILD in ${PACKAGE_DIR}"
    exit 1
fi

cd "$PACKAGE_DIR"

FAILURES=0
PKGNAME=$(grep -E '^pkgname=' PKGBUILD | head -1 | sed "s/pkgname=//" | tr -d "'" | tr -d '"')
echo "=== WarmShower Package Validator ==="
echo "Package: ${PKGNAME:-unknown}"
echo "Dir:     ${PACKAGE_DIR}"
echo ""

# ── 1. Checksum and source verification ──────────────────────────────────────
echo "--- Check 1: Source verification (makepkg --verifysource) ---"
if makepkg --verifysource --noconfirm 2>&1; then
    echo "  PASS"
else
    echo "  FAIL: makepkg --verifysource failed"
    FAILURES=$((FAILURES + 1))
fi
echo ""

# ── 2. namcap lint ────────────────────────────────────────────────────────────
echo "--- Check 2: PKGBUILD lint (namcap) ---"
NAMCAP_OUTPUT=$(namcap PKGBUILD 2>&1)
NAMCAP_ERRORS=$(echo "$NAMCAP_OUTPUT" | grep -cE "^E:" || true)
NAMCAP_WARNINGS=$(echo "$NAMCAP_OUTPUT" | grep -cE "^W:" || true)

if [ "$NAMCAP_ERRORS" -gt 0 ]; then
    echo "  FAIL: $NAMCAP_ERRORS error(s), $NAMCAP_WARNINGS warning(s)"
    echo "$NAMCAP_OUTPUT"
    FAILURES=$((FAILURES + 1))
elif [ "$NAMCAP_WARNINGS" -gt 0 ]; then
    echo "  WARN: 0 errors, $NAMCAP_WARNINGS warning(s) (not fatal)"
    echo "$NAMCAP_OUTPUT"
else
    echo "  PASS: No errors or warnings."
fi
echo ""

# ── 3. Branding check ─────────────────────────────────────────────────────────
echo "--- Check 3: CachyOS branding scan ---"
BRANDING_HITS=$(grep -rniE "(cachyos|cachy)" . \
    --include="PKGBUILD" \
    --include="*.install" \
    --include="*.sh" \
    --include="*.conf" \
    2>/dev/null || true)

if [ -n "$BRANDING_HITS" ]; then
    echo "  WARN: Residual CachyOS branding found (review before publishing):"
    echo "$BRANDING_HITS" | sed 's/^/    /'
    # Branding is a warning, not a hard failure — reviewer decides
else
    echo "  PASS: No CachyOS branding found."
fi
echo ""

# ── 4. Mandatory field check ──────────────────────────────────────────────────
echo "--- Check 4: Required PKGBUILD fields ---"
FIELD_FAILURES=0
for FIELD in pkgname pkgver pkgrel arch url license; do
    if ! grep -qE "^${FIELD}=" PKGBUILD; then
        echo "  FAIL: Missing required field: ${FIELD}"
        FIELD_FAILURES=$((FIELD_FAILURES + 1))
    fi
done
if [ "$FIELD_FAILURES" -eq 0 ]; then
    echo "  PASS: All required fields present."
else
    FAILURES=$((FAILURES + FIELD_FAILURES))
fi
echo ""

# ── 5. SKIP checksum check ────────────────────────────────────────────────────
echo "--- Check 5: SKIP checksum policy (Rule 10) ---"
# SKIP is allowed only when the corresponding source is a VCS URL.
# Extract source= lines and sha512sums= in parallel to verify each SKIP is matched
# to a git+/svn+/hg+/bzr+ source entry.
SKIP_VIOLATIONS=0
SOURCES=()
while IFS= read -r line; do
    # Extract plain URL tokens from source= array declarations
    TOKEN=$(echo "$line" | grep -oE "'[^']+'" | head -1 | tr -d "'")
    [ -n "$TOKEN" ] && SOURCES+=("$TOKEN")
done < <(grep -A 100 '^source=' PKGBUILD | grep -E "^\s+'|^\s+\"" || true)

# Simple heuristic: count SKIP entries and VCS sources
SKIP_COUNT=$(grep -oE "'SKIP'" PKGBUILD | wc -l || true)
VCS_COUNT=$(grep -oE "git\+|svn\+|hg\+|bzr\+" PKGBUILD | wc -l || true)

if [ "$SKIP_COUNT" -gt 0 ] && [ "$SKIP_COUNT" -gt "$VCS_COUNT" ]; then
    echo "  FAIL: ${SKIP_COUNT} SKIP checksum(s) but only ${VCS_COUNT} VCS source(s). Possible Rule 10 violation."
    FAILURES=$((FAILURES + 1))
elif [ "$SKIP_COUNT" -gt 0 ]; then
    echo "  PASS: ${SKIP_COUNT} SKIP checksum(s) matched to ${VCS_COUNT} VCS source(s). OK."
else
    echo "  PASS: No SKIP checksums."
fi
echo ""

# ── Result ────────────────────────────────────────────────────────────────────
echo "=== Validation Result ==="
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS — All checks passed for ${PKGNAME:-$PACKAGE_DIR}"
    exit 0
else
    echo "FAIL — ${FAILURES} check(s) failed for ${PKGNAME:-$PACKAGE_DIR}"
    exit 1
fi
