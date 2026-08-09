---
title: kit CLI リファレンス
description: devkit のコマンドサーフェス — オペレーターやコントリビューターが実行するすべての `bun run kit` コマンドと、それをラップするスクリプト。
section: Reference
order: 200
---

`kit` は Ankole の devkit コマンドラインです。リポジトリルートから `bun run kit <command>` として呼び出され、環境セットアップ、ローカルサービス、開発環境、データベースライフサイクル、有効化コード、ログ、コード生成、リポジトリ分析をカバーします。このページはすべてのコマンドのリファレンスです。

決定的な性質を先に述べます: `kit` は `tools/devkit/` にある Bun + TypeScript プログラムであり、リポジトリの `package.json` スクリプトが一般的なコマンド（`services:start`、`services:stop`、`dev`、`analyze` など）をラップしているため、完全な `bun run kit` 形式を入力する必要はありません。どちらの形式でも動作します。スクリプトはエイリアスです。

## 環境と検出

| コマンド | 内容 |
|---|---|
| `kit env-setup` | Ankole 開発に必要なホストツールチェーンをインストールします — システムビルドパッケージ、Docker、Rust、Elixir/Erlang ツールチェーン、固定された Bun。`--print` を追加すると、インストーラーコマンドを実行せずに印刷します。 |
| `kit is-ci` | CI 環境なら終了コード `0`、そうでなければ `1` を返します。CI で分岐するスクリプトが使います。 |
| `kit is-dev` | 開発環境なら終了コード `0`、そうでなければ `1` を返します。 |

新しマシンでは `env-setup` を一度実行してください。残りは、他のコマンドが内部で呼ぶ検出ヘルパーです。

## ローカルサービスと開発環境

| コマンド | 内容 |
|---|---|
| `kit external-services start` | devkit Docker Compose サービス（PostgreSQL など）を起動します。`bun run services:start` としてラップされています。 |
| `kit external-services stop` | devkit Compose サービスを停止します。`bun run services:stop` としてラップされています。 |
| `kit external-services status` | devkit サービスの健全性を報告します。`bun run services:status` としてラップされています。 |
| `kit dev` | 完全な開発環境を起動します — Phoenix、フロントエンドアセット、管理された Docker worker 1 台。`bun run dev` としてラップされています。このターミナルを開いたままにしてください。 |

`kit dev` はスタック全体を実行する唯一のコマンドです。PostgreSQL を起動または検証し、ローカルデータベースを作成して移行し、欠落または古い worker イメージをビルドし、管理された worker を起動します。2 つ目の `kit dev` を起動しないでください。そのターミナルで `Ctrl+C` して停止します。

## データベースライフサイクル

`kit app-db` はローカルのコントロールプレーンデータベースを所有します:

| コマンド | 内容 |
|---|---|
| `kit app-db create` | まだ存在しなければアプリデータベースを作成します。 |
| `kit app-db drop` | アプリデータベースを削除します。破壊的操作の確認に `--yes` が必要です。 |
| `kit app-db rebuild` | アプリデータベースを削除・作成・移行します。`--yes` が必要です。再作成後に Ecto マイグレーションを実行します。 |
| `kit app-db migrate` | 設定されたローカルデータベースに対してコントロールプレーンの Ecto マイグレーションを実行します。 |

これらの間に適用されるオプション: `--start-services` は操作前に Compose を起動し、`--pull-images` は最新のサービスイメージを先に引き、ヘルスチェック待機がサービスの準備完了までの待ち時間を制御します。特に `app-db rebuild` はローカルの `ankole_dev` データベースを削除します。データが本当に破棄可能なときだけ実行してください。

## セットアップと検査

| コマンド | 内容 |
|---|---|
| `kit show bootstrap-activation-code` | 現在のセットアップ有効化コードを印刷します。初回訪問ページがコードを必要とし、`kit dev` ターミナルが見えないときに使います。 |
| `kit logs pretty` | stdin からの Ankole 構造化 JSON ログ行を整形して印刷します。読みやすいローカル出力のためにログストリームをパイプします。 |

## コード生成と分析

| コマンド | 内容 |
|---|---|
| `kit generate [collection-name:]<schematic-name> [options]` | schematic からファイルを生成または変更します。`bun run kit g code-workspace`（`bun run workspace:update` としてラップ）は VS Code ワークスペースを再生成します。 |
| `kit analyze all` | すべてのリポジトリ分析を実行します。`bun run analyze` としてラップされています。 |
| `kit analyze smells` | コードの臭いを報告します。`bun run analyze:smells` としてラップされています。 |
| `kit analyze unused` | 未使用コードを報告します。`bun run analyze:unused` としてラップされています。 |
| `kit analyze structure` | リポジトリ構造を報告します。`bun run analyze:structure` としてラップされています。 |
| `kit analyze cycles` | 依存関係の循環を報告します。`bun run analyze:cycles` としてラップされています。 |

## Worker テストランナー

`kit agent-computer-test` は Agent Computer Worker パッケージのテストを標準の worker コンテナランタイムで実行します。実際のターンと同じ環境でテストが実行されます。`--suite` に `unit` または `integration` を取り、`--prebuilt-image` で特定の Agent Computer Worker Docker イメージに対して実行できます（ビルドの代わり）。

## さらに調べる

```bash
bun run kit --help
```

`kit` は `@crustjs` コマンドツリーなので、すべてのレベルに `--help` があります。上記のコマンドはオペレーターやコントリビューターが実際に実行するものです。任意のコマンドの完全なサブコマンドサーフェス（例: `kit app-db --help`）については、CLI に直接尋ねてください。

## 次のステップ

- これらのコマンドを使うローカル環境のウォークスルーについては、[Quick start](../quickstart/) を読んでください。
- `kit dev` が起動するものについては、[architecture overview](../architecture/) を読んでください。
