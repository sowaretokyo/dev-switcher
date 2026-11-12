# Dev Switcherの取り込み用JSONを作成してください

利用者が指定した開発環境を、以下の schemaVersion 4 の UTF-8 JSON として作成してください。利用者が「JSONから取り込む…」で内容を確認して追加します。取り込みによって起動しません。
未指定のコマンド・引数・パス・起動方針は推測せず確認してください。`.env`、`.env.*`、`.envrc` は読まず、起動・DB migration・reset・seed・依存パッケージのインストールを実行しないでください。

## 1. 全体の規則

- 文字コードは UTF-8。コメントと末尾カンマは書かない
- 未知のキーはエラーにする。綴り違いの任意キーを黙って無視しないためである
- 「任意」と書いたキー以外はすべて必須。必須の配列は空でもキーを省略せず `[]` と書く
- 任意のキーに `null` は書かない。指定しないときはキーごと省略する
- 文字列の「空でない」は、前後の空白を除いて 1 文字以上あることを指す
- UUID は `233F0046-5A31-4BA9-8622-78392125C5ED` のような 36 文字のハイフン区切り表記。英字の大文字・小文字はどちらも受け付け、ID の比較と重複判定は大文字小文字を区別しない。Dev Switcher が保存するときは大文字で書く（Foundation の `UUID` の表記）
- パスは絶対パスの file URL（`file:///Users/example/GitHub/shop-web/`）。`~`、相対パス、サンプルの仮パスは使わない。空白などは URL エンコードする
- 「名前の重複」は大文字小文字を区別せずに判定する

## 2. 最上位

```text
{ "schemaVersion": 4, "projects": [ 開発環境, ... ] }
```

| キー | 型 | 制約 |
| --- | --- | --- |
| `schemaVersion` | 整数 | `4`。保存時は常に 4 で書く |
| `projects` | 開発環境の配列 | 取り込みでは 1 件以上。保存ファイルでは 0 件も可 |

コード上の型名に合わせ、開発環境の配列のキーは `projects` のままとする。

## 3. 開発環境（`projects[]`）

| キー | 型 | 制約 |
| --- | --- | --- |
| `id` | UUID | 登録済みの全開発環境で一意 |
| `name` | 文字列 | 空でない。登録済みの全開発環境で名前が重複しない |
| `color` | 文字列 | `blue` / `purple` / `pink` / `red` / `orange` / `yellow` / `green` / `teal` |
| `workingDirectories` | 作業ディレクトリの配列 | 1 件以上 |
| `services` | プロセスの配列 | `[]` 可。配列順がプロセスの起動順 |
| `managedStacks` | 管理対象スタックの配列 | `[]` 可。配列順がスタックの起動順 |
| `stopOrder` | UUID の配列 | 任意。プロセスの停止順を明示する場合だけ指定する |
| `enabledNow` | オブジェクト | 任意。今回の起動対象の上書き |

`services` と `managedStacks` の合計は 1 件以上とする。一括起動では `managedStacks` を配列順にすべて起動してから `services` を配列順に起動し、停止はその逆で行う（`docs/SPEC.md` 3.6）。

`stopOrder` を指定する場合は、この開発環境の全プロセスの ID をちょうど 1 回ずつ並べる。スタックの ID は含めない。省略するとプロセスは起動順の逆で停止する。通常は省略する。

`enabledNow` のキーはこの開発環境のプロセスまたはスタックの ID、値は `true` / `false`。この開発環境に存在しない ID をキーにすると検証エラーになる。キーのない対象は `enabledByDefault` に従う。通常は `{}` にするか省略する。

## 4. 作業ディレクトリ（`workingDirectories[]`）

| キー | 型 | 制約 |
| --- | --- | --- |
| `id` | UUID | 開発環境内で一意 |
| `name` | 文字列 | 空でない。`Web`、`Native` などの表示名。開発環境内で重複しない |
| `directory` | file URL | 絶対パス。開発環境内で同じパスを重複させない。保存・取り込み時に実在するディレクトリであること |
| `serviceIDs` | UUID の配列 | このディレクトリに属するプロセスの ID。`[]` 可 |
| `stackIDs` | UUID の配列 | このディレクトリに属するスタックの ID。`[]` 可 |

`serviceIDs` と `stackIDs` の合計は 1 件以上とする。開発環境の各プロセスはちょうど 1 つの作業ディレクトリの `serviceIDs` に、各スタックはちょうど 1 つの作業ディレクトリの `stackIDs` に含める。存在しない ID を含めない。

