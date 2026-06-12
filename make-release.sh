#!/bin/bash
# make-release.sh - Build and publish versioned category bundles
#
# For each category ("bundle") it produces, in dist/:
#   <category>-<version>.tar.gz                 source tarball
#   <category>-<version>.tar.gz.sha256          checksum
#   ctrl-exec-<cat>-plugins_<version>_all.deb   Debian package
#   ctrl-exec-<cat>-plugins_<version>_all.deb.sha256
#
# The three bundles:
#   ce-agent-plugins   -> ctrl-exec-agent-plugins
#   ce-auth-plugins    -> ctrl-exec-auth-plugins
#   ce-api-plugins     -> ctrl-exec-api-plugins
#
# Each .deb stages its category tree read-only under
#   /usr/share/ctrl-exec/plugins/<category>/
# Installing a bundle never activates a script or wires in an auth hook -
# deployment stays a deliberate operator step (see each plugin's README).
#
# Packaging is dispatched through build_packages(); only deb is implemented
# today. rpm and alpine (apk) are planned for all bundles, and an OpenWRT ipk
# for the agent bundle - see the PACKAGE FORMATS stubs below.
#
# Usage:
#   ./make-release.sh [--auto] [--dry-run] [--category <n>] [--no-deb]
#
#   --auto           Commit, tag, and push without prompting
#   --dry-run        Show what would be built; no files written, no git changes
#   --category <n>   Build only one category: ce-agent-plugins, ce-auth-plugins, or ce-api-plugins
#                    Single-category builds do not bump version or touch git
#   --no-deb         Skip Debian package builds (tarballs only)
#
# Reads version from VERSION file in the repo root.
# Run from the repo root.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

AUTO=0
DRY_RUN=0
ONLY_CATEGORY=''
BUILD_DEB=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)      AUTO=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --no-deb)    BUILD_DEB=0; shift ;;
        --category)  ONLY_CATEGORY="${2:-}"; shift 2 ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"

[[ -f "$VERSION_FILE" ]] || die "VERSION file not found."
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ -n "$VERSION" ]] || die "VERSION file is empty."
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "VERSION must be semver n.n.n, got: $VERSION"

# ---------------------------------------------------------------------------
# Category definitions
# ---------------------------------------------------------------------------

declare -A TARBALL_NAME=(
    [ce-agent-plugins]="ce-agent-plugins"
    [ce-auth-plugins]="ce-auth-plugins"
    [ce-api-plugins]="ce-api-plugins"
)

declare -A CATEGORY_DIR=(
    [ce-agent-plugins]="ce-agent-plugins"
    [ce-auth-plugins]="ce-auth-plugins"
    [ce-api-plugins]="ce-api-plugins"
)

CATEGORIES=(ce-agent-plugins ce-auth-plugins ce-api-plugins)

# Debian package name per category (the bundle's installable name).
declare -A DEB_NAME=(
    [ce-agent-plugins]="ctrl-exec-agent-plugins"
    [ce-auth-plugins]="ctrl-exec-auth-plugins"
    [ce-api-plugins]="ctrl-exec-api-plugins"
)

# Short (synopsis) description per package.
declare -A DEB_SYNOPSIS=(
    [ce-agent-plugins]="ctrl-exec agent script plugins (bundle)"
    [ce-auth-plugins]="ctrl-exec authentication-hook plugins (bundle)"
    [ce-api-plugins]="ctrl-exec API client and viewer plugins (bundle)"
)

# Extended description per package (each continuation line gets a leading space
# when written to the control file).
declare -A DEB_DESCRIPTION=(
    [ce-agent-plugins]="Curated agent-side scripts for ctrl-exec: read-only system audits and
file-transfer helpers that an agent exposes through its allowlist.
The plugin tree is staged read-only under
/usr/share/ctrl-exec/plugins/ce-agent-plugins; deploy the scripts you
need into the agent script directory and add them to scripts.conf.
Installing this package does not activate any script."
    [ce-auth-plugins]="Authentication hooks for ctrl-exec (htpasswd, unix-user,
api-key-registry, rest-query, text-file) that gate requests by exit
code (0 authorised / 1 denied / 2 bad credentials / 3 insufficient
privilege). The plugin tree is staged read-only under
/usr/share/ctrl-exec/plugins/ce-auth-plugins; deploy the hook you need
and reference it as auth_hook in ctrl-exec.conf or agent.conf.
Installing this package does not wire in any hook."
    [ce-api-plugins]="Client tooling for the ctrl-exec HTTP API: the ctrl-exec-cli, the
