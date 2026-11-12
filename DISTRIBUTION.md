# 配布

MIT ライセンスでソースコードと DMG を公開配布するための手順。初回は GitHub Releases の DMG でインストールし、以後は Sparkle が新版を自動確認・通知する。ダウンロード・インストールは利用者が実行する。App Store は使わない。

対象はmacOS 15以降のApple Silicon / Intel Mac。配布版にはDeveloper ID署名とAppleの公証を付ける。公開するかどうかは、担当者が実機確認後に判断する。

## 初回設定

Release workflow は Public / Private のどちらでも使える。一般向けに配布する際は、リポジトリを Public にする。現在の公開範囲は次のコマンドで確認できる。リポジトリの公開範囲の変更は、この workflow では行わない。

```bash
gh repo view sowaretokyo/dev-switcher --json visibility --jq .visibility
```

GitHubのSettings → Secrets and variables → Actionsに次を登録する。証明書は秘密鍵を含むパスワード付き`.p12`を使用する。秘密情報はリポジトリやチャットに貼らない。

| 種類 | 名前 | 内容 |
| --- | --- | --- |
| Variable | `DEVELOPER_ID_APPLICATION` | `Developer ID Application: 組織名 (TEAMID)` |
| Secret | `DEVELOPER_ID_P12_BASE64` | `.p12`をBase64化した値 |
| Secret | `DEVELOPER_ID_P12_PASSWORD` | `.p12`のパスワード |
| Secret | `APPLE_ID` | 公証に使うApple Account |
| Secret | `APPLE_APP_SPECIFIC_PASSWORD` | 公証用のアプリ用パスワード |
| Secret | `APPLE_TEAM_ID` | 証明書と同じTeam ID |
| Variable | `SPARKLE_PUBLIC_ED_KEY` | 更新検証用の Ed25519 公開鍵 |
| Secret | `SPARKLE_ED_PRIVATE_KEY` | Sparkle の更新署名用秘密鍵 |

証明書の書き出しとSecretsへの登録は[GitHub公式手順](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)を参照する。このアプリではprovisioning profileは使わない。

### Sparkle の初回設定

2026-11-12 に、GitEdit と同じ既存鍵で Dev Switcher の GitHub Secret / Variable を登録済み。通常のリリースでは初回設定スクリプトを再実行しない。

Apple の Developer ID 証明書とは別に、更新アーカイブの EdDSA 署名鍵が必要。GitEdit と同じ既存鍵を共用できる。次のスクリプトはログインキーチェーンの `ed25519` アカウントから既存鍵を取得し、Dev Switcher の GitHub Secret / Variable へ登録する。新しい鍵は作らない。GitHub に既存設定があれば上書きせず止まる。GitHub CLI で対象リポジトリの設定を変更できる権限が必要。

```bash
swift package resolve
bash scripts/setup-sparkle.sh
```

専用の scratch path を使った場合は `SWIFT_BUILD_PATH=/絶対パス bash scripts/setup-sparkle.sh` と指定する。別のキーチェーンアカウントを使う場合は `SPARKLE_KEY_ACCOUNT` も指定する。秘密鍵はターミナルやチャットへ表示せず、一時書き出しはアクセス権を制限して登録後に削除する。キーチェーンの鍵を安全に保管する。GitHub に保存済みの Secret の値を読み出すことはできないため、Mac に鍵がない場合は元のキーチェーンまたは安全なバックアップを使う。配布開始後に鍵を作り直す場合は、[Sparkle の鍵ローテーション手順](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures)を確認する。

更新情報は `https://github.com/sowaretokyo/dev-switcher/releases/latest/download/appcast.xml` から取得する。GitHub Pages の設定は不要。Private のまま下書きは準備できるが、一般利用者の更新確認にはリポジトリとリリースの公開が必要である。

## GitHubから配布版を準備する

1. このworkflowを既定ブランチに反映する。
2. Actions → **Prepare DMG release** → Run workflowで対象ブランチ、`version`（v1.0.0 は `1.0.0`）、`build`（v1.0.0 は `4`）を指定する。
3. ビルド・テスト・DMG生成の検証後、署名・公証済みの`DevSwitcher.dmg`、バージョン付きDMG、`appcast.xml`、`SHA256SUMS.txt`を持つRelease下書きが作られる。
4. 下書きの「配布前の確認」を実施し、確認したMacと結果を記入してからPublish releaseを押す。
5. Release のリンクを利用者へ案内する。初回の公開配布時は、README の「公開配布の準備中」の案内を削除する。

README のダウンロード先は `https://github.com/sowaretokyo/dev-switcher/releases/latest/download/DevSwitcher.dmg`。この固定名のアセットを含むリリースを、通常リリースとして公開し、最新リリースに設定する。初回の公開時は、ログアウトしたブラウザでもダウンロードできることを確認する。

更新ごとにversionとbuildを増やす。既存の`vX.Y.Z`タグは上書きしない。誤った版を配った場合も、修正版を新しいバージョンとして配る。

