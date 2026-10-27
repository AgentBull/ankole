---
title: デプロイメント環境変数
description: control plane と Agent Computer Worker がプロセス起動時に読み取るデプロイメント設定のリファレンス。
section: Reference
order: 202
---

このページでは、PostgreSQL、Pod Base シャードデータベース、`ankole-function-runtime`、デプロイ用の秘密情報、オブジェクトストア、およびプロセス設定に関する起動時環境変数をまとめます。なお、Worker provider の構成自体は環境変数ではなく、PostgreSQL 内に YAML として保存されます。

インスタンス稼働中に管理者が動的に変更できるランタイム設定については、[アプリケーション設定](../app-configuration/)を参照してください。それらのランタイム設定を `.env` や Kubernetes Secret に記述しないでください。

## ブートストラップと secret（プロセス起動）

以下の変数は、control plane を起動する前に設定しておく必要があります。Docker Compose では `.env` に、Helm chart では参照先の Secret に設定します。

| 変数 | 必須 | 意味 |
|---|---|---|
| `DATABASE_URL` | はい（`prod`） | control plane（`Ankole.Repo`）用の PostgreSQL 18+ 接続文字列 |
| `BASE_DB_URLS` | いいえ | 物理 Pod Base シャード（`Ankole.Pod.BaseRepo`）用の `;` 区切り PostgreSQL 18+ 接続 URL（任意）。クエリパラメータ `ankole_sharding`、`ankole_pool_size`、`ankole_stock_only` に対応します。単一 DB の FOSS 構成で未設定の場合は `DATABASE_URL` を `base_default` として使用し、`sslmode` は拒否します |
| `ANKOLE_SECRET_BASE` | はい（`prod`） | サイト全体の secret base。暗号化キーや署名キーの導出に使われます |
| `RELEASE_COOKIE` | はい（`prod`） | Erlang distribution cookie。同一デプロイ内のすべての control plane ノードで同じ値を共有します |
| `ANKOLE_FUNCTION_RUNTIME_TOKEN` | はい（`prod`） | control plane と `ankole-function-runtime` が共有する内部 Bearer シークレット |
| `ANKOLE_FUNCTION_RUNTIME_URL` | はい（`prod`） | `ankole-function-runtime` の内部 HTTP URL（例：Compose では `http://function-runtime:9000`） |
| `POSTGRES_PASSWORD` | バンドル版 PostgreSQL のみ | PostgreSQL のパスワード（バンドル版 PostgreSQL を有効にした場合に必須。それ以外は `DATABASE_URL` または外部 Secret で指定） |
| `ANKOLE_HOST` | Compose | デプロイメントを公開する DNS ホスト名 |
| `ACME_EMAIL` | Compose | Caddy が Let's Encrypt の証明書発行に使う連絡先メールアドレス |
| `ANKOLE_DOCKER_GID` | Compose | Docker socket を所有するグループ ID。非特権ユーザーで動作する control plane がこのグループ権限で socket にアクセスします |

これらの値は `.env` または Secret で厳重に管理し、バージョン管理システムには絶対にコミットしないでください。Docker Compose 環境では、付属の `.env.example` を初期テンプレートとして利用できます。

なお、Worker 用の認証キーを運用者が `.env` や Secret に用意する必要はありません。control plane が Worker ごとに専用の認証情報を発行して渡します。

Helm chart の `values.yaml` では、これらに対応する設定キーとして `secrets.ankoleSecretBase`、`secrets.releaseCookie`、`secrets.functionRuntimeToken`、`secrets.databaseURL`、`secrets.baseDBURLs`、`secrets.postgresqlPassword`、`controlPlane.siteAdminConsolePath`、`functionRuntime.*` が定義されています。

## ランタイム調整（プロセス環境）

以下の変数はプロセス起動時に読み取られ、control plane や `ankole-function-runtime` の動作パラメータを調整します。秘密情報ではありません。