ctrl-exec MCP bridge, ready-to-import Postman/Insomnia/Bruno
collections, and single-file OpenAPI viewers (RapiDoc, Swagger UI,
ReDoc). The plugin tree is staged under
/usr/share/ctrl-exec/plugins/ce-api-plugins; copy the CLI onto your
PATH or open a viewer/collection as needed."
)

# Recommended companion package(s) per category. Soft: a bundle is useful for
# inspection without the dispatcher/agent installed.
declare -A DEB_RECOMMENDS=(
    [ce-agent-plugins]="ctrl-exec-agent"
    [ce-auth-plugins]="ctrl-exec-agent | ctrl-exec"
    [ce-api-plugins]="ctrl-exec"
)

DEB_MAINTAINER="OpenDigital CC <sjm@opendigital.cc>"
DEB_HOMEPAGE="https://github.com/OpenDigitalCC/ctrl-exec"

if [[ -n "$ONLY_CATEGORY" ]]; then
    [[ -v TARBALL_NAME[$ONLY_CATEGORY] ]] \
        || die "Unknown category '$ONLY_CATEGORY'. Valid: ce-agent-plugins, ce-auth-plugins, ce-api-plugins"
    CATEGORIES=("$ONLY_CATEGORY")
fi

# Full release: all three categories, git operations, version bump
FULL_RELEASE=0
[[ -z "$ONLY_CATEGORY" && $DRY_RUN -eq 0 ]] && FULL_RELEASE=1

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

for category in "${CATEGORIES[@]}"; do
    src="$REPO_ROOT/${CATEGORY_DIR[$category]}"
    [[ -d "$src" ]] || die "Category directory not found: $src"
done

if [[ $FULL_RELEASE -eq 1 ]]; then
    git rev-parse --git-dir &>/dev/null \
        || die "Not a git repository."
    git diff --quiet && git diff --cached --quiet \
        || die "Working tree has uncommitted changes. Commit or stash before releasing."
fi

if [[ $BUILD_DEB -eq 1 && $DRY_RUN -eq 0 ]]; then
    command -v dpkg-deb >/dev/null 2>&1 \
        || die "dpkg-deb not found (install dpkg-dev). Use --no-deb to skip Debian packages."
fi

DIST_DIR="$REPO_ROOT/dist"

# ---------------------------------------------------------------------------
# Packaging
# ---------------------------------------------------------------------------
#
# build_packages() is the dispatcher: for each requested output format it calls
# the matching builder for one category. Only deb is wired up today.
#
#   PACKAGE FORMATS (planned)
#     deb      build_deb       all bundles            [implemented]
#     rpm      build_rpm       all bundles            [todo]
#     apk      build_apk       all bundles (alpine)   [todo]
#     ipk      build_ipk       ce-agent-plugins only  [todo, OpenWRT agent]
#
# Each builder takes (category, version) and writes its artefact + .sha256 into
# dist/, echoing the artefact path on stdout. Add a new format by writing a
# build_<fmt> with the same contract and listing it in build_packages().

# Stage a category's deployable plugin tree into a package root under the given
# prefix. Unlike the source tarball, the native packages omit each plugin's
# dev-only test harness - both the new-style test/ directory (runners +
# generated reports) and the Perl-style t/ directory. Operators deploy plugins,
# not the test suites. Usage:
#   stage_plugin_tree <category> <dest-parent-dir>
stage_plugin_tree() {
    local category="$1" destparent="$2"
    mkdir -p "$destparent"
    tar -cf - \
        --exclude='*.bak' \
        --exclude='.git' \
        --exclude='.DS_Store' \
        --exclude='*/test' \
        --exclude='*/t' \
        -C "$REPO_ROOT" "${CATEGORY_DIR[$category]}" \
        | tar -xf - -C "$destparent"
}

# Write a checksum file next to an artefact (checksum lists the basename only).
write_sha256() {
    local artefact="$1" name
    name="$(basename "$artefact")"
    sha256sum "$artefact" | awk -v n="$name" '{print $1"  "n}' \
        > "${artefact}.sha256"
}

