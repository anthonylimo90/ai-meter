#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

source "$ROOT_DIR/Config/version.env"
export COPYFILE_DISABLE=1

: "${APP_SIGN_IDENTITY:?Set APP_SIGN_IDENTITY to a Developer ID Application identity}"
: "${INSTALLER_SIGN_IDENTITY:?Set INSTALLER_SIGN_IDENTITY to a Developer ID Installer identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"

PKG_PATH="$ROOT_DIR/dist/AI Meter-$APP_VERSION.pkg"
ZIP_PATH="$ROOT_DIR/dist/AI Meter-$APP_VERSION.zip"
STAGE_ROOT="$(mktemp -d "$TMPDIR/aimeter-release.XXXXXX")"
APP_PATH="$STAGE_ROOT/AI Meter.app"
ZIP_FOR_NOTARY="$STAGE_ROOT/AI Meter-$APP_VERSION.zip"

trap 'rm -rf "$STAGE_ROOT"' EXIT

ARCHS="arm64 x86_64" \
APP_SIGN_IDENTITY="$APP_SIGN_IDENTITY" \
OUTPUT_APP="$APP_PATH" \
    "$ROOT_DIR/scripts/package_app.sh"

APP_SIGNATURE="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
print "$APP_SIGNATURE" | grep -q "Authority=Developer ID Application"
print "$APP_SIGNATURE" | grep -Eq "flags=.*runtime"

rm -f "$ZIP_FOR_NOTARY"
ditto --norsrc --noextattr --noqtn --noacl \
    -c -k --keepParent "$APP_PATH" "$ZIP_FOR_NOTARY"
xcrun notarytool submit \
    "$ZIP_FOR_NOTARY" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

mkdir -p "$ROOT_DIR/dist"
rm -f "$ZIP_PATH"
ditto --norsrc --noextattr --noqtn --noacl \
    -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

ARCHS="arm64 x86_64" \
APP_SIGN_IDENTITY="$APP_SIGN_IDENTITY" \
INSTALLER_SIGN_IDENTITY="$INSTALLER_SIGN_IDENTITY" \
PREBUILT_APP="$APP_PATH" \
OUTPUT_PKG="$PKG_PATH" \
    "$ROOT_DIR/scripts/package_installer.sh"

pkgutil --check-signature "$PKG_PATH" \
    | grep -q "Developer ID Installer"
xcrun notarytool submit \
    "$PKG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$PKG_PATH"
xcrun stapler validate "$PKG_PATH"
pkgutil --check-signature "$PKG_PATH"
spctl --assess --type install --verbose=2 "$PKG_PATH"

shasum -a 256 "$ZIP_PATH" "$PKG_PATH" > "$ROOT_DIR/dist/SHA256SUMS"
print "$ZIP_PATH"
print "$PKG_PATH"
