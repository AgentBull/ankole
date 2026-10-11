---
title: デプロイメント環境変数
description: control plane と Agent Computer Worker がプロセス起動時に読み取るデプロイメント設定のリファレンス。
section: Reference
order: 202
---

このページは PostgreSQL、デプロイの秘密情報、ファイルストア、プロセス設定の起動変数です。Worker provider の設定は PostgreSQL に YAML として保存します。

インスタンスの実行中に管理者が変更できるランタイム設定は、[AppConfigure](../app-configuration/)ガイドが所有しています。それらの設定を `.env` や Kubernetes Secret に入れないでください。

## ブートストラップと secret（プロセス起動）

これらは control plane が起動する前に存在していなければなりません。Docker Compose では `.env` に、Helm chart が読み取る場合は Secret に設定します。

| 変数 | 必須 | 意味 |
|---|---|---|
| `DATABASE_URL` | はい | control plane 用の PostgreSQL 接続文字列 |
| `ANKOLE_SECRET_BASE` | はい | インスタンス全体の secret base。他のキーの導出に使われる |
| `RELEASE_COOKIE` | はい | Erlang distribution cookie。同じデプロイのすべてのコントロールプレーンノードが同じ値を使う |
| `POSTGRES_PASSWORD` | バンドル版 PostgreSQL のみ | PostgreSQL のパスワード（バンドル版 PostgreSQL を有効にした場合に必須。それ以外は外部 Secret が提供する） |
| `ANKOLE_HOST` | Compose | デプロイメントが提供される DNS 名 |
| `ACME_EMAIL` | Compose | Caddy が Let's Encrypt に使うメールアドレス |
| `ANKOLE_DOCKER_GID` | Compose | Docker socket のグループ ID。control plane は非特権ユーザーとして実行され、このグループを通じて socket を使用する |

これらの値は `.env` または Secret に保管してください。バージョン管理にコミットしてはなりません。Docker Compose の `.env.example` が開始時の構成です。

Worker 用のキーを `.env` や Secret に設定する必要はありません。control plane が各 Worker に専用の credential を渡します。

Helm chart の `values.yaml` には、関連する Kubernetes の値 `ankoleSecretBase`、`releaseCookie`、`databaseURL`、`postgresqlPassword` がリストされています。

## ランタイム調整（プロセス環境）

これらは起動時に読み取られ、実行中のプロセスを調整します。secret ではありません。

| 変数 | デフォルト | 意味 |
|---|---|---|
| `ANKOLE_ENV` | — | デプロイメント環境のラベル（例：`prod`、`dev`） |
| `ANKOLE_LOG_LEVEL` | `info` | ログレベル（`debug`、`info`、`warning`、`error`） |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | control-plane のデータベース接続プールサイズ |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | `300` | バンドル版サーバー用の PostgreSQL の `max_connections` 設定 |
| `ANKOLE_LIBRARY_ROOT` | chart のデフォルト | 同梱の Agent Library（`app/library`）へのパス |
| `ANKOLE_INTERNAL_SKILLS_ROOT` | — | 内部 Skill bundle へのパス |
| `ANKOLE_AI_GATEWAY_BASE_URL` | — | AIGateway のベース URL の上書き（ほとんど必要ない） |

## ファイルストア（プロセス起動）

コントロールプレーンは各 Agent のドライブをファイルストアに保存します。対象は添付ファイル、生成画像、送信したファイル、インストール済み Skill、Automation Job のスクリプト、Agent が保存したファイルです。Worker はストレージの認証情報を受け取らず、ファイルのバイトはコントロールプレーンを経由します。