# build_deb <category> <version>  ->  echoes the .deb path
# Builds an Architecture: all Debian package that stages the category tree
# read-only under /usr/share/ctrl-exec/plugins/<category>/.
build_deb() {
    local category="$1" version="$2"
    local pkg="${DEB_NAME[$category]}"
    local deb="${pkg}_${version}_all.deb"
    local dest="$DIST_DIR/$deb"

    local root="$BUILD_TMP/$pkg"
    rm -rf "$root"
    mkdir -p "$root/DEBIAN"

    # Payload: the plugin tree, read-only reference copy.
    local share="$root/usr/share/ctrl-exec/plugins"
    stage_plugin_tree "$category" "$share"

    # Packaged docs: copyright + a native-package changelog.
    local docdir="$root/usr/share/doc/$pkg"
    mkdir -p "$docdir"
    cat > "$docdir/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: ctrl-exec-plugins
Source: $DEB_HOMEPAGE

Files: *
Copyright: 2026 OpenDigital CC <sjm@opendigital.cc>
License: see-individual-plugins
 This package bundles independently licensed plugins. Each plugin under
 /usr/share/ctrl-exec/plugins/$category carries its own LICENSE file; refer
 to those files for the licence terms covering each plugin.
EOF

    # Native-package changelog (Debian format), gzipped per policy.
    cat > "$docdir/changelog" <<EOF
$pkg ($version) unstable; urgency=medium

  * Bundle release $version of the $category plugins.

 -- $DEB_MAINTAINER  $(date -R)
EOF
    gzip -9n "$docdir/changelog"

    # Normalise permissions to Debian policy: 0755 dirs, 0755 executables,
    # 0644 everything else (the source tree is group-writable under the repo
    # umask, which lintian flags).
    find "$root/usr" -type d                 -exec chmod 0755 {} +
    find "$root/usr" -type f -perm /111      -exec chmod 0755 {} +
    find "$root/usr" -type f ! -perm /111    -exec chmod 0644 {} +
    chmod 0755 "$root/DEBIAN"

    # Installed-Size is in KiB, payload only (everything under the package root
    # except the DEBIAN control area).
    local isize
    isize="$(du -sk --exclude=DEBIAN "$root" | cut -f1)"

    # Control file. The extended description is indented one space per line;
    # blank lines become " .".
    {
        printf 'Package: %s\n'        "$pkg"
        printf 'Version: %s\n'        "$version"
        printf 'Architecture: all\n'
        printf 'Maintainer: %s\n'     "$DEB_MAINTAINER"
        printf 'Section: admin\n'
        printf 'Priority: optional\n'
        printf 'Homepage: %s\n'       "$DEB_HOMEPAGE"
        printf 'Recommends: %s\n'     "${DEB_RECOMMENDS[$category]}"
        printf 'Installed-Size: %s\n' "$isize"
        printf 'Description: %s\n'     "${DEB_SYNOPSIS[$category]}"
        while IFS= read -r line; do
            if [[ -z "$line" ]]; then
                printf ' .\n'
            else
                printf ' %s\n' "$line"
            fi
        done <<< "${DEB_DESCRIPTION[$category]}"
    } > "$root/DEBIAN/control"
    chmod 0644 "$root/DEBIAN/control"

    # Build with root:root ownership without needing root or fakeroot.
    dpkg-deb --root-owner-group --build "$root" "$dest" >/dev/null
    write_sha256 "$dest"
    rm -rf "$root"

    echo "$dest"
}

