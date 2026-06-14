#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_VERSION="${APP_VERSION:-0.1.1}"
APP_BUILD="${APP_BUILD:-2}"
PACKAGE_IDENTIFIER="${PACKAGE_IDENTIFIER:-com.anthonylimo.aimeter.pkg}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
OUTPUT_PKG="$ROOT_DIR/dist/AI Meter-$APP_VERSION.pkg"
STAGE_ROOT="$(mktemp -d "$TMPDIR/aimeter-installer.XXXXXX")"
COMPONENT_PKG="$STAGE_ROOT/AI Meter-component.pkg"
PAYLOAD_ROOT="$STAGE_ROOT/root"
STAGED_APP="$PAYLOAD_ROOT/Applications/AI Meter.app"
BUILT_APP="$STAGE_ROOT/built/AI Meter.app"
SCRIPTS_DIR="$ROOT_DIR/scripts/installer"

trap 'rm -rf "$STAGE_ROOT"' EXIT

APP_VERSION="$APP_VERSION" APP_BUILD="$APP_BUILD" OUTPUT_APP="$BUILT_APP" \
    "$ROOT_DIR/scripts/package_app.sh"

mkdir -p "$PAYLOAD_ROOT/Applications"
COPYFILE_DISABLE=1 cp -R "$BUILT_APP" "$STAGED_APP"
xattr -cr "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

chmod 755 "$SCRIPTS_DIR/preinstall" "$SCRIPTS_DIR/postinstall"

pkgbuild \
    --root "$PAYLOAD_ROOT" \
    --install-location "/" \
    --identifier "$PACKAGE_IDENTIFIER" \
    --version "$APP_VERSION" \
    --scripts "$SCRIPTS_DIR" \
    "$COMPONENT_PKG"

mkdir -p "$ROOT_DIR/dist"
rm -f "$OUTPUT_PKG"

if [[ -n "$INSTALLER_SIGN_IDENTITY" ]]; then
    productsign \
        --sign "$INSTALLER_SIGN_IDENTITY" \
        "$COMPONENT_PKG" \
        "$OUTPUT_PKG"
else
    cp "$COMPONENT_PKG" "$OUTPUT_PKG"
fi

pkgutil --check-signature "$OUTPUT_PKG" || true
pkgutil --payload-files "$OUTPUT_PKG" | grep -q "AI Meter.app/Contents/MacOS/AIMeter"

echo "$OUTPUT_PKG"
