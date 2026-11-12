#!/bin/bash
set -euo pipefail

# 初回だけ実行する。GitEdit と同じ既存の鍵を登録し、鍵の生成・ローテーションはしない。
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=sowaretokyo/dev-switcher
ACCOUNT=${SPARKLE_KEY_ACCOUNT:-ed25519}
SWIFT_BUILD_PATH=${SWIFT_BUILD_PATH:-"$ROOT/.build"}
GENERATE_KEYS="$SWIFT_BUILD_PATH/artifacts/sparkle/Sparkle/bin/generate_keys"
[[ -x "$GENERATE_KEYS" ]] || { echo 'Run swift package resolve first.' >&2; exit 1; }
EXISTING_VARIABLE=$(gh variable list --repo "$REPO" --json name --jq 'any(.[]; .name == "SPARKLE_PUBLIC_ED_KEY")')
EXISTING_SECRET=$(gh secret list --repo "$REPO" --json name --jq 'any(.[]; .name == "SPARKLE_ED_PRIVATE_KEY")')
if [[ "$EXISTING_VARIABLE" == true || "$EXISTING_SECRET" == true ]]; then
    echo 'Sparkle configuration already exists. Inspect it before rotating or repairing keys.' >&2
    exit 1
fi

export SPARKLE_PUBLIC_ED_KEY
SPARKLE_PUBLIC_ED_KEY=$("$GENERATE_KEYS" --account "$ACCOUNT" -p)
python3 "$ROOT/scripts/sparkle.py" check-key
umask 077
KEY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dev-switcher-update-key.XXXXXX")
trap 'rm -rf "$KEY_DIR"' EXIT
"$GENERATE_KEYS" --account "$ACCOUNT" -x "$KEY_DIR/private-key"
gh secret set SPARKLE_ED_PRIVATE_KEY --repo "$REPO" < "$KEY_DIR/private-key"
printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | gh variable set SPARKLE_PUBLIC_ED_KEY --repo "$REPO"
echo 'Sparkle key configured. The private key remains in the login Keychain and GitHub Actions secret.'