| 変数 | デフォルト | 意味 |
|---|---|---|
| `ANKOLE_ENV` | — | デプロイメント環境のラベル（例：`prod`、`dev`） |
| `ANKOLE_LOG_LEVEL` | `info` | ログレベル（`debug`、`info`、`warning`、`error`） |
| `POOL_SIZE` | `10` | control-plane プロセスが直接読み取る `Ankole.Repo` のデータベース接続プールサイズ |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | Docker Compose 用の `.env` 変数（`compose.yaml` 内で `POOL_SIZE` にマッピングされます） |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | `300` | バンドル版 PostgreSQL サーバーに設定する `max_connections` の値 |
| `ANKOLE_SITE_ADMIN_CONSOLE_PATH` | `/site-admin-console` | Site Admin Console の URL パス |
| `ANKOLE_FUNCTION_RUNTIME_IMAGE` | リリース既定値 | Docker Compose で使用する `ankole-function-runtime` コンテナイメージ |
| `ANKOLE_FUNCTION_RUNTIME_MAX_CONCURRENCY` | `32` | `ankole-function-runtime` コンテナあたりの最大同時実行数 |
| `ANKOLE_LIBRARY_ROOT` | chart のデフォルト | 同梱の Agent Library（`app/library`）へのパス |
| `ANKOLE_INTERNAL_SKILLS_ROOT` | — | 内部 Skill bundle へのパス |
| `ANKOLE_AI_GATEWAY_BASE_URL` | — | AIGateway のベース URL の上書き指定 |

## ファイルストア（プロセス起動）

`ANKOLE_FILES_STORE` は control plane のオブジェクトストア（`Ankole.ObjectStore`）を構成します。ここには各 Agent のドライブ（添付ファイル、生成画像、送信ファイル、インストール済み Skill、Automation Job のスクリプト、Agent が保存したファイル）のほか、Pod の `file` ページ、Pod ドキュメント/Base/Chat 添付ファイル、およびコンパイル済み Applet バンドルが保存されます。Worker にはストレージの認証情報を渡さず、ファイルデータの読み書きはすべて control plane を経由します。対応するすべての OpenDAL backend の詳細については、[control plane ドライブ・オブジェクトストレージの設定](../drive-storage/)を参照してください。

