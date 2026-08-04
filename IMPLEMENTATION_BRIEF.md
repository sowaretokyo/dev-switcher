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
- サービス種別ごとのヘルスチェックと「起動中」から「稼働中」への遷移
- `failurePolicy`に従った起動失敗の中断または一部停止
- 停止側の全サービス終了
- 停止側の実測ポート解放確認
- 起動側の全対象ポート確認
- 失敗時の現在状態表示
- 一部停止と対象外
- アプリ再起動後の実プロセス再検証と、引き継ぐ・停止する・無視する選択

Milestone 2で扱うヘルスチェックは`DESIGN.md`の種別ごとの既定値を使い、利用者へ設定を求めない。ポートもHTTPエンドポイントも持たないworker／watcherは、プロセスが正常に起動し、短い初期観測期間に異常終了しなかったことを利用可能性の判定とする。Docker固有のhealth判定はmanaged commandとともにMilestone 3で実装する。

再起動後の引き継ぎでは、前回観測したPIDなどを「稼働中」という事実として復元しない。再検証の手掛かりはプロジェクト設定と別に保存し、開始時刻、実行ファイル、作業ディレクトリ、期待するポートを実測して、一致したプロセスだけを候補にする。候補が一致しない場合や観測に失敗した場合は引き継がない。プロセス不存在など確実に古い手掛かりだけを自動整理し、観測不能な手掛かりは利用者が判断するまで保持する。外部プロセスは自動終了しない。

Milestone 2では切替ロジックと日常操作のUIを完成させる。複数サービスを追加・編集する完成版UI、自動検出、managed command、Docker lifecycleはMilestone 3の対象とし、Milestone 2のテストでは値型から複数サービス構成を作る。

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

## 10.1 Milestone 2の完了条件

- 複数サービスを設定順に起動し、終了順（既定は起動順の逆）に停止できる
- 起動対象外のサービスを起動せず、警告や一部停止として扱わない
- listen開始だけで稼働中にせず、ヘルスチェックを通過してから稼働中にする
- `failurePolicy: block`の起動失敗では今回起動したサービスを安全に停止し、後続を起動しない
- `failurePolicy: continue`の起動失敗では後続を起動し、プロジェクトを一部停止として表示する
- 停止側で実際に起動または引き継いだ全サービスを停止する
- 停止側の全実測ポートが解放されるまで、起動側の検証へ進まない
- 起動側で今回有効な全サービスの全設定ポートが空くまで、サービスを1つも起動しない
- 切替失敗時に、切替元と切替先の現在状態を必須情報として表示する
- 起動前までの中止では切替元の停止を完了し、切替先を起動しない。起動開始後は中止を受け付けない
- アプリ再起動後に候補プロセスを実測し、引き継ぐ・停止する・無視するを選べる
- PIDが再利用された場合や実測情報が一致しない場合、別プロセスを誤って引き継いだり終了したりしない
- Swift Testingで、起動順、終了順、2段階の切替ゲート、失敗ポリシー、PID再検証を確認する
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

## 12. Milestone 2を実装するClaude Codeへの依頼

```text
このリポジトリのCLAUDE.md、MVP_SPEC.md、DESIGN.md、IMPLEMENTATION_BRIEF.mdを全文読み、既存のMilestone 1実装を調査したうえで、IMPLEMENTATION_BRIEF.mdのMilestone 2だけを実装してください。

既存の設計資料とMilestone 1の安全性を保持してください。Swift 6＋SwiftUI＋必要箇所のみAppKit、macOS 15以降、SwiftPM、外部パッケージなしを維持してください。

最初にswift buildとswift testを実行してMilestone 1の基準線を確認し、その後「ファイル × 変更内容」の短い実装プランを提示してください。ローカルポートのlistenが禁止された実行環境では、そのテストを弱めたりskipしたりせず、未検証として報告してください。

Milestone 2には、複数サービスの起動・終了順、ヘルスチェック、failurePolicy、一部停止と対象外、停止側と起動側を分けた2段階ゲート、失敗時の現在状態、アプリ再起動後の再検証と引き継ぎを含めます。切替はactorで直列化し、ゲートを通過しなければ起動フェーズへ入れない構造にしてください。

ProjectDefinitionには終了順と今回の起動対象、ServiceDefinitionには必要な終了方法を表現できるようにします。既存のschema version 1を暗黙の既定値で握りつぶさず、明示的に新形式へ変換してください。再検証の手掛かりはプロジェクト設定とは別に保存し、保存値を稼働中の事実として信用しないでください。

複数サービスを追加・編集する完成版UI、自動検出、managed command、Docker lifecycle、配布工程は実装しないでください。最後にMilestone 2の完了条件と照合し、swift buildとswift testの成功・失敗を正確に報告してください。
```
