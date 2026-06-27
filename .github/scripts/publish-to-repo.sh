#!/usr/bin/env bash
# publish-to-repo.sh — Add a signed package to the WarmShower pacman repository.
#
# Usage:
#   publish-to-repo.sh <package.pkg.tar.zst> [<package2.pkg.tar.zst> ...]
#
# Required environment variables:
#   REPO_DB_PATH            — Local path to warmshower.db.tar.gz (downloaded before running)
#   R2_ACCESS_KEY_ID        — Cloudflare R2 access key ID
#   R2_SECRET_ACCESS_KEY    — Cloudflare R2 secret access key
#   R2_ACCOUNT_ID           — Cloudflare account ID
#   R2_BUCKET               — R2 bucket name (e.g. warmshower-repo)
#   WS_PACKAGE_REPOSITORY   — Public base URL of the repository.
#                             This is the SINGLE configurable URL for the entire repo.
#                             Temporary: https://<account>.r2.cloudflarestorage.com/warmshower
#                             Production: https://repo.warmshower.ai
#                             Never hardcode either value — always read from this variable.
#   REPO_ARCH               — Architecture tier (x86_64, x86_64_v3, x86_64_v4, znver4)
#
# This script:
#   1. Verifies each package has a matching .sig file
#   2. Runs repo-add to update the local warmshower.db
#   3. Uploads packages, signatures, and updated db to R2
#
# Requires: pacman (for repo-add), rclone

set -euo pipefail

PACKAGES=("$@")
REPO_NAME="warmshower"
ARCH="${REPO_ARCH:-x86_64}"
BASE_URL="${WS_PACKAGE_REPOSITORY:-https://repo.warmshower.ai}"

if [ ${#PACKAGES[@]} -eq 0 ]; then
  echo "Usage: $0 <package.pkg.tar.zst> [...]"
  exit 1
fi

# Validate all signatures exist before we start
echo "=== Verifying package signatures ==="
for pkg in "${PACKAGES[@]}"; do
  if [ ! -f "${pkg}.sig" ]; then
    echo "ERROR: Missing signature file: ${pkg}.sig"
    echo "All packages must be signed before publishing."
    exit 1
  fi
  echo "  ✓ ${pkg}.sig"
done

# Run repo-add to update the database
echo ""
echo "=== Updating repository database ==="
DB_FILE="${REPO_DB_PATH:-${REPO_NAME}.db.tar.gz}"

if [ ! -f "$DB_FILE" ]; then
  echo "  Creating new repository database: $DB_FILE"
fi

repo-add --verify --sign "$DB_FILE" "${PACKAGES[@]}"
echo "  ✓ Database updated: $DB_FILE"

# Upload to R2 using rclone
echo ""
echo "=== Uploading to WarmShower repository ($ARCH) ==="

# Configure rclone for R2 using environment variables
export RCLONE_CONFIG_WARMSHOWER_TYPE=s3
export RCLONE_CONFIG_WARMSHOWER_PROVIDER=Cloudflare
export RCLONE_CONFIG_WARMSHOWER_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export RCLONE_CONFIG_WARMSHOWER_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_WARMSHOWER_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

REMOTE_PATH="warmshower:${R2_BUCKET}/${ARCH}"

# Upload packages and signatures
for pkg in "${PACKAGES[@]}"; do
  echo "  Uploading: $(basename "$pkg")"
  rclone copy "$pkg" "$REMOTE_PATH/"
  rclone copy "${pkg}.sig" "$REMOTE_PATH/"
done

# Upload updated database files
echo "  Uploading: database files"
rclone copy "$DB_FILE" "$REMOTE_PATH/"
rclone copy "${DB_FILE%.tar.gz}" "$REMOTE_PATH/" 2>/dev/null || true
FILES_DB="${DB_FILE/.db./.files.}"
[ -f "$FILES_DB" ] && rclone copy "$FILES_DB" "$REMOTE_PATH/"
[ -f "${FILES_DB%.tar.gz}" ] && rclone copy "${FILES_DB%.tar.gz}" "$REMOTE_PATH/" 2>/dev/null || true

echo ""
echo "=== Publish complete ==="
echo "Packages are now available at:"
for pkg in "${PACKAGES[@]}"; do
  echo "  ${BASE_URL}/${ARCH}/$(basename "$pkg")"
done
