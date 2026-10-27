---
title: kit CLI リファレンス
description: devkit のコマンド一覧 — オペレーターやコントリビューターが使用する `bun run kit` コマンドと、`package.json` のラッパースクリプトを解説します。
section: Reference
order: 200
---

`kit` は Ankole の開発・運用支援 CLI（devkit）です。リポジトリルートから `bun run kit <command>` として実行でき、環境構築、ローカルサービスの管理、開発サーバーの起動、データベースのライフサイクル操作、セットアップ有効化コードの確認、ログ整形、コード生成、リポジトリの静的解析までを一通りカバーしています。このページでは、利用可能なすべてのコマンドを一覧で説明します。

`kit` の実体は `tools/devkit/` 配下にある Bun + TypeScript プログラムです。よく使うコマンド（`services:start`、`services:stop`、`dev`、`analyze` など）はリポジトリ直下の `package.json` スクリプトとしてラップされているため、毎回 `bun run kit ...` とフルで入力しなくても実行できます。スクリプトは単なるエイリアスなので、どちらの形式で呼び出しても同じように動作します。

## 環境と検出

| コマンド | 内容 |
|---|---|
| `kit env-setup` | Ankole の開発に必要なホストツールチェーン（システムビルドパッケージ、Docker、Rust、Elixir/Erlang ツールチェーン、バージョン固定された Bun）をインストールします。`--print` を付けると、インストーラーを実行せずコマンド内容だけを表示します。 |
| `kit is-ci` | CI 環境であれば終了コード `0`、それ以外なら `1` を返します。CI かどうかで処理を分岐するスクリプトから利用されます。 |
| `kit is-dev` | 開発環境であれば終了コード `0`、それ以外なら `1` を返します。 |

新しい開発マシンでは、最初に一度だけ `env-setup` を実行してください。残りの 2 つは、他のコマンドやスクリプトが内部で環境判定に使うヘルパーです。

## ローカルサービスと開発環境

| コマンド | 内容 |
|---|---|
| `kit external-services start` | devkit の Docker Compose サービス（PostgreSQL 18 と `ankole-function-runtime`）を起動します。`bun run services:start` としてラップされています。 |
| `kit external-services stop` | devkit の Compose サービスを停止します。`bun run services:stop` としてラップされています。 |
| `kit external-services status` | devkit サービスの稼働状態とヘルスチェック結果を報告します。`bun run services:status` としてラップされています。 |
| `kit dev` | PostgreSQL 18、`ankole-function-runtime`、Phoenix とフロントエンドアセット、および Agent ごとに Worker コンテナを 1 つ立ち上げる Docker Worker バックエンドを含む、開発環境一式を起動します。`bun run dev` としてラップされています。実行中はターミナルを開いたままにしてください。 |

`kit dev` はローカルスタック全体をまとめて立ち上げるメインコマンドです。実行すると、まず PostgreSQL 18 と `ankole-function-runtime` を起動（または稼働確認）し、ローカルのコントロールプレーンデータベース（`ankole_dev`）の作成とマイグレーションを行い、Worker イメージが未作成または古ければビルドしたうえで、Docker Worker バックエンドを有効にしてコントロールプレーンを起動します。また、`BASE_DB_URLS` が未設定の場合は、コントロールプレーンの開発用ブートストラップ処理によって 4 つのローカル Base シャードデータベース（`ankole_base_00`〜`ankole_base_03`）も自動作成・初期化されます。

コントロールプレーンは Agent の作成時にその Agent 専用の Worker コンテナを起動し、コンテナ内ではローカルの Agent Computer ソースコードが `bun --watch` で実行されます。稼働中のコンテナは `docker ps -a --filter label=ankole.installation=dev` で確認できます。なお、`kit dev` を複数同時に起動しないでください。停止するときは実行中のターミナルで `Ctrl+C` を押します。停止時には `dev` インストールの Worker コンテナもあわせて削除されますが、次回起動後に既存の Agent が処理を行うタイミングで、コントロールプレーンが再度 Worker コンテナを作成します。

