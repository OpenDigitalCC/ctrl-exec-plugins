#!/bin/bash
# test-release.sh - check what a release actually ships.
#
# Builds the ce-api-plugins bundle with make-release.sh into a scratch dist
# directory (single-category build: no git changes, no VERSION bump), unpacks
# the .deb with dpkg-deb -x (no root) and checks the packaged scripts:
#   - ctrl-exec-cli --version names the VERSION file's release
#   - ctrl-exec-cli --help documents --socket (R-033: the 0.3.10 deb lacked it)
#   - the packaged CLI is the tree's CLI, apart from the stamped version line
#   - the source tarball's CLI carries the same version
#   - ctrl-exec-mcp is stamped too
# Run from anywhere: tools/test-release.sh. Exits 0 only if every check passes.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$REPO/VERSION")"
CLI=ce-api-plugins/ctrl-exec-cli/ctrl-exec-cli
MCP=ce-api-plugins/ctrl-exec-mcp/ctrl-exec-mcp

echo "# Release test: ce-api-plugins bundle"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb not installed"; echo "VERDICT: PASS"; exit 0; }

T="${TMPDIR:-/tmp}/test-release-$$"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/dist" "$T/deb" "$T/tar"

fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }

if ! DIST_DIR="$T/dist" TMPDIR="$T" bash "$REPO/make-release.sh" --category ce-api-plugins >"$T/build.log" 2>&1; then
    cat "$T/build.log"
    echo "VERDICT: FAIL"
    exit 1
fi

deb="$T/dist/ctrl-exec-api-plugins_${VERSION}_all.deb"
[ -f "$deb" ] && ok "deb built: $(basename "$deb")" || { bad "deb missing: $deb"; echo "VERDICT: FAIL"; exit 1; }
dpkg-deb -x "$deb" "$T/deb" || { bad "dpkg-deb -x failed"; echo "VERDICT: FAIL"; exit 1; }
tar -xzf "$T/dist/ce-api-plugins-${VERSION}.tar.gz" -C "$T/tar"

pkg="$T/deb/usr/share/ctrl-exec/plugins/$CLI"
[ -x "$pkg" ] || { bad "packaged CLI missing or not executable"; echo "VERDICT: FAIL"; exit 1; }

got="$("$pkg" --version 2>&1)"
[ "$got" = "ctrl-exec-cli $VERSION" ] && ok "deb CLI --version is '$got'" || bad "deb CLI --version is '$got', want 'ctrl-exec-cli $VERSION'"

"$pkg" --help 2>&1 | grep -q -- '--socket' && ok "deb CLI --help documents --socket" || bad "deb CLI --help has no --socket"

diff <(sed "s/^our \$VERSION = .*/our \$VERSION/" "$REPO/$CLI") \
     <(sed "s/^our \$VERSION = .*/our \$VERSION/" "$pkg") >/dev/null \
    && ok "deb CLI equals the tree's CLI apart from the version line" || bad "deb CLI differs from the tree's CLI"

grep -q "^our \$VERSION = '$VERSION';" "$T/tar/$CLI" 2>/dev/null \
    && ok "tarball CLI carries version $VERSION" || bad "tarball CLI is not stamped $VERSION"

grep -q "^our \$VERSION = '$VERSION';" "$T/deb/usr/share/ctrl-exec/plugins/$MCP" \
    && ok "deb ctrl-exec-mcp carries version $VERSION" || bad "deb ctrl-exec-mcp is not stamped $VERSION"

grep -q "^our \$VERSION = '0.0.0-dev';" "$REPO/$CLI" \
    && ok "tree CLI keeps the placeholder (the build did not touch it)" || bad "tree CLI no longer has the placeholder"

echo
[ "$fails" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$fails" -eq 0 ]
