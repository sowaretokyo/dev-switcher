# Dev Switcher — Swift実装ブリーフ

- ステータス: 実装開始可能
- 作成日: 2026-08-01
- MVP範囲更新: 2026-08-05
- 通常プロセスの再起動とログ通知 rev.9: 2026-09-09
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
- macOS 15以降
- 外部パッケージなしで開始する

ビルドの正はSwift Package Managerとする。

```text
Package.swift
Sources/DevSwitcher/
Tests/DevSwitcherTests/
scripts/build-app.sh        # Milestone 4で追加
```

SwiftPMのexecutable targetをSwiftUIアプリとして実装する。Milestone 3までは`swift build`と`swift test`を正とし、Milestone 4でローカル実行用の`.app`を追加する。Universal build、Developer ID署名、公証、DMG、別Mac確認はPost-MVPとする。

## 3. 推奨ディレクトリ

```text
Sources/DevSwitcher/
├─ App/
│  ├─ DevSwitcherApp.swift
│  └─ AppState.swift
├─ Domain/
│  ├─ ProjectDefinition.swift
│  ├─ WorkingDirectoryDefinition.swift
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
└─ Features/
   ├─ Dashboard/
   ├─ ProjectEditor/
   ├─ Logs/
   └─ Switching/
```

責務に応じて分割する。ファイル名と構造を守るために不自然な抽象化を増やす必要はない。

## 4. ドメインモデル

少なくとも次を別の値型として持つ。

- `ProjectDefinition`: 利用者が保存する設定
- `WorkingDirectoryDefinition`: 表示名、ローカルディレクトリ、所属するサービスID。Gitリポジトリかどうかは扱わない
- `ServiceDefinition`: 起動・終了方法とポート設定
- `CommandSpec`: 実行ファイル、引数、作業ディレクトリ
- `PortSpec`: ラベル、番号、代表指定、開くURL
- `RuntimeState`: 実プロセスから再構築する現在状態
- `ObservedRuntime`: 起動・引き継ぎ済みサービスのプロセス識別情報と実測ポート
- `SwitchState`: 停止、解放確認、起動、起動確認の進行状態

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

### 5.4 managed command（Post-MVP）

`supabase start`や`docker compose up -d`のように起動コマンド自身が終了してもサービスが残るものは、通常の子プロセスと区別する。

MVPでは通常のforeground child processだけを管理する。managed commandとDockerを設定できる旧形式を読み込んだ場合は、起動前に明示的に拒否し、通常のプロセスグループ停止へ黙ってフォールバックしない。将来対応する場合は次の責務分離を維持する。

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

停止側は`ObservedRuntime`に記録した実測ポートの解放を検証する。起動側の設定ポートは検証しない（rev.3 の判断。`DESIGN.md` の I-3 と決定 b を参照）。設定ポートは表示と「開く」URL のための補助情報であり、起動可否の根拠にしない。

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
- 設定スキーマv3で名前付き作業ディレクトリを保存し、v1/v2はサービスの既存作業パスごとに変換する
- 一時ファイルへ書いてからatomicに置き換える
- 必須値欠落、重複ID、範囲外ポート、同一サービス内の重複ポート、代表ポートなし・複数を拒否する
- ポートの入力自体は任意とし、未入力を拒否しない。サービス間の同じポートも拒否しない
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
- プロセスの生存による起動確認と「起動中」から「起動済み」への遷移
- `failurePolicy`に従った起動失敗の中断または一部停止
- 停止側の全サービス終了
- 停止側の実測ポート解放確認
- 失敗時の現在状態表示
- 一部停止と対象外
- アプリ再起動後の実プロセス再検証と、停止する・そのまま使う選択

Milestone 2ではHTTPヘルスチェックを行わない（rev.3 の判断）。全サービスの起動成功は「プロセスが既定の初期観測期間中に終了せず、観測終了時点でも管理下にあること」で判定し、利用者へ設定を求めない。種別による判定の違いも持たせない。設定ポートへHTTPリクエストを送ってはいけない。同じポートを先に取った別サービスの応答を自分の応答と誤認するため。Dockerはコマンド自身が終了してもコンテナが残るため、この判定を当てはめられない。managed commandとともにPost-MVPで実装するまで、起動前に明示的に拒否する。

