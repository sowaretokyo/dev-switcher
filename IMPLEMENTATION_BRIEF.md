# Dev Switcher — Swift実装ブリーフ

- ステータス: 実装開始可能
- 作成日: 2026-08-01
- MVP範囲更新: 2026-08-05
- Supabase lifecycle rev.8: 2026-09-08
- 通常プロセスの再起動とログ通知 rev.9: 2026-09-09
- JSONからの一括追加: 2026-09-11
- 対象外プロセスの追加起動: 2026-09-15
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

### 5.4 managed command

`supabase start`や`docker compose up -d`のように起動コマンド自身が終了してもサービスが残るものは、通常の子プロセスと区別する。

SupabaseはCLIプロセスではなく、`supabase/config.toml`の`project_id`で同定したローカルスタックを管理する。設定ディレクトリは明示的な`--workdir`、未指定なら起動コマンドの作業ディレクトリから決定し、`SUPABASE_WORKDIR`などの周辺環境で対象を暗黙に変えない。状態は`notRunning` / `running` / `degraded` / `unknown`、管理関係は`launched` / `adopted` / `restored`として別々に保持する。単一の`active`値へ状態、資源占有、停止権限を混在させない。

設定検証では、1開発環境内のSupabaseサービスを`enabled`にかかわらず1件までとし、`project_id`の重複を登録済み開発環境全体で拒否する。`project_id`を解決できない定義も保存または起動へ進めない。

起動前にローカルSupabaseスタックを実測し、`MVP_SPEC.md` 6.1.1の状態遷移を適用する。対象workdirの`supabase status`だけでは別`project_id`のスタックを検出できないため、Supabase用のread-only inventoryでローカルスタックを列挙する。この観測を汎用Docker lifecycleやコンテナの直接停止へ拡張しない。

状態分類をCLIのstderr文字列だけで決めない。inventoryに対象コンテナが無ければ`notRunning`、DBコンテナがrunningかつhealthyで、設定ディレクトリが既知なら対象設定の`status`も成功した場合を`running`とする。inventoryの構造化されたコンテナ状態からDBコンテナの欠損・停止・unhealthyを確認できれば`degraded`とし、どれにも確定できないエラーや未対応の応答は`unknown`として変更操作を止める。設定ディレクトリが不明な外部スタックは、DBコンテナの実測だけで`running`または`degraded`を判定する。

同一スタックが`running`で引き継ぎを承認された場合はmanaged handleを登録して残りのサービスへ進み、`supabase start`を実行しない。`degraded`または別スタックの停止を承認された場合は、確認時の全`project_id`と状態をsnapshotし、実行直前のinventoryと完全一致した場合だけ、各IDへ限定した`stop`、`notRunning`の確認、対象の`start`、`running`の確認を順に行う。不一致なら変更前に確認を出し直す。どの観測失敗も`notRunning`へ倒さず、`--all`で複数対象をまとめて停止しない。

起動トランザクションでは`launchedInThisRun`と`adopted`を分離し、`failurePolicy: block`の巻き戻しは前者だけを対象にする。引き継ぎ後に後続サービスが失敗した場合、Supabaseのmanaged handleを維持して開発環境を`residual`にし、停止操作を可能にする。確認のキャンセル、`unknown`、既存スタックの停止失敗はpreflight失敗として`failurePolicy`を適用しない。`supabase start`の実行直前に再観測し、コマンド成功と`running`確認が揃った後だけ`launched`とする。起動処理失敗後に`notRunning`を確認できた場合は`failurePolicy`を適用し、それ以外は由来不明のため自動停止せず中断する。

アプリ終了時は停止せず、次回起動時にmanaged command用の手掛かりから状態を再実測する。手掛かりには少なくとも`project_id`、設定ディレクトリ、導出したlifecycleコマンドの構成同一性を持たせる。一致した`launched`または`adopted`だけを`restored`とし、不一致または観測不能な対象へ`status`や`stop`を実行しない。read-only inventoryはアプリ起動時、フォアグラウンド復帰時、起動・停止・切替の直前に更新し、定期ポーリングは行わない。起動時と復帰時に手掛かりのない外部スタックを検出しても、確認は利用者が起動または切替を実行するまで出さない。

