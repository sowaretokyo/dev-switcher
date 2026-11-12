macOS 15以降のApple Silicon / Intel Macに対応したDMGです。

## v1.0.0 の変更点

- 開発環境ごとに通常プロセス、Supabase、Docker Compose をまとめて管理できます。切替時は元の環境の停止と実測ポートの解放を確認してから、次を起動します。
- `package.json` の scripts と Compose ファイルから、登録する候補を選べます。JSON からの一括追加にも対応しています。
- Mac の言語設定に合わせて日本語・英語の画面と取り込みガイドを表示します。
- この版から Sparkle による新版の確認・通知に対応します。インストールは利用者が開始します。

## インストール・更新

DMGをダウンロードし、Dev Switcherを終了してから、アプリをApplicationsへドラッグしてください。既存のアプリがある場合は置き換えます。登録済みの設定は保持されます。

`DevSwitcher.dmg` とバージョン付きの DMG は同一内容です。`SHA256SUMS.txt` に両方のハッシュを記載しています。

Sparkle 対応版からは、新版の通知または「Dev Switcher」メニューの「アップデートを確認…」で更新できます。インストールは利用者の操作で開始します。未対応の旧版からは、最初の一度だけ DMG で入れ替えてください。

MIT ライセンス。著作権者: sowaretokyo。許諾文は DMG とアプリ内に同梱しています。[ソースコードと LICENSE](https://github.com/sowaretokyo/dev-switcher)。

## Dev Switcher 1.0.0 (English)

Dev Switcher manages development processes, Supabase, and Docker Compose in one macOS app. When switching environments, it verifies that the previous one has stopped and its observed ports are free before starting the next one. You can add commands from `package.json` scripts or Compose files, or import environments from JSON. The app and import guide support Japanese and English.

This version adds Sparkle update checks and notifications. Installing an update requires your action. Older versions without Sparkle need one manual DMG replacement.

Requires macOS 15 or later on Apple Silicon or Intel. Download the DMG, quit Dev Switcher, drag `DevSwitcher.app` to Applications, and replace the existing app if prompted. Your saved environments remain in Application Support. The DMG and app include the [MIT license](https://github.com/sowaretokyo/dev-switcher/blob/main/LICENSE).

## 配布前の確認（担当者が記入してから下書きを公開）

- 確認したMac・macOS: 未記入
- DMGからの初回インストール・起動: 未確認
- DMG・アプリへのLICENSE同梱とダウンロードしたDMGのハッシュ: 未確認
- Sparkle搭載の旧ビルドからの更新・再起動: 未確認
- 更新アーカイブの署名不一致の拒否: 未確認
- 自動確認オフの設定を再起動後も保持: 未確認
- 更新時の手掛かり保存失敗で終了を取り消し、開発プロセスを維持すること: 未確認
- 新版への置き換え・設定保持・既存プロセスの再検証: 未確認
- JSON取り込みガイドの表示・通常プロセスの起動と停止: 未確認