| 変数 | 必須 | 意味 |
|---|---|---|
| `ANKOLE_FILES_STORE` | はい | `fs` は control plane の永続ボリューム上のディレクトリ、`s3` は Amazon S3 または Cloudflare R2 などの S3 互換ストア |
| `ANKOLE_FILES_FS_ROOT` | `fs` | ストアの絶対パス。Docker Compose では `/var/lib/ankole/files` にマウントされた `files_data` ボリュームを使用します |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | バケット名 |
| `ANKOLE_FILES_S3_REGION` | `s3` | リージョン。Cloudflare R2 の場合は `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | いいえ | S3 互換ストアのカスタムエンドポイント |
| `ANKOLE_FILES_S3_ROOT` | いいえ | バケット内のオブジェクトキー接頭辞（prefix） |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID`、`ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | いいえ | 固定の認証情報。省略時は EKS Pod Identity を含む既定の AWS 認証情報チェーンを使用します |

`fs` ストアを使用できるのは、control plane が 1 レプリカの構成に限られます。複数レプリカで運用する場合は `s3` などの共有リモートストレージを使用してください。

また、`s3` への大容量ファイルの書き込みにはマルチパートアップロードが使用されます。アップロード途中に control plane が停止すると未完了のパートがバケット内に残るため、未完了のマルチパートアップロードを自動中止するライフサイクルルールをバケットに設定してください。

## Worker Provider の初期設定

起動時に読み取られる以下の変数は、デプロイメントの識別名や起動対象の Worker イメージを指定します。個々の Worker provider は **Console → Workers → Providers** で YAML として設定し、認証情報は別途暗号化して保存されます。provider 作成後に種類・配置・永続ストレージ方式を変更することはできません。インスタンス設定の変更は、対象 Agent がアイドル状態になった時点で反映されます。

| 変数 | 意味 |
|---|---|
| `ANKOLE_AGENT_COMPUTER_IMAGE` | control plane のリリースに対応する Worker イメージ |
| `ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT` | 既定の RuntimeFabric WebSocket URL |
| `ANKOLE_WORKER_INSTALLATION` | デプロイメント識別ラベル（既定値：`ankole`） |
| `ANKOLE_WORKER_PROVIDERS_FILE` | 任意の provider 初期投入（seed）用 YAML。初回読み込みと既存 Agent への割り当てが同一トランザクションで実行されます |

ローカル開発時（`bun dev`）のソースコードや内部 Skill のマウントは `config/dev.exs` で構成されており、本番リリースイメージには開発用マウントは含まれません。

## Provider の Egress プロキシ

model provider への通信をアウトバウンドプロキシ経由にする必要がある場合は、control-plane プロセスに以下の標準プロキシ変数を設定します（`https_proxy` などの小文字表記も使用できます）。

| 変数 | 意味 |
|---|---|
| `HTTPS_PROXY` | HTTPS およびセキュア WebSocket（`wss`）の provider リクエスト用プロキシ |
| `HTTP_PROXY` | HTTP および WebSocket（`ws`）の provider リクエスト用プロキシ。`HTTPS_PROXY` と `ALL_PROXY` がどちらも未設定の場合、セキュアなリクエストにも使用されます |
| `ALL_PROXY` | プロトコル固有の変数が未設定の場合に使われるフォールバックプロキシ |
| `NO_PROXY` | プロキシを経由せず直接接続するホスト名またはドメイン接尾辞のカンマ区切りリスト |

プロキシ URL には `http`、`https`、`socks5`、`socks5h` スキームを指定でき、プロキシ認証が必要な場合は URL 内に認証情報を埋め込むことも可能です。判定時は常に `NO_PROXY` が最優先されます。セキュアなリクエストでは `HTTPS_PROXY` → `ALL_PROXY` → `HTTP_PROXY` の順に、平文のリクエストでは `HTTP_PROXY` → `ALL_PROXY` の順に参照されます。これらの変数を変更した後は control plane を再起動してください。

## Worker 専用の環境（Agent Computer Worker）

以下の変数は Worker 作成時に control plane が自動設定するものであり、運用者が手動で設定することはありません。Worker は `WORKER_ID` から担当の Agent を識別します。なお、Session や Turn の情報は環境変数ではなく、各 `turn_start` メッセージで渡されます。

| 変数 | 意味 |
|---|---|
| `WORKER_ID` | 担当する Agent の UID。Worker はこの Agent 専用として動作します |
| `ANKOLE_RUNTIME_FABRIC_ENDPOINT` | Worker の接続先となる `ws://` または `wss://` の RuntimeFabric URL |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | generation ごとに発行されるランダム認証情報。control plane 側にはダイジェストと暗号化された再試行用の値が保存されます |
| `ANKOLE_WORKER_STORAGE` | provider が指定するストレージ準備モード |

Worker コンテナに追加の環境変数を渡したい場合は、provider YAML の `env` または Kubernetes の `podTemplate` で設定します。`ANKOLE_MAX_CONCURRENT_SLOTS` は Worker 内の環境ワークスペースと Codex turn の同時実行上限を制御します（既定値：`12`、通常の model turn は slot を消費しません）。これらの設定を変更すると、アイドル時に Worker が置き換えられます。

なお、`ANKOLE_BROWSER_*` や `ANKOLE_BUILTIN_SKILLS_ROOT` などのブラウザ・組み込み Skill 用パスは Worker イメージ側で固定されており、管理者が変更することはできません。

また、`PATH`、`HOME`、`DATABASE_URL`、および `ANKOLE_` で始まる変数名は Agent 環境エディターでは予約済みのため指定できません。必要な場合は provider YAML の対応フィールドで設定してください。詳しくは[環境変数](../worker-env/)を参照してください。

## デプロイメント環境変数を変更する

起動時環境変数を変更する場合は、Docker Compose の `.env` または Helm の values を更新したうえで、対象プロセスを再起動します。Worker provider の設定変更は Console から行ってください（一度読み込まれた seed ファイルが既存のデータベース設定を上書きすることはありません）。Worker イメージやインスタンス設定を変更した場合は、各 Agent がアイドル状態になったタイミングで Worker が順次置き換えられます。

## 次のステップ

- Agent が使用するカスタム環境変数については、[環境変数](../worker-env/)を参照してください。
- ランタイム設定と AppConfigure キーの一覧については、[AppConfigure](../app-configuration/)を参照してください。
- デプロイメント全体での環境変数の位置づけについては、[Quick start のデプロイメントセクション](../quickstart/#deployment)を参照してください。
