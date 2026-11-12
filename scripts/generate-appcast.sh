#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_ROOT=${APP_BUILD_ROOT:-"$ROOT/.build/distribution"}
: "${APP_VERSION:?APP_VERSION is required}"
: "${APP_BUILD:?APP_BUILD is required}"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'APP_VERSION must be X.Y.Z' >&2; exit 1; }
[[ "$APP_BUILD" =~ ^[0-9]+$ ]] || { echo 'APP_BUILD must be an integer' >&2; exit 1; }
python3 "$ROOT/scripts/sparkle.py" check-key
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" && -n "${SPARKLE_KEY_ACCOUNT:-}" ]]; then
    echo 'Specify only one Sparkle signing key source.' >&2; exit 1
fi
if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" && -z "${SPARKLE_KEY_ACCOUNT:-}" ]]; then
    echo 'SPARKLE_ED_PRIVATE_KEY or SPARKLE_KEY_ACCOUNT is required.' >&2; exit 1
fi

DIST_DIR="$ROOT/dist/$APP_VERSION-$APP_BUILD-release"
DMG_NAME="DevSwitcher-$APP_VERSION-$APP_BUILD-release.dmg"
TOOLS="$BUILD_ROOT/arm64/artifacts/sparkle/Sparkle/bin"
[[ -x "$TOOLS/generate_appcast" ]] || { echo 'Build the distribution app first.' >&2; exit 1; }
[[ -s "$DIST_DIR/$DMG_NAME" ]] || { echo "Missing release DMG: $DIST_DIR/$DMG_NAME" >&2; exit 1; }
[[ ! -e "$DIST_DIR/appcast.xml" ]] || { echo 'Appcast already exists; use a new build.' >&2; exit 1; }
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/dev-switcher-appcast.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
cp "$DIST_DIR/$DMG_NAME" "$STAGING/$DMG_NAME"

# 秘密鍵はコマンド引数やファイルに残さず、公式ツールの標準入力へ渡す。
GENERATE_ARGS=(--maximum-deltas 0 --maximum-versions 1 \
    --download-url-prefix "https://github.com/sowaretokyo/dev-switcher/releases/download/v$APP_VERSION/" \
    --link "https://github.com/sowaretokyo/dev-switcher/releases/tag/v$APP_VERSION" \
    -o "$STAGING/appcast.xml" "$STAGING")
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$TOOLS/generate_appcast" --ed-key-file - "${GENERATE_ARGS[@]}"
else
    "$TOOLS/generate_appcast" --account "$SPARKLE_KEY_ACCOUNT" "${GENERATE_ARGS[@]}"
fi

CHECK_ARGS=(validate-feed "$STAGING/appcast.xml" "$DIST_DIR/$DMG_NAME"
    --version "$APP_VERSION" --build "$APP_BUILD"
    --public-key "$SPARKLE_PUBLIC_ED_KEY")
if [[ -n "${PREVIOUS_APPCAST:-}" ]]; then
    CHECK_ARGS+=(--previous "$PREVIOUS_APPCAST")
fi
# 署名の形式だけでなく、配布アプリに埋め込む公開鍵で実際に検証する。
python3 "$ROOT/scripts/sparkle.py" "${CHECK_ARGS[@]}"
cp "$STAGING/appcast.xml" "$DIST_DIR/appcast.xml"
cd "$DIST_DIR"
shasum -a 256 "$DMG_NAME" DevSwitcher.dmg appcast.xml > SHA256SUMS.txt
echo "Created: $DIST_DIR/appcast.xml"