Sparkle は `build`（`CFBundleVersion`）で新旧を比較するため、バージョンを上げても build を 1 に戻さない。workflow は直前の通常リリースに appcast があれば取得し、同じか小さい build を拒否する。appcast は今回の 1 件のみを含み、ダウンロード先をバージョン固定 URL にする。差分更新・プレリリースチャンネルは生成しない。

下書きの作成では利用者へ更新が届かず、通常リリースを公開して最新に設定した後に届く。Sparkle 未搭載の旧版からは、初回だけ DMG を手動で入れ替える。

公開済みの v0.1.1（build 1）には Sparkle がない。v1.0.0 への Sparkle 更新を公開前に確認する場合は、Sparkle 搭載の旧ビルドと、公開前の更新情報を配信できる検証用フィードを別途用意する。v0.1.1 からの DMG による手動更新と、Sparkle による更新は分けて記録する。検証用フィードを用意できない場合は、更新の通し操作を未確認と明記し、公開判断で扱う。

ビルド・テスト・公証のいずれかに失敗した場合はRelease下書きの作成まで進まない。下書きは一般の読み取り権限の利用者にはまだ配布されないため、配布担当者が確認する。

## ローカルで確認・生成する

macOS 26 SDKを含むXcode 26以降とCommand Line Toolsが必要。アプリの最低対応OSはmacOS 15。リポジトリ直下で実行する。

```bash
# ローカル確認用DMG（ad-hoc署名のみ・公証なし）
APP_VERSION=0.0.0 APP_BUILD=0 bash scripts/build-dmg.sh --local
```

配布版をローカルで作る場合は、キーチェーンにDeveloper ID証明書を登録し、最初に公証の認証情報を対話入力で保存する。

```bash
security find-identity -v -p codesigning
xcrun notarytool store-credentials dev-switcher-notary

export APP_VERSION=1.0.0 APP_BUILD=4
export SPARKLE_PUBLIC_ED_KEY
SPARKLE_PUBLIC_ED_KEY=$(.build/artifacts/sparkle/Sparkle/bin/generate_keys --account ed25519 -p)

DEVELOPER_ID_APPLICATION='Developer ID Application: 組織名 (TEAMID)' \
NOTARYTOOL_PROFILE=dev-switcher-notary \
bash scripts/build-dmg.sh --release

SPARKLE_KEY_ACCOUNT=ed25519 bash scripts/generate-appcast.sh
```

生成先は`dist/<version>-<build>-local/`または`dist/<version>-<build>-release/`。既存の生成先がある場合は上書きせず停止する。再実行時は確認用のbuildを増やすか、失敗した生成物を担当者が確認して削除する。

ビルドキャッシュの保存先は既定で `.build/distribution/`。別の場所を使う場合は、ビルドと appcast 生成の両方に同じ `APP_BUILD_ROOT=/絶対パス` を指定する。

ローカルで作った配布版は、Release の下書きに `DevSwitcher.dmg`、`*-release.dmg`、`appcast.xml`、`SHA256SUMS.txt` を添付する。固定名とバージョン付きの DMG は同一内容で、appcast と併せてハッシュを記録する。前回の appcast がある場合は生成時に `PREVIOUS_APPCAST=/絶対パス/appcast.xml` も指定する。署名・公証は[Apple公式手順](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)に従い、アプリと DMG の両方へ公証票を付ける。

MIT の著作権表示と許諾文は、DMG 直下の `LICENSE` と、アプリの `Contents/Resources/LICENSE` に同梱する。アプリだけを Applications へコピーしても保持される。

Sparkle の Framework と補助プロセスもアプリへ同梱し、同じ Developer ID で内側から署名する。Sparkle のライセンスは `Contents/Resources/Sparkle-LICENSE` に含める。`--local` と `swift run` では更新サーバーへ接続しない。

## 配布前に確認すること

自動検証はコンパイル、Swiftテスト、両CPUのバイナリ同梱、コード署名、DMG整合性を対象とする。次は配布担当者が実機で確認し、Release下書きへ記録する。

- 開発用ビルドのない別のMacで、DMGからApplicationsへコピーして起動できる。
- DMG とコピー後のアプリに LICENSE があり、ダウンロードしたファイルが `SHA256SUMS.txt` と一致する。
- JSON取り込みのAI向けガイドをコピーでき、通常プロセスを起動・停止できる。
- 旧版を終了して新版へ置き換えた後、登録済み設定が残り、既存プロセスを再検証できる。
- Sparkle 搭載の旧ビルドから新版の検出・ダウンロード・更新・再起動を確認する。自動確認をオフにした設定も再起動後に保持される。v1.0.0 の検証条件は上記のとおり。
- 改ざんした更新アーカイブや鍵の不一致を拒否する。更新による終了時も、手掛かり保存に失敗した場合は終了を取り消し、開発プロセスを維持する。それぞれの確認結果を分けて記録する。
- Apple Silicon / Intel Macで確認した範囲を記録する。

設定は`~/Library/Application Support/DevSwitcher`に保存される。更新時はアプリ本体だけを置き換え、このディレクトリは削除しない。