保存済み設定の読み込み時はディレクトリの実在を確認しない。リポジトリを移動しても設定全体が読めなくなることを避けるためで、実在は登録・取り込み・起動の時点で確認する。

## 5. プロセス（`services[]`）

| キー | 型 | 制約 |
| --- | --- | --- |
| `id` | UUID | 登録済みの全開発環境のプロセスとスタックの中で一意 |
| `name` | 文字列 | 空でない。開発環境内のプロセスとスタックの中で名前が重複しない |
| `tag` | 文字列 | 任意。表示用の自由なタグ（`web`、`worker` など）。空でなく 32 文字以内（文字数は書記素クラスタで数える。Swift の `String.count` と同じ） |
| `start` | コマンド | 起動コマンド。`workingDirectory` は所属する作業ディレクトリの `directory` と同じ URL |
| `stop` | コマンド | 任意。停止コマンド。`workingDirectory` は実在するディレクトリ（通常は `start` と同じ） |
| `ports` | ポートの配列 | `[]` 可 |
| `enabledByDefault` | 真偽値 | 一括起動の対象にするか |
| `failurePolicy` | 文字列 | `block`（失敗したら開発環境全体を失敗にする）/ `continue`（後続を起動し一部停止とする） |

`tag` は表示にだけ使い、起動・停止・判定の挙動を変えない。タグからポートやコマンドを補完しない。

`stop` を指定すると、停止時にプロセスグループへ SIGTERM を送らず、このコマンドを実行してからプロセスグループの終了を待つ（`docs/SPEC.md` 7 章）。プロセスグループへの SIGTERM で止まるプロセスには指定しない。

次は検証エラーになる。

- `start` が Supabase の起動に当たる。判定は次のどちらかとする
  - `start.executable` の末尾名が `supabase` で、`start` サブコマンドを持つ（Supabase CLI のグローバルオプションを `start` の前に置いた形を含む）
  - 引数の要素が `supabase` または `supabase@<version>` で、その直後の要素が `start`、かつ `supabase` の直前の要素が存在しないか `-` で始まらない

  `pnpm exec supabase start`、`pnpm supabase start`、`npx supabase start`、`yarn supabase start`、`bunx supabase start` などが該当する。直前の要素が `-` で始まる形は、`--filter supabase` のようにオプションの値である可能性を文字列だけでは区別できないため、この判定では該当しない。`pnpm --filter supabase start`（ワークスペースパッケージ `supabase` の `start` スクリプト）はエラーにならない。該当したコマンドは、7.1 の 4 形式のいずれか（パッケージの CLI を使うなら `pnpm exec supabase start`）で `type: "supabase"` のスタックとして登録する

次は警告になるが、保存・取り込みはできる。

- 引数の要素が `supabase` または `supabase@<version>` で、その直後の要素が `start`、かつ `supabase` の直前の要素が `-` で始まる（例: `npx -y supabase start`、`pnpm --filter=api supabase start`）。Supabase の起動であり得るためエラーにはしないが、Supabase の起動なら `type: "supabase"` のスタック（7.1 の 4 形式）として登録するよう案内する。`pnpm --filter supabase start` のようにワークスペースパッケージのスクリプトである場合は、この警告を無視してよい
- `start.executable` の末尾名が `docker` または `docker-compose`。停止はプロセスグループ単位であり、コンテナは残り得る。コンテナまで管理するなら `dockerCompose` スタックとして登録する

## 6. コマンド（`start` / `stop`）

| キー | 型 | 制約 |
| --- | --- | --- |
| `executable` | 文字列 | 空でない。`pnpm` のような実行ファイル名、または絶対パス |
| `arguments` | 文字列の配列 | 各要素は空でない。引数なしなら `[]` |
| `workingDirectory` | file URL | 絶対パス |

実行ファイルは起動時に、利用者のログインシェルから取得した `PATH` で絶対パスへ解決し、見つからなければ起動前に失敗する。`"pnpm dev"` を `executable` にしたり、`sh -c` などでシェル文字列へ連結したりしない。`["dev", "--port", "3000"]` のように引数を要素ごとに分ける。

## 7. 管理対象スタック（`managedStacks[]`）

