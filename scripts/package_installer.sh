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
SWIFT_BUILD_SCRATCH_PATH="${SWIFT_BUILD_SCRATCH_PATH:-}"
STAGE_ROOT="$(mktemp -d "$TMPDIR/aimeter-installer.XXXXXX")"
COMPONENT_PKG="$STAGE_ROOT/AI Meter-component.pkg"
SOURCE_APP="$STAGE_ROOT/built/AI Meter.app"
CLEAN_APP="$STAGE_ROOT/component/AI Meter.app"
CLEAN_SCRIPTS_DIR="$STAGE_ROOT/installer-scripts"

if [[ "${PRESERVE_STAGE:-0}" == "1" ]]; then
    print "Preserving stage root: $STAGE_ROOT"
else
    trap 'rm -rf "$STAGE_ROOT"' EXIT
fi

if [[ -n "$PREBUILT_APP" ]]; then
    SOURCE_APP="$PREBUILT_APP"
else
    APP_VERSION_OVERRIDE="$APP_VERSION" \
    APP_BUILD_OVERRIDE="$APP_BUILD" \
    ARCHS="$ARCHS" \
    APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}" \
    OUTPUT_APP="$SOURCE_APP" \
    SWIFT_BUILD_SCRATCH_PATH="$SWIFT_BUILD_SCRATCH_PATH" \
        "$ROOT_DIR/scripts/package_app.sh"
fi

mkdir -p "$(dirname "$CLEAN_APP")"
ditto --norsrc --noextattr --noqtn --noacl "$SOURCE_APP" "$CLEAN_APP"
chmod -R u+w "$CLEAN_APP"
xattr -cr "$CLEAN_APP" 2>/dev/null || true
xattr -dr com.apple.provenance "$CLEAN_APP" 2>/dev/null || true
xattr -dr com.apple.FinderInfo "$CLEAN_APP" 2>/dev/null || true
xattr -dr 'com.apple.fileprovider.fpfs#P' "$CLEAN_APP" 2>/dev/null || true
codesign --verify --deep --strict "$CLEAN_APP"

ditto --norsrc --noextattr --noqtn --noacl \
    "$ROOT_DIR/scripts/installer" \
    "$CLEAN_SCRIPTS_DIR"
chmod -R u+w "$CLEAN_SCRIPTS_DIR"
xattr -cr "$CLEAN_SCRIPTS_DIR" 2>/dev/null || true
xattr -dr com.apple.provenance "$CLEAN_SCRIPTS_DIR" 2>/dev/null || true
chmod 755 "$CLEAN_SCRIPTS_DIR/preinstall" "$CLEAN_SCRIPTS_DIR/postinstall"

build_clean_component_pkg() {
    local clean_pkg_root="$STAGE_ROOT/clean-pkg"
    local clean_payload_root="$STAGE_ROOT/clean-payload"
    local clean_scripts_root="$STAGE_ROOT/clean-scripts"
    rm -rf "$clean_pkg_root" "$clean_payload_root" "$clean_scripts_root"
    mkdir -p "$clean_pkg_root" "$clean_payload_root" "$clean_scripts_root"

    ditto --norsrc --noextattr --noqtn --noacl \
        "$CLEAN_APP" \
        "$clean_payload_root/AI Meter.app"
    find "$clean_payload_root" \
        \( -name '._*' -o -name '.__*' -o -name '.DS_Store' \) \
        -delete
    mkbom "$clean_payload_root" "$clean_pkg_root/Bom"

    (
        cd "$clean_payload_root"
        find . -print \
            | LC_ALL=C sort \
            | cpio -o --format odc 2>/dev/null \
            | gzip -c > "$clean_pkg_root/Payload"
    )

    cp "$CLEAN_SCRIPTS_DIR/preinstall" "$clean_scripts_root/preinstall"
    cp "$CLEAN_SCRIPTS_DIR/postinstall" "$clean_scripts_root/postinstall"
    chmod 755 "$clean_scripts_root/preinstall" "$clean_scripts_root/postinstall"
    (
        cd "$clean_scripts_root"
        find . -print \
            | LC_ALL=C sort \
            | cpio -o --format odc 2>/dev/null \
            | gzip -c > "$clean_pkg_root/Scripts"
    )

    local file_count
    local install_kbytes
    file_count="$(find "$clean_payload_root" -print | wc -l | tr -d ' ')"
    install_kbytes="$(du -sk "$clean_payload_root" | awk '{print $1}')"

    cat > "$clean_pkg_root/PackageInfo" <<XML
<?xml version="1.0" encoding="utf-8"?>
<pkg-info overwrite-permissions="true" relocatable="false" identifier="$PACKAGE_IDENTIFIER" postinstall-action="none" version="$APP_VERSION" format-version="2" install-location="/Applications" auth="root">
    <payload numberOfFiles="$file_count" installKBytes="$install_kbytes"/>
    <bundle path="./AI Meter.app" id="com.anthonylimo.aimeter" CFBundleShortVersionString="$APP_VERSION" CFBundleVersion="$APP_BUILD"/>
    <bundle-version>
        <bundle id="com.anthonylimo.aimeter"/>
    </bundle-version>
    <upgrade-bundle>
        <bundle id="com.anthonylimo.aimeter"/>
    </upgrade-bundle>
    <update-bundle/>
    <atomic-update-bundle/>
    <strict-identifier>
        <bundle id="com.anthonylimo.aimeter"/>
    </strict-identifier>
    <relocate/>
    <scripts>
        <preinstall file="./preinstall" timeout="600"/>
        <postinstall file="./postinstall" timeout="600"/>
    </scripts>
</pkg-info>
XML

    (
        cd "$clean_pkg_root"
        xar --compression=none \
            -cf "$COMPONENT_PKG" \
            Bom Payload Scripts PackageInfo
    )
}

pkgbuild \
    --component "$CLEAN_APP" \
    --install-location "/Applications" \
    --identifier "$PACKAGE_IDENTIFIER" \
    --version "$APP_VERSION" \
    --scripts "$CLEAN_SCRIPTS_DIR" \
    "$COMPONENT_PKG"

if pkgutil --payload-files "$COMPONENT_PKG" | grep -Eq '(^|/)\._|/\.__'; then
    print "Rebuilding component package without AppleDouble metadata."
    build_clean_component_pkg
fi

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
