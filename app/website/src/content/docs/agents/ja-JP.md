---
title: Agents
description: Console で Agent を作成し、所有者、永続的な動作、モデル、機能、環境変数を設定する方法を説明します。
section: User guide
order: 13
---

Agent は、Ankole Agent Harness 内で継続して存在する作業主体です。各 Agent は、固有のミッション、所有者、アクセス権、ツール、モデルプロファイル、ファイル領域を持ちます。

Agent は、知識境界の範囲で Company Brain を使えます。Signal routing rule は、Agent をメッセージやその他のイベントに接続します。

## Agent を作成する

1. **Console → Agents** を開き、**New Agent** を選択します。
2. 必須の表示名を入力します。Console は英語または中国語のテキストから UID を生成します。たとえば `Research Analyst` から `research-analyst`、`研究分析师` から `yan-jiu-fen-xi-shi` です。混合言語の名前も機能します。
3. UID を確認または変更し、ロールとオプションのアバター URL を入力します。UID はこのデプロイメントインスタンス内で一意の安定した識別子であり、Agent を保存した後は変更できません。表示名は後から変更しても、既存の設定を壊しません。
4. Agent を所有する人間の Principal と、group memory の開示モードを選択します。
5. Agent を保存します。ページにはその永続的な指示、モデルプロファイル、Agent 固有の環境変数が表示されます。

ロールは、「Research Analyst」や「Customer Support」など、作業の短い要約を提供します。以下の 4 つの永続的なドキュメントが、責任、動作、ビジュアルデザイン、機密性を管理します。

## 所有者と group memory の開示を設定する

すべての Agent に所有者が必要です。所有者は、Agent が作成または保持する知識と、その Agent を audience とする知識を確認できます。所有者が Group のメンバーでない場合、所有権だけではその Group の知識を読み取れません。

group memory の開示モードは、複数の人が回答を見られるときに Agent が開示できる知識を制御します。

- **Strict** では、group conversation にいる全員が、memory item の audience scope を満たす必要があります。
- **Relaxed** では、質問者だけを確認します。他の参加者は結果を狭めません。

direct message では、両方のモードが同じように動作します。Group が広い開示規則を受け入れている場合を除き、**Strict** を使います。知識と開示の全体像は [Brain](../brain/) を参照してください。

## 永続的なドキュメントを設定する

Agent ページで **MISSION / SOUL / DESIGN / CONFIDENTIALITY POLICY** を開きます。

| ドキュメント | 書くべき内容 |
|---|---|
| `MISSION.md` | Agent がなぜ存在するか、どの作業を所有するか、完全な結果が何を意味するか |
| `SOUL.md` | どのようにコミュニケーションするか、どのように決定するか、不確実性にどう対処するか |
| `DESIGN.md` | ウェブページ、スライド、ドキュメント、チャート、その他のビジュアルアーティファクトのデザインシステム |
| `ConfidentialityPolicy.md` | Agent が Brain に知識を書き込むときに audience scope を選択する方法 |

`DESIGN.md` は <a href="https://www.designmd.co/about" target="_blank" rel="noreferrer">DESIGN.md 形式</a>を使います。YAML frontmatter は色、タイポグラフィ、間隔、角、コンポーネントなどのデザイン token を保存します。Markdown の本文はビジュアルの原理とその適用方法を説明します。Ankole にはそのまま使えるデフォルトのデザインシステムが含まれています。**Console → Agents → DESIGN** で自社のブランドに置き換えられます。

ワークフロー、権限境界、動作ルールを `DESIGN.md` に入れないでください。それらは `MISSION.md`、`SOUL.md`、`ConfidentialityPolicy.md`、または特定の Skill に入れてください。`ConfidentialityPolicy.md` は Agent 自身の Brain 書き込みを導きます。chat からの自動学習では、conversation の参加者から audience を決めます。少なく明確なドキュメントのセットから始め、実際の作業が必要であることを示したときだけルールを追加してください。

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

最初の LLM Provider とモデルのセットアップは、[Quick start](../quickstart/#llm-providers)を参照してください。

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

無効化された Agent は新しい作業を受け付けませんが、「無効」ステータスのまま agent 一覧に残ります。いつでも再有効化でき、完全に削除することもできます。削除は無効化済みの Agent に対してのみ実行でき、その Agent のセッション、ジョブ、関連レコードも一緒に削除されます。1 つのチャットの入口だけを止めたい場合は、Agent 全体を無効化するのではなく、関連する signal routing ルールを無効化してください。

## Agent が応答しない場合

次の項目を順に確認してください。

1. Agent が有効になっている。
2. `primary`、`light`、`heavy` のプロファイルが設定され、LLM Provider が利用可能である。
3. この Agent を指す signal routing ルールがある。
4. 少なくとも 1 つの worker が準備完了である。
5. **Console → Conversations** にメッセージが含まれ、役立つエラーが表示されている。

channel 固有の確認は、[Quick start のトラブルシューティング](../quickstart/#agent-not-replying)を参照してください。
