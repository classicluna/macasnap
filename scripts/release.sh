#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -ne 1 ]]; then
    echo "Usage: scripts/release.sh VERSION" >&2
    exit 2
fi
VERSION="$1"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Invalid version: $VERSION" >&2
    exit 2
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: git working tree must be clean before releasing." >&2
    exit 1
fi
if [[ "$(git branch --show-current)" != "main" ]]; then
    echo "Error: releases must be made from branch main." >&2
    exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh is required." >&2
    exit 1
fi
gh auth status >/dev/null

printf '%s\n' "$VERSION" > VERSION
git add VERSION
# VERSION may already hold this number (first release).
git diff --cached --quiet || git -c user.name="Evan Kazakin" -c user.email="evankazakin@gmail.com" commit -m "Release v$VERSION"
scripts/build-app.sh
ditto -c -k --keepParent build/Macasnap.app build/Macasnap.zip
git tag "v$VERSION"
git push origin main
git push origin "v$VERSION"
gh release create "v$VERSION" build/Macasnap.zip --title "Macasnap $VERSION" --generate-notes