| キー | 型 | 制約 |
| --- | --- | --- |
| `id` | UUID | 登録済みの全開発環境のプロセスとスタックの中で一意 |
| `name` | 文字列 | 空でない。開発環境内のプロセスとスタックの中で名前が重複しない |
| `type` | 文字列 | `supabase` / `dockerCompose` |
| `supabase` | オブジェクト | `type` が `supabase` のときだけ必須。それ以外では書かない |
| `dockerCompose` | オブジェクト | `type` が `dockerCompose` のときだけ必須。それ以外では書かない |
| `ports` | ポートの配列 | `[]` 可。表示と「開く」URL のための補助情報 |
| `enabledByDefault` | 真偽値 | 一括起動の対象にするか |
| `failurePolicy` | 文字列 | `block` / `continue` |

停止方法はスタックの種類が決める。利用者は停止コマンドを指定できない。

### 7.1 `supabase`

| キー | 型 | 制約 |
| --- | --- | --- |
| `start` | コマンド | `supabase start` / `pnpm exec supabase start` / `npx supabase start` / `pnpx supabase start` の形式。`pnpm supabase start`、`yarn supabase start`、`bunx supabase start` などは受け付けないので、これらの形式へ書き換える。`workingDirectory` は所属する作業ディレクトリの `directory` と同じ URL |

検証規則:

- `npx` / `pnpx` / `pnpm exec` の後のパッケージ名は `supabase` または `supabase@<version>`
- `start` サブコマンドの前に置けるのは Supabase CLI のグローバルオプション（`--workdir`、`--profile`、`--network-id`、`--dns-resolver`、`--output` / `-o`、`--debug`、`--experimental`、`--yes`、`--create-ticket`）だけ。値を取るオプションに値が無ければエラー
- 引数に `--all` または `--no-backup` を含めない
- `--workdir` があればそのディレクトリ（相対なら `start.workingDirectory` 基準）、なければ `start.workingDirectory` の `supabase/config.toml` から、トップレベルの `project_id` を取得できること。値は英数字・`_`・`.`・`-` のみ、先頭は英数字、128 文字以内
- 1 つの開発環境に `type: "supabase"` のスタックは 1 件まで（`enabledByDefault` にかかわらず数える）
- `project_id` は、登録済みの全開発環境の Supabase スタックの中で一意

### 7.2 `dockerCompose`

| キー | 型 | 制約 |
| --- | --- | --- |
| `projectName` | 文字列 | 任意。`docker compose -p` に相当するプロジェクト名 |
| `files` | 文字列の配列 | 任意。Compose ファイルのパス。指定する場合は 1 件以上 |
| `profiles` | 文字列の配列 | 任意。起動・観測の `--profile` に渡す値。指定する場合は 1 件以上 |
| `upArguments` | 文字列の配列 | `up -d` の後に渡す追加引数。なければ `[]` |

検証規則:

- `files` の各要素は作業ディレクトリからの相対パス（`../` 可）で、実在するファイルを指す。絶対パスと `~` は受け付けない。Dev Switcher は解決した絶対パスを `docker compose -f` に指定順で渡す
- `files` を省略した場合、作業ディレクトリ直下に `compose.yaml`、`compose.yml`、`docker-compose.yaml`、`docker-compose.yml` のいずれかが存在すること。親ディレクトリは探さない。この場合も Dev Switcher は解決したファイル（基本ファイルと、あれば override ファイル）を `-f` で明示して渡す（`docs/SPEC.md` 6.7）
- `profiles` の各要素は空でない。起動・観測に使い、停止はこの設定によらず `--profile '*'` で同じプロジェクト名の全 profile を対象にする。設定外の profile も停止対象であることを編集・詳細・確認画面に表示する
- `upArguments` は許可リスト方式で検証する。各要素は次のいずれかでなければならず、それ以外（`-dV` のような短いオプションの結合、許可リストに無いオプション、`=` の付け方の違いを含む）はすべてエラーにする
  - サービス名: `-` で始まらず、英数字で始まり英数字・`_`・`.`・`-` だけからなる文字列
  - 値を取らないオプション: `--build`、`--no-build`、`--wait`、`--force-recreate`、`--no-recreate`、`--no-deps`、`--quiet-pull`
  - `--pull=always`、`--pull=missing`、`--pull=never`。または `--pull` の直後の要素に `always` / `missing` / `never`。この場合の直後の要素は `--pull` の値として消費し、サービス名として解釈しない。値が無い、または 3 つ以外の値ならエラー
  - `--wait-timeout=<1 以上の整数>`。または `--wait-timeout` の直後の要素に 1 以上の整数。この場合も直後の要素は値として消費し、サービス名として解釈しない
