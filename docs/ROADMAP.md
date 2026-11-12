# Dev Switcher — ロードマップ

- 作成日: 2026-10-16
- 関連文書: `docs/SPEC.md`、`docs/ARCHITECTURE.md`、`docs/SCHEMA.md`

社内 MVP（Supabase 専用の管理と通常プロセスの管理）を基準線とし、汎用ツールへ発展させる。最初の 3 段階（Phase A / B / C）で `docs/SPEC.md` の現行仕様を実装し、その後の項目は優先度順に検討する。各段階は既存の安全性（排他切替、停止側のゲート、観測不能を停止中へ倒さないこと、外部の資源へ黙って停止操作をしないこと）を維持し、`swift build` と `swift test` の成功を完了条件に含める。

## 現在の実装状況（2026-11-12）

- Phase A: 2026-10-19 に実装済み。
- Phase C: 設定 v4、旧形式からの移行と順序変更通知、タグ、通常プロセスの停止コマンド、編集・取り込み画面を実装済み。
- Phase B: Compose の設定解析、driver、登録・確認・詳細表示を実装済み。停止は `--profile '*'` で同じプロジェクト名の全 profile を対象にし、画面でも範囲を明示する。2026-11-12 に Docker Compose v5.5.0 で、設定外の profile の観測・確認後の引き継ぎ・停止と、通常の起動・停止・再起動を確認した。検証用の 3 コンテナはすべて停止済み。制約のない環境での全テスト成功を確認してから完了とする。
- この実行環境では `kern.bootsessionuuid` の読み取りが拒否される。変更前の `48f0219` でも同じ実プロセス系テストが失敗するため、テストを弱めたりスキップしたりせず、別途結果を記録する。

## 1. 実装段階

### 推奨順: A → C → B

Phase A を最初に行うのは、挙動を変えないリファクタであり、既存の Supabase のテストで正しさを確かめられるためである。抽象を先に入れておけば、後続の段階は切替のトランザクションに触れずに済む。

C を B より先に行うのは、Docker Compose のスタックを定義する場所がデータモデルに必要なためである。B を先にすると、v3 の `kind` enum へ一時的に Compose を足し、C でもう一度変換することになる。これは `kind` を表示用タグにする方針とも矛盾する。C の後なら、B は種類を 1 つ追加する作業に閉じる。

C に含む「通常プロセスの停止コマンドの有効化」は、管理対象スタックの抽象に依存しない。必要なら A と並行して進めてよいが、`SwitchCoordinator` の preflight と停止処理に触れるため、同時に実装するときは worktree を分けるか触るファイルを分ける。

### Phase A: 管理対象スタックの抽象と Supabase の移し替え

目的は、Supabase 専用の型と分岐を種類共通の抽象（`docs/ARCHITECTURE.md` 4 章）へ移し、Supabase をその 1 実装にすることである。データモデルと保存形式（schemaVersion 3）は変えず、`kind: "supabase"` のサービスをアダプタでスタックとして扱う。

| 内容 | 完了条件 |
| --- | --- |
| `ManagedStackType` / `ManagedStackIdentity` / 状態・管理関係・観測・snapshot・確認 plan・承認の種類共通の型 | Supabase 専用の同名の型が Domain に残っていない |
| `ManagedStackDriver` と `SupabaseStackDriver`、`ManagedStackSupervisor`、`RuntimeRegistry` の `knownStacks` | Supabase の知識（ラベル名、CLI 形式、禁止オプション）が Supabase 実装の中に閉じている |
| `SwitchCoordinator` の確認フローを起動単位と種類共通の plan に置き換え | `kind == .supabase` の分岐が `SwitchCoordinator` から無くなる |
| エラー型と手掛かりの汎用化（手掛かりファイル v7） | v6 の手掛かりを読み込み、再起動後に `restored` にできる |
| `AppState` と確認シートの汎用化 | 画面の表示内容が現行と変わらない |

既存のテストの検証内容を変えずにすべて成功させる。型名の変更に伴う機械的な書き換えだけを許す。

### Phase C: タグ化、schemaVersion 4、通常プロセスの停止コマンド

目的は、データモデルを `docs/SCHEMA.md` の v4 にし、プロセスとスタックを別のエンティティにすることである。

