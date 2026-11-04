---
title: MCP server リファレンス
description: Connector、リモート HTTP、ローカル MCP の依存関係と呼び出し方法。
section: Reference
order: 201
---

Skill が業務に合うツールを選び、MCPorter がスキーマの取得と呼び出しを行います。MCP 依存関係はモデルのネイティブツールとして登録しません。Worker は制御プレーンのゲートウェイを呼び出し、ゲートウェイが認証情報を解決して外部サービスに接続します。

## 依存関係の宣言

`agents/openai.yaml` に記述します。

```yaml
dependencies:
  tools:
    - type: mcp
      value: github
      transport: connector
      toolkit: github
      enabled_tools:
        - repos_get
    - type: mcp
      value: lookup
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: LOOKUP_TOKEN
      enabled_tools:
        - search
```

`connector` には `toolkit` が必要で、`connection` と `account` で接続とアプリケーションアカウントを指定できます。認証は Pod の接続ページで設定します。`streamable_http` には `url` が必要です。`bearer_token_env_var` は設定済み WorkerEnv の名前を参照しますが、値を読み取ってリモート認証に使うのは制御プレーンです。その値は Worker の環境スナップショットから除外します。`protocol_version` は `auto`、`legacy`、`2026-07-28` を選べます。

信頼できるローカルサーバーは `stdio` と `command` で宣言し、Worker の `/bin/sh -lc` で起動します。各方式で `enabled_tools` または `disabled_tools` を指定できます。1 Skill あたり最大 64 件で、同名サーバーの設定が矛盾すると準備に失敗します。

## 実行と呼び出し

メイン Agent は `any`・`main`、Background Agent Job は `any`・`background_job` の有効な Skill を使います。一時的な `MCPORTER_CONFIG` は `imports: []` を設定し、外部サーバーの代わりに内部ゲートウェイと更新可能な短期 Turn トークンを指定します。外部の秘密情報は制御プレーンに保持します。

Applet Action は Function Runtime の `AnkoleRuntime.mcp`、チーム用 Action は対応する `admin.mcp` を利用します。Agent の Skill 環境を継承しません。

```bash
mcporter list 'github.repos_get' --schema --json --timeout 360000
mcporter call 'github.repos_get' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

対象ツールの契約を読み、JSON は標準入力で渡し、処理に適したタイムアウトを指定してください。`github@work` のような別名で接続を選べます。結果のページングや警告を確認し、認可リンクなどの構造化エラーを保持してください。

[Using MCP](../using-mcp/)、[Skill の作成](../writing-a-skill/)、[Automation Jobs](../automation-jobs/)も参照してください。