- 許可リストに無い代表例と理由: プロジェクトの選択を変える `-p` / `--project-name` / `-f` / `--file` / `--project-directory`、Dev Switcher が付ける `-d` / `--detach`、フォアグラウンドで動き続ける `--attach` / `--abort-on-container-exit` / `--exit-code-from` / `--watch`、起動しない `--no-start`、コンテナやボリュームを削除する `--remove-orphans` / `-V` / `--renew-anon-volumes`
- プロジェクト名は `projectName`、Compose ファイルのトップレベル `name:`、プロジェクトディレクトリ名（最初の Compose ファイルを含むディレクトリ）の順で決まる。Dev Switcher 独自の規則で、Docker の決定規則とは同じではない（`docs/SPEC.md` 6.7）。決まった名前は英小文字・数字・`-`・`_` のみで、先頭が英小文字か数字であること
- `projectName` と `name:` の値は変換せずに上の規則で検証する。プロジェクトディレクトリ名から決める場合だけ、英小文字化と規則外の文字の除去を行う
- `name:` が変数展開（`${...}`）を含む、複数の Compose ファイルで値が異なる、解釈できない場合はエラー。`projectName` を明示する
- 決まったプロジェクト名は、登録済みの全開発環境の `dockerCompose` スタックの中で一意。1 つの開発環境に複数の `dockerCompose` スタックを登録できる

`.env` で `COMPOSE_PROJECT_NAME` を設定しているプロジェクトや、ターミナルから起動したスタックを引き継ぎたいプロジェクトでは、ターミナル側のプロジェクト名（`docker compose ls` で確認できる）を `projectName` に明示する。Dev Switcher は `.env` を読まないため、その値を知り得ない。

## 8. ポート（`ports[]`）

| キー | 型 | 制約 |
| --- | --- | --- |
| `id` | UUID | 同じプロセスまたはスタックの中で一意 |
| `port` | 整数 | 1〜65535。同じプロセスまたはスタックの中で重複しない |
| `primary` | 真偽値 | ポートが 1 件以上あれば、ちょうど 1 件を `true` にする |
| `label` | 文字列 | 任意。`API`、`Studio` などの空でない表示名 |
| `openUrl` | 文字列 | 任意。`http` または `https` の URL。「開く」メニューに載る |

異なるプロセス・スタックの間で同じ番号を指定できる。ポートが未指定のとき、タグや種類から番号を補完しない。

## 9. ID の作り方と参照

新規の開発環境、作業ディレクトリ、プロセス、スタック、ポートには、それぞれ別の UUID を生成する。サンプルの UUID を流用しない。`serviceIDs`、`stackIDs`、`stopOrder`、`enabledNow` には、対応するプロセスまたはスタックの UUID を使う。保存済み JSON を移す場合は、既存の ID と順序を保持してよい。

取り込みでは、ファイル内の開発環境どうしと、登録済みの開発環境との両方について、ID・名前・スタック ID の重複を検証する。取り込みは新規追加だけで、同じ ID・名前の既存設定を更新しない。

## 10. 旧形式からの変換

読み込み時に、v1 → v2 → v3 → v4 の順に変換する。保存は常に v4 で行う。読み込みだけではファイルを書き換えず、次に利用者の操作で保存した時点で v4 になる。取り込みも同じ変換を通す。

### 10.1 v3 → v4

この節の「サービス」は、v3 の `services[]` の要素を指す。v3 では Supabase もサービスの一種だった。

| v3 | v4 |
| --- | --- |
| `schemaVersion: 3` | `schemaVersion: 4` |
| `services[]` のうち `kind: "supabase"` | `managedStacks[]` の `type: "supabase"`。`id`、`name`、`ports`、`enabledByDefault`、`failurePolicy` はそのまま。`start` は `supabase.start` へ移す |
| 上記の ID を含む `workingDirectories[].serviceIDs` | その ID を `serviceIDs` から除き、同じ作業ディレクトリの `stackIDs` へ移す |
| 上記の ID を含む `stopOrder` | その ID を除く。他の並びは保つ |
| その他の `services[].kind` | 同じ文字列を `tag` へ移す（`web`、`expo`、`inngest`、`worker`、`docker`、`other`） |
| `services[].stop` | そのまま保持する。v4 では停止時に実行される（v3 では起動時に拒否されていた） |
| `workingDirectories[].directory`、`start.workingDirectory` | そのまま |
| `enabledNow` | そのまま。キーの ID はスタックへ移った後も同じ対象を指す |
| （なし） | Supabase の無い開発環境にも `managedStacks: []`、全作業ディレクトリに `stackIDs: []` を加える |

