# Dev Switcher — 実装構成

- ステータス: 確定（汎用化版の初版）
- 作成日: 2026-10-16
- 関連文書: `docs/SPEC.md`（振る舞いの正）、`docs/SCHEMA.md`（JSON 形式の正）、`docs/ROADMAP.md`（実装段階）

この文書は `docs/SPEC.md` の振る舞いを Swift の実装へ写像する（How）。型名と signature は設計の意図を固定するための案であり、実装時に責務を変えない範囲で名前や分割を調整してよい。状態、観測、停止権限を 1 つの Bool や 1 つの値にまとめる変更は、調整の範囲に含めない。

## 1. 技術構成

- Swift 6 言語モード、SwiftUI、必要箇所のみ AppKit（ログ表示の `NSTextView`、`NSWorkspace`、ウィンドウ・フォーカス制御）
- Foundation のプロセス・ファイル・永続化 API。外部パッケージは追加しない。必要になった場合は理由・代替案・影響を示して承認を得る
- macOS 15 以降。ビルド定義の正は Swift Package Manager
- テストは Swift Testing
- 配布用の `.app` と DMG は `scripts/` で生成する（`DISTRIBUTION.md`）

## 2. モジュール構成

| ターゲット | 責務 |
| --- | --- |
| `DevSwitcherCore` | UI に依存しない領域。設定の型と検証、プロセス・スタックの実行と観測、切替のトランザクション、永続化 |
| `DevSwitcher` | SwiftUI のアプリ層。`AppState`（`@MainActor` の状態と排他トークン）、画面、ログ表示 |
| `DevSwitcherMain` | 実行ファイルの入口 |

`DevSwitcherCore` の下位ディレクトリは現状を維持し、管理対象スタックの型と実装を次のように加える。

```text
Sources/DevSwitcherCore/
├─ Domain/
│  ├─ ManagedStack/                 # 新規: 種類に依存しない型と、種類ごとの設定・検証・ID 解決
│  │  ├─ ManagedStackDefinition.swift
│  │  ├─ ManagedStackState.swift    # 状態・管理関係・観測・snapshot・確認 plan・承認
│  │  ├─ SupabaseStackConfiguration.swift   # 旧 ServiceDefinition の Supabase 導出部を移す
│  │  └─ DockerComposeStackConfiguration.swift
│  └─ …（既存）
├─ Runtime/
│  ├─ ManagedStacks/                # 新規: 観測・起動・対象限定停止の実装
│  │  ├─ ManagedStackDriver.swift
│  │  ├─ ManagedStackSupervisor.swift       # 旧 ManagedCommandSupervisor
│  │  ├─ ManagedStackCommandRunner.swift    # 旧 SupabaseCommandRunner を一般化
│  │  ├─ Supabase/                  # SupabaseDockerInventory、SupabaseStackDriver
│  │  └─ DockerCompose/             # ComposeProjectNameResolver、ComposePsParser、DockerComposeStackDriver
│  └─ …（既存）
├─ Switching/
└─ Persistence/
```

## 3. 現状の Supabase 結合と置き換えの方針

現行コードは「管理対象スタック」という抽象を持たず、Supabase を通常プロセスの一種（`ServiceKind.supabase`）として扱っている。主な結合点は次のとおりで、いずれも種類に依存しない型へ置き換え、Supabase 固有の知識は Supabase 実装の中へ閉じ込める。

