#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_ROOT=${APP_BUILD_ROOT:-"$ROOT/.build/distribution"}
: "${APP_VERSION:?APP_VERSION is required (e.g. 0.1.0)}"
: "${APP_BUILD:?APP_BUILD is required (e.g. 1)}"
: "${APP_SIGNING_IDENTITY:?APP_SIGNING_IDENTITY is required (- for local testing)}"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'APP_VERSION must be X.Y.Z' >&2; exit 1; }
[[ "$APP_BUILD" =~ ^[0-9]+$ ]] || { echo 'APP_BUILD must be an integer' >&2; exit 1; }
if [[ "$APP_SIGNING_IDENTITY" != '-' && "$APP_SIGNING_IDENTITY" != 'Developer ID Application: '* ]]; then
    echo 'Use a Developer ID Application identity, or - for local testing.' >&2
    exit 1
fi
if [[ "$APP_SIGNING_IDENTITY" != '-' ]]; then
    python3 "$ROOT/scripts/sparkle.py" check-key
fi

OUTPUT_DIR=${APP_OUTPUT_DIR:-"$ROOT/dist/$APP_VERSION-$APP_BUILD"}
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
APP="$OUTPUT_DIR/DevSwitcher.app"
[[ ! -e "$APP" ]] || { echo "Output already exists: $APP" >&2; exit 1; }
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/dev-switcher-app.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

ICON_SOURCE="$ROOT/packaging/AppIcon.icns"
[[ -f "$ICON_SOURCE" ]] || { echo "Missing app icon: $ICON_SOURCE" >&2; exit 1; }
LICENSE_SOURCE="$ROOT/LICENSE"
[[ -s "$LICENSE_SOURCE" ]] || { echo "Missing or empty license: $LICENSE_SOURCE" >&2; exit 1; }

BINARIES=()
for ARCH in arm64 x86_64; do
    BUILD_ARGS=(--package-path "$ROOT" --scratch-path "$BUILD_ROOT/$ARCH"
        -c release --triple "$ARCH-apple-macosx15.0" --product DevSwitcher)
    swift build "${BUILD_ARGS[@]}"
    BIN_DIR=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)
    [[ -x "$BIN_DIR/DevSwitcher" ]] || { echo "Missing executable: $BIN_DIR/DevSwitcher" >&2; exit 1; }
    BINARIES+=("$BIN_DIR/DevSwitcher")
    if [[ "$ARCH" == arm64 ]]; then
        RESOURCE_BUNDLE="$BIN_DIR/DevSwitcher_DevSwitcherApp.bundle"
    fi
done

[[ -d "$RESOURCE_BUNDLE" ]] || { echo "Missing resource bundle: $RESOURCE_BUNDLE" >&2; exit 1; }
SPARKLE_ARTIFACT="$BUILD_ROOT/arm64/artifacts/sparkle/Sparkle"
SPARKLE_SOURCE="$SPARKLE_ARTIFACT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$SPARKLE_SOURCE" && -s "$SPARKLE_ARTIFACT/LICENSE" ]] || {
    echo 'Missing Sparkle framework or license.' >&2; exit 1
}
BUNDLE="$STAGING/DevSwitcher.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$BUNDLE/Contents/Frameworks"
xcrun lipo -create "${BINARIES[@]}" -output "$BUNDLE/Contents/MacOS/DevSwitcher"
chmod +x "$BUNDLE/Contents/MacOS/DevSwitcher"
ditto "$RESOURCE_BUNDLE" "$BUNDLE/Contents/Resources/DevSwitcher_DevSwitcherApp.bundle"
ditto "$ICON_SOURCE" "$BUNDLE/Contents/Resources/AppIcon.icns"
ditto "$LICENSE_SOURCE" "$BUNDLE/Contents/Resources/LICENSE"
ditto "$SPARKLE_SOURCE" "$BUNDLE/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_ARTIFACT/LICENSE" "$BUNDLE/Contents/Resources/Sparkle-LICENSE"
ditto "$ROOT/packaging/Info.plist" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $APP_BUILD" "$BUNDLE/Contents/Info.plist"
if [[ "$APP_SIGNING_IDENTITY" != '-' ]]; then
    python3 "$ROOT/scripts/sparkle.py" configure "$BUNDLE/Contents/Info.plist" --release
else
    python3 "$ROOT/scripts/sparkle.py" configure "$BUNDLE/Contents/Info.plist"
fi
plutil -lint "$BUNDLE/Contents/Info.plist"
for ARCH in arm64 x86_64; do
    xcrun lipo "$BUNDLE/Contents/MacOS/DevSwitcher" -verify_arch "$ARCH"
    xcrun lipo "$BUNDLE/Contents/Frameworks/Sparkle.framework/Sparkle" -verify_arch "$ARCH"
done

SIGN_ARGS=(--force --sign "$APP_SIGNING_IDENTITY")
if [[ "$APP_SIGNING_IDENTITY" == '-' ]]; then
    SIGN_ARGS+=(--timestamp=none)
else
    SIGN_ARGS+=(--options runtime --timestamp)
fi
# 内側から同じ署名者で署名する。--deep による一括署名は使わない。
SPARKLE="$BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
for COMPONENT in "$SPARKLE/XPCServices/Downloader.xpc" "$SPARKLE/XPCServices/Installer.xpc" \
    "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$BUNDLE/Contents/Frameworks/Sparkle.framework"; do
    [[ -e "$COMPONENT" ]] || { echo "Missing Sparkle component: $COMPONENT" >&2; exit 1; }
    codesign "${SIGN_ARGS[@]}" "$COMPONENT"
done
codesign "${SIGN_ARGS[@]}" "$BUNDLE"
codesign --verify --deep --strict --verbose=2 "$BUNDLE"
mv "$BUNDLE" "$APP"
echo "Created: $APP"
