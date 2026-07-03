#!/bin/bash
# Build a clean drag-to-install DMG: app + /Applications alias, fixed Finder
# window layout (icon view, positions) and a volume icon. No decoration.
set -euo pipefail

VERSION="${1:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Cachesweep.app"
STAGING="$ROOT/dist/dmg-staging"
DMG="$ROOT/dist/Cachesweep-$VERSION.dmg"
RW="$ROOT/dist/Cachesweep-rw.dmg"
VOLNAME="Cachesweep"

[ -d "$APP" ] || { echo "Cachesweep.app not found — run package.sh first"; exit 1; }

rm -rf "$STAGING" "$DMG" "$RW"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"

# read-write image first, so the Finder layout can be written into it
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -fs HFS+ \
    -format UDRW -ov "$RW" >/dev/null
MOUNT_OUT="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen)"
DEV="$(echo "$MOUNT_OUT" | awk '/^\/dev\//{print $1; exit}')"
# take the real mount point from hdiutil (handles name collisions)
VOL="$(echo "$MOUNT_OUT" | grep -o '/Volumes/.*$' | tail -1)"

cleanup() { hdiutil detach "$DEV" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# the volume can take a moment to surface its files after attach
for _ in $(seq 1 20); do
  [ -f "$VOL/.VolumeIcon.icns" ] && break
  sleep 0.5
done

# window layout — retried once; Finder scripting can be briefly busy on CI
layout() {
  osascript <<OSA
tell application "Finder"
  tell disk "$(basename "$VOL")"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {420, 160, 1020, 500}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set position of item "Cachesweep.app" of container window to {150, 165}
    set position of item "Applications" of container window to {450, 165}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
}
layout || { sleep 3; layout; }

# volume icon LAST — Finder's layout pass drops the file if set earlier
cp "$ROOT/Resources/AppIcon.icns" "$VOL/.VolumeIcon.icns"
SetFile -c icnC "$VOL/.VolumeIcon.icns"
SetFile -a C "$VOL"

sync
hdiutil detach "$DEV" >/dev/null
trap - EXIT

hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"
rm -rf "$STAGING"
echo "✓ $DMG"
