#!/bin/bash
set -Eeuo pipefail

# Standalone RPATH sanitation for an already-built app tree.
#
# Use this when a previous build was produced with a conda/Linuxbrew compiler
# on PATH: those toolchains bake "-Wl,-rpath,<prefix>/lib" into every .node
# they link, which makes rpmbuild fail with
#   ERROR 0002: file '...' contains an invalid rpath '/home/user/anaconda3/lib'
#   error: Bad exit status from /var/tmp/rpm-tmp.* (%install)
#
# Re-running the full build is not required — this repairs the artifacts in
# place. $ORIGIN-relative and system-standard entries are preserved.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_DIR/scripts/lib/common.sh"
. "$REPO_DIR/scripts/lib/rpath.sh"

APP_DIR="${APP_DIR:-$REPO_DIR/qwenwork-app}"

main() {
    [ -d "$APP_DIR" ] || error "App directory not found: $APP_DIR (run make build-app first)"
    info "Sanitizing RPATH/RUNPATH entries under: $APP_DIR"
    scrub_local_rpaths "$APP_DIR"
    info "Done. Now re-run: make package"
}

main "$@"