再起動後の引き継ぎでは、前回観測したPIDなどを「稼働中」という事実として復元しない。再検証の手掛かりはプロジェクト設定と別に保存し、開始時刻、実行ファイル、作業ディレクトリ、期待するポートを実測して、一致したプロセスだけを候補にする。候補が一致しない場合や観測に失敗した場合は引き継がない。プロセス不存在など確実に古い手掛かりだけを自動整理し、観測不能な手掛かりは利用者が判断するまで保持する。外部プロセスは自動終了しない。

Milestone 2では切替ロジックと日常操作のUIを完成させる。複数サービスを追加・編集するUIはMilestone 3の対象とし、Milestone 2のテストでは値型から複数サービス構成を作る。自動検出、managed command、Docker lifecycleはPost-MVPとする。

### Milestone 3: 手動の複数サービス管理

- 単一の編集画面で開発環境を手動追加、編集、登録解除する
- 1開発環境に複数の名前付き作業ディレクトリを追加、削除、並べ替えする
- 作業ディレクトリごとにパスを1回指定し、複数プロセスを追加、削除、並べ替えする
- プロセス名、種別、起動コマンド、任意のポート、既定の起動対象、失敗ポリシーを編集する
- 起動済みプロジェクトは編集できず、先に停止を求める
- 既存の終了順、今回の起動対象、未対応の終了方法を編集保存で欠落させない
- 5ステップウィザード、自動検出、複製、managed command、Docker、HTTP readinessは実装しない
- 通常の起動・停止は開発環境単位とし、稼働中の通常プロセスだけ復旧用の再起動を提供する。個別起動・個別停止は実装しない

### Milestone 4: ローカル`.app`

- `scripts/build-app.sh`でローカル実行用の`.app`を生成する
- 生成した`.app`から起動、設定読込、終了時flushまで確認する
- 製品名とSwiftPMの実行ファイル名を維持する

### Post-MVP

- JavaScript、Expo、Supabase、Inngest、Docker Composeの自動検出と5ステップウィザード
- プロジェクト複製
- managed command、カスタム終了コマンド、Docker lifecycle
- HTTP readinessとカスタムヘルスチェック
- Expo QR、メニューバー、グローバルショートカット
- Universal buildの確定、Developer ID署名、公証、DMG、別Macでの初回起動確認
- XCTest UI自動化

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
- ポート未入力のサービスを保存でき、プロセスの生存だけで起動成功にできる
- 起動前に設定ポートの空き確認を行わず、HTTPリクエストも送らない
- `failurePolicy: block`の起動失敗では今回起動したサービスを安全に停止し、後続を起動しない
- `failurePolicy: continue`の起動失敗では後続を起動し、プロジェクトを一部停止として表示する
- 同じ設定ポートを持つサービスが複数あっても、保存を拒否せず設定順に起動を試行する
- 停止側で実際に起動または引き継いだ全サービスを停止する
- 停止側の全実測ポートが解放されるまで、切替先を1件も起動しない
- 起動後の実測ポートをsnapshot・UI・再検証の手掛かりへ反映する
- 切替失敗時に、切替元と切替先の現在状態を必須情報として表示する
- 起動前までの中止では切替元の停止を完了し、切替先を起動しない。起動開始後は中止を受け付けない
- アプリ再起動後に候補プロセスを実測し、停止する・そのまま使うを選べる
- PIDが再利用された場合や実測情報が一致しない場合、別プロセスを誤って引き継いだり終了したりしない
- Swift Testingで、起動順、終了順、停止側のポート解放ゲート、失敗ポリシー、PID再検証を確認する
- `swift build`と`swift test`が成功する

## 10.2 Milestone 3の完了条件

