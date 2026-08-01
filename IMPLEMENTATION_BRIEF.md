# Dev Switcher — Swift実装ブリーフ

- ステータス: 実装開始可能
- 作成日: 2026-08-01
- 対象: Claude Codeおよび実装担当者

## 1. 最初に読むもの

次の順で全文を読む。

1. `CLAUDE.md`
2. `MVP_SPEC.md`
3. `DESIGN.md`
4. `IMPLEMENTATION_BRIEF.md`

`MVP_SPEC.md`をMVP範囲と受け入れ条件の正とする。`DESIGN.md`、`mock.html`、`DevSwitcher.tsx`はUIと状態遷移の参照資料であり、MVP対象外の将来UIも含む。

## 2. 技術構成

- Swift 6言語モード
- SwiftUI
- 必要箇所のみAppKit
- Foundation
- Swift Testing
- UIテストはXCTest
- macOS 15以降
- 外部パッケージなしで開始する

ビルドの正はSwift Package Managerとする。

```text
Package.swift
Sources/DevSwitcher/
Tests/DevSwitcherTests/
scripts/build-app.sh        # 配布工程で追加
```

SwiftPMのexecutable targetをSwiftUIアプリとして実装する。機能MVPを`swift build`と`swift test`で検証した後、`.app`、署名、公証、DMGの工程を追加する。

## 3. 推奨ディレクトリ

```text
Sources/DevSwitcher/
├─ App/
│  ├─ DevSwitcherApp.swift
│  └─ AppState.swift
├─ Domain/
│  ├─ ProjectDefinition.swift
│  ├─ ServiceDefinition.swift
│  ├─ RuntimeState.swift
│  ├─ SwitchState.swift
│  └─ ValidationError.swift
├─ Runtime/
│  ├─ LoginShellEnvironment.swift
│  ├─ ProcessRunner.swift
│  ├─ ProcessIdentity.swift
│  ├─ ProcessInspector.swift
│  ├─ PortInspector.swift
│  ├─ RuntimeRegistry.swift
│  └─ LifecycleAdapter.swift
├─ Switching/
│  └─ SwitchCoordinator.swift
├─ Persistence/
│  └─ ProjectStore.swift
├─ Detection/
│  └─ ProjectDetector.swift
└─ Features/
   ├─ Dashboard/
   ├─ ProjectEditor/
   ├─ ProjectWizard/
   ├─ Logs/
   └─ Switching/
```

責務に応じて分割する。ファイル名と構造を守るために不自然な抽象化を増やす必要はない。

## 4. ドメインモデル

少なくとも次を別の値型として持つ。

- `ProjectDefinition`: 利用者が保存する設定
- `ServiceDefinition`: 起動・終了方法とポート設定
- `CommandSpec`: 実行ファイル、引数、作業ディレクトリ
- `PortSpec`: ラベル、番号、代表指定、開くURL
- `RuntimeState`: 実プロセスから再構築する現在状態
- `ObservedRuntime`: 起動・引き継ぎ済みサービスのプロセス識別情報と実測ポート
- `SwitchState`: 停止、解放確認、取得確認、起動の進行状態

設定と実状態を同じ型へ保存しない。必須値が欠けた定義はデコードまたは登録時に拒否する。

## 5. プロセス実行

### 5.1 コマンド

利用者のコマンドをシェル文字列として連結しない。

```swift
struct CommandSpec: Codable, Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let workingDirectory: URL
}
```

`executable`は起動前に絶対パスへ解決する。見つからない場合は即時失敗させる。

### 5.2 GUIアプリの環境変数

Finderから起動したGUIアプリは、ターミナルと同じ`PATH`を持たない。

起動時に固定コマンドでログインシェル環境を取得し、NUL区切りで解析する。利用者が登録した値をシェルへ埋め込まない。

```text
/bin/zsh -lic '/usr/bin/env -0'
```

取得に失敗した場合、最小PATHへ黙ってフォールバックしない。原因を表示して起動を止める。

プロジェクトの`.env`および`.env.*`をDev Switcher自身は読み取らない。起動された開発コマンドが通常どおり扱う。

### 5.3 プロセスグループ

`Process.terminate()`で直接の子だけを止める設計にしない。`pnpm`やExpoが起動した孫プロセスも終了対象にする。

通常サービスは独立したプロセスグループとして起動し、停止時はグループへSIGTERMを送り、猶予後も残る場合だけ利用者確認後にSIGKILLを送る。

必要であれば`posix_spawn`と`POSIX_SPAWN_SETPGROUP`を使用する。stdoutとstderrは別のpipeから受け取り、受信時刻を付けて同じログストリームへ統合する。

### 5.4 managed command

`supabase start`や`docker compose up -d`のように起動コマンド自身が終了してもサービスが残るものは、通常の子プロセスと区別する。

