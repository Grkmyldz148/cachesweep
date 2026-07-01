#!/bin/bash
# Build a drag-to-install DMG containing Cachesweep.app + an /Applications alias.
set -euo pipefail

VERSION="${1:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Cachesweep.app"
STAGING="$ROOT/dist/dmg-staging"
DMG="$ROOT/dist/Cachesweep-$VERSION.dmg"

[ -d "$APP" ] || { echo "Cachesweep.app not found — run package.sh first"; exit 1; }

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Cachesweep" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

rm -rf "$STAGING"
echo "✓ $DMG"