`stop`と`status`は、`start`と同じCLI呼び出し形式および有効な設定ディレクトリから導出する。利用者が入力した任意の停止コマンド、`supabase stop --all`、`--no-backup`は拒否する。Supabase以外のmanaged commandとDockerは起動前に明示的に拒否し、通常のプロセスグループ停止へ黙ってフォールバックしない。

- child process: プロセスグループで管理
- Supabase managed command: 明示的なstatus/stopコマンドで管理
- Docker: コンテナ単位で管理し、コンテナ内PIDを直接killしない

停止対象はポートの有無ではなく、起動または引き継ぎ済みの管理方式から決定する。child processは`ObservedRuntime`、Supabase managed commandは`launched` / `adopted` / `restored`と再検証済みの`project_id`を停止根拠にする。

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

JSON取り込みは`MVP_SPEC.md` 7.5を正とする。保存形式とそのバージョン変換を共有し、プレビューでは書き込まず、追加時に登録済み定義を含めて再検証・一括保存する。Swift Testingで、設定と順序の保持、重複・不正値の拒否、保存失敗時の全件未反映、操作中の拒否、取り込み時にコマンドを実行しないことを確認する。

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

Milestone 2ではHTTPヘルスチェックを行わない（rev.3 の判断）。通常のforeground processの起動成功は「プロセスが既定の初期観測期間中に終了せず、観測終了時点でも管理下にあること」で判定し、利用者へ設定を求めない。通常プロセスの種別による判定の違いも持たせない。設定ポートへHTTPリクエストを送ってはいけない。同じポートを先に取った別サービスの応答を自分の応答と誤認するため。例外としてSupabaseはプロセス生存ではなく`status`で起動を確認し、`stop`で停止する。DockerやSupabase以外のmanaged commandはPost-MVPで対応するまで、起動前に明示的に拒否する。

再起動後の引き継ぎでは、前回観測したPIDなどを「稼働中」という事実として復元しない。再検証の手掛かりはプロジェクト設定と別に保存し、開始時刻、実行ファイル、作業ディレクトリ、期待するポートを実測して、一致したプロセスだけを候補にする。候補が一致しない場合や観測に失敗した場合は引き継がない。プロセス不存在など確実に古い手掛かりだけを自動整理し、観測不能な手掛かりは利用者が判断するまで保持する。外部プロセスは自動終了しない。

Milestone 2では切替ロジックと日常操作のUIを完成させる。複数サービスを追加・編集するUIはMilestone 3の対象とし、Milestone 2のテストでは値型から複数サービス構成を作る。自動検出、Supabase以外のmanaged command、Docker lifecycleはPost-MVPとする。

### Milestone 3: 手動の複数サービス管理

- 単一の編集画面で開発環境を手動追加、編集、登録解除する
- 1開発環境に複数の名前付き作業ディレクトリを追加、削除、並べ替えする
- 作業ディレクトリごとにパスを1回指定し、複数プロセスを追加、削除、並べ替えする
- プロセス名、種別、起動コマンド、任意のポート、既定の起動対象、失敗ポリシーを編集する
- 起動済みプロジェクトは編集できず、先に停止を求める
- 既存の終了順、今回の起動対象、未対応の終了方法を編集保存で欠落させない
- 5ステップウィザード、自動検出、複製、Supabase以外のmanaged command、Docker、HTTP readinessは実装しない
- 一括起動・停止は開発環境単位とし、稼働中の環境では通常プロセスの追加起動・再起動を提供する。追加起動は`MVP_SPEC.md` 6.1.2に従い、次回の一括起動対象を変えない。個別停止とSupabaseの個別起動・再起動は含めない

### Milestone 4: ローカル`.app`

