#!/bin/zsh

# Generates a single-item Sparkle appcast for the current release.
#
# The appcast advertises only the latest version, which is sufficient for the
# updater to offer an update to users on any older version. The update archive
# is signed with the project's EdDSA key (Keychain by default, or ED_KEY_FILE).
#
# Required:
#   ZIP_PATH         Path to the zipped .app update archive.
#   ENCLOSURE_URL    Public download URL the archive will live at.
# Optional:
#   ED_KEY_FILE      EdDSA private key file. If unset, the Keychain key is used.
#   SIGN_UPDATE      Path to Sparkle's sign_update tool (auto-located otherwise).
#   OUTPUT           Output path (default: dist/appcast.xml).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/Config/version.env"

ZIP_PATH="${ZIP_PATH:?Set ZIP_PATH to the update archive}"
ENCLOSURE_URL="${ENCLOSURE_URL:?Set ENCLOSURE_URL to the archive download URL}"
OUTPUT="${OUTPUT:-$ROOT_DIR/dist/appcast.xml}"
FEED_URL="https://anthonylimo90.github.io/ai-meter/appcast.xml"
RELEASE_NOTES_URL="https://github.com/anthonylimo90/ai-meter/releases/tag/v$APP_VERSION"
MIN_OS="14.0"

SIGN_UPDATE="${SIGN_UPDATE:-}"
if [[ -z "$SIGN_UPDATE" ]]; then
    SIGN_UPDATE="$(
        find "$ROOT_DIR/.build" -type f \
            -path '*sparkle/Sparkle/bin/sign_update' 2>/dev/null | head -1
    )"
fi
if [[ -z "$SIGN_UPDATE" || ! -x "$SIGN_UPDATE" ]]; then
    print -u2 "Could not locate Sparkle sign_update tool"
    exit 1
fi

SIGN_ARGS=()
if [[ -n "${ED_KEY_FILE:-}" ]]; then
    SIGN_ARGS+=(--ed-key-file "$ED_KEY_FILE")
fi
# sign_update prints: sparkle:edSignature="..." length="..."
SIGNATURE_ATTRS="$("$SIGN_UPDATE" "${SIGN_ARGS[@]}" "$ZIP_PATH")"

PUBDATE="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"

mkdir -p "$(dirname "$OUTPUT")"
cat > "$OUTPUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>AI Meter</title>
    <link>$FEED_URL</link>
    <description>Updates for AI Meter, the macOS menu-bar AI usage meter.</description>
    <language>en</language>
    <item>
      <title>AI Meter $APP_VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$APP_BUILD</sparkle:version>
      <sparkle:shortVersionString>$APP_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>AI Meter $APP_VERSION. See the <a href="$RELEASE_NOTES_URL">release notes</a> for details.</p>]]></description>
      <enclosure url="$ENCLOSURE_URL" type="application/octet-stream" $SIGNATURE_ATTRS />
    </item>
  </channel>
</rss>
XML

print "$OUTPUT"