スタックは移行前のサービスの ID を引き継ぐ。保存済みの手掛かり（前回起動・引き継いだ Supabase）との対応を保つためである。

次の場合は変換に失敗させ、該当する開発環境とプロセスを示す。v3 の検証を通った保存ファイルでは起こらないが、取り込みファイルでは起こり得る。

- `kind: "supabase"` のサービスに `stop` がある
- 1 つの開発環境に `kind: "supabase"` のサービスが 2 件以上ある

【PM 判断待ち: 論点 5】

`kind: "docker"` のサービスは v3 では起動時に拒否されていたが、v4 では `tag: "docker"` の通常プロセスとして起動できるようになり、検証時に警告を表示する。

v4 ではスタックがプロセスより先に起動し後に停止するため、v3 で Supabase より前に起動するサービスがあった開発環境、または Supabase より後に停止するサービスがあった開発環境は、変換によって起動順または停止順が変わる。この場合は、変換結果を保存するまで、読み込みのたびに該当する開発環境の名前と変わった内容を通知する。プロセス同士の相対的な順序は変わらない。

### 10.2 v1 / v2 → v3

各サービスの `start.workingDirectory` ごとに作業ディレクトリを作る。表示名はパス末尾とし、末尾が重複する場合だけ番号を付ける。サービスは並べ替えず、ID、起動順、停止順、今回の起動対象を維持する。

## 11. 例

パスは利用者の環境に合わせて置き換える。UUID は例であり、新規作成時は生成し直す。

### 11.1 Web と worker と Supabase

```json
{
  "schemaVersion": 4,
  "projects": [
    {
      "id": "6F1C2A3E-8B4D-4C5E-9A7F-1B2C3D4E5F60",
      "name": "shop-web",
      "color": "blue",
      "workingDirectories": [
        {
          "id": "0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9",
          "name": "Web",
          "directory": "file:///Users/example/GitHub/shop-web/",
          "serviceIDs": [
            "1E2F3A4B-5C6D-4E7F-8091-A2B3C4D5E6F7",
            "2F3A4B5C-6D7E-4F80-9102-B3C4D5E6F7A8"
          ],
          "stackIDs": [
            "3A4B5C6D-7E8F-4091-A213-C4D5E6F7A8B9"
          ]
        }
      ],
      "services": [
        {
          "id": "1E2F3A4B-5C6D-4E7F-8091-A2B3C4D5E6F7",
          "name": "Web",
          "tag": "web",
          "start": {
            "executable": "pnpm",
            "arguments": ["dev"],
            "workingDirectory": "file:///Users/example/GitHub/shop-web/"
          },
          "ports": [
            {
              "id": "7D8E9FA0-B1C2-4D3E-8F40-516273849506",
              "port": 3000,
              "primary": true,
              "openUrl": "http://localhost:3000"
            }
          ],
          "enabledByDefault": true,
          "failurePolicy": "block"
        },
        {
          "id": "2F3A4B5C-6D7E-4F80-9102-B3C4D5E6F7A8",
          "name": "Worker",
          "tag": "worker",
          "start": {
            "executable": "pnpm",
            "arguments": ["worker"],
            "workingDirectory": "file:///Users/example/GitHub/shop-web/"
          },
          "stop": {
            "executable": "pnpm",
            "arguments": ["worker:stop"],
            "workingDirectory": "file:///Users/example/GitHub/shop-web/"
          },
          "ports": [],
          "enabledByDefault": false,
          "failurePolicy": "continue"
        }
      ],
      "managedStacks": [
        {
          "id": "3A4B5C6D-7E8F-4091-A213-C4D5E6F7A8B9",
          "name": "Supabase",
          "type": "supabase",
          "supabase": {
            "start": {
              "executable": "pnpm",
              "arguments": ["exec", "supabase", "start"],
              "workingDirectory": "file:///Users/example/GitHub/shop-web/"
            }
          },
          "ports": [
            {
              "id": "8E9FA0B1-C2D3-4E4F-9051-627384950617",
              "label": "API",
              "port": 54321,
              "primary": true
            },
            {
              "id": "9FA0B1C2-D3E4-4F50-A162-738495061728",
              "label": "DB",
              "port": 54322,
              "primary": false
            },
            {
              "id": "A0B1C2D3-E4F5-4061-B273-849506172839",
              "label": "Studio",
              "port": 54323,
              "primary": false,
              "openUrl": "http://localhost:54323"
            }
          ],
          "enabledByDefault": true,
          "failurePolicy": "block"
        }
      ],
      "enabledNow": {}
    }
  ]
}
```