| 現在の結合点 | 置き換え後 |
| --- | --- |
| `ServiceKind` enum と `kind == .supabase` の分岐 | プロセスは自由文字列の `tag`。スタックは `ManagedStackDefinition` として別配列で持つ |
| `ServiceDefinition.supabaseConfiguration` | `SupabaseStackConfiguration`（スタックの種類ごとの設定）へ移す |
| `ProjectValidator` の Supabase 件数・`project_id` 一意性 | `ManagedStackType.policy` を使う種類共通の検証と、種類ごとの設定検証 |
| `ValidationError` の Supabase 8 ケース | 種類共通のケースと、種類ごとの理由を持つ 1 ケース（5.1） |
| `SupabaseStackState` / `SupabaseManagementRelationship` / `SupabaseStackObservation` / `SupabaseStackSnapshot` | `ManagedStackState` / `ManagedStackRelationship` / `ManagedStackObservation` / `ManagedStackSnapshot` |
| `SupabaseConfirmationPlan` / `SupabaseApproval` | `ManagedStackConfirmationPlan` / `ManagedStackApproval`（複数スタック・複数種類を 1 つにまとめる） |
| `SupabaseStackController` と `ManagedCommandSupervisor` | `ManagedStackDriver`（種類ごとの実装）と `ManagedStackSupervisor`（管理関係を持つ handle） |
| `RuntimeRegistry.Handle.managed` の `SupabaseStackObservation`、`knownSupabaseConfigurations` | `ManagedStackSupervisor` と、ID をキーにした `knownStacks` |
| `SwitchCoordinator` の Supabase plan・停止・起動（約 120 箇所） | 種類共通の確認フローと起動単位（4.3） |
| `SwitchFailure.Reason` の `supabase*` 3 ケース、`RuntimeError.managedStartOwnershipUnconfirmed` | 種類と ID を持つ種類共通のケース |
| `ManagedRuntimeHint` の `supabaseProjectID` と `SupabaseLifecycleFingerprint` | `{type, identity, fingerprint}` を持つ汎用の手掛かり（6.2） |
| `AppState` の Supabase 表示・確認・手掛かり（約 70 箇所） | スタック共通の表示状態と確認シート（4.5） |
| `StartupObservationPolicy` の `kind == .docker` 拒否 | 削除。Docker 系コマンドは検証の警告だけにする |
| `RuntimeError.stopCommandUnsupported` | 削除。通常プロセスの `stop` を実行する（7 章） |

## 4. 管理対象スタック

### 4.1 Domain の型

```swift
public enum ManagedStackType: String, Codable, Sendable, CaseIterable {
    case supabase
    case dockerCompose

    /// 種類ごとの契約のうち、設定検証と確認フローが参照する静的な部分。
    public var policy: ManagedStackPolicy { get }
}

public struct ManagedStackPolicy: Equatable, Sendable {
    /// 1 開発環境あたりの上限。nil は制限なし。`enabled` にかかわらず数える。
    public let maximumPerEnvironment: Int?
    /// 起動時に停止を確認する既存スタックの範囲。
    public let conflictScope: ConflictScope
    public let supportsAdoption: Bool

    public enum ConflictScope: Equatable, Sendable {
        /// 同じ種類の全スタック（Supabase）。
        case allOfType
        /// 対象と同じ ID だけ（Docker Compose）。
        case identityOnly
    }
}

/// 同じ種類の中での同一性。値の検証は種類ごとの設定が行い、生成後は正規化しない。
public struct ManagedStackIdentity: Hashable, Codable, Sendable, CustomStringConvertible {
    public let type: ManagedStackType
    public let value: String
}

public struct ManagedStackDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var configuration: ManagedStackConfiguration
    public var ports: [PortSpec]
    public var enabledByDefault: Bool
    public var failurePolicy: FailurePolicy

    public var type: ManagedStackType { configuration.type }
}

public enum ManagedStackConfiguration: Equatable, Sendable {
    case supabase(SupabaseStackConfiguration)
    case dockerCompose(DockerComposeStackConfiguration)

    public var type: ManagedStackType { get }
    /// ファイルを読まずに判定できる設定エラー（禁止オプション、起動コマンドの形式など）。
    public func structuralIssues(workingDirectory: URL) -> [ManagedStackConfigurationIssue]
    /// 設定ファイルを読んで ID を決める。推測で補わず、決められなければ throw する。
    public func resolve(workingDirectory: URL) throws -> ResolvedStackConfiguration
}

/// ID と構成同一性まで確定した設定。コマンドはここからしか作れない。
public enum ResolvedStackConfiguration: Equatable, Sendable {
    case supabase(SupabaseResolvedConfiguration)          // 旧 SupabaseServiceConfiguration ＋ project_id
    case dockerCompose(DockerComposeResolvedConfiguration)

    public var identity: ManagedStackIdentity { get }
    public var fingerprint: ManagedStackFingerprint { get }
}

/// 確認時・保存時と設定が変わっていないかを、ハッシュではなく値の比較で照合する。
public enum ManagedStackFingerprint: Codable, Equatable, Sendable {
    case supabase(SupabaseLifecycleFingerprint)
    case dockerCompose(DockerComposeFingerprint)   // 作業ディレクトリ、プロジェクト名、files、profiles、upArguments
}

public struct ResolvedManagedStack: Equatable, Sendable {
    public let environmentID: UUID
    public let stackID: UUID
    public let stackName: String
    public let configuration: ResolvedStackConfiguration
}
```

