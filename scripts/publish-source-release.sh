#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRY_RUN="${LOCALFLOW_RELEASE_DRY_RUN:-0}"

if [[ $# -ne 1 ]]; then
    echo "Usage: ./scripts/publish-source-release.sh <semantic-version>" >&2
    exit 2
fi
VERSION="$1"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: version must be semantic, for example 0.2.0" >&2
    exit 2
fi

if [[ "$(git status --porcelain)" != "" ]]; then
    echo "ERROR: working tree is not clean" >&2
    exit 1
fi

if [[ "$DRY_RUN" != "1" ]] && ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh is not authenticated" >&2
    exit 1
fi

HEAD_SHA="$(git rev-parse HEAD)"
REMOTE_MAIN="$(git rev-parse origin/main 2>/dev/null || true)"
if [[ -z "$REMOTE_MAIN" || "$HEAD_SHA" != "$REMOTE_MAIN" ]]; then
    echo "ERROR: HEAD is not origin/main" >&2
    exit 1
fi

if git rev-parse "refs/tags/v$VERSION" >/dev/null 2>&1; then
    echo "ERROR: tag v$VERSION already exists" >&2
    exit 1
fi

if [[ "$DRY_RUN" != "1" ]] && gh release view "v$VERSION" >/dev/null 2>&1; then
    echo "ERROR: release v$VERSION already exists" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ARCHIVE="$STAGE/LocalFlow-$VERSION-source.tar.gz"
MANIFEST="$STAGE/localflow-release.json"

echo "=== Creating source archive ==="
git archive --format=tar.gz --prefix="LocalFlow-$VERSION/" -o "$ARCHIVE" HEAD
SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
echo "Archive: $ARCHIVE"
echo "SHA-256: $SHA256"

SOURCE_URL="https://github.com/codejunkie99/LocalFlow/releases/download/v$VERSION/LocalFlow-$VERSION-source.tar.gz"

echo "=== Writing release manifest ==="
cat > "$MANIFEST" <<JSON
{"version":"$VERSION","commit":"$HEAD_SHA","source_url":"$SOURCE_URL","source_sha256":"$SHA256"}
JSON
python3 -m json.tool "$MANIFEST" >/dev/null
echo "Manifest validated: $MANIFEST"

echo "=== Tag and release commands ==="
echo "git tag v$VERSION $HEAD_SHA"
echo "gh release create v$VERSION \\"
echo "  $ARCHIVE \\"
echo "  $MANIFEST \\"
echo "  --title \"LocalFlow v$VERSION\" \\"
echo "  --notes \"Source release for LocalFlow v$VERSION. See SETUP.md for installation.\""

if [[ "$DRY_RUN" == "1" ]]; then
    echo "Dry run complete: no tag, release, or remote asset was created."
    exit 0
fi

git tag "v$VERSION" "$HEAD_SHA"
git push origin "v$VERSION"
gh release create "v$VERSION" \
    "$ARCHIVE" \
    "$MANIFEST" \
    --title "LocalFlow v$VERSION" \
    --notes "Source release for LocalFlow v$VERSION. See SETUP.md for installation."

echo "Release published: $SOURCE_URL"