- `scripts/build-app.sh`でローカル実行用の`.app`を生成する
- 生成した`.app`から起動、設定読込、終了時flushまで確認する
- 製品名とSwiftPMの実行ファイル名を維持する

### Post-MVP

- JavaScript、Expo、Supabase、Inngest、Docker Composeの自動検出と5ステップウィザード
- プロジェクト複製
- Supabase以外のmanaged command、カスタム終了コマンド、Docker lifecycle
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
- Supabaseの確認キャンセル、観測不能、既存スタックの停止失敗では`failurePolicy: continue`でも後続を起動しない
- 引き継いだSupabaseは後続の`failurePolicy: block`による巻き戻し対象にせず、残存ありとして停止できる
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

v1/v2設定は各プロセスの既存作業パスごとにv3へ変換し、プロセスID、起動順、終了順、今回の起動対象を維持してください。5ステップウィザード、自動検出、プロジェクト複製、作業ディレクトリまたはプロセス単位の個別起動・個別停止、Supabase以外のmanaged command、カスタム終了コマンド、Docker lifecycle、HTTP readiness、配布工程は実装しないでください。Milestone 2の起動・停止・切替・排他・引き継ぎ・終了時flushを変更しないでください。最後にMilestone 3の完了条件と照合し、swift buildとswift testの成功・失敗を正確に報告してください。
```

## 13. Supabase lifecycle rev.8を実装するClaude Codeへの依頼

```text
このリポジトリのCLAUDE.md、MVP_SPEC.md、DESIGN.md、IMPLEMENTATION_BRIEF.mdを全文読み、MVP_SPEC.md 5.5、6.1.1、11と、DESIGN.md rev.8を正としてSupabase lifecycle rev.8を実装してください。

作業ツリーにはSupabase lifecycleの部分実装を含む未コミット差分があります。最初にgit status --shortとgit diffを確認し、既存差分を破棄・巻き戻し・上書きしないでください。その後、変更前のswift buildとswift testを実行し、成功・失敗を基準線として記録してください。実装前に、次の形式で短いプランを提示してください。

| ファイル | 変更内容 |
| --- | --- |
| 対象ファイル | そのファイルが受け持つ責務と変更点 |

目的は、Supabase CLIプロセスではなく、`supabase/config.toml`の`project_id`で識別したローカルスタックを安全に観測・起動・引き継ぎ・停止することです。1開発環境につきSupabaseサービスは1件まで、`project_id`は登録済み開発環境全体で一意とします。複数スタックの同時利用と、同じスタックを複数の開発環境から共有する機能は実装しません。

現状の部分実装は完成形ではありません。少なくとも次を置き換えてください。

- `ManagedCommandSupervisor.Status`の`running` / `stopped` / `incomplete`と単一の`active`値を、実測状態`notRunning` / `running` / `degraded` / `unknown`と、管理関係`launched` / `adopted` / `restored`へ分離する
- `supabase status`のstderr文字列から停止・不完全状態を推測する処理を、Dockerの構造化されたread-only inventoryへ置き換える
- `supabase stop`の終了コード0だけで停止済みとせず、対象`project_id`が`notRunning`になったことを再観測する
- 同一`project_id`の`running`を起動失敗にするpreflightを、引き継ぎ確認へ置き換える
- 承認済みサービスIDの集合だけを渡すAPIを、対象`project_id`、確認時の全スタックと状態、対象設定のfingerprintを含む承認snapshotへ置き換える
- 起動時だけのmanaged hint再検証に、フォアグラウンド復帰時と起動・停止・切替直前の再観測を加える。定期ポーリングは追加しない

想定する変更責務は次のとおりです。既存責務に合わなければファイル分割は変更して構いませんが、状態、観測、停止権限を1つのBoolへまとめないでください。

