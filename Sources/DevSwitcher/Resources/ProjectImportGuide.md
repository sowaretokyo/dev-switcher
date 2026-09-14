# Dev Switcherの取り込み用JSONを作成してください

利用者が指定した開発環境を、以下の形式のUTF-8 JSONファイルとして作成してください。複数の開発環境・作業ディレクトリ・プロセスを1ファイルに含められます。出力にコメントや末尾カンマは含めないでください。

利用者はDev Switcherの「JSONから取り込む…」でファイルを選び、内容を確認して一括追加します。既存設定の一括更新には対応していません。同名・同IDの開発環境はエラーになります。

## 生成する前に確認する情報

- 開発環境名と、各作業ディレクトリの表示名・Mac上の絶対パス。
- 各プロセスの名前、種別、実行ファイル、引数、起動順。
- 既定で起動対象にするか、起動失敗時に全体を止めるか続行するか。
- ポートは任意。指定する場合は番号・代表ポート・必要に応じた表示名と開くURL。

未指定のコマンド・引数・パス・起動方針は推測せず、利用者に確認してください。利用者が指定したリポジトリのpackage.jsonなどでコマンドを裏付けることはできますが、.env、.env.*、.envrcは読みません。JSONの作成・確認のために起動コマンド、DB migration、reset、seedを実行しないでください。

## JSONの形式

最上位は `{"schemaVersion": 3, "projects": [...]}`。`projects`は1件以上必要です。Dev Switcherの保存形式と同じです。以下の「任意」以外は必須です。

### 開発環境

| キー | 値 |
| --- | --- |
| `id` | UUID文字列 |
| `name` | 空でない名前 |
| `color` | `blue` / `purple` / `pink` / `red` / `orange` / `yellow` / `green` / `teal` |
| `workingDirectories` | 作業ディレクトリの配列、1件以上 |
| `services` | プロセスの配列、1件以上。配列順が起動順 |
| `stopOrder` | 任意。指定する場合は全プロセスIDを終了順に1回ずつ列挙 |
| `enabledNow` | 任意。プロセスIDをキー、真偽値を値とするオブジェクト |

`stopOrder`を省略すると起動順の逆で終了します。`enabledNow`に指定のないプロセスは`enabledByDefault`に従います。通常は`stopOrder`を省略し、`enabledNow`は`{}`にしてください。

### 作業ディレクトリ

| キー | 値 |
| --- | --- |
| `id` | UUID文字列 |
| `name` | `Web`や`Native`などの空でない表示名 |
| `directory` | 存在するローカルディレクトリの絶対file URL |
| `serviceIDs` | このディレクトリに属するプロセスIDの配列、1件以上 |

パスは`file:///Users/example/GitHub/web/`のようなfile URLにします。空白などはURLエンコードしてください。`~`や相対パス、サンプルの仮パスは使用しません。1開発環境内で同じパスや表示名を重複させず、各プロセスをちょうど1つの作業ディレクトリに所属させてください。

### プロセス

| キー | 値 |
| --- | --- |
| `id` | UUID文字列 |
| `name` | 開発環境内で一意の空でない名前 |
| `kind` | `web` / `expo` / `supabase` / `inngest` / `worker` / `other` |
| `start` | `executable`、`arguments`、`workingDirectory`を持つオブジェクト |
| `ports` | ポートの配列。未指定なら`[]`を明記 |
| `enabledByDefault` | `true` / `false` |
| `failurePolicy` | `block` / `continue` |

`start.executable`は`pnpm`などの実行ファイル、`start.arguments`は`["dev", "--port", "3000"]`のような文字列配列です。引数なしなら`[]`にします。`"pnpm dev"`を実行ファイル名にしたり、シェルで連結したコマンドへ変換したりしないでください。`start.workingDirectory`は所属する作業ディレクトリの`directory`と同じURLです。

`block`は起動失敗時に開発環境全体を失敗にし、`continue`は後続の起動を続けます。カスタム終了コマンドの`stop`と、未対応の`docker`種別は生成しないでください。Supabaseは`kind: "supabase"`とし、`supabase start`または`pnpm exec supabase start`形式で指定します。1開発環境に1件までです。`supabase/config.toml`の`project_id`を取得でき、登録済みの全開発環境と重複しない必要があります。

### ポート

| キー | 値 |
| --- | --- |
| `id` | UUID文字列 |
| `port` | 1〜65535の整数 |
| `primary` | `true` / `false`。ポートがある場合、ちょうど1件を`true`にする |
| `label` | 任意。空でない表示名 |
| `openUrl` | 任意。`http`または`https`のURL |

同一プロセス内でポート番号を重複させないでください。異なるプロセス間の同じ番号は指定できます。ポート未指定時に種別から番号を補完しないでください。

## IDと確認

新規の開発環境・作業ディレクトリ・プロセス・ポートには別々のUUIDを生成してください。`serviceIDs`、`stopOrder`、`enabledNow`の参照先には対応するプロセスのUUIDを使います。サンプルのUUIDを複数環境へコピーしないでください。保存済みJSONを移す場合は既存のIDと順序を保持できます。

生成後はJSONとして解析できること、必須項目、IDの一意性と参照関係、パスの実在を確認してください。実行ファイルの利用可否や、各コマンドが正常に起動するかは取り込みだけでは保証されません。利用者が確認画面でパス・コマンド・起動対象を確認してから追加し、必要なタイミングで起動します。