状態と管理関係は、現行の Supabase 用の型をそのまま一般化する。`ManagedStackObservation` の同一判定は ID と状態だけで行い、判定根拠の文言（`detail`）を比較に含めない。文言の差で確認を出し直すと、利用者が理由なく承認を繰り返すことになるためである。

```swift
public enum ManagedStackState: String, Equatable, Sendable { case notRunning, running, degraded, unknown }
public enum ManagedStackRelationship: String, Codable, Equatable, Sendable { case launched, adopted, restored }

public struct ManagedStackObservation: Equatable, Sendable {
    public let identity: ManagedStackIdentity
    public let state: ManagedStackState
    public let detail: String?
}

/// 観測時点の集合。種類ごとに「観測全体が失敗した」ことを保持し、その種類の未列挙 ID を
/// notRunning ではなく unknown として返す。
public struct ManagedStackSnapshot: Equatable, Sendable {
    public func observation(of identity: ManagedStackIdentity) -> ManagedStackObservation
    public var hasUnknown: Bool { get }
    public var failureDetails: [String] { get }
}
```

### 4.2 Runtime の契約

```swift
/// 種類ごとの観測・起動・対象限定停止。状態を変更するのは start と stop だけで、
/// observe は読み取り専用。停止してよいかどうかは呼び出し側の管理関係が決める。
public protocol ManagedStackDriver: Sendable {
    var type: ManagedStackType { get }

    /// `known` は設定が分かっているスタック。conflictScope が allOfType の実装は、
    /// known に無いスタックも列挙して返す。identityOnly の実装は known だけを観測する。
    func observe(known: [ResolvedManagedStack]) async -> ManagedStackSnapshot

    /// 起動コマンドを実行し、running を実測するまで待つ。両方が揃わなければ throw する。
    func start(_ stack: ResolvedManagedStack, known: [ResolvedManagedStack]) async throws -> [LogLine]

    /// `identity` だけを停止し、notRunning を実測するまで待つ。
    /// `context` はコマンドの実行に使う設定。Supabase は未登録スタックの停止にも
    /// 対象側の CLI 呼び出し形式を使う。
    func stop(
        _ identity: ManagedStackIdentity,
        using context: ResolvedManagedStack,
        known: [ResolvedManagedStack]
    ) async throws -> [LogLine]
}

/// 種類ごとのコマンド実行を差し替え可能にする。禁止オプションの拒否と環境変数の除去は、
/// コマンド構築側に加えてこの最後の実行境界でも行う。
public protocol ManagedStackCommandRunning: Sendable {
    func run(_ command: CommandSpec, policy: ManagedStackCommandPolicy) async throws -> ManagedStackCommandResult
}

public struct ManagedStackCommandPolicy: Sendable {
    public let forbiddenArguments: Set<String>        // 例: --all, --no-backup / down, rm, -v ...
    public let forbiddenSubcommands: Set<String>      // 例: Compose の down, rm, kill
    public let removedEnvironmentKeys: Set<String>    // 例: SUPABASE_WORKDIR / COMPOSE_PROJECT_NAME, COMPOSE_FILE, COMPOSE_PROFILES
}
```

`ManagedStackSupervisor`（旧 `ManagedCommandSupervisor`）は 1 スタック分の handle で、`ResolvedManagedStack`、管理関係、最後の観測結果、イベントストリームを持つ。停止は driver の `stop` に委ね、失敗時は実測し直して状態を残す。`isRunning`（`running` のときだけ真）と `isOccupyingResources`（`notRunning` 以外で真）を区別する現行の意味は変えない。

`RuntimeRegistry` は `Handle.managed(ManagedStackSupervisor)` を持ち、`knownSupabaseConfigurations` を `knownStacks: [ManagedStackIdentity: ResolvedManagedStack]` に、Supabase 専用の `startManagedStack` / `adoptManagedStack` / `stopUnmanagedStack` / `managedSupabaseProjectIDs` を種類共通の同名操作に置き換える。種類ごとの driver は `[ManagedStackType: any ManagedStackDriver]` として注入する。観測は、登録済みまたは管理下のスタックがある種類だけで行う。スタックを使っていない利用者の操作ごとに `docker` を呼ばないためである。

観測のたびに、管理関係を持つスタックのうち `notRunning` と観測されたものは handle を外し、`SwitchCoordinator` の状態と手掛かりからも除く（現行の `releaseStoppedManagedHandle` と `refreshManagedObservations` の `clearState`）。停止側では、handle を持つスタックは状態が `unknown` でも driver の `stop` を呼び、停止後の実測が `notRunning` でなければ残存として返す（現行の `ManagedCommandSupervisor.stop`）。どちらも現行の挙動であり、Phase A で変えない。

