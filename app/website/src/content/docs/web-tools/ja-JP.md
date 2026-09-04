---
title: Web ツール
description: Agent の web 検索とページ読み取りを設定し、代わりにブラウザを使うべき場面を見極めます。
section: User guide
order: 33
---

Agent は `web_search` を使って公開ページを探し、`web_fetch` を使って選んだページを読み取ります。`web_search` には設定済みの Provider が必要ですが、`web_fetch` は Provider が設定されていない場合でも Worker 組み込みのレンダリングフォールバックを利用できます。

## 正しいツールを選ぶ

| 能力 | 使う場面 | 実行面 |
|---|---|---|
| `web_search` | キーワード、時間、ソース範囲から公開ページを探す | Main Agent と Background Agent Job |
| `web_fetch` | 既知の公開 URL を 1 つ以上テキストとして読む | Main Agent と Background Agent Job |
| [ブラウザ自動化](../browser-automation/) | ログイン、クリック、入力、ページ移動、スクリーンショット、対話型ページの読み取り | **Background Agent Job のみ** |

ブラウザ自動化は `browser` Skill が提供し、`ankole-runtime: background_job` を宣言します。これは `web_search` や `web_fetch` の Provider 一覧には表示されず、通常の main-Agent turn で直接実行することもできません。

タスクにブラウザが必要なときは、main Agent に Background Agent Job を作成してもらうか、既存のものを利用してもらってください。Job は現在の会話をブロックせず、必要なときに質問、状態、または結果を送り返します。

## Web ツールの設定

### Provider の追加

1. **Console → LLM Providers** を開きます。
2. `web_search`、`web_fetch`、またはその両方をサポートする Provider 種別を選択します。
3. API key と、要求される Provider のフィールドを入力します。
4. 保存し、Provider が有効になっていることを確認します。

1 つの Provider 種別に対して複数のインスタンスを作成できます。たとえば 2 つの Bright Data SERP インスタンスで、異なるリージョンを使ったり、異なる Agent に提供したりできます。

### Provider の Agent への割り当て

1. **Console → Agents** を開き、Agent を選択します。
2. **Model profiles** で `web_search` を見つけ、検索をサポートする Provider を選択します。
3. `web_fetch` を見つけ、ページ読み取りをサポートする Provider を選択します。
4. 両方の profile を保存し、新しい会話を開始します。

これらは Provider 専用の profile です。モデルや context 長は不要です。各 Provider 種別が自身の能力を宣言するため、一覧には一致するインスタンスだけが表示されます。

一覧が空の場合は、まず一致する Provider を追加してください。最初の Provider の設定は [クイックスタート](../quickstart/#llm-providers) を参照してください。

## 現在の組み込み Provider

Control Plane Plugin がさらに Provider 種別を追加できます。現在 Ankole に組み込まれている種別は次のとおりです。

### `web_search` Provider

| Provider | `web_fetch` もサポート | 主な違い | 使う場面 |
|---|---|---|---|
| **Parallel** | はい | 1 つの Provider が検索と抽出を提供。objective、複数クエリ、モード、合計文字予算をサポート | 検索と読み取りに 1 つの credential を使いたい、または調査向きのクエリがある |
| **Bright Data SERP** | いいえ | SERP API を使用。Zone が必要で、国、言語、Google ドメインを選択可能 | 検索リージョン、言語、ローカライズ結果を制御する必要がある |
| **Jina Search** | いいえ | リージョン、ロケーション、言語、ページ、キャッシュ、検索エンジンのオプションをサポート | リージョン、ページング、またはキャッシュ制御付きの直接 web 検索が必要 |
| **AgentBull Cloud** | いいえ | 検索ソースを集約し、ソース範囲、時間範囲、キャッシュ迂回をサポート | メタ検索、または明示的なソースと時間の範囲が必要 |

Parallel の Provider インスタンスは 1 つで、`web_search` と `web_fetch` の両方に割り当てられます。

Jina Search と Jina Reader は別々の Provider 種別です。同じ Jina の credential を使う場合でも、別々に追加して、それぞれ対応する profile に割り当ててください。

### `web_fetch` Provider

| Provider | `web_search` もサポート | 主な違い | 使う場面 |
|---|---|---|---|
| **Parallel** | はい | Parallel Search と同じ Provider と credential を使ってページテキストを抽出 | すでに Parallel Search を使っており、設定を 1 つにまとめたい |
| **Jina Reader** | いいえ | 公開ページを Markdown に変換。リンク保持、対象・待機セレクタ、キャッシュ、エンジン、token 上限をサポート | 記事本文、またはページの選択部分が必要 |

`web_fetch` は公開 HTTPS ページ向けです。ログインはせず、PDF、画像、アーカイブ、音声、動画のダウンローダーでもありません。

Worker 組み込みのレンダリングフォールバックは Provider ではないため、Console の Provider 一覧には表示されません。レンダリングされたページテキストを読むだけです。

フォールバックはクリック、タイピング、ログイン状態の再利用、スクリーンショットができません。main Agent にブラウザ自動化を提供することもありません。

セレクタと待機オプションは、Provider が遅延して現れるページテキストを読む一助になりますが、実際のインタラクションを提供するものではありません。ログイン、クリック、フォーム入力が必要なタスクでは、Background Agent Job 内のブラウザ自動化を使ってください。

## Agent に Web ツールを使わせる

特別なコマンドは不要です。得たい結果を説明してください。たとえば:

> 今週の関連アナウンスを 3 件見つけてください。元のページを読んで変更点を比較し、ソースのリンクを含めてください。

Agent はまず検索し、次に読むべきページを選択します。すでに URL を知っている場合は、それを Agent に渡して、ページを読んで要約するよう依頼してください。

次の場合は明示的にブラウザを依頼します。

- ページにログインが必要なとき
- コンテンツを見る前に Agent がクリック、入力、またはページ移動をする必要があるとき
- タスクにスクリーンショット、またはレンダリングされたページの確認が必要なとき
- 複雑な操作の後にだけコンテンツが現れるとき

ブラウザの作業は Background Agent Job 内で実行されます。通常の検索、公開ページの読み取り、複数ソースの比較には、`web_search` と `web_fetch` を直接使ってください。

## Web タスクがうまく動かないとき

### 検索または読み取りの失敗

次の項目を順に確認してください。

1. 現在の Agent がタスクに必要な profile を持っていること。`web_search` には Provider が必要です。
2. `web_fetch` に Provider がない場合、Worker が組み込みのレンダリングフォールバックを提供すること。
3. 選択した Provider 種別が要求する能力を宣言していること。
4. Provider が有効で、credential と必須フィールドが正しいこと。
5. profile を変更した後に新しい会話を開始したこと。
6. 対象がログイン不要の公開 HTTPS ページであること。

### ブラウザ自動化が実行されなかった

Agent の `browser` Skill が有効で、Background Agent Job を作成できることを確認してください。ブラウザ自動化を `web_search` や `web_fetch` の profile に割り当てようとしないでください。

すでに Background Agent Job にあるタスクなら、Worker の空き状況と、Job が報告するブラウザセッションやアクセスの問題を確認してください。
