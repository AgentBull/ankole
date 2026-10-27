---
title: MCP server リファレンス
description: Skill に紐付いた MCP 依存関係が、Main、Background、Automation の各実行環境にどのように注入されるかを説明します。
section: Reference
order: 201
---

Ankole はドメイン連携のために Skill の裏側で MCP を利用します。Agent 単位の MCP レジストリや永続的な mcporter 設定ファイルは保持しません。

Skill の MCP 依存関係はネイティブのモデルツールとしては登録されず、MCP カタログ全体が Agent に渡されることもありません。これにより、ルーティングの責務を Skill に一元化し、ツール選択の経路が二重化するのを防いでいます。

## 依存関係の宣言

MCP 依存関係は、各 Skill の `openai.yaml` 内にある `dependencies.tools` の下に追加します。

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-http-server
      description: "Lookup service"
      transport: streamable_http
      url: https://mcp.example.com/mcp
      protocol_version: 2026-07-28
      bearer_token_env_var: MCP_HTTP_TOKEN
      enabled_tools:
        - lookup

    - type: mcp
      value: my-stdio-server
      transport: stdio
      command: bunx --bun @example/mcp-server
      disabled_tools:
        - delete_record
```

1 つの Skill につき最大 64 個の依存関係を宣言できます。スキーマ検証は厳格に行われ、未知のフィールドや指定した `transport` に適合しないフィールドが含まれている場合は拒否されます。

### `streamable_http`

| フィールド | 意味 |
| --- | --- |
| `url` | HTTP または HTTPS のサーバー URL |
| `protocol_version` | 任意のプロトコルモード（`auto`、`legacy`、または `2026-07-28`）。デフォルトは `auto` |
| `bearer_token_env_var` | Bearer トークンを格納する環境変数名 |
| `enabled_tools` | 任意。正確な生ツール名による許可リスト（allowlist） |
| `disabled_tools` | 任意。正確な生ツール名による拒否リスト（denylist） |

`protocol_version` は、接続先サーバーが特定のプロトコル世代を必須とする場合にのみ固定してください。トークンの実体は [環境変数](../worker-env/) に保存し、Skill 側には環境変数名だけを記述します。

### `stdio`

| フィールド | 意味 |
| --- | --- |
| `command` | サーバーを起動するための信頼されたコマンドライン |
| `enabled_tools` | 任意。正確な生ツール名による許可リスト（allowlist） |
| `disabled_tools` | 任意。正確な生ツール名による拒否リスト（denylist） |

Agent Computer は指定されたコマンドを `/bin/sh -lc` で起動します。`stdio` は、信頼できるファーストパーティ製のサーバーコマンドに限定して使用してください。

なお、依存関係の宣言自体には呼び出しタイムアウトの設定項目はありません。Skill の手順または Automation スクリプト側から、`mcporter list` や `mcporter call` の実行時に毎回 `--timeout` を渡してください。

## 有効な集合と競合

各実行環境には、現在有効になっている Skill の MCP 依存関係を統合したセット（和集合）が渡されます。複数の Skill で同じサーバー名を使用できるのは、接続先、説明、フィルタの各フィールドがすべて一致している場合のみです。定義が競合している場合は、実行環境のセットアップ段階で停止します。

どのモデル実行経路がその Skill を参照できるかは、`ankole-runtime` によって制御されます。Main Agent は `any` と `main` の Skill を使用し、Background Agent Job は `any` と `background_job` の Skill を使用します。一方、Automation Job はモデルを実行しないため、`ankole-runtime` によるフィルタリングを行わず、現在有効なすべての Skill から依存関係を受け取ります。

Skill を無効化すると、次の Turn、Background 実行、または Automation の試行からその依存関係が除外されます。

## 生成される mcporter 設定

Agent Computer は実行ごとにパーミッション `0600` の一意な設定ファイルを書き出し、そのパスを環境変数 `MCPORTER_CONFIG` として注入します。このファイルには必ず `imports: []` が含まれるため、mcporter が Agent Home、プロジェクト、Codex、エディタ、ホスト側の既存設定を勝手にマージすることはありません。設定ファイルは実行終了時に削除されます。

また、書き出される設定ファイルに含まれるのは接続先情報と認証情報の環境変数名だけであり、WorkerEnv のシークレット値そのものが書き込まれることはありません。

mcporter の呼び出し経路は実行形態によって異なります。Main Agent は `command` ツール経由で、Background Agent Job は Codex ターミナル経由で、Automation Job は `main.ts` から `Bun.spawn` を使って呼び出します。

## 1 つのツールを選択して呼ぶ

Skill では、スキーマを網羅的に探索する前に、まず呼び出すべき 1 つのドメインツールを絞り込む必要があります。スキーマの確認は、その対象ツールの最新定義が必要なときにだけ実行してください。

```bash
mcporter list 'my-http-server.lookup' --schema --json --timeout 360000
```

引数オブジェクトは標準入力（stdin）経由で渡します。シェルのコマンド文字列に JSON を直接埋め込まないでください。

```bash
mcporter call 'my-http-server.lookup' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

Automation スクリプトでも同じ引数配列（argv）を使用し、子プロセスの stdin に JSON を書き込み、終了コード（exit code）を確認したうえで stdout をパースします。

## セキュリティの制限

MCP サーバーからの出力は、信頼できない外部入力として扱う必要があります。Skill と mcporter を介した実行経路では、出力スキーマの検証、MCP アノテーションにもとづくスケジューリング、ツール単位の承認確認、および実行結果に含まれる WorkerEnv シークレット値のマスキングは行われません。そのため、信頼できるファーストパーティの MCP Skill に限定して運用してください。実際の読み書き権限の境界は、リモート認証情報に付与されたスコープによって決まります。

## 次のステップ

- Skill の指示文の書き方については、[Writing a Skill](../writing-a-skill/) を参照してください。
- Bearer トークンの登録方法については、[環境変数](../worker-env/) を参照してください。
- 有効化した MCP 機能の使い方については、[Using MCP](../using-mcp/) を参照してください。
