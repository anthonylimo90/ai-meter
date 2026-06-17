#!/bin/zsh

set -euo pipefail

APP_PATH="${1:?Usage: validate_app.sh APP_PATH [EXPECTED_ARCHS]}"
EXPECTED_ARCHS="${2:-}"
EXECUTABLE="$APP_PATH/Contents/MacOS/AIMeter"
RESOURCE_BUNDLE="$APP_PATH/Contents/Resources/AIMeter_AIMeterUI.bundle"

codesign --verify --deep --strict "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null
test -x "$EXECUTABLE"
test -f "$APP_PATH/Contents/Resources/AppIcon.icns"
test -d "$RESOURCE_BUNDLE"

for asset in openai claude gemini cursor copilot; do
    test -f "$RESOURCE_BUNDLE/$asset.png"
done

if [[ -n "$EXPECTED_ARCHS" ]]; then
    ACTUAL_ARCHS="$(lipo -archs "$EXECUTABLE")"
    for arch in ${=EXPECTED_ARCHS}; do
        if [[ " $ACTUAL_ARCHS " != *" $arch "* ]]; then
            print -u2 "Missing architecture $arch in $EXECUTABLE"
            exit 1
        fi
    done
fi
