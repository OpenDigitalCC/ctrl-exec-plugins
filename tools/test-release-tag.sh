#!/bin/bash
# test-release-tag.sh - check that a release tags the release commit (T-091).
#
# The tag v<release> must sit on a commit whose VERSION is the release and
# which carries dist/ (R-035: v0.3.11 read VERSION 0.3.12). Everything runs in
# throwaway git repositories under a temp dir, with a copy of make-release.sh:
# the real repo and this worktree are never committed to or tagged.
#   1. --tag refuses before the release is committed (no dist/ at HEAD)
#   2. a release commit that also bumped VERSION is refused (the old flow)
#   3. build, commit, --tag: tag VERSION = release, tag holds dist/, no bump
#   4. --open-next before the tag is refused; after it bumps and commits,
#      and the tag stays on the release commit
#   5. --auto against a local bare origin: tag pushed with VERSION = release,
#      main has the next version
# Run from anywhere: tools/test-release-tag.sh. Exits 0 only if all pass.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="${TMPDIR:-/tmp}/test-release-tag-$$"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

echo "# Release tag test: the tag carries the release"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

fails=0
ok()  { echo "PASS  $*"; }
bad() { echo "FAIL  $*"; fails=$((fails + 1)); }

# new_repo <dir> <version>: a throwaway repo holding the release builder and
# the three category trees, one commit, VERSION = <version>.
new_repo() {
    mkdir -p "$1"
    cp "$REPO/make-release.sh" "$1/"
    cp -a "$REPO/ce-agent-plugins" "$REPO/ce-auth-plugins" "$REPO/ce-api-plugins" "$1/"
    echo "$2" > "$1/VERSION"
    git -C "$1" init -q -b main
    git -C "$1" add -A
    git -C "$1" commit -q -m "base"
}
mr() { local d="$1"; shift; ( cd "$d" && TMPDIR="$T" bash ./make-release.sh "$@" ); }
vat() { git -C "$1" show "$2:VERSION" 2>/dev/null | tr -d '[:space:]'; }

# 1 + 2: refusals
A="$T/a"; new_repo "$A" 1.2.3
mr "$A" --no-deb >"$T/a.log" 2>&1 || { cat "$T/a.log"; bad "build failed"; echo "VERDICT: FAIL"; exit 1; }
[ "$(cat "$A/VERSION")" = "1.2.3" ] && ok "build leaves VERSION at the release" || bad "build changed VERSION to $(cat "$A/VERSION")"
if mr "$A" --tag >"$T/a.log" 2>&1; then bad "--tag succeeded with dist/ uncommitted"; else ok "--tag refused: dist/ not committed"; fi
git -C "$A" tag | grep -q . && bad "a tag was created on refusal" || ok "no tag created on refusal"

echo 1.2.4 > "$A/VERSION"
git -C "$A" add dist VERSION; git -C "$A" commit -q -m "release: 1.2.3 (old flow: bumped in the release commit)"
if mr "$A" --tag >"$T/a.log" 2>&1; then bad "--tag accepted a release commit whose VERSION is the next version"; else ok "--tag refused: release commit carries the next VERSION"; fi
git -C "$A" tag | grep -q . && bad "a tag was created on refusal" || ok "no tag created on refusal"

# 3 + 4: the manual flow
B="$T/b"; new_repo "$B" 1.2.3
mr "$B" --no-deb >"$T/b.log" 2>&1 || { cat "$T/b.log"; bad "build failed"; echo "VERDICT: FAIL"; exit 1; }
if mr "$B" --open-next >"$T/b.log" 2>&1; then bad "--open-next ran before the tag"; else ok "--open-next refused before the tag"; fi
git -C "$B" add dist; git -C "$B" commit -q -m "release: 1.2.3"
rel="$(git -C "$B" rev-parse HEAD)"
mr "$B" --tag >"$T/b.log" 2>&1 && ok "--tag on the release commit" || { cat "$T/b.log"; bad "--tag failed on the release commit"; }
[ "$(vat "$B" v1.2.3)" = "1.2.3" ] && ok "git show v1.2.3:VERSION is 1.2.3" || bad "v1.2.3:VERSION is '$(vat "$B" v1.2.3)'"
git -C "$B" ls-tree -r --name-only v1.2.3 | grep -q '^dist/ce-api-plugins-1.2.3.tar.gz$' \
    && ok "the tag carries dist/" || bad "the tag has no dist/ for 1.2.3"
[ "$(git -C "$B" rev-parse 'v1.2.3^{commit}')" = "$rel" ] && ok "the tag is on the release commit" || bad "the tag is not on the release commit"
if mr "$B" --tag >"$T/b.log" 2>&1; then bad "--tag re-tagged an existing tag"; else ok "--tag refused: tag exists"; fi
mr "$B" --open-next >"$T/b.log" 2>&1 && ok "--open-next after the tag" || { cat "$T/b.log"; bad "--open-next failed"; }
[ "$(cat "$B/VERSION")" = "1.2.4" ] && ok "VERSION is now 1.2.4" || bad "VERSION is '$(cat "$B/VERSION")'"
[ "$(git -C "$B" log -1 --format=%s)" = "chore: open 1.2.4" ] && ok "next version opened in its own commit" || bad "last commit is '$(git -C "$B" log -1 --format=%s)'"
[ "$(vat "$B" v1.2.3)" = "1.2.3" ] && ok "tag still reads 1.2.3 after opening the next version" || bad "tag VERSION moved"

# 5: --auto with a bare origin
O="$T/origin.git"; git init -q --bare -b main "$O"
C="$T/c"; new_repo "$C" 2.0.0
git -C "$C" remote add origin "$O"; git -C "$C" push -q -u origin main
mr "$C" --auto --no-deb >"$T/c.log" 2>&1 && ok "--auto completed" || { cat "$T/c.log"; bad "--auto failed"; }
[ "$(vat "$O" v2.0.0)" = "2.0.0" ] && ok "pushed tag v2.0.0 has VERSION 2.0.0" || bad "pushed tag VERSION is '$(vat "$O" v2.0.0)'"
git -C "$O" ls-tree -r --name-only v2.0.0 | grep -q '^dist/ce-agent-plugins-2.0.0.tar.gz$' \
    && ok "pushed tag carries dist/" || bad "pushed tag has no dist/"
[ "$(vat "$O" main)" = "2.0.1" ] && ok "origin main has the next version 2.0.1" || bad "origin main VERSION is '$(vat "$O" main)'"
[ "$(git -C "$O" log --format=%s main | head -2 | tr '\n' '|')" = "chore: open 2.0.1|release: 2.0.0|" ] \
    && ok "history is release then open-next" || bad "unexpected history: $(git -C "$O" log --format=%s main | head -3 | tr '\n' '|')"

echo
[ "$fails" -eq 0 ] && echo "VERDICT: PASS" || echo "VERDICT: FAIL"
[ "$fails" -eq 0 ]
