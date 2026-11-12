#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ $# != 1 || ( "$1" != --local && "$1" != --release ) ]]; then
    echo 'Usage: APP_VERSION=X.Y.Z APP_BUILD=N bash scripts/build-dmg.sh --local|--release' >&2
    exit 1
fi
: "${APP_VERSION:?APP_VERSION is required}"
: "${APP_BUILD:?APP_BUILD is required}"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'APP_VERSION must be X.Y.Z' >&2; exit 1; }
[[ "$APP_BUILD" =~ ^[0-9]+$ ]] || { echo 'APP_BUILD must be an integer' >&2; exit 1; }
MODE=${1#--}
if [[ "$MODE" == release ]]; then
    : "${DEVELOPER_ID_APPLICATION:?Developer ID Application certificate name is required}"
    : "${NOTARYTOOL_PROFILE:?notarytool keychain profile is required}"
    [[ "$DEVELOPER_ID_APPLICATION" == 'Developer ID Application: '* ]] || {
        echo 'Release builds require a Developer ID Application identity.' >&2
        exit 1
    }
    NOTARY_ARGS=(--keychain-profile "$NOTARYTOOL_PROFILE")
    if [[ -n "${NOTARYTOOL_KEYCHAIN:-}" ]]; then
        NOTARY_ARGS+=(--keychain "$NOTARYTOOL_KEYCHAIN")
    fi
    export APP_SIGNING_IDENTITY="$DEVELOPER_ID_APPLICATION"
else
    export APP_SIGNING_IDENTITY=-
fi
export APP_OUTPUT_DIR="$ROOT/dist/$APP_VERSION-$APP_BUILD-$MODE"
DMG_NAME="DevSwitcher-$APP_VERSION-$APP_BUILD-$MODE.dmg"
[[ ! -e "$APP_OUTPUT_DIR" ]] || { echo "Output already exists: $APP_OUTPUT_DIR" >&2; exit 1; }

bash "$ROOT/scripts/build-app.sh"
APP="$APP_OUTPUT_DIR/DevSwitcher.app"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/dev-switcher-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

if [[ "$MODE" == release ]]; then
    # アプリにも公証票を付ける。DMGからコピーした後のオフライン起動でも検証可能にする。
    ditto -c -k --keepParent "$APP" "$STAGING/notarization.zip"
    xcrun notarytool submit "$STAGING/notarization.zip" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi

mkdir "$STAGING/volume"
ditto "$APP" "$STAGING/volume/DevSwitcher.app"
ln -s /Applications "$STAGING/volume/Applications"
cp "$ROOT/packaging/INSTALL.txt" "$STAGING/volume/インストール方法.txt"
cp "$ROOT/LICENSE" "$STAGING/volume/LICENSE"
hdiutil create -volname "Dev Switcher $APP_VERSION" -srcfolder "$STAGING/volume" \
    -format UDZO -fs HFS+ "$APP_OUTPUT_DIR/$DMG_NAME"

if [[ "$MODE" == release ]]; then
    codesign --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$APP_OUTPUT_DIR/$DMG_NAME"
    xcrun notarytool submit "$APP_OUTPUT_DIR/$DMG_NAME" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$APP_OUTPUT_DIR/$DMG_NAME"
    xcrun stapler validate "$APP_OUTPUT_DIR/$DMG_NAME"
fi
hdiutil verify "$APP_OUTPUT_DIR/$DMG_NAME"
cd "$APP_OUTPUT_DIR"
# 固定のダウンロード URL 用。署名・公証を終えた DMG をそのまま複製する。
cp "$DMG_NAME" DevSwitcher.dmg
shasum -a 256 "$DMG_NAME" DevSwitcher.dmg > SHA256SUMS.txt
echo "Created: $APP_OUTPUT_DIR/$DMG_NAME"
if [[ "$MODE" == local ]]; then
    echo 'Local preview only: this DMG has no Developer ID signature or notarization.'
fi
