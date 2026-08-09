---
title: デプロイメント環境変数
description: control plane と Agent Computer Worker がプロセス起動時に読み取るデプロイメント設定のリファレンス。
section: Reference
order: 202
---

このページでは、Ankole がプロセス起動時に読み取るデプロイメント環境変数だけを列挙します。これらは PostgreSQL への接続、インスタンスの secret の確立、RuntimeFabric の起動、control-plane と Worker プロセスの調整を行います。

インスタンスの実行中に管理者が変更できるランタイム設定は、[AppConfigure](../app-configuration/)ガイドが所有しています。それらの設定を `.env` や Kubernetes Secret に入れないでください。

## ブートストラップと secret（プロセス起動）

これらは control plane が起動する前に存在していなければなりません。Docker Compose では `.env` に、Helm chart が読み取る場合は Secret に設定します。

| 変数 | 必須 | 意味 |
|---|---|---|
| `DATABASE_URL` | はい | control plane 用の PostgreSQL 接続文字列 |
| `ANKOLE_SECRET_BASE` | はい | インスタンス全体の secret base。他のキーの導出に使われる |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | はい | worker が RuntimeFabric に提示する auth key |
| `POSTGRES_PASSWORD` | バンドル版 PostgreSQL のみ | PostgreSQL のパスワード（バンドル版 PostgreSQL を有効にした場合に必須。それ以外は外部 Secret が提供する） |
| `ANKOLE_HOST` | Compose | デプロイメントが提供される DNS 名 |
| `ACME_EMAIL` | Compose | Caddy が Let's Encrypt に使うメールアドレス |

これらの値は `.env` または Secret に保管してください。バージョン管理にコミットしてはなりません。Docker Compose の `.env.example` が開始時の構成です。

Helm chart の `values.yaml` には、関連する Kubernetes の値 `ankoleSecretBase`、`workerAuthKey`、`postgresqlPassword` がリストされています。

## ランタイム調整（プロセス環境）

これらは起動時に読み取られ、実行中のプロセスを調整します。secret ではありません。

| 変数 | デフォルト | 意味 |
|---|---|---|
| `ANKOLE_ENV` | — | デプロイメント環境のラベル（例：`prod`、`dev`） |
| `ANKOLE_LOG_LEVEL` | `info` | ログレベル（`debug`、`info`、`warning`、`error`） |
| `ANKOLE_LOG_FORMAT` | `json` | ログ行の形式（取り込み用は `json`、ローカルで読む場合は `pretty`） |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | control-plane のデータベース接続プールサイズ |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | `300` | バンドル版サーバー用の PostgreSQL の `max_connections` 設定 |
| `ANKOLE_MAX_CONCURRENT_TURNS` | `9` | 同時 actor turn の上限 |
| `ANKOLE_LIBRARY_ROOT` | chart のデフォルト | 同梱の Agent Library（`app/library`）へのパス |
| `ANKOLE_INTERNAL_SKILLS_ROOT` | — | 内部 Skill bundle へのパス |
| `ANKOLE_AI_GATEWAY_BASE_URL` | — | AIGateway のベース URL の上書き（ほとんど必要ない） |
| `ANKOLE_RUNTIME_FABRIC_BIND_ENDPOINT` | — | RuntimeFabric のバインドエンドポイント |

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

worker は、固定された小さな環境変数のセットを読み取ります。actor identity は**その中にありません**。それは `turn_start` で届き、環境変数では届きません。これらは運用者ではなく、マネージド worker ブートストラップが設定します。

| 変数 | 意味 |
|---|---|
| `WORKER_ID` | worker の identity（例：`worker-local-1`） |
| `ANKOLE_RUNTIME_FABRIC_ENDPOINT` | RuntimeFabric の TCP エンドポイント |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | RuntimeFabric の worker auth key。エンドポイントとは別に渡される |
| `ANKOLE_AGENTS_ROOT` | 共有 `/agents` workspace マウントのルート |
| `ANKOLE_AGENT_COMPUTER_IMAGE` | worker が実行する Agent Computer Worker イメージ |
| `ANKOLE_VERSION` | Ankole のバージョンラベル |

Worker イメージは、ブラウザ、Bubblewrap、Codex、Skill のパスを設定します。これには `ANKOLE_BROWSER_*`、`ANKOLE_BWRAP_PATH`、`ANKOLE_CODEX_BINARY`、`ANKOLE_BUILTIN_SKILLS_ROOT` が含まれます。管理者はこれらのパスを変更できません。

`PATH`、`HOME`、`DATABASE_URL`、および `ANKOLE_` で始まる名前は予約されており、Console で変更できません。Agent 用のカスタム値は[環境変数](../worker-env/)を参照してください。

## デプロイメント環境変数を変更する

- Docker Compose の場合は、`.env` を変更し、影響を受けるコンテナを再起動します。
- Kubernetes の場合は、Helm の値または関連する Secret を変更し、影響を受けるワークロードを再起動します。

プロセスは起動時にのみこれらの変数を読み取ります。プロセスを再起動せずにファイルや Secret を変更しても、現在のランタイムは変わりません。

## 次のステップ

- Agent が使うカスタム値については、[環境変数](../worker-env/)を参照してください。
- ランタイム設定と AppConfigure キーの完全なリストについては、[AppConfigure](../app-configuration/)を参照してください。
- デプロイメント変数のコンテキストについては、[Quick start のデプロイメントのセクション](../quickstart/#deployment)を参照してください。