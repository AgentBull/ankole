---
title: Agents
description: Console で Agent を作成し、ロール、永続的な動作、モデル、機能、環境変数を設定する。
section: User guide
order: 13
---

Agent は、時間をかけて働くデジタル同僚です。各 Agent は独自の identity、作業指示、モデル、機能、ファイルスペースを持ちます。signal routing ルールが Agent をchat channel からのメッセージに接続します。

## Agent を作成する

1. **Console → Agents** を開き、**New Agent** を選択します。
2. 必須の表示名を入力します。Console は英語または中国語のテキストから UID を生成します。たとえば `Research Analyst` から `research-analyst`、`研究分析师` から `yan-jiu-fen-xi-shi` です。混合言語の名前も機能します。
3. UID を確認または変更し、ロールとオプションのアバター URL を入力します。UID はこのデプロイメントインスタンス内で一意の安定した識別子であり、Agent を保存した後は変更できません。表示名は後から変更しても、既存の設定を壊しません。
4. Agent を保存します。ページにはその永続的な指示、モデルプロファイル、Agent 固有の環境変数が表示されます。

以前の Ankole バージョンの Agent は、表示名なしでも読み込みと実行が可能です。次に基本情報を保存する前に、表示名を追加する必要があります。

ロールは、「Research Analyst」や「Customer Support」など、作業の短い要約を提供します。以下の 3 つの永続的なドキュメントが、責任、動作、ビジュアルデザインを管理します。

## 永続的なドキュメントを設定する

Agent ページで **MISSION / SOUL / DESIGN** を開きます。

| ドキュメント | 書くべき内容 |
|---|---|
| `MISSION.md` | Agent がなぜ存在するか、どの作業を所有するか、完全な結果が何を意味するか |
| `SOUL.md` | どのようにコミュニケーションするか、どのように決定するか、不確実性にどう対処するか |
| `DESIGN.md` | ウェブページ、スライド、ドキュメント、チャート、その他のビジュアルアーティファクトのデザインシステム |

`DESIGN.md` は <a href="https://www.designmd.co/about" target="_blank" rel="noreferrer">DESIGN.md 形式</a>を使います。YAML frontmatter は色、タイポグラフィ、間隔、角、コンポーネントなどのデザイン token を保存します。Markdown の本文はビジュアルの原理とその適用方法を説明します。Ankole にはそのまま使えるデフォルトのデザインシステムが含まれています。**Console → Agents → DESIGN** で自社のブランドに置き換えられます。

ワークフロー、権限境界、動作ルールを `DESIGN.md` に入れないでください。それらは `MISSION.md`、`SOUL.md`、または特定の Skill に入れてください。少なく明確なドキュメントのセットから始め、実際の作業が必要であることを示したときだけルールを追加してください。

保存した変更は後の会話に適用されます。すでに実行中の作業は、開始時に読み取ったバージョンで続行します。

## モデルを設定する

同じページで、少なくとも `primary`、`light`、`heavy` のモデルプロファイルを設定します。これらは通常の会話、軽い作業、複雑な推論を担当します。

最初のセットアップでは、3 つすべてに、すでに検証済みの同じモデルを使えます。

オプションのプロファイルは、Agent が必要なときだけ設定します。

- Agent が画像を読む必要があるときは、`vision_fallback` を設定します。
- Agent が公開ウェブページを検索または読む必要があるときは、`web_search` と `web_fetch` を設定します。
- Agent が画像を作成する必要があるときは、`image_generate` を設定します。
- Job が別の provider かモデルを必要とするときは、**Background Agent Jobs** を設定します。ChatGPT サブスクリプションは、[ChatGPT サブスクリプション provider](../chatgpt-subscription-provider/)を通じて同じ provider 選択を使います。

モデルを選択または入力する前に Provider を選択します。context length フィールドも Provider の選択後に使用できます。空のままにすると、Provider とモデルのデフォルト値を使います。

高度な設定には、選択した Provider が宣言したオプションだけが表示されます。**Reasoning summary** は Responses API だけに適用されます。**Answer detail** は応答の既定の詳しさを設定します。**Service tier** は、このモデルプロファイルの request tier を上書きします。使用できる値は Provider、アカウント、モデルによって異なります。空のままにすると Provider のデフォルト値を使います。

最初の LLM Provider とモデルのセットアップは、[Quick start](../quickstart/#3-add-an-llm-provider-and-create-an-agent)を参照してください。

## 機能と環境変数を設定する

Agent は、Agent Plugins と Skills のデプロイメントインスタンスのデフォルトを継承します。変更するには、**Console → Agent Library** を開き、デフォルトを編集するか、この Agent の上書きを設定します。

完全な手順は[Agent Library](../skills/)を参照してください。

Skill、コマンドラインツール、または MCP サービスが API key を必要とする場合は、Agent ページの **Environment variables** に追加します。Agent 固有の値はこの Agent だけが使えます。

これは同じ名前のグローバル値を上書きします。[環境変数](../worker-env/)を参照してください。

## chat channel を接続する

新しい Agent は、Slack、Microsoft Teams、Lark、Feishu、DingTalk からメッセージを受け取る前に、signal routing ルールが必要です。

**Console → Signal routing** を開き、チャットアプリケーションとターゲット Agent を選択します。1 つのチャットアプリケーションに複数のルールを作成でき、異なる Agent 用に別々の bot アプリケーションを作成できます。

[Signal routing ルール](../signal-bindings/)を参照してください。

## Agent を変更または無効化する

表示名、ロール、永続的な指示、モデル、機能はいつでも変更できます。他の設定が UID を使って Agent を識別するため、UID は変更できません。

無効化された Agent は新しい作業を受け付けません。1 つのチャットの入口だけを止めたい場合は、Agent 全体を無効化するのではなく、関連する signal routing ルールを無効化してください。

## Agent が応答しない場合

次の項目を順に確認してください。

1. Agent が有効になっている。
2. `primary`、`light`、`heavy` のプロファイルが設定され、LLM Provider が利用可能である。
3. この Agent を指す signal routing ルールがある。
4. 少なくとも 1 つの worker が準備完了である。
5. **Console → Conversations** にメッセージが含まれ、役立つエラーが表示されている。

channel 固有の確認は、[Quick start のトラブルシューティング](../quickstart/#if-the-agent-does-not-reply)を参照してください。