- child process: プロセスグループで管理
- managed command: 明示的な終了コマンドと実測ポートで管理
- Docker: コンテナ単位で管理し、コンテナ内PIDを直接killしない

停止対象はポートの有無ではなく、起動または引き継ぎ済みの`ObservedRuntime`から決定する。

## 6. プロセスとポートの検査

- PIDだけでプロセス同一性を判定しない
- 開始時刻、実行ファイル、作業ディレクトリを保持する
- kill直前に同一性を再検証する
- listenポートは設定値とは別に実測する
- ポート検査には固定引数で`/usr/sbin/lsof`を実行してよい
- `lsof`の出力解析失敗を「ポートなし」と扱わない

停止側は`ObservedRuntime`に記録した実測ポートを検証し、起動側は今回有効なサービスの設定ポートを検証する。

## 7. 並行処理

- UI状態の更新は`@MainActor`
- プロセス管理と切替は`actor`で直列化する
- 同時に2つの起動・停止・切替を開始できないAPIにする
- キャンセル可能なのは次プロジェクトの起動前まで
- detached taskへ所有権不明の状態を渡さない

エラーをログだけに残さず、型付きエラーとしてUIへ返す。

## 8. 設定保存

- 保存先はApplication Support配下
- JSONへスキーマバージョンを含める
- 一時ファイルへ書いてからatomicに置き換える
- 必須値欠落、重複ID、範囲外ポート、代表ポートなし・複数、起動対象サービス間の重複ポートを拒否する
- 空文字や0で補完しない

保存するのはプロジェクト定義とUI設定であり、「稼働中」という実状態ではない。

## 9. 実装順

### Milestone 1: 実行可能な縦切り

最初にここだけを完成させる。

- SwiftPMプロジェクトを作成
- ドメインモデルとfail-fastな検証
- Application Supportへの設定保存
- 手動登録した1プロジェクト・1サービスの表示
- 構造化コマンドの起動
- stdout／stderrのログ表示
- プロセスグループ単位の通常終了
- 実測ポート表示
- `swift build`と`swift test`を通す

自動検出、Docker、Supabase、Inngest、切替ウィザードはMilestone 1へ混ぜない。

### Milestone 2: 安全な切替

- 複数サービスと起動・終了順
- 停止側の全サービス終了
- 停止側の実測ポート解放確認
- 起動側の全対象ポート確認
- 失敗時の現在状態表示
- 一部停止と対象外

### Milestone 3: プロジェクト管理

- 追加ウィザード
- 編集、複製、登録解除
- JavaScript、Expo、Supabase、Inngest、Docker Composeの自動検出
- managed commandとDocker lifecycle

### Milestone 4: 配布

- アプリアイコン
- `.app`生成
- Universal buildの要否確認
- Developer ID署名
- 公証
- DMG生成
- 別Macでの初回起動確認

## 10. Milestone 1の完了条件

- 未登録時の空状態が表示される
- 1件のプロジェクトとサービスを手動登録できる
- 起動ボタンで登録コマンドが指定ディレクトリから起動する
- ログをリアルタイム表示できる
- 起動したサービスと実測ポートを表示できる
- 終了ボタンで孫プロセスを含めて通常終了できる
- 不正な設定は保存前に具体的なエラーになる
- アプリを閉じても、利用者が明示的に終了していないサービスは残る
- 再起動時に保存状態を稼働中と決めつけない
- `swift build`と`swift test`が成功する

## 11. 実装開始時の禁止事項

- MVP全画面を一度に作らない
- `DevSwitcher.tsx`をWebViewで表示しない
- React、Flutter、Tauriを追加しない
- 外部パッケージを無断で追加しない
- 任意のコマンド文字列を`zsh -c`へ渡さない
- DB reset、migration、seedを実行しない
- `.env`または`.env.*`を読み取らない
- ローカルリポジトリを削除・移動しない
- lint、build、test未実行で完了報告しない

## 12. 最初のClaude Codeへの依頼

```text
このリポジトリのCLAUDE.md、MVP_SPEC.md、DESIGN.md、IMPLEMENTATION_BRIEF.mdを全文読み、IMPLEMENTATION_BRIEF.mdのMilestone 1だけを実装してください。

既存の設計資料は保持してください。Swift 6＋SwiftUI＋必要箇所のみAppKit、macOS 15以降、SwiftPM、外部パッケージなしで開始してください。

最初に「ファイル × 変更内容」の短い実装プランを提示し、その後は追加の仕様判断を広げず実装してください。プロセス実行は構造化引数、ログインシェル環境の固定取得、プロセスグループ単位の終了を守ってください。

最後にswift buildとswift testを実行し、成功・失敗を正確に報告してください。
```