### 4.3 起動単位と切替

`SwitchCoordinator` の起動フェーズは、プロセスとスタックを 1 つの列として扱う。

```swift
enum LaunchUnit: Sendable {
    case stack(ManagedStackDefinition)
    case process(ServiceDefinition)
}

extension ProjectDefinition {
    /// 起動順。Phase C 以降はスタック（登録順）→ プロセス（起動順）。
    var launchUnits: [LaunchUnit] { get }
    /// 停止順。プロセス（停止順）→ スタック（登録順の逆）。
    var shutdownUnits: [LaunchUnit] { get }
}
```

Phase A ではデータモデルを変えないため、`launchUnits` は `services` の配列順から作り、`kind == .supabase` のサービスをアダプタで `.stack` に変換する。Phase C で `managedStacks` を持つ v4 のモデルに替えた時点で、`docs/SPEC.md` 3.6 の順序になる。

切替のトランザクションは現行の `run(stopping:starting:…)` の順序を維持する。

1. 登録済み全スタックの ID を解決し直し、`knownStacks` を入れ替える。解決不能・重複があれば新しい起動・切替を止める（単独停止は止めない）
2. 管理下と登録済みのスタックを再観測する
3. 起動先の preflight（実行できない設定を、停止を始める前に落とす）
4. 起動先の各スタックについて確認 plan を作る。確認が必要で承認が無ければ `SwitchFailure.managedStackConfirmationRequired(plan)` で中断する。承認があれば再観測して承認内容と照合し、不一致なら最新の plan で同じく中断する
5. 切替元の停止（プロセス → 管理下のスタック）とゲート
6. 起動フェーズ（ここから中止不可）: 承認済みの既存スタックの停止、起動単位の順の起動・引き継ぎ・初期観測

確認 plan は、起動先の全スタックについての行と、`allOfType` の種類の停止対象行を 1 つにまとめる。

```swift
public struct ManagedStackConfirmationPlan: Equatable, Sendable {
    public let environmentName: String
    public let entries: [ManagedStackConfirmationTarget]  // 種類・ID・状態・action・登録情報
    public let snapshot: ManagedStackSnapshot              // 確認時点の全観測
    public let fingerprints: [UUID: ManagedStackFingerprint]  // 起動先スタックごと
    public var requiresConfirmation: Bool { get }          // 全行が新規起動だけなら false
    public var approval: ManagedStackApproval { get }
}
```

`SupabaseConfirmationTarget.Action` の `adopt` / `restart` / `stop` / `start` はそのまま種類共通の action とする。`launchedInThisRun` と `adoptedServiceIDs` の分離、`residualManagedServiceIDs` による「残存あり」の表示、起動失敗後の `notRunning` 以外を `managedStartOwnershipUnconfirmed` として中断する経路も、ID を種類共通の型に替えるだけで意味は変えない。

### 4.4 エラーの型

| 型 | 置き換え |
| --- | --- |
| `SwitchFailure.Reason` | `supabaseConfirmationRequired(plan:)` → `managedStackConfirmationRequired(plan:)`、`supabaseObservationFailed(details:)` → `managedStackObservationFailed(details:)`、`supabaseStopFailed(projectID:…)` → `managedStackStopFailed(identity:reason:stopped:remaining:)` |
| `RuntimeError` | `managedStartOwnershipUnconfirmed(stack:identity:state:reason:)`。`stopCommandUnsupported` は削除 |
| `SupabaseOperationError` | `ManagedStackOperationError`（`commandFailed` / `commandUnavailable` / `stateNotConfirmed` に種類と ID を持たせる） |
| `StartupObservationError` | 削除（`kind == .docker` の拒否を廃止するため） |

### 4.5 AppState と UI

`AppState` が Supabase 専用に持っている責務は、次のようにスタック共通へ置き換える。排他トークンを通す点、アプリ起動時とフォアグラウンド復帰時は観測と表示更新だけを直列に行う点は変えない。

