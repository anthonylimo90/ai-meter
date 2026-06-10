#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

export HOME="$ROOT_DIR/.home"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.cache/clang"
mkdir -p "$HOME" "$CLANG_MODULE_CACHE_PATH"

APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}"

swift build -c release --product AIMeter --disable-sandbox -Xswiftc -gnone
BIN_DIR="$(swift build -c release --disable-sandbox -Xswiftc -gnone --show-bin-path)"
OUTPUT_APP="$ROOT_DIR/dist/AI Meter.app"
STAGE_ROOT="$(mktemp -d "$TMPDIR/aimeter-stage.XXXXXX")"
APP_DIR="$STAGE_ROOT/AI Meter.app"
CONTENTS_DIR="$APP_DIR/Contents"

trap 'rm -rf "$STAGE_ROOT"' EXIT

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
install -m 755 "$BIN_DIR/AIMeter" "$CONTENTS_DIR/MacOS/AIMeter"

RESOURCE_BUNDLE="$BIN_DIR/AIMeter_AIMeterUI.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    ditto "$RESOURCE_BUNDLE" "$CONTENTS_DIR/Resources"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>AI Meter</string>
    <key>CFBundleExecutable</key>
    <string>AIMeter</string>
    <key>CFBundleIdentifier</key>
    <string>com.anthonylimo.aimeter</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AI Meter</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>__APP_VERSION__</string>
    <key>CFBundleVersion</key>
    <string>__APP_BUILD__</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

sed -i '' \
    -e "s/__APP_VERSION__/$APP_VERSION/g" \
    -e "s/__APP_BUILD__/$APP_BUILD/g" \
    "$CONTENTS_DIR/Info.plist"

xattr -cr "$APP_DIR"
codesign --force --deep --sign "$APP_SIGN_IDENTITY" "$APP_DIR"

mkdir -p "$ROOT_DIR/dist"
rm -rf "$OUTPUT_APP"
COPYFILE_DISABLE=1 cp -R "$APP_DIR" "$OUTPUT_APP"
xattr -cr "$OUTPUT_APP"
codesign --verify --deep "$OUTPUT_APP"

echo "$OUTPUT_APP"
