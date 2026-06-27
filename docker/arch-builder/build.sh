#!/usr/bin/env bash
# build.sh — Build a WarmShower OS package inside the container.
#
# Usage (inside container):
#   build.sh <package_dir> [--sign]
#
# Arguments:
#   package_dir   — Path to the PKGBUILD directory (relative to /workspace or absolute).
#   --sign        — Sign packages after building (requires WS_SIGNING_KEY env var).
#
# Environment variables:
#   WS_SIGNING_KEY              — GPG armored export of the CI signing subkey.
#   WS_SIGNING_KEY_PASSPHRASE   — Passphrase for the signing key.
#   REPO_ARCH                   — Architecture tier (default: x86_64).
#   MAKEPKG_OPTS                — Extra flags passed to makepkg.

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
PACKAGE_DIR="${1:-}"
SIGN=false
shift || true

for arg in "$@"; do
    case "$arg" in
        --sign) SIGN=true ;;
    esac
done

if [ -z "$PACKAGE_DIR" ]; then
    echo "Usage: build.sh <package_dir> [--sign]"
    exit 1
fi

# Resolve path — allow relative paths from /workspace
if [[ "$PACKAGE_DIR" != /* ]]; then
    PACKAGE_DIR="/workspace/${PACKAGE_DIR}"
fi

if [ ! -d "$PACKAGE_DIR" ]; then
    echo "ERROR: Package directory not found: $PACKAGE_DIR"
    exit 1
fi

if [ ! -f "${PACKAGE_DIR}/PKGBUILD" ]; then
    echo "ERROR: No PKGBUILD found in: $PACKAGE_DIR"
    exit 1
fi

echo "=== WarmShower Package Builder ==="
echo "Package:      ${PACKAGE_DIR}"
echo "Architecture: ${REPO_ARCH:-x86_64}"
echo "Sign:         ${SIGN}"
echo "Date:         $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

# ── Sync package database ─────────────────────────────────────────────────────
echo "=== Refreshing package database ==="
sudo pacman -Syu --noconfirm 2>&1 | tail -5

# ── Build ──────────────────────────────────────────────────────────────────────
echo ""
echo "=== Building package ==="
cd "$PACKAGE_DIR"

# Run makepkg as the builder user (we already are builder inside the container)
MAKEPKG_FLAGS="--syncdeps --noconfirm --cleanbuild ${MAKEPKG_OPTS:-}"
makepkg $MAKEPKG_FLAGS

# ── Find built packages ───────────────────────────────────────────────────────
echo ""
echo "=== Build complete ==="
PACKAGES=("${PACKAGE_DIR}"/*.pkg.tar.zst)
if [ "${#PACKAGES[@]}" -eq 0 ] || [ ! -f "${PACKAGES[0]}" ]; then
    echo "ERROR: No *.pkg.tar.zst found after build."
    exit 1
fi

echo "Built packages:"
for pkg in "${PACKAGES[@]}"; do
    echo "  $(basename "$pkg")  ($(du -h "$pkg" | cut -f1))"
done

# ── Namcap validation ─────────────────────────────────────────────────────────
echo ""
echo "=== Namcap validation ==="
NAMCAP_ERRORS=0
for pkg in "${PACKAGES[@]}"; do
    echo "Checking: $(basename "$pkg")"
    # Check the built package binary
    if namcap "$pkg" 2>&1 | grep -E "^(E:|error:)" ; then
        echo "  WARNING: namcap errors detected in $(basename "$pkg")"
        NAMCAP_ERRORS=$((NAMCAP_ERRORS + 1))
    fi
done
# Check the PKGBUILD itself
echo "Checking: PKGBUILD"
namcap PKGBUILD 2>&1 | grep -E "^(E:|W:|error:|warning:)" || echo "  OK"

if [ "$NAMCAP_ERRORS" -gt 0 ]; then
    echo "WARNING: $NAMCAP_ERRORS package(s) had namcap errors (not fatal — review output above)"
fi

# ── Signing ───────────────────────────────────────────────────────────────────
if [ "$SIGN" = "true" ]; then
    echo ""
    echo "=== Signing packages ==="

    if [ -z "${WS_SIGNING_KEY:-}" ]; then
        echo "ERROR: --sign requested but WS_SIGNING_KEY is not set."
        echo "       Export the GPG signing subkey and set WS_SIGNING_KEY."
        exit 1
    fi

    # Import the signing key
    echo "$WS_SIGNING_KEY" | gpg --batch --import
    echo "  Signing key imported."

    # Warm up the key cache
    if [ -n "${WS_SIGNING_KEY_PASSPHRASE:-}" ]; then
        echo "${WS_SIGNING_KEY_PASSPHRASE}" | gpg --batch --passphrase-fd 0 \
            --pinentry-mode loopback --sign /dev/null 2>/dev/null || true
    fi

    # Sign each package
    for pkg in "${PACKAGES[@]}"; do
        SIG_FLAGS="--batch --detach-sign --no-armor"
        if [ -n "${WS_SIGNING_KEY_PASSPHRASE:-}" ]; then
            SIG_FLAGS="$SIG_FLAGS --passphrase ${WS_SIGNING_KEY_PASSPHRASE} --pinentry-mode loopback"
        fi
        # shellcheck disable=SC2086
        gpg $SIG_FLAGS "$pkg"
        # Verify immediately
        gpg --verify "${pkg}.sig" "$pkg" \
            && echo "  Signed and verified: $(basename "$pkg")" \
            || { echo "ERROR: Signature verification failed for $(basename "$pkg")"; exit 1; }
    done
fi

echo ""
echo "=== Summary ==="
echo "Package dir:  $PACKAGE_DIR"
echo "Packages:     ${#PACKAGES[@]}"
for pkg in "${PACKAGES[@]}"; do
    SIGSTATUS="unsigned"
    [ -f "${pkg}.sig" ] && SIGSTATUS="signed"
    echo "  $(basename "$pkg") [$SIGSTATUS]"
done