| ファイル | 変更内容 |
| --- | --- |
| `Sources/DevSwitcherCore/Domain/ServiceDefinition.swift` | Supabaseの設定ディレクトリ、`project_id`、start/status/対象限定stopを構造化して導出する。`--all`、`--no-backup`、任意stopを生成できない型にする |
| `Sources/DevSwitcherCore/Domain/ProjectValidator.swift`、`ValidationError.swift` | 1開発環境2件以上のSupabaseと、登録済み開発環境間の`project_id`重複を具体的なエラーで拒否する |
| `Sources/DevSwitcherCore/Domain/RuntimeState.swift`、`SwitchState.swift` | 4つの実測状態、3つの管理関係、確認snapshotと結果を別型で表現する |
| `Sources/DevSwitcherCore/Runtime/ManagedCommandSupervisor.swift` | `active`とstderr判定を廃止し、inventory、status、start、対象限定stop、停止後確認を組み合わせる |
| `Sources/DevSwitcherCore/Runtime/RuntimeRegistry.swift` | `launched` / `adopted` / `restored`のhandleを登録し、状態ではなく管理関係と再検証済みIDを停止権限にする |
| `Sources/DevSwitcherCore/Persistence/RuntimeHintStore.swift` | `project_id`、設定ディレクトリ、lifecycle fingerprintを保存する。旧hintを根拠にstatus/stopを実行しない |
| `Sources/DevSwitcherCore/Switching/SwitchCoordinator.swift` | 全スタックのpreflight、承認snapshotの再検証、個別停止、引き継ぎ、failurePolicy、巻き戻しを1つの排他トランザクションとして実装する |
| `Sources/DevSwitcher/App/AppState.swift`、`DevSwitcherApp.swift` | 起動・切替時だけ確認を出し、アプリ起動・フォアグラウンド復帰時は観測と表示更新だけを直列実行する |
| `Sources/DevSwitcher/Features/Switching/` | 同一IDの引き継ぎ、degradedの復旧、別IDへの切替を1つのSupabase確認シートで扱い、複数対象を全件表示する |
| `Tests/DevSwitcherCoreTests/`、`Tests/DevSwitcherTests/` | DockerとSupabase CLIを差し替え可能なtest doubleで、以下の完了条件を自動検証する |

`project_id`は、明示的な`--workdir`があればそのディレクトリ、なければ`CommandSpec.workingDirectory`を基準に`supabase/config.toml`から取得してください。ディレクトリ名、コンテナ名、ポートから補完・正規化しないでください。対象ファイルが無い、読めない、トップレベルの`project_id`が無い・空・重複・解釈不能のいずれも具体的なエラーにします。外部パッケージは追加せず、必要な範囲だけを読む専用parserに分離し、コメント内や別sectionの文字列を誤認しないテストを追加してください。TOMLエスケープを正しく解釈しない限り、バックスラッシュを削除するなどの部分変換はせずfail-fastで拒否してください。`.env`、`.env.*`、`.envrc`は読みません。`SUPABASE_WORKDIR`など、対象を暗黙に変える環境値はSupabase CLIへ渡さないでください。

ローカルスタックの列挙は、Supabase CLIが付ける`com.supabase.cli.project`ラベルを使い、`docker ps -a`と`docker inspect`相当のread-onlyコマンドからJSONを解析する専用inventoryへ分離してください。IDはコンテナ名から切り出さずラベル値を使います。DBコンテナの存在、running状態、healthを構造化データから判定し、次の規則を実装してください。

- 対象IDのコンテナが0件なら`notRunning`。volumeは数えない
- DBコンテナがrunningかつhealthyで、設定ディレクトリが既知なら対象workdirの`supabase status`も成功した場合だけ`running`
- 設定ディレクトリが不明な外部スタックは、DBコンテナがrunningかつhealthyなら`running`
- コンテナが1件以上あり、DBの欠損・停止・unhealthyを確認できたら`degraded`
- Dockerの実行失敗、JSON解析失敗、ラベル欠落、DB候補の重複、未対応の状態は`unknown`。`notRunning`へ倒さない

