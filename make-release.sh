#!/bin/bash
# make-release.sh - Build and publish versioned category tarballs
#
# Produces three tarballs in dist/:
#   ce-agent-plugins-<version>.tar.gz    ce-agent-plugins category
#   ce-auth-plugins-<version>.tar.gz     ce-auth-plugins category
#   ce-api-plugins-<version>.tar.gz      ce-api-plugins category
#
# Usage:
#   ./make-release.sh [--auto] [--dry-run] [--category <n>]
#
#   --auto           Commit, tag, and push without prompting
#   --dry-run        Show what would be built; no files written, no git changes
#   --category <n>   Build only one category: ce-agent-plugins, ce-auth-plugins, or ce-api-plugins
#                    Single-category builds do not bump version or touch git
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)      AUTO=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
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

DIST_DIR="$REPO_ROOT/dist"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

info "ctrl-exec-plugins release builder"
info "Version: $VERSION"
echo ""

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
    done
fi

BUILT=()

for category in "${CATEGORIES[@]}"; do
    src_dir="${CATEGORY_DIR[$category]}"
    tarball="${TARBALL_NAME[$category]}-${VERSION}.tar.gz"
    dest="$DIST_DIR/$tarball"

    plugin_count=$(find "$REPO_ROOT/$src_dir" -mindepth 2 -maxdepth 2 \
        -name README.md 2>/dev/null | wc -l | tr -d ' ')

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] $category -> $tarball  ($plugin_count plugin(s))"
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
    info "Done. Tarball written to dist/"
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
