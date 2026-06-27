#!/usr/bin/env bash
# entrypoint.sh — Container entry point for WarmShower OS package builder.
#
# Dispatches to the correct sub-script based on the first argument.
#
# Commands:
#   build   <package_dir>  — build a package with makepkg
#   test    <package_dir>  — validate checksums and namcap
#   repo    <repo_dir>     — generate / update warmshower.db from a package directory
#   help                   — show this message

set -euo pipefail

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    build)
        exec /usr/local/bin/build.sh "$@"
        ;;
    test)
        exec /usr/local/bin/test.sh "$@"
        ;;
    repo)
        # repo subcommand: regenerate warmshower.db from all *.pkg.tar.zst in a dir
        REPO_DIR="${1:-/repo}"
        DB="${REPO_DIR}/warmshower.db.tar.gz"
        PKGS=("${REPO_DIR}"/*.pkg.tar.zst)
        if [ "${#PKGS[@]}" -eq 0 ] || [ ! -f "${PKGS[0]}" ]; then
            echo "No packages found in ${REPO_DIR}"
            exit 1
        fi
        echo "=== Generating repository database ==="
        repo-add "$DB" "${PKGS[@]}"
        echo "=== Done: $DB ==="
        ;;
    help|--help|-h)
        cat <<'EOF'
WarmShower OS Package Builder — Container Help

Usage:
  docker run --rm -v $(pwd):/workspace warmshower-builder <command> [args]

Commands:
  build   <package_dir>   Build a PKGBUILD directory inside the container.
                          Output packages are written to /workspace/<package_dir>/.
  test    <package_dir>   Run namcap + verifysource on a PKGBUILD directory.
  repo    <repo_dir>      Run repo-add on all *.pkg.tar.zst in <repo_dir>
                          to generate / update warmshower.db.
  help                    Show this message.

Volumes:
  /workspace   — Mount your warmshower-pkgbuilds checkout here.
  /ccache      — Mount a persistent ccache directory for faster builds.
  /repo        — Mount your local repository output directory here.

Environment variables:
  WS_SIGNING_KEY              — GPG armored secret key export (for signing).
  WS_SIGNING_KEY_PASSPHRASE   — Passphrase for the signing key.
  REPO_ARCH                   — Architecture tier (default: x86_64).
  CCACHE_DIR                  — Override ccache directory (default: /ccache).

Examples:
  # Build warmshower-mirrorlist
  docker run --rm \
    -v $(pwd):/workspace \
    -v ~/.ccache:/ccache \
    warmshower-builder build warmshower-mirrorlist-pkg

  # Validate warmshower-keyring
  docker run --rm \
    -v $(pwd):/workspace \
    warmshower-builder test warmshower-keyring-pkg

  # Rebuild the repository database
  docker run --rm \
    -v /tmp/ws-repo:/repo \
    warmshower-builder repo /repo
EOF
        ;;
    *)
        echo "Unknown command: $COMMAND"
        echo "Run: docker run --rm warmshower-builder help"
        exit 1
        ;;
esac