一括起動では Supabase、Web の順に起動し（Worker は対象外）、停止は Web、Supabase の順になる。

### 11.2 Web と Docker Compose

```json
{
  "schemaVersion": 4,
  "projects": [
    {
      "id": "4B5C6D7E-8F90-4A12-B324-D5E6F7A8B9C0",
      "name": "admin-console",
      "color": "green",
      "workingDirectories": [
        {
          "id": "5C6D7E8F-90A1-4B23-8435-E6F7A8B9C0D1",
          "name": "App",
          "directory": "file:///Users/example/GitHub/admin-console/",
          "serviceIDs": [
            "6D7E8F90-A1B2-4C34-9546-F7A8B9C0D1E2"
          ],
          "stackIDs": [
            "7E8F90A1-B2C3-4D45-A657-08B9C0D1E2F3"
          ]
        }
      ],
      "services": [
        {
          "id": "6D7E8F90-A1B2-4C34-9546-F7A8B9C0D1E2",
          "name": "Web",
          "tag": "web",
          "start": {
            "executable": "pnpm",
            "arguments": ["dev", "--port", "3100"],
            "workingDirectory": "file:///Users/example/GitHub/admin-console/"
          },
          "ports": [
            {
              "id": "B1C2D3E4-F506-4172-8384-95061728394A",
              "port": 3100,
              "primary": true,
              "openUrl": "http://localhost:3100"
            }
          ],
          "enabledByDefault": true,
          "failurePolicy": "block"
        }
      ],
      "managedStacks": [
        {
          "id": "7E8F90A1-B2C3-4D45-A657-08B9C0D1E2F3",
          "name": "DB と Redis",
          "type": "dockerCompose",
          "dockerCompose": {
            "projectName": "admin-console",
            "upArguments": []
          },
          "ports": [
            {
              "id": "C2D3E4F5-0617-4283-9495-061728394A5B",
              "label": "Postgres",
              "port": 5432,
              "primary": true
            },
            {
              "id": "D3E4F506-1728-4394-A5A6-1728394A5B6C",
              "label": "Redis",
              "port": 6379,
              "primary": false
            }
          ],
          "enabledByDefault": true,
          "failurePolicy": "block"
        }
      ]
    }
  ]
}
```

起動時は、作業ディレクトリで解決した Compose ファイルを `-f` に明示し、`docker compose -p admin-console -f <file>... up -d` を実行する。`running` を実測してから Web を起動する。停止は Web を止めた後に、同じファイルで `docker compose -p admin-console -f <file>... --profile '*' stop` を実行し、同じプロジェクト名の全 profile を停止する。

## 12. AI に生成させるときの確認事項

生成の前に、利用者へ次を確認する。指定のないコマンド・引数・パス・起動方針は推測しない。

- 開発環境名、各作業ディレクトリの表示名と Mac 上の絶対パス
- 各プロセスの名前、実行ファイル、引数、起動順、停止コマンドの有無
- 管理対象スタックの有無と種類（Supabase / Docker Compose）、Compose のプロジェクト名・ファイル・プロファイル
- 既定で起動対象にするか、起動失敗時に全体を止めるか続行するか
- ポートは任意。指定する場合は番号、代表ポート、必要に応じて表示名と開く URL

利用者が指定したリポジトリの `package.json`、`supabase/config.toml`、Compose ファイルでコマンドや名前を裏付けてよいが、`.env`、`.env.*`、`.envrc` は読まない。JSON の作成・確認のために起動コマンド、DB の migration・reset・seed、依存パッケージのインストールを実行しない。

生成後は、JSON として解析できること、必須キー、未知キーが無いこと、ID の一意性と参照関係、パスの実在を確認する。実行ファイルの利用可否や各コマンドが正常に起動するかは、取り込みだけでは保証されない。利用者が確認画面で内容を確認してから追加し、必要なときに起動する。
