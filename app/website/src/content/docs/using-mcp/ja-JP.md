---
title: MCP-backed Skill を使う
description: 有効化された Skill が、mcporter を通じて Agent または Automation スクリプトを MCP server にルーティングする方法。
section: Developer guide
order: 123
---

Ankole は Skills の背後で MCP を使います。ドメインのルーティングと結果のルールは Skill が担います。固定された mcporter CLI は、Skill が選んだあの 1 つの tool について、プロトコル発見と呼び出しを担います。

Agent 固有のドメイン統合では、MCP server を Agent に直接登録しないでください。それを宣言する Skill を有効にしてください。その Skill を無効にすると、依存関係は次回の実行から消えます。

## Main Agent と Background Agent Job

MCP の tool 名ではなく、業務の結果を Agent に依頼してください。Agent は一致する Skill を読み、1 つの tool を選び、必要なときだけその tool の現在の schema を確認します。その後、JSON の引数オブジェクトを stdin に渡して mcporter を呼び出します。

Main Agent は command tool を使います。Background Agent Job は Codex terminal を使います。どちらの経路も、MCP catalog 全体を model のネイティブ tool として公開しません。

## Automation Job

Automation Job は Skill の指示を読みません。`main.ts` を書く Agent は、選んだ tool、引数、範囲（bounds）、結果のチェックをスクリプトに組み込む必要があります。

Automation の各 attempt は、`MCPORTER_CONFIG` を通じて、現在有効な Skill の依存関係と最新の Agent WorkerEnv を受け取ります。`Bun.spawn` で mcporter を呼び出し、JSON を stdin に書き、exit code を確認し、stdout をパースしてください。`~/.mcporter/mcporter.json` を作成しないでください。

## Credential

Skill は `MCP_HTTP_TOKEN` のような credential の変数名を保存します。その値は [Environment variables](../worker-env/) で設定します。生成される config には変数名が含まれ、値は含まれません。

変数がない場合、呼び出しは失敗します。token を chat、Skill、スクリプト、引数ファイル、shell コマンドに貼り付けないでください。

## 失敗と結果の範囲

無効な宣言や競合する server 定義は、model コマンドや Automation スクリプトが開始する前に失敗します。transport、protocol、argument、server のエラーは、mcporter を非ゼロの exit にさせます。

Command のログと Automation のログには上限があります。Skill のページネーション、鮮度、warning、部分結果（partial-result）のルールに従ってください。process が成功終了しても、業務の結果が完全であることを証明するわけではありません。

## 参考

- [MCP server reference](../mcp/) は、宣言と実行時の挙動を定義します。
- [Writing a Skill](../writing-a-skill/) は、作成の形を示します。
- [Environment variables](../worker-env/) は、credential の保存場所を定義します。