Docker CLIの場所は既存の`ExecutableResolver`とGUI用PATH解決を利用し、shell文字列を組み立てないでください。このinventoryは観測専用です。`docker start`、`docker stop`、コンテナ削除、volume操作は実装しません。ラベル名とJSON decodeを1箇所に閉じ込め、Supabase CLI互換性を将来更新できるようにしてください。

設定保存時は、`enabled`に関係なく1開発環境内のSupabaseが2件以上なら拒否してください。候補を含む全登録済み開発環境の`project_id`を解決して重複を拒否し、解決不能な環境があれば一意性を確認できたことにせず保存を失敗させます。保存済み設定の読み込みではファイルを黙って書き換えず、起動直前にも全登録済みSupabaseのIDを再解決してください。解決不能または重複なら新しい起動・切替を止めますが、すでに管理下にあるサービスの停止導線は残してください。

起動または切替のpreflightは、今回の起動対象にSupabaseが含まれる場合だけ、他サービスや切替元を変更する前に行います。観測結果から次の1件の確認planを作ってください。

- 対象IDが`running`: 対象を`adopted`にする。`supabase start`は実行しない
- 対象IDが`degraded`: 対象限定stop、`notRunning`確認、対象start、`running`確認
- 別IDが`running`または`degraded`: 停止対象へ追加する
- 対象が`notRunning`: 別IDの停止完了後に対象start、`running`確認
- 1件でも`unknown`: 確認や変更操作へ進まず、理由を表示する

既存スタックが複数なら確認を分割せず、引き継ぐ対象と停止する全対象を1つのシートに表示してください。各行に`project_id`を必須表示し、登録済みなら開発環境名と設定ディレクトリ、未登録なら「未登録」を表示します。停止後に対象の起動が失敗しても停止済みスタックを自動再起動しないことを明記し、キャンセルを既定操作にします。通常の開発環境切替で停止承認済みの管理下Supabaseを重ねて確認しないでください。

承認値には、確認時の全スタックIDと状態、対象設定の`project_id`とfingerprintを含めてください。承認後、最初の変更操作の直前にinventoryと対象設定を再取得し、snapshotと一致しなければ何も変更せず、最新内容で確認を出し直します。承認済みIDを各`supabase stop --project-id <id>`で1件ずつ停止して`notRunning`を確認し、全件停止後にも予期しないスタックが現れていないか再観測してから対象を起動または引き継いでください。`--all`と`--no-backup`はコマンド構築APIでも拒否し、直接Dockerを変更しないでください。

同じ対象IDの`running`と別IDが共存する場合は、別IDだけを停止し、対象がまだ`running`であることを確認して`adopted`にします。対象が`degraded`なら対象を含む承認済み全件を停止して対象だけを起動します。途中の停止に失敗したら後続の停止と起動を中断し、すでに停止したスタックを再起動しません。失敗したID、停止済みID、未処理IDを結果へ残してください。

確認キャンセル、`unknown`、snapshot不一致、既存スタックの停止失敗はpreflight失敗です。Supabaseサービスが`failurePolicy: continue`でも後続サービスを起動しないでください。`supabase start`は実行直前に対象が`notRunning`か再観測し、コマンドと起動後の`running`確認がともに成功した後だけ`launched`のhandleを登録してください。起動処理失敗後が`notRunning`なら`failurePolicy`を適用します。`running` / `degraded` / `unknown`なら起動由来を確定できないため自動停止せず、`failurePolicy`に関係なく中断してください。再試行時に最新状態を観測し、引き継ぎまたは停止の確認へ進めます。

起動トランザクションでは、今回Dev Switcherが起動した`launchedInThisRun`と、既存スタックを引き継いだ`adopted`を別々に保持してください。後続サービスが`failurePolicy: block`で失敗した場合、`launchedInThisRun`だけを逆順で停止し、`adopted`は稼働・管理関係・hintを維持します。この開発環境は`residual`（残存あり）とし、通常の停止操作から引き継いだSupabaseを停止できるようにしてください。今回起動したSupabaseは従来どおり巻き戻します。