| 責務 | 現在 | 置き換え後 |
| --- | --- | --- |
| 観測結果の表示 | `SupabaseUIState`、`unregisteredSupabaseObservations`、`supabaseObservationError` | スタックごとの表示状態（種類・ID・状態・管理関係）と、種類ごとの観測エラー |
| 起動・切替時の確認 | `supabaseConfirmation`、`approve/cancelSupabaseConfirmation` | `ManagedStackConfirmationPlan` を表示する 1 つの確認状態 |
| 手掛かりの再検証 | `pendingManagedHints`、`restoreManagedHints`、`discardUnmatchedManagedHints` | 種類共通の手掛かりで同じ処理 |
| 管理下の資源の有無 | `projectIDsWithManagedResources` | 同じ（スタックの handle を含める） |

UI は次を変更する。

- `SupabaseConfirmationSheet` を種類共通の確認シートにし、各行に種類と ID を表示する
- サイドバーと詳細に、作業ディレクトリ配下のスタックの行と詳細（種類、ID、状態、管理関係、ポート、コマンドのログ）を加える
- 編集画面のプロセス欄の種別ピッカーをタグの自由入力に替え、作業ディレクトリごとに「スタックを追加」（種類の選択と種類ごとの入力欄）を加える。Docker 系コマンドの警告をプロセス欄に表示する
- JSON 取り込みの確認画面にスタックと警告を表示する

## 5. 設定の検証

### 5.1 ProjectValidator

検証は現行どおり、構造検証（ファイルを読まない）、ファイルシステム検証（作業ディレクトリの実在）、スタック ID の解決と一意性検証（設定ファイルを読む）の 3 段に分ける。保存済み設定の読み込みでは構造検証だけを行い、リポジトリの移動で設定全体が読めなくなることを避ける。

ID の解決（`ManagedStackConfiguration.resolve`）は設定ファイルの読み取りだけで完結させ、`docker` や各 CLI を実行しない。検証のテストでは、コマンド実行のフェイクに 1 件も呼び出しが記録されないことを確認する。

スタックの検証は種類に依存しない形で書く。

- 1 開発環境あたりの件数を `type.policy.maximumPerEnvironment` と比べる
- 候補を含む全開発環境のスタックを登録順に `resolve` し、`ManagedStackIdentity` の重複を検出する。解決できないスタックが 1 つでもあれば一意性を確認できたことにせず失敗させる
- 種類ごとの設定エラーは `ManagedStackConfiguration.structuralIssues` が返す

```swift
public enum ValidationError: Error, Equatable, Sendable {
    // …プロセス・作業ディレクトリ・ポートの既存ケースは維持する（serviceKind 関連を除く）
    case managedStackConfigurationInvalid(stack: String, issue: ManagedStackConfigurationIssue)
    case managedStackLimitExceeded(type: ManagedStackType, limit: Int, stacks: [String])
    case managedStackIdentityUnresolved(stack: String, reason: String)
    case duplicateManagedStackIdentity(identity: ManagedStackIdentity, otherProject: String)
    case processUsesManagedStackCommand(service: String, type: ManagedStackType)
}

public enum ValidationWarning: Equatable, Sendable {
    /// 停止はプロセスグループ単位であり、コンテナは残り得る。保存を妨げない。
    case containerCommandAsProcess(service: String, executable: String)
}
```

警告は `ValidationError` と別の型にし、保存・取り込みの可否判定に混ぜない。

### 5.2 種類ごとの設定

`SupabaseStackConfiguration` は、現行の `ServiceDefinition.supabaseConfiguration` の導出（対応する起動コマンドの形式、`--workdir` の解決、グローバルオプションの引き継ぎ、`status` と `stop --project-id` の生成）と `SupabaseConfigFile` の `project_id` 読み取りを、そのまま移す。挙動を変えない。

`DockerComposeStackConfiguration` は次の部品で構成する。

| 部品 | 責務 |
| --- | --- |
| `ComposeFileLocator` | `files` の解決、または作業ディレクトリ直下の既定ファイルと override ファイルの選択。親ディレクトリを探さない |
| `ComposeProjectNameReader` | Compose ファイルのトップレベル `name:` だけを読む専用処理。YAML 全体は解析しない。変数展開・複数値の不一致・解釈不能は throw |
| `ComposeProjectName` | `docs/SPEC.md` 6.7 の名前規則で検証した値。プロジェクトディレクトリ名からの導出だけ正規化を行う |
| `DockerComposeResolvedConfiguration` | `up -d`、`ps --all --format json`、`stop` のコマンドを `-p` 付きで生成する。`down`・`rm`・`kill` などを生成する入口を持たない |

