#!/bin/bash
# One-shot signed + notarized release.
#
#   Scripts/release.sh 0.2.0
#
# Pipeline: build & Developer ID-sign → notarize the app (via zip) → staple
# the app → Sparkle zip + EdDSA appcast → DMG (stapled app inside) → sign,
# notarize & staple the DMG. Artifacts land in dist/.
#
# One-time prerequisites:
#   1. "Developer ID Application" certificate in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → +)
#   2. Notary credentials stored once:
#      xcrun notarytool store-credentials cachesweep-notary \
#        --apple-id <apple-id-mail> --team-id <TEAMID> --password <app-specific-pw>
set -euo pipefail

VERSION="${1:?usage: release.sh <version>}"
PROFILE="${NOTARY_PROFILE:-cachesweep-notary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Cachesweep.app"
ZIP="$DIST/Cachesweep-$VERSION.zip"
DMG="$DIST/Cachesweep-$VERSION.dmg"

command -v xcrun >/dev/null || { echo "Xcode command line tools gerekli"; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "✗ Developer ID Application sertifikası bulunamadı (Xcode → Accounts → Manage Certificates)"; exit 1; }

# Notary auth: CI passes NOTARY_APPLE_ID/NOTARY_PASSWORD/NOTARY_TEAM_ID via env;
# locally the stored keychain profile is used.
if [ -n "${NOTARY_APPLE_ID:-}" ]; then
  NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
else
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || { echo "✗ Notary profili '$PROFILE' yok — önce store-credentials çalıştır (script başındaki yorum)"; exit 1; }
  NOTARY_ARGS=(--keychain-profile "$PROFILE")
fi

"$ROOT/Scripts/package.sh" "$VERSION"

echo "▶︎ Notarization (app)…"
NZIP="$DIST/notarize-tmp.zip"
ditto -c -k --keepParent "$APP" "$NZIP"
xcrun notarytool submit "$NZIP" "${NOTARY_ARGS[@]}" --wait
rm -f "$NZIP"
xcrun stapler staple "$APP"

echo "▶︎ Sparkle zip + appcast…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
"$ROOT/Scripts/make_appcast.sh" "$VERSION"

echo "▶︎ DMG…"
"$ROOT/Scripts/make_dmg.sh" "$VERSION"
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "▶︎ Notarization (dmg)…"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$DMG"

echo
echo "✓ Yayına hazır:"
echo "   $DMG           (imzalı + notarized + stapled)"
echo "   $ZIP           (Sparkle güncellemesi)"
echo "   $DIST/appcast.xml"
echo
echo "Sonraki adım: GitHub release v$VERSION → dmg + zip + appcast.xml yükle."
