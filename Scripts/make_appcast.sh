#!/bin/bash
# Sign the release zip with the Sparkle EdDSA key and emit dist/appcast.xml.
# Local: reads key from Keychain. CI: pass key via $SPARKLE_PRIVATE_KEY.
set -euo pipefail

VERSION="${1:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="Grkmyldz148/cachesweep"
ZIP="$ROOT/dist/Cachesweep-$VERSION.zip"
SIGN="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
URL="https://github.com/$REPO/releases/download/v$VERSION/Cachesweep-$VERSION.zip"

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  SIGINFO="$("$SIGN" --ed-key-file <(printf '%s' "$SPARKLE_PRIVATE_KEY") "$ZIP")"
else
  SIGINFO="$("$SIGN" "$ZIP")"   # from local Keychain
fi
# SIGINFO looks like:  sparkle:edSignature="…" length="12345"

PUBDATE="$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"

cat > "$ROOT/dist/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Cachesweep</title>
    <description>Cachesweep updates</description>
    <language>en</language>
    <item>
      <title>$VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $SIGINFO />
    </item>
  </channel>
</rss>
XML

echo "✓ dist/appcast.xml ($VERSION)"