## データベースライフサイクル

ローカルのコントロールプレーンデータベースは `kit app-db` で管理します。

| コマンド | 内容 |
|---|---|
| `kit app-db create` | アプリデータベースが未作成の場合に新規作成します。 |
| `kit app-db drop` | アプリデータベースを削除します。破壊的操作のため、確認用の `--yes` フラグが必須です。 |
| `kit app-db rebuild` | アプリデータベースを削除して再作成し、Ecto マイグレーションまで一括で実行します。`--yes` が必須です。 |
| `kit app-db migrate` | 設定済みのローカルデータベースに対して、コントロールプレーンの Ecto マイグレーションを実行します。 |

`create`、`drop`、`rebuild` には共通オプションを指定できます。`--start-services` は操作前に Compose サービスを起動し、`--pull` は最新のサービスイメージを事前に取得し、`--wait-timeout` はサービスのヘルスチェック完了を待機する秒数（デフォルトは `60`）を指定します。特に `app-db rebuild` はローカルの `ankole_dev` データベースを完全に消去するため、中身を破棄しても問題ない場合にのみ実行してください。

## セットアップと検査

| コマンド | 内容 |
|---|---|
| `kit show bootstrap-activation-code` | 現在のセットアップ有効化コードを表示します。初回アクセス時の画面でコードの入力を求められた際、`kit dev` を動かしているターミナル出力が手元で見えない場合に便利です。 |
| `kit logs pretty` | 標準入力（stdin）から受け取った Ankole の構造化 JSON ログを、人間が読みやすい形式に整形して出力します。ローカルでログストリームをパイプして確認するときに使います。 |

## コード生成と分析

| コマンド | 内容 |
|---|---|
| `kit generate [collection-name:]<schematic-name> [options]` | schematic テンプレートからファイルを生成・更新します。`bun run kit g code-workspace`（エイリアス: `bun run workspace:update`）を実行すると、VS Code のワークスペース設定ファイルを再生成できます。 |
| `kit analyze all` | リポジトリ全体の静的解析を一括実行します。`bun run analyze` としてラップされています。 |
| `kit analyze smells` | コードスメル（設計・実装上の懸念箇所）を検出して報告します。`bun run analyze:smells` としてラップされています。 |
| `kit analyze unused` | 未使用のコードを検出して報告します。`bun run analyze:unused` としてラップされています。 |
| `kit analyze structure` | リポジトリのディレクトリ・モジュール構造を検査して報告します。`bun run analyze:structure` としてラップされています。 |
| `kit analyze cycles` | 依存関係の循環（サイクル）を検出して報告します。`bun run analyze:cycles` としてラップされています。 |

## Worker テストランナー

`kit agent-computer-test` は、Agent Computer Worker パッケージのテストを標準の Worker コンテナランタイム内で実行するコマンドです。これにより、実際の Turn 実行時と同一の環境でテストを検証できます。`--suite` には `unit` または `integration` を指定でき、`--image` を渡せば新規ビルドを行わずに指定した既存の Agent Computer Worker Docker イメージ上でテストを実行できます。

## さらに調べる

```bash
bun run kit --help
```

`kit` は `@crustjs` のコマンドツリーとして構築されているため、どの階層でも `--help` を指定できます。このページで紹介したのはオペレーターやコントリビューターが日常的に使う代表的なコマンドです。各サブコマンドの詳しいオプション体系を確認したい場合は、`bun run kit app-db --help` のように CLI のヘルプを直接表示してください。

## 次のステップ

- これらのコマンドを使ってローカル環境を立ち上げる手順については、[Quick start](../quickstart/) を参照してください。
- `kit dev` で起動される各コンポーネントの役割については、[architecture overview](../architecture/) を参照してください。