# build_packages <category> <version>  ->  builds every enabled format for one
# bundle. Appends each artefact path to the global BUILT_PKGS array.
build_packages() {
    local category="$1" version="$2" path
    if [[ $BUILD_DEB -eq 1 ]]; then
        path="$(build_deb "$category" "$version")"
        BUILT_PKGS+=("$path")
        info "$category -> $(basename "$path")  ($(du -h "$path" | cut -f1))"
    fi
    # Future: build_rpm / build_apk here; build_ipk for ce-agent-plugins.
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

info "ctrl-exec-plugins release builder"
info "Version: $VERSION"
echo ""

# Scratch area for package staging; always cleaned up.
BUILD_TMP="${TMPDIR:-/tmp}/ce-plugins-release-$$"
trap 'rm -rf "$BUILD_TMP"' EXIT
mkdir -p "$BUILD_TMP"

if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p "$DIST_DIR"
    # Remove previous releases for the categories being built
    for category in "${CATEGORIES[@]}"; do
        prefix="${TARBALL_NAME[$category]}"
        old_count=$(find "$DIST_DIR" -maxdepth 1 -name "${prefix}-*.tar.gz" | wc -l)
        if [[ $old_count -gt 0 ]]; then
            rm -f "$DIST_DIR/${prefix}"-*.tar.gz "$DIST_DIR/${prefix}"-*.tar.gz.sha256
            info "Removed $old_count previous $prefix release(s)."
        fi
        # Remove previous Debian packages for this bundle.
        debprefix="${DEB_NAME[$category]}"
        deb_old=$(find "$DIST_DIR" -maxdepth 1 -name "${debprefix}_*_all.deb" | wc -l)
        if [[ $deb_old -gt 0 ]]; then
            rm -f "$DIST_DIR/${debprefix}"_*_all.deb "$DIST_DIR/${debprefix}"_*_all.deb.sha256
            info "Removed $deb_old previous $debprefix package(s)."
        fi
    done
fi

BUILT=()
BUILT_PKGS=()

for category in "${CATEGORIES[@]}"; do
    src_dir="${CATEGORY_DIR[$category]}"
    tarball="${TARBALL_NAME[$category]}-${VERSION}.tar.gz"
    dest="$DIST_DIR/$tarball"

    plugin_count=$(find "$REPO_ROOT/$src_dir" -mindepth 2 -maxdepth 2 \
        -name README.md 2>/dev/null | wc -l | tr -d ' ')

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] $category -> $tarball  ($plugin_count plugin(s))"
        if [[ $BUILD_DEB -eq 1 ]]; then
            info "[dry-run] $category -> ${DEB_NAME[$category]}_${VERSION}_all.deb"
        fi
        continue
    fi

    tar -czf "$dest" \
        --exclude='*.bak' \
        --exclude='.git' \
        --exclude='.DS_Store' \
        -C "$REPO_ROOT" \
        "$src_dir"

    sha256sum "$dest" | awk '{print $1"  '"$tarball"'"}' \
        > "$DIST_DIR/${tarball}.sha256"

    size=$(du -sh "$dest" | cut -f1)
    info "$category -> $tarball  ($plugin_count plugin(s), $size)"
    BUILT+=("$dest")

    # Per-bundle native packages (deb today; rpm/apk/ipk later).
    build_packages "$category" "$VERSION"
done

echo ""

# ---------------------------------------------------------------------------
# Dry run exit
# ---------------------------------------------------------------------------

if [[ $DRY_RUN -eq 1 ]]; then
    info "Dry run complete - no files written."
    exit 0
fi

# ---------------------------------------------------------------------------
# Single-category exit (no git, no version bump)
# ---------------------------------------------------------------------------

if [[ $FULL_RELEASE -eq 0 ]]; then
    info "Done. Artefacts written to dist/"
    [[ ${#BUILT_PKGS[@]} -gt 0 ]] && info "Built ${#BUILT_PKGS[@]} package(s)."
    info "Version not bumped (single category build)."
    exit 0
fi

# ---------------------------------------------------------------------------
# Version bump (patch: n.n.n -> n.n.n+1)
# ---------------------------------------------------------------------------

MAJOR="${VERSION%%.*}"
REST="${VERSION#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"
NEXT_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
echo "$NEXT_VERSION" > "$VERSION_FILE"
info "VERSION bumped: $VERSION -> $NEXT_VERSION"

# ---------------------------------------------------------------------------
# Git: tag and optionally commit + push
# ---------------------------------------------------------------------------

TAG="v${VERSION}"

if git rev-parse "$TAG" &>/dev/null 2>&1; then
    warn "Tag $TAG already exists - skipping tag creation."
else
    git tag -a "$TAG" -m "release: $VERSION"
    info "Tagged: $TAG"
fi

echo ""
echo "================================================================"
echo " Release $VERSION complete"
echo "================================================================"
echo ""
for dest in "${BUILT[@]}"; do
    tarball=$(basename "$dest")
    echo "  Tarball:   dist/$tarball"
    echo "  Checksum:  dist/${tarball}.sha256"
done
for dest in "${BUILT_PKGS[@]}"; do
    pkg=$(basename "$dest")
    echo "  Package:   dist/$pkg"
    echo "  Checksum:  dist/${pkg}.sha256"
done
echo "  Tag:       $TAG"
echo "  Next ver:  $NEXT_VERSION"
echo ""

if [[ $AUTO -eq 1 ]]; then
    git add dist/ VERSION
    git commit -m "release: $VERSION"
    git push
    git push origin "$TAG"
    info "Released and pushed."
else
    echo "Next steps:"
    echo ""
    echo "  1. Review and commit the release:"
    echo "       git add dist/ VERSION"
    echo "       git commit -m 'release: $VERSION'"
    echo ""
    echo "  2. Push commits and tag:"
    echo "       git push && git push origin $TAG"
    echo ""
fi

echo "================================================================"