| 内容 | 完了条件 |
| --- | --- |
| `ServiceKind` を自由文字列の `tag` に替え、`managedStacks` と `stackIDs` を追加 | v4 の往復保存、未知キーの拒否 |
| v3 → v4 の変換 | Supabase のスタック化、ID・起動順・停止順・起動対象の保持、順序が変わる場合の通知 |
| 起動順・停止順をスタック先行・後行に変更 | `docs/SPEC.md` 3.6 の順序をテストで確認 |
| Docker 系コマンドの警告、`supabase start` のプロセス登録の拒否、`kind == .docker` の起動拒否の撤去 | 警告では保存を妨げない |
| 通常プロセスの停止コマンド | `docs/SPEC.md` 7 章の受け入れ条件 |
| 編集画面・JSON 取り込み・`ProjectImportGuide.md` と `ProjectImportExample.json` を v4 に更新 | AI 向けガイドから v4 の JSON を作成・取り込みできる |
| 画面ラベルを `docs/SPEC.md` の「停止」「終了」の用語に合わせる（「終了中」→「停止処理中」など） | `docs/ARCHITECTURE.md` 8 章の 3 ラベルが変わっている |
| `type: "dockerCompose"` は Phase B まで未対応として扱う | 保存・取り込みで `dockerCompose` のスタックを「未対応の種類」として検証エラーにし、編集画面でも選べない |

### Phase B: Docker Compose の追加

目的は、`dockerCompose` を 2 つ目の管理対象スタックとして同梱することである。

| 内容 | 完了条件 |
| --- | --- |
| プロジェクト名の決定（`projectName`、`name:`、ディレクトリ名）と検証 | `docs/SPEC.md` 6.7 と `docs/SCHEMA.md` 7.2 の規則をテストで確認 |
| `DockerComposeStackDriver`（`ps` の解析、`up -d`、`stop`） | 状態分類と禁止操作のテスト、実 Docker Desktop での手動確認（利用者の承認のもとで実施） |
| 編集画面の Compose 入力欄、確認シートの Compose 行 | 引き継ぎ・復旧・起動失敗の各確認を画面で確認 |

## 2. その後の優先項目

### 2.1 既存定義からの取り込み

目的は、`package.json` の scripts、Procfile、Compose ファイルから、プロセスとスタックの候補を作って手入力を減らすことである。現状は手動登録と、AI が作成した JSON の取り込みだけを提供している。

壁は 3 つある。パッケージマネージャー（pnpm / npm / yarn / bun）を lockfile から判断する規則を決める必要があること、「未確認の自動検出コマンドを実行しない」「`.env` を読まない」を守ってファイルの読み取りだけで候補を作る必要があること、外部依存なしで Compose ファイルを必要な範囲だけ解析する必要があることである。候補は必ず確認画面を通し、推測した値を黙って保存しない。

### 2.2 readiness 判定

目的は、「起動済み（プロセスが生存している）」から一歩進めて、「応答できる」ことを表示・待機できるようにすることである。

壁は、設定ポートへ HTTP リクエストを送ると、同じポートを先に取った別プロセスの応答を自分の応答と誤認することである（現行仕様で HTTP 判定を撤回した理由）。対象プロセスのプロセスグループが実際に listen しているポートに限って問い合わせる、Compose の healthcheck を使う、などの判定根拠を設計し直す必要がある。

### 2.3 英語 UI と英語の文書

目的は、社外の開発者が使えるようにすることである。

壁は、Core 層が日本語の `description` を直接返している構造である（`ValidationError`、`RuntimeError`、`SwitchFailure` など）。エラーと状態を構造化した値として返し、文言化を UI 層の String Catalog へ移す分離が前提になる。文書（`docs/`、AI 向けの取り込みガイド）の英語化もここで行う。

### 2.4 署名・公証・Homebrew cask

目的は、チーム外へ配布し、更新を容易にすることである。現状は、非公開の GitHub Releases で Developer ID 署名と公証を付けた DMG を配布する手順がある（`DISTRIBUTION.md`）。

壁は、公開配布に必要な公開リポジトリ、LICENSE、README が未整備であること（PM 判断で後回し）、Homebrew cask には公開されたダウンロード URL と安定したバージョン付けが必要なことである。自動アップデートは扱っていない。

### 2.5 メニューバーとグローバルホットキー

目的は、切替の操作を速くすることである（現状はウィンドウで 3 操作）。

壁は、メニューバーのアイコンがノッチの裏に隠れる環境でホットキーが必須になること、外部依存なしのグローバルホットキーは Carbon の `RegisterEventHotKey` などに頼ること、操作面が 2 つになるため切替中の表示と排他の設計が必要なことである。メニューバーに載せるのは状態表示と切替だけとし、ログや編集はウィンドウに残す。

### 2.6 その他の候補

次は要望が具体化した時点で検討する。

- Compose の one-shot サービス（正常終了するコンテナ）を含むプロジェクトを `degraded` にしない判定
- 起動・切替の途中でアプリが強制終了した場合の手掛かり保存の穴の確認と修正（`docs/ARCHITECTURE.md` 11 章）
- Expo の QR 表示と LAN／Tunnel 切替
- 全プロセス混合ログ
- 管理対象スタックの個別起動・個別停止