`upArguments` は `docs/SCHEMA.md` 7.2 の許可リストで検証する。許可リストと、どの経路でも生成・実行しない引数・サブコマンドの一覧は、それぞれ 1 か所に定数として持ち、構造検証、コマンド生成、`ManagedStackCommandRunning` の 3 か所で参照する。`ComposeFileLocator` が解決したファイル一覧は、起動・観測・停止の全コマンドに同じ `-f` として付ける。起動・観測は設定した `profiles` を使い、停止だけは `ComposeCommandRules.stopProfiles` の `--profile '*'` で同じプロジェクト名の全 profile を対象にする。実行境界でも、全 profile を指定しない停止を拒否する。

## 6. 永続化

### 6.1 設定ファイル（`projects.json`）

`ProjectsDocument.currentSchemaVersion` を 4 にし、`docs/SCHEMA.md` の形式で読み書きする。旧形式は現行の `ProjectSchemaV1` / `ProjectSchemaV2` と同じく、過去の形を固定した読み込み専用の型（`ProjectSchemaV3`）を置いて変換する。現行の `ServiceKind` enum は v3 の読み込み専用型の中にだけ残す。v4 の decoder は未知のキーを拒否する。変換で起動順・停止順が変わった開発環境は、読み込み結果に含めて `AppState` が通知する。保存は現行どおり一時ファイルへ書いてから atomic に置き換える。

### 6.2 再検証用の手掛かり（`runtime-hints.json`）

手掛かりファイルは設定とは別ファイルのまま、`RuntimeHintsDocument.currentSchemaVersion` を 7 にする。管理対象スタックの手掛かりを種類共通にする。

```swift
public struct ManagedStackHint: Codable, Equatable, Sendable {
    public let projectID: UUID          // 開発環境の ID
    public let stackID: UUID            // v3 から移行したスタックは旧サービス ID と同じ
    public let stackName: String
    public let type: ManagedStackType
    /// 以下が nil なのは、旧 schema から移行した未検証の手掛かりだけ。
    /// nil の手掛かりを根拠に状態確認や停止のコマンドを実行しない。
    public let identity: ManagedStackIdentity?
    public let fingerprint: ManagedStackFingerprint?
    public let relationship: ManagedStackRelationship?
}
```

読み込みは現行の v1〜v6 の分岐を読み込み専用で維持する。v6 の `ManagedRuntimeHint` は過去の形を固定した型で読み、`type: .supabase`、`identity: supabaseProjectID`、`fingerprint: .supabase(…)` へ変換する。v4・v5 の手掛かりは現行どおり未検証のまま保持する。現行 v7 でキーが欠けている場合は、空配列として扱わず decode を失敗させる。稼働中のスタックの手掛かりを黙って失わないためである。

再検証の規則は変えない（現行の `SwitchCoordinator.restoreManagedStack`）。手掛かりの管理関係があり、`identity` と `fingerprint` が現在の設定から解決した値と一致した場合だけ実測する。実測が `running` なら `restored` として起動済みに、`degraded` なら `restored` として管理下に戻したうえで失敗理由を残し、残存として停止導線を出す。`notRunning` なら手掛かりを破棄し、`unknown` なら理由を残して手掛かりを保持する。

## 7. 通常プロセスの停止コマンド

`ServiceSupervisor`（Dev Switcher が起動したプロセス）、`AdoptedSupervisor`（アプリ再起動後に引き継いだプロセス）、`ResidualGroupSupervisor`（残存したプロセスグループ）の停止を、停止方法で分岐させる。

```swift
public enum ProcessStopMethod: Equatable, Sendable {
    /// プロセスグループへ SIGTERM を送り、猶予まで終了を待つ。
    case signal
    /// 停止コマンドを実行し、完了後に猶予まで終了を待つ。SIGTERM は送らない。
    case command(CommandSpec)
}

public struct ProcessStopOptions: Sendable {
    public var commandTimeout: Duration = .seconds(30)
    public var grace: Duration = .seconds(10)        // 現行の stopGrace と同じ
}
```

停止コマンドは利用者のログインシェルから取得した環境で、`ExecutableResolver` により絶対パスへ解決して直接実行する。出力は対象プロセスのログへ流す。実行の前に対象のプロセスグループを実測し、存在しなければ停止コマンドを実行せず停止済みとする。停止コマンドは独立したプロセスグループで起動し、タイムアウトした場合はそのグループへ SIGTERM を送る（Dev Switcher が起動したものなので停止してよい）。猶予後も停止コマンドのグループが残れば、それも残存として結果に含める。停止結果は対象のプロセスグループの実測で決め、`ServiceStopOutcome.stopped` / `.residual` / `.ownershipLost` の既存の分類に載せる。停止コマンドの失敗・タイムアウトは結果の理由とログに残す。

