#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

source "$ROOT_DIR/Config/version.env"

export HOME="$ROOT_DIR/.home"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.cache/clang"
export COPYFILE_DISABLE=1
mkdir -p "$HOME" "$CLANG_MODULE_CACHE_PATH"

APP_VERSION="${APP_VERSION_OVERRIDE:-$APP_VERSION}"
APP_BUILD="${APP_BUILD_OVERRIDE:-$APP_BUILD}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}"
ARCHS="${ARCHS:-}"
OUTPUT_APP="${OUTPUT_APP:-$ROOT_DIR/dist/AI Meter.app}"
SWIFT_BUILD_SCRATCH_PATH="${SWIFT_BUILD_SCRATCH_PATH:-}"

BUILD_ARGS=(
    -c release
    --product AIMeter
    --disable-sandbox
    -Xswiftc -gnone
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks
)
if [[ -n "$ARCHS" ]]; then
    for arch in ${=ARCHS}; do
        BUILD_ARGS+=(--arch "$arch")
    done
fi
if [[ -n "$SWIFT_BUILD_SCRATCH_PATH" ]]; then
    BUILD_ARGS+=(--scratch-path "$SWIFT_BUILD_SCRATCH_PATH")
fi

swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
STAGE_ROOT="$(mktemp -d "$TMPDIR/aimeter-stage.XXXXXX")"
APP_DIR="$STAGE_ROOT/AI Meter.app"
CONTENTS_DIR="$APP_DIR/Contents"

trap 'rm -rf "$STAGE_ROOT"' EXIT

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
install -m 755 "$BIN_DIR/AIMeter" "$CONTENTS_DIR/MacOS/AIMeter"

# Embed Sparkle.framework (resolved by SwiftPM) so the app can self-update.
SCRATCH_ROOT="${SWIFT_BUILD_SCRATCH_PATH:-$ROOT_DIR/.build}"
SPARKLE_FRAMEWORK="$(
    find "$SCRATCH_ROOT" -type d \
        -path '*Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' \
        2>/dev/null | head -1
)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    print -u2 "Could not locate Sparkle.framework under $SCRATCH_ROOT"
    exit 1
fi
mkdir -p "$CONTENTS_DIR/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$CONTENTS_DIR/Frameworks/Sparkle.framework"

RESOURCE_BUNDLE="$BIN_DIR/AIMeter_AIMeterUI.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    ditto \
        "$RESOURCE_BUNDLE" \
        "$CONTENTS_DIR/Resources/AIMeter_AIMeterUI.bundle"
fi
install -m 644 "$ROOT_DIR/Resources/AppIcon.icns" \
    "$CONTENTS_DIR/Resources/AppIcon.icns"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    <key>SUFeedURL</key>
    <string>https://anthonylimo90.github.io/ai-meter/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>gaT7/vOc+HjQPsnNBhvea6AWhPFcGfevymaV5qI4hps=</string>
    <key>SUEnableAutomaticChecks</key>
    <false/>
</dict>
</plist>
PLIST

sed -i '' \
    -e "s/__APP_VERSION__/$APP_VERSION/g" \
    -e "s/__APP_BUILD__/$APP_BUILD/g" \
    "$CONTENTS_DIR/Info.plist"

mkdir -p "$(dirname "$OUTPUT_APP")"
rm -rf "$OUTPUT_APP"
ditto --norsrc --noextattr --noqtn --noacl "$APP_DIR" "$OUTPUT_APP"
xattr -cr "$OUTPUT_APP" 2>/dev/null || true
xattr -dr com.apple.provenance "$OUTPUT_APP" 2>/dev/null || true
xattr -dr com.apple.FinderInfo "$OUTPUT_APP" 2>/dev/null || true
xattr -dr 'com.apple.fileprovider.fpfs#P' "$OUTPUT_APP" 2>/dev/null || true

if [[ "$APP_SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$OUTPUT_APP"
else
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "$APP_SIGN_IDENTITY" \
        "$OUTPUT_APP"
fi

"$ROOT_DIR/scripts/validate_app.sh" "$OUTPUT_APP" "$ARCHS"
echo "$OUTPUT_APP"
