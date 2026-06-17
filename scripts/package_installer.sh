#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

source "$ROOT_DIR/Config/version.env"
export COPYFILE_DISABLE=1

APP_VERSION="${APP_VERSION_OVERRIDE:-$APP_VERSION}"
APP_BUILD="${APP_BUILD_OVERRIDE:-$APP_BUILD}"
PACKAGE_IDENTIFIER="${PACKAGE_IDENTIFIER:-com.anthonylimo.aimeter.pkg}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
PREBUILT_APP="${PREBUILT_APP:-}"
ARCHS="${ARCHS:-}"
OUTPUT_PKG="${OUTPUT_PKG:-$ROOT_DIR/dist/AI Meter-$APP_VERSION.pkg}"
STAGE_ROOT="$(mktemp -d "$TMPDIR/aimeter-installer.XXXXXX")"
COMPONENT_PKG="$STAGE_ROOT/AI Meter-component.pkg"
SOURCE_APP="$STAGE_ROOT/built/AI Meter.app"
CLEAN_APP="$STAGE_ROOT/component/AI Meter.app"
CLEAN_SCRIPTS_DIR="$STAGE_ROOT/installer-scripts"

trap 'rm -rf "$STAGE_ROOT"' EXIT

if [[ -n "$PREBUILT_APP" ]]; then
    SOURCE_APP="$PREBUILT_APP"
else
    APP_VERSION_OVERRIDE="$APP_VERSION" \
    APP_BUILD_OVERRIDE="$APP_BUILD" \
    ARCHS="$ARCHS" \
    APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}" \
    OUTPUT_APP="$SOURCE_APP" \
        "$ROOT_DIR/scripts/package_app.sh"
fi

mkdir -p "$(dirname "$CLEAN_APP")"
ditto --norsrc --noextattr --noqtn --noacl "$SOURCE_APP" "$CLEAN_APP"
xattr -cr "$CLEAN_APP" 2>/dev/null || true
codesign --verify --deep --strict "$CLEAN_APP"

ditto --norsrc --noextattr --noqtn --noacl \
    "$ROOT_DIR/scripts/installer" \
    "$CLEAN_SCRIPTS_DIR"
chmod 755 "$CLEAN_SCRIPTS_DIR/preinstall" "$CLEAN_SCRIPTS_DIR/postinstall"

pkgbuild \
    --component "$CLEAN_APP" \
    --install-location "/Applications" \
    --identifier "$PACKAGE_IDENTIFIER" \
    --version "$APP_VERSION" \
    --scripts "$CLEAN_SCRIPTS_DIR" \
    "$COMPONENT_PKG"

mkdir -p "$(dirname "$OUTPUT_PKG")"
rm -f "$OUTPUT_PKG"

if [[ -n "$INSTALLER_SIGN_IDENTITY" ]]; then
    productsign \
        --sign "$INSTALLER_SIGN_IDENTITY" \
        "$COMPONENT_PKG" \
        "$OUTPUT_PKG"
    pkgutil --check-signature "$OUTPUT_PKG"
else
    cp "$COMPONENT_PKG" "$OUTPUT_PKG"
fi

pkgutil --payload-files "$OUTPUT_PKG" \
    | grep -q "AI Meter.app/Contents/MacOS/AIMeter"
if pkgutil --payload-files "$OUTPUT_PKG" | grep -Eq '(^|/)\._|/\.__'; then
    print -u2 "Installer contains AppleDouble metadata files."
    exit 1
fi

echo "$OUTPUT_PKG"