managed hintには`project_id`、設定ディレクトリ、lifecycle fingerprintを保存し、保存値だけで稼働中へ戻さないでください。前回の`launched`または`adopted`を示すhintと、現在の設定、inventory、対象workdirのstatusが一致した場合だけ`restored`にします。旧schema、設変更、ID変更、観測不能ではstatusやstopを実行せず、hintと理由を保持します。定義の欠落、設定またはIDの不一致を確認できるhintは、利用者の明示操作で破棄できるようにします。schemaを変更する場合は明示的な移行分岐と往復テストを追加し、欠落値を既定値で補完しないでください。

read-only inventoryは、アプリ起動時、アプリがフォアグラウンドへ戻った時、各start/stop/switchの直前に更新してください。既存の排他トークンとactorを通し、操作中の観測と競合させないでください。アプリ起動時と復帰時は表示更新とhintの自動再検証だけを行い、手掛かりのない外部スタックを検出しても確認、引き継ぎ、停止を実行しません。確認は利用者がstartまたはswitchを押した時だけ出します。Timerや定期ポーリングは追加しません。

最低限、次をSwift Testingで検証してください。実Dockerや利用者のSupabaseへ依存せず、inventoryとCLI実行を注入可能にしてtest doubleで確認します。

- Supabaseが2件ある1開発環境を、片方がdisabledでも拒否する
- 異なる開発環境の同じ`project_id`を拒否し、異なるIDは保存できる
- `config.toml`の欠落、空、重複、コメント内・別sectionの誤認、未対応エスケープを拒否する
- コンテナ0件、healthy DB、DB欠損、stopped、unhealthy、Docker失敗、JSON不正を4状態へ分類する
- 同一IDの`running`は確認後に`adopted`となり、startを実行しない。キャンセルではコマンドを1件も実行しない
- 同一IDの`degraded`は承認後だけ、対象限定stop、停止確認、start、running確認の順になる
- 別IDが1件または複数ある場合、1つの確認に全件を含め、承認後も各IDを個別停止する
- 登録済みと未登録の既存スタックを確認表示で区別する
- 承認後にID集合・状態・対象fingerprintのいずれかが変わった場合、停止・起動せず最新内容で再確認する
- 途中の停止失敗と`unknown`では、`failurePolicy: continue`でも後続を起動しない
- `--all`、`--no-backup`、Docker変更コマンドが全経路で実行されない
- 対象start失敗後の実測が`notRunning`の場合だけ`failurePolicy`を適用し、由来不明の占有状態を自動停止しない
- 今回起動したSupabaseは後続のblock失敗で停止し、引き継いだSupabaseは停止せず残存ありと停止導線を維持する
- `launched`と`adopted`のhintを再起動後に実測して`restored`へでき、旧hint・設定不一致・ID不一致・観測不能からstatus/stopしない。破棄可能な不一致hintは明示操作で破棄できる
- アプリ起動とフォアグラウンド復帰では確認を出さず、start/switch時だけ出す
- 通常の開発環境切替で管理下Supabaseの停止確認を二重に出さない
- `failurePolicy`、通常プロセスの起動順・停止順、ポート解放ゲート、通常プロセスの引き継ぎに回帰がない

外部パッケージ、汎用Docker lifecycle、Supabase以外のmanaged command、複数Supabaseの同時稼働、共有スタック、HTTP readiness、自動検出ウィザードは追加しないでください。DB reset、migration、seed、`supabase stop --all`、`--no-backup`、ローカルファイル削除を実行しないでください。実Supabaseのstart/stopは利用者の明示承認なしに検証で実行せず、未実施なら未検証として報告してください。

実装後にswift buildとswift testを実行してください。失敗した場合はテストをskip・弱体化せず、原因と未完了条件を報告してください。最後に、変更したファイル、検証結果、実Docker Desktop＋Supabase CLIで未確認の項目、残るCLIバージョン互換性リスクを簡潔に報告してください。完了判断は利用者が行います。
```