- GUIから開発環境を手動追加し、複数の名前付き作業ディレクトリとプロセスを登録できる
- 作業ディレクトリとプロセスの追加、削除、並べ替えを保存し、再起動後も同じ構成を復元できる
- プロセス名、種別、起動コマンド、任意のポート、既定の起動対象、失敗ポリシーを編集できる
- ポート未入力のWeb、Inngest、workerを保存でき、種別からポートを自動入力しない
- 同じ設定ポートを持つ複数サービスを保存できる
- 起動済みプロジェクトの編集と登録解除をUIとAPI境界の両方で拒否し、停止後は同じ操作を実行できる
- 編集対象外の終了順、今回の起動対象、未対応の終了方法を保存時に欠落させない
- v1/v2設定をv3へ変換し、既存のプロセスID、起動順、終了順、今回の起動対象を維持する
- プロジェクト設定を読み込めない状態では、古いメモリ内容による追加、更新、起動を拒否する。停止は復旧手段として維持する
- Milestone 2の起動順、停止順、排他、引き継ぎ、終了時flushの安全性を変更しない
- `swift build`と`swift test`が成功する

## 10.3 Milestone 4の完了条件

- `scripts/build-app.sh`がローカル実行用の`DevSwitcher.app`を生成する
- 生成物を起動し、設定読込、通常操作、終了時flushが動作する
- SwiftPMの`DevSwitcher`実行ファイル名と既存テストを維持する
- 署名、公証、DMG、別Mac確認を完了条件に含めない

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

## 12. Milestone 3を実装するClaude Codeへの依頼

```text
このリポジトリのCLAUDE.md、MVP_SPEC.md、DESIGN.md、IMPLEMENTATION_BRIEF.mdを全文読み、既存のMilestone 2実装を調査したうえで、IMPLEMENTATION_BRIEF.mdのMilestone 3だけを実装してください。

既存の設計資料とMilestone 2の安全性を保持してください。Swift 6＋SwiftUI＋必要箇所のみAppKit、macOS 15以降、SwiftPM、外部パッケージなしを維持してください。

最初にswift buildとswift testを実行してMilestone 2の基準線を確認し、その後「ファイル × 変更内容」の短い実装プランを提示してください。利用者のApplication Supportへテストデータを書かず、実プロセス検査やローカルlistenが禁止された実行環境では、そのテストを弱めたりskipしたりせず、未検証として報告してください。

Milestone 3は手動の開発環境管理に絞ります。単一の編集画面で開発環境を追加、編集、登録解除でき、1開発環境内に複数の名前付き作業ディレクトリとプロセスを登録できるようにしてください。各作業ディレクトリに表示名とパスを持たせ、所属プロセスの入力欄でパスを重複指定させないでください。リポジトリ型やGitの自動判定は追加しません。編集対象はプロセス名、種別、起動コマンド、任意のポート、既定の起動対象、失敗ポリシーです。ポートは任意で、種別やコマンドから推測・自動入力しないでください。同じ設定ポートを持つ複数プロセスも保存可能にします。

起動済みプロジェクトの編集と登録解除はUIだけでなくAPI境界でも拒否し、停止後に許可してください。設定ファイルを読み込めない状態では古いメモリ内容による追加、更新、起動を拒否し、停止は復旧手段として維持してください。編集画面が扱わない終了順、今回の起動対象、未対応の終了方法を保存時に欠落させないでください。必須値を空文字や0で補完せず、具体的な検証エラーを表示してください。

v1/v2設定は各プロセスの既存作業パスごとにv3へ変換し、プロセスID、起動順、終了順、今回の起動対象を維持してください。5ステップウィザード、自動検出、プロジェクト複製、作業ディレクトリまたはプロセス単位の個別起動・個別停止、managed command、カスタム終了コマンド、Docker lifecycle、HTTP readiness、配布工程は実装しないでください。Milestone 2の起動・停止・切替・排他・引き継ぎ・終了時flushを変更しないでください。最後にMilestone 3の完了条件と照合し、swift buildとswift testの成功・失敗を正確に報告してください。
```