自動の SIGKILL は、どちらの停止方法でも行わない。強制停止（`forceStop`）は現行どおり利用者の明示操作で、送信直前に同一性を再検証する。

`RuntimeError.stopCommandUnsupported` と、`stop` を持つプロセスを起動前に拒否している preflight を削除する。

### 7.1 停止コマンド自体が残存した場合

停止コマンドは独立したプロセスとして `RuntimeRegistry` が所有し、元のプロセスとは別の UUID・プロセスグループで記録する。元の対象に対する停止・強制停止操作は、残存した停止コマンドも対象に含める。元の対象が先に終了しても、停止コマンドの PGID・実測ポートと停止導線を保持し、残存中の再起動を拒否する。出力は元の対象のログファイルへ追記し、停止コマンドの完了まで追尾する。

手掛かり v7 の通常プロセスのレコードに、停止コマンドの場合だけ `stopCommandFor`（親サービスの UUID）と `stopCommand`（保存時のコマンド設定）を追加する。両方を指定するか両方を省略し、一部欠落や自分自身への参照は読み込みエラーにする。再起動後は親の現在の停止コマンドと一致する場合だけ再検証し、停止コマンドを稼働中サービスとして引き継ぐ選択肢は出さない。設定不一致・観測不能では手掛かりを保持する。

## 8. 状態機械との対応

| SPEC の状態 | 型 |
| --- | --- |
| 対象外 / 停止中 / 起動中 / 起動済み / 停止処理中 / 失敗 / 残存あり（プロセス・スタック） | `ServicePhase`。スタックは `ManagedStackSupervisor` の観測と管理関係から導く。`running` だけを `.healthy`（起動済み）にし、`degraded` / `unknown` で管理関係を持つものは `.residual` |
| 開発環境の状態 | `ProjectPhase`（`degraded` は一部停止、`switching` は切替中） |
| 切替の進行 | `SwitchState`。スタックの停止・起動も既存の `stopping` / `starting` に名前を入れて表示し、スタックの `running` 確認は `observingStartup` を使う |
| 失敗画面の現在状態 | `CurrentStateFacts`（optional にしない） |

`ServicePhase` の名前はプロセスとスタックの両方に使うが、型の改名は Phase A の対象外とする。

現行コードの画面ラベル「終了中」「終了できない」「強制終了して続行」は、`docs/SPEC.md` の用語（「停止」は Dev Switcher の操作、「終了」はプロセスの exit とアプリの quit）に合わせて「停止処理中」「停止できない」「強制停止して続行」へ変える。Phase A は表示を変えないため、Phase C で行う。

## 9. 並行処理

- UI 状態の更新は `@MainActor` の `AppState` で行い、起動・停止・切替・設定変更・引き継ぎ・再検証は排他トークンを通す（`docs/SPEC.md` I-1）
- プロセス管理と切替は `actor`（`RuntimeRegistry`、`SwitchCoordinator`、各 supervisor）で直列化する
- キャンセルできるのは切替先の起動フェーズに入る前まで
- detached task へ所有権不明の状態を渡さない
- エラーをログだけに残さず、型付きエラーとして UI へ返す

## 10. テスト方針

既存のテストは弱めない。実ポートの listen や実プロセスの観測を使うテストは、ポートの listen が禁止された実行環境でも skip や条件の緩和をせず、失敗または未検証として報告する。利用者の Application Support へテストデータを書かない。

Phase A はリファクタであり、既存の Supabase のテスト（`SupabaseLifecycleTests`、`SupabaseRegistrationTests`、`SupabaseStackTests`、`SupabaseCommandRunnerTests`、`SwitchCoordinatorTests` ほか）の検証内容を維持する。型名の変更に伴う機械的な書き換えは許すが、期待値と検証項目は変えない。

管理対象スタックのテストは、driver の下位にある観測とコマンド実行を差し替えて行い、実 Docker や利用者のスタックに依存しない。

| フェイク | 用途 |
| --- | --- |
| `FakeSupabaseInventory` / `FakeCommandRunner`（既存のものを一般化） | Supabase の状態分類、確認フロー、禁止オプション |
| `FakeComposeRunner` | `docker compose ps` の出力（1 行 1 JSON と配列、未対応の状態、解析不能）と、実行されたコマンドの記録 |
| `FakeManagedStackDriver` | `SwitchCoordinator` の種類共通の確認フロー、複数種類の混在、`identityOnly` の種類で別 ID を観測・停止しないこと |

