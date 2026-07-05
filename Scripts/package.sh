#!/bin/bash
# Build a distributable Cachesweep.app bundle (menu-bar app + Sparkle).
set -euo pipefail

VERSION="${1:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Cachesweep"
BUNDLE_ID="io.cachesweep.Cachesweep"
PUBKEY="DPfB2ibXtUxBqrHb3FBYwRpi66kARex0XPps4SB+cs0="
FEED="https://github.com/Grkmyldz148/cachesweep/releases/latest/download/appcast.xml"

echo "▶︎ Release derleniyor (v$VERSION, arm64 + x86_64)…"
# per-arch build + lipo: the combined --arch invocation trips a
# "duplicate output file" SwiftDriver bug on some Xcode versions (CI runners)
swift build -c release --triple arm64-apple-macosx --package-path "$ROOT"
swift build -c release --triple x86_64-apple-macosx --package-path "$ROOT"
BIN_ARM="$(swift build -c release --triple arm64-apple-macosx --package-path "$ROOT" --show-bin-path)"
BIN_X86="$(swift build -c release --triple x86_64-apple-macosx --package-path "$ROOT" --show-bin-path)"
BIN_DIR="$BIN_ARM"

APP="$ROOT/dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

lipo -create "$BIN_ARM/$APP_NAME" "$BIN_X86/$APP_NAME" -output "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"

# SwiftPM localization / resource bundle (13 languages).
if [ -d "$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle" ]; then
  cp -R "$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle" "$APP/Contents/Resources/"
fi

# Find the bundled framework at runtime.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>$FEED</string>
  <key>SUPublicEDKey</key><string>$PUBKEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

echo "▶︎ İmzalama…"
# Developer ID varsa gerçek imza (hardened runtime + timestamp), yoksa ad-hoc.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
  echo "   Developer ID: $IDENTITY"
  sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
  FW="$APP/Contents/Frameworks/Sparkle.framework"
  # içten dışa: önce Sparkle'ın gömülü çalıştırılabilirleri (Sparkle 2 düzeni)
  [ -e "$FW/Versions/B/XPCServices/Downloader.xpc" ] && sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
  [ -e "$FW/Versions/B/XPCServices/Installer.xpc" ]  && sign "$FW/Versions/B/XPCServices/Installer.xpc"
  [ -e "$FW/Versions/B/Autoupdate" ]                 && sign "$FW/Versions/B/Autoupdate"
  [ -e "$FW/Versions/B/Updater.app" ]                && sign "$FW/Versions/B/Updater.app"
  sign "$FW"
  sign "$APP"
  codesign --verify --deep --strict "$APP" && echo "   ✓ imza doğrulandı"
else
  echo "   ⚠️  Developer ID sertifikası yok — ad-hoc imza (dağıtım için kullanma)"
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "✓ $APP  (v$VERSION)"
