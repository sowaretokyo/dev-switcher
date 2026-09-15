# チーム向け配布

2026-09-15の方針: DMGを非公開GitHub Releasesで配布し、利用者が新版へ入れ替える。配布先へのアクセスはGitHubのリポジトリ権限で管理する。SparkleとApp Storeは使わない。

対象はmacOS 15以降のApple Silicon / Intel Mac。配布版にはDeveloper ID署名とAppleの公証を付ける。公開するかどうかは、担当者が実機確認後に判断する。

## 初回設定

配布先リポジトリをPrivateにし、利用者を招待する。次の結果が`PRIVATE`であることを確認する。Release workflowも生成前とアップロード直前に同じ確認を行い、公開リポジトリでは停止する。

```bash
gh repo view yamada-soware/dev-switcher-design --json visibility --jq .visibility
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

証明書の書き出しとSecretsへの登録は[GitHub公式手順](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)を参照する。このアプリではprovisioning profileは使わない。

## GitHubから配布版を準備する

1. このworkflowを既定ブランチに反映する。
2. Actions → **Prepare private DMG release** → Run workflowで対象ブランチ、`version`（例: `0.1.0`）、`build`（例: `1`）を指定する。
3. ビルド・テスト・DMG生成の検証後、署名・公証済みDMGと`SHA256SUMS.txt`を持つRelease下書きが作られる。
4. 下書きの「配布前の確認」を実施し、確認したMacと結果を記入してからPublish releaseを押す。
5. Releaseのリンクをチームへ案内する。

更新ごとにversionとbuildを増やす。既存の`vX.Y.Z`タグは上書きしない。誤った版を配った場合も、修正版を新しいバージョンとして配る。

ビルド・テスト・公証のいずれかに失敗した場合はRelease下書きの作成まで進まない。下書きは一般の読み取り権限の利用者にはまだ配布されないため、配布担当者が確認する。

## ローカルで確認・生成する

XcodeとCommand Line Toolsが必要。リポジトリ直下で実行する。

```bash
# 署名・公証前の確認用DMG（チーム配布用ではない）
APP_VERSION=0.0.0 APP_BUILD=0 bash scripts/build-dmg.sh --local
```

配布版をローカルで作る場合は、キーチェーンにDeveloper ID証明書を登録し、最初に公証の認証情報を対話入力で保存する。

```bash
security find-identity -v -p codesigning
xcrun notarytool store-credentials dev-switcher-notary

APP_VERSION=0.1.0 APP_BUILD=1 \
DEVELOPER_ID_APPLICATION='Developer ID Application: 組織名 (TEAMID)' \
NOTARYTOOL_PROFILE=dev-switcher-notary \
bash scripts/build-dmg.sh --release
```

生成先は`dist/<version>-<build>-local/`または`dist/<version>-<build>-release/`。既存の生成先がある場合は上書きせず停止する。再実行時は確認用のbuildを増やすか、失敗した生成物を担当者が確認して削除する。

ローカルで作った配布版は、非公開Releaseの下書きに`*-release.dmg`と`SHA256SUMS.txt`を添付する。署名・公証は[Apple公式手順](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)に従い、アプリとDMGの両方へ公証票を付ける。

## 配布前に確認すること

自動検証はコンパイル、Swiftテスト、両CPUのバイナリ同梱、コード署名、DMG整合性を対象とする。次は配布担当者が実機で確認し、Release下書きへ記録する。

- 開発用ビルドのない別のMacで、DMGからApplicationsへコピーして起動できる。
- JSON取り込みのAI向けガイドをコピーでき、通常プロセスを起動・停止できる。
- 旧版を終了して新版へ置き換えた後、登録済み設定が残り、既存プロセスを再検証できる。
- 対象チームのApple Silicon / Intel Macで確認した範囲を記録する。

設定は`~/Library/Application Support/DevSwitcher`に保存される。更新時はアプリ本体だけを置き換え、このディレクトリは削除しない。