Docker Compose では少なくとも次を確認する。

- プロジェクト名の決定順、`name:` の読み取り（引用符、変数展開、複数ファイルの不一致、コメント、ネストしたキーの誤認）、ディレクトリ名の正規化、規則外の値の拒否
- 全コマンドに同じ `-p`、`-f` が付き、起動・観測は設定した `profiles`、停止は常に `--profile '*'` を使う。限定した profile の停止は実行境界で拒否する。`COMPOSE_PROJECT_NAME`、`COMPOSE_FILE`、`COMPOSE_PROFILES` が除かれる
- `upArguments` の許可リスト（サービス名、許可したオプション、値の形式）と、短いオプションの結合や未知のオプションの拒否
- 状態判定の優先順位（`docs/SPEC.md` 6.7 の表）と、起動・停止の待機期限の時点の状態での判定
- 状態分類（running のみ、停止済みだけが残る、一部停止、restarting、unhealthy、health starting、removing、0 件、`docker` 失敗）
- 禁止された `upArguments` の拒否と、`down`・`rm`・`kill`・`-v`・`--rmi`・`--remove-orphans` がどの経路でも実行されないこと
- 引き継ぎ、`degraded` の復旧、起動失敗後の由来不明の占有で自動停止しないこと

通常プロセスの停止コマンドでは、実プロセスを使って次を確認する。

- 停止コマンドが実行され、SIGTERM が送られないこと
- 停止コマンドの後に猶予内でグループが終了すれば停止成功、残れば残存で、SIGKILL が送られないこと
- 停止コマンドの失敗・タイムアウトが結果とログに残ること
- 再起動と切替で、停止後の実測ポートの解放ゲートが従来どおり働くこと

スキーマでは、v3 からの変換（Supabase のスタック化、ID・起動順・停止順・起動対象の保持、起動順が変わる場合の通知、変換失敗）、未知キーの拒否、往復保存、手掛かりの v6 から v7 への変換を確認する。

## 11. 既知の課題

起動・切替の途中でアプリが強制終了した場合、一括処理の前後で手掛かりを保存しているため、途中で起動したプロセスがディスクへ記録される前にアプリが落ちる時間帯がある（`Sources/DevSwitcher/App/AppState.swift` の一括起動の前後の保存処理）。実際にプロセスを見失うかは未検証である。確認手順は、複数プロセスのうち最初の 1 件が起動し後続が起動中のタイミングでテスト用アプリを強制終了し、再起動後に残存プロセスを引き継ぎ・停止できるかを見ること。修正の範囲と優先度は PM が判断する。

## 12. コード中の旧文書参照の読み替え

コードのコメントには、削除した旧文書への参照が残っている。コメントは Phase A 以降の実装で触れる際に新しい参照へ直す。それまでは次の表で読み替える。

| 旧参照 | 新しい参照 |
| --- | --- |
| `MVP_SPEC.md` 5.5（Supabase スタック） | `docs/SPEC.md` 6.2、6.6 |
| `MVP_SPEC.md` 6.1.1（起動と引き継ぎ） | `docs/SPEC.md` 6.3、6.4 |
| `MVP_SPEC.md` 6.1.2（追加起動） | `docs/SPEC.md` 5.4 |
| `MVP_SPEC.md` 11（外部プロセスと引き継ぎ） | `docs/SPEC.md` 11、6.5 |
| `MVP_SPEC.md` 12（強制終了と外部プロセス） | `docs/SPEC.md` 7（強制停止）、12 |
| `DESIGN.md` I-1〜I-9 | `docs/SPEC.md` 16.2 の同じ番号 |
| `DESIGN.md` 決定 c（外部プロセスは自動停止しない） | `docs/SPEC.md` 12 |
| `DESIGN.md` 決定 g（複数ポート） | `docs/SPEC.md` 9 |
| `DESIGN.md` 決定 i（編集・登録解除の導線） | `docs/SPEC.md` 15.1、15.3 |
| `DESIGN.md` 4 章（情報設計・対象外の描き方）、7 章（画面） | `docs/SPEC.md` 16.1、16.3 |
| `DESIGN.md` 8 章（デザイントークン） | `docs/SPEC.md` 16.3 と `DesignTokens.swift` |
| `DESIGN.md`「型で守る」 | この文書 4.3、8 章と `docs/SPEC.md` 16.2 |
