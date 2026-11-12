# Dev Switcher

[![CI](https://github.com/sowaretokyo/dev-switcher/actions/workflows/ci.yml/badge.svg)](https://github.com/sowaretokyo/dev-switcher/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/sowaretokyo/dev-switcher?display_name=tag)](https://github.com/sowaretokyo/dev-switcher/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

開発サーバー・worker・Supabase・Docker Compose をまとめて起動・停止・切替できる、macOS ネイティブの開発環境マネージャー。MIT ライセンスで無料で利用できます。

## ダウンロード

**👉 [DevSwitcher.dmg をダウンロード](https://github.com/sowaretokyo/dev-switcher/releases/latest/download/DevSwitcher.dmg)**（macOS 15+ / Universal）

DMG を開き、`DevSwitcher.app` を Applications へドラッグしてください。更新時は Dev Switcher を終了してから置き換えます。登録済みの設定は保持されます。

Sparkle 対応版では、新版を自動確認して通知します。「Dev Switcher」メニューの「アップデートを確認…」から手動確認もできます。ダウンロード・インストールは利用者が実行します。Sparkle 未搭載の旧版からは、最初の一度だけ DMG で入れ替えてください。

## 特徴

- SwiftUI + AppKit のネイティブアプリ。日本語・英語に対応
- 複数の作業ディレクトリとプロセスを、1 つの開発環境にまとめて管理
- 切替元の停止と実測ポートの解放を確認してから、次の環境を起動
- Supabase / Docker Compose の起動・状態確認・停止
- `package.json` の scripts と Compose ファイルから、選んだ候補を登録
- プロセスごとのログ表示と、JSON からの開発環境の一括追加

## 使い方

1. 使用するランタイム・package manager・CLI をインストールし、ターミナルで起動コマンドが動くことを確認します。Supabase / Docker Compose を使う場合は Docker も必要です。
2. 「開発環境を追加」で作業ディレクトリを指定し、プロセスやスタックを登録します。既存の定義から候補を選ぶか、JSON から一括追加することもできます。
3. 起動する対象を選んで「起動」。別の環境へ移るときは「切替」を使います。

同時に起動する開発環境は 1 つです。アプリを終了しても開発プロセスやスタックは動き続けるため、停止したい場合はアプリ内で停止してください。

詳しい挙動は[仕様](./docs/SPEC.md)、JSON の形式は[設定ガイド](./docs/SCHEMA.md)を参照してください。[English documentation](./docs/en/SPEC.md) もあります。

## 開発

macOS 26 SDK を含む Xcode 26 以降が必要です。Swift 6 / Swift Package Manager を使い、アプリ更新には [Sparkle](https://sparkle-project.org/) を使用しています。

```bash
open Package.swift               # Xcode で開く
swift run DevSwitcher            # 起動
swift build                      # ビルド
swift test                       # テスト
python3 scripts/localization.py --check
python3 -B -m unittest discover -s Tests/Packaging -v
```

実装方針は[アーキテクチャ](./docs/ARCHITECTURE.md)、今後の予定と検証状況は[ロードマップ](./docs/ROADMAP.md)を参照してください。

## リリース

GitHub Actions の **Prepare DMG release** に `version` と `build` を指定すると、CI の検証後に Developer ID 署名・公証済みの Universal DMG を持つ Release 下書きを作成します。実機確認後に公開します。

設定とローカル生成の手順は [DISTRIBUTION.md](./DISTRIBUTION.md)、変更履歴は [Releases](https://github.com/sowaretokyo/dev-switcher/releases) を参照してください。

## ライセンス

[MIT](./LICENSE) — © 2026 [sowaretokyo](https://sowaretokyo.co.jp)
