---
title: MCP server リファレンス
description: Skill バックの MCP 依存関係が、Main、Background、Automation の各実行にどのように入るかです。
section: Reference
order: 201
---

Ankole はドメイン統合のために Skill の背後で MCP を使います。Agent レベルの MCP レジストリや永続的な mcporter 設定は保持しません。

Skill の MCP 依存関係は、ネイティブのモデルツールとして登録されません。Agent はその完全な MCP catalog を受け取りません。これにより Skill がルーティングの owner であり続け、2 つ目のツール選択面を避けます。

## 依存関係の宣言

MCP 依存関係は、Skill の `openai.yaml` の `dependencies.tools` の下に追加します。

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

1 つの Skill は最大 64 個の依存関係を宣言できます。schema は厳密で、未知のフィールドや transport に適合しないフィールドは拒否されます。

### `streamable_http`

| フィールド | 意味 |
| --- | --- |
| `url` | HTTP または HTTPS の server URL |
| `protocol_version` | 任意のプロトコルモード: `auto`、`legacy`、または `2026-07-28`。デフォルトは `auto` |
| `bearer_token_env_var` | bearer token を保持する環境変数の名前 |
| `enabled_tools` | 任意。正確な raw 名の allowlist |
| `disabled_tools` | 任意。正確な raw 名の denylist |

server が特定のプロトコル世代を必要とする場合にだけ `protocol_version` を固定してください。token は [環境変数](../worker-env/) に保存してください。Skill には変数名だけを置きます。

### `stdio`

| フィールド | 意味 |
| --- | --- |
| `command` | server を起動する信頼されたコマンドライン |
| `enabled_tools` | 任意。正確な raw 名の allowlist |
| `disabled_tools` | 任意。正確な raw 名の denylist |

Agent Computer は `/bin/sh -lc` でコマンドを実行します。stdio は信頼された第一方の server コマンドにだけ使ってください。

宣言は呼び出しのタイムアウトを設定しません。Skill または Automation スクリプトが、各 mcporter list または call コマンドに `--timeout` を渡します。

## 有効な集合と競合

実行が受け取るのは、現在有効な Skill からの MCP 依存関係の和集合です。2 つの Skill が同じ server 名を使えるのは、接続、説明、フィルタのフィールドが一致する場合だけです。競合があると実行のセットアップが止まります。

`ankole-runtime` は、どのモデルが Skill を読めるかを制御します。Main Agent は `any` と `main` の Skill を使います。Background Agent Job は `any` と `background_job` の Skill を使います。Automation Job はモデルを実行しないため、現在有効なすべての Skill から `ankole-runtime` フィルタなしで依存関係を受け取ります。

Skill を無効にすると、その依存関係は次の turn、Background 実行、または Automation の試行から取り除かれます。

## 生成される mcporter 設定

Agent Computer は実行ごとに一意の `0600` 設定を書き、そのパスを `MCPORTER_CONFIG` として注入します。ファイルには常に `imports: []` が含まれるため、mcporter は Agent Home、プロジェクト、Codex、エディタ、ホストの設定をマージしません。ファイルは実行の終了時に削除されます。

ファイルには接続の事実と credential の変数名だけが含まれます。WorkerEnv の secret 値が含まれることはありません。

Main Agent は command tool を通じて mcporter を呼びます。Background Agent Job は Codex terminal を通じて呼びます。Automation Job は `main.ts` から `Bun.spawn` で呼びます。

## ネイティブのモデル可視 MCP 境界

現在のところ、Ankole にはバンドルされたモデル可視 MCP server は同梱されていません。将来の具体的な統合は、Main と Background の両方で同じ `mcp__<server>` namespace、ツール名、説明、遅延ロード（deferred loading）の動作を使わなければなりません。Ankole は server の JSON Schema をそのまま各 runtime に渡します。Main は自身の Responses tool owner を使い、Background は Codex ネイティブの MCP を使い、その projection を Codex に所有させます。Ankole は一方の runtime の schema を書き換えて他方を模倣することはせず、この将来のケースのために空のレジストリや汎用のローカル MCP loader を追加しません。

## 1 つのツールを選択して呼ぶ

Skill は、schema の探索より先に 1 つのドメインツールを選択しなければなりません。そのツールの現在の schema が必要なときにだけ、そのツールを検査します。

```bash
mcporter list 'my-http-server.lookup' --schema --json --timeout 360000
```

引数のオブジェクトは stdin 経由で渡します。JSON をシェルのテキストに挿入しないでください。

```bash
mcporter call 'my-http-server.lookup' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

Automation スクリプトは同じ argv を使い、JSON を子プロセスの stdin に書き、exit code を確認し、stdout を解析します。

## セキュリティの制限

MCP の出力は信頼できない入力です。Skill と mcporter の経路は、Ankole のかつてのネイティブ出力 schema 検証、MCP annotation のスケジューリング、ツールレベルの承認 UI、すべての WorkerEnv secret に対する結果の編集を提供しません。信頼された第一方の MCP Skill に使ってください。実際の読み書きの権限境界は、リモート credential の scope であり続けます。

## 次のステップ

- Skill の指示の作り方は [Writing a Skill](../writing-a-skill/) を読んでください。
- bearer token の設定は [環境変数](../worker-env/) を読んでください。
- 有効な能力の使い方は [Using MCP](../using-mcp/) を読んでください。