| 変数 | 必須 | 意味 |
|---|---|---|
| `ANKOLE_FILES_STORE` | はい | `fs` はコントロールプレーンの永続ボリューム上のディレクトリ、`s3` は Amazon S3 または Cloudflare R2 などの S3 互換ストア |
| `ANKOLE_FILES_FS_ROOT` | `fs` | ストアの絶対パス。Docker Compose は `/var/lib/ankole/files` にマウントした `files_data` ボリュームを使います |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | バケット |
| `ANKOLE_FILES_S3_REGION` | `s3` | リージョン。Cloudflare R2 は `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | いいえ | S3 互換ストアのエンドポイント |
| `ANKOLE_FILES_S3_ROOT` | いいえ | バケット内のキー接頭辞 |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID`、`ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | いいえ | 静的な認証情報。設定しない場合は EKS Pod Identity を含む既定の AWS 認証情報チェーンを使います |

`fs` ストアではコントロールプレーンのレプリカは 1 つだけです。複数のレプリカを動かす場合は `s3` を使います。

`s3` への大きな書き込みはマルチパートアップロードです。アップロード中にコントロールプレーンが停止するとパートがバケットに残るため、未完了のマルチパートアップロードを中止するライフサイクルルールをバケットに設定してください。

## Worker Provider の初期設定

起動時の値はデプロイと対象 Worker イメージを指定します。各 provider は **Console → Workers → Providers** の YAML で設定し、認証情報は別に暗号化して保存します。作成後に種類、配置、永続ストレージは変更できません。インスタンス設定は Agent のアイドル時に適用します。

| 変数 | 意味 |
|---|---|
| `ANKOLE_AGENT_COMPUTER_IMAGE` | control plane のリリースに対応する Worker イメージ |
| `ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT` | 既定の RuntimeFabric WebSocket URL |
| `ANKOLE_WORKER_INSTALLATION` | デプロイラベル。既定値は `ankole` |
| `ANKOLE_WORKER_PROVIDERS_FILE` | 任意の provider seed YAML。初回読み込みと既存 Agent の割り当ては同一トランザクション |

`bun dev` のソースと内部 Skill のマウントは `config/dev.exs` で設定します。リリースには開発用マウントはありません。

## Provider の Egress プロキシ

model provider のトラフィックがアウトバウンドプロキシを経由しなければならない場合は、control-plane プロセスにこれらの標準変数を設定します。`https_proxy` のような小文字形式も機能します。

| 変数 | 意味 |
|---|---|
| `HTTPS_PROXY` | HTTPS とセキュア WebSocket（`wss`）の provider リクエスト用プロキシ |
| `HTTP_PROXY` | HTTP と WebSocket（`ws`）の provider リクエスト用プロキシ。`HTTPS_PROXY` や `ALL_PROXY` の値が存在しない場合、セキュアなリクエストもこれを使う |
| `ALL_PROXY` | プロトコル固有の変数が存在しない場合の provider リクエスト用フォールバックプロキシ |
| `NO_PROXY` | 直接接続しなければならないホストまたはドメイン接尾辞のカンマ区切りリスト |

プロキシ URL は `http`、`https`、`socks5`、`socks5h` を使用でき、プロキシが認証を要求する場合は埋め込みの credential も使用できます。`NO_PROXY` が常に優先されます。セキュアなリクエストでは、Ankole は `HTTPS_PROXY`、次に `ALL_PROXY`、その次に `HTTP_PROXY` を試します。通常のリクエストでは `HTTP_PROXY`、次に `ALL_PROXY` を試します。これらの変数を変更したら、control plane を再起動してください。

## Worker 専用の環境（Agent Computer Worker）

control plane は Worker を作成するときにこれらの変数を設定します。運用者は設定しません。Worker は `WORKER_ID` から自分の Agent を知ります。Session と Turn は各 `turn_start` で届き、環境変数では届きません。

| 変数 | 意味 |
|---|---|
| `WORKER_ID` | Agent の UID。Worker はこの Agent だけにサービスを提供する |
| `ANKOLE_RUNTIME_FABRIC_ENDPOINT` | Worker が接続する `ws://` または `wss://` の RuntimeFabric URL |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | generation のランダム認証情報。control plane はダイジェストと暗号化した再試行値を保存 |
| `ANKOLE_WORKER_STORAGE` | provider が指定するストレージ準備モード |

Worker 環境は provider YAML の `env` または Kubernetes `podTemplate` に設定します。`ANKOLE_MAX_CONCURRENT_SLOTS` は Worker の環境 workspace と Codex turn を制限し、既定値は 12 です。model turn は Worker slot を使いません。設定変更後はアイドル時に置換します。

Worker イメージは、ブラウザと Skill のパスを設定します。これには `ANKOLE_BROWSER_*` と `ANKOLE_BUILTIN_SKILLS_ROOT` が含まれます。管理者はこれらのパスを変更できません。

`PATH`、`HOME`、`DATABASE_URL`、`ANKOLE_` で始まる名前は Agent 環境エディターで予約済みです。provider YAML の対応設定は指定できます。[環境変数](../worker-env/)を参照してください。

## デプロイメント環境変数を変更する

起動変数は Compose の `.env` または Helm values で変更し、対象プロセスを再起動します。provider は Console で変更します。読み込み済みの seed ファイルは既存設定を上書きしません。イメージやインスタンス設定の変更は Agent のアイドル時に Worker を置換します。

## 次のステップ

- Agent が使うカスタム値については、[環境変数](../worker-env/)を参照してください。
- ランタイム設定と AppConfigure キーの完全なリストについては、[AppConfigure](../app-configuration/)を参照してください。
- デプロイメント変数のコンテキストについては、[Quick start のデプロイメントのセクション](../quickstart/#deployment)を参照してください。
