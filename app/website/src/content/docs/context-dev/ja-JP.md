---
title: Context.dev のウェブデータ
description: Context.dev API を通じて、Agent に bot 対策済みのページ読み取り、サイト全体のクロール、スキーマ形状の抽出、ブランドプロフィール、スケジュールされた変更監視を提供する。
section: Guides
order: 307
---

Ankole は `web_search` と `web_fetch` でウェブを読み、`browser` Skill で実際のブラウザを操作します。それでも 3 つではカバーできない作業があります。通常の fetch を拒否するページ、ドキュメントサイト全体をクリーンな Markdown にしなければならない作業、定義した JSON 形状で応答しなければならないサイト、数ヶ月間監視が必要な競合ページです。`context-dev` Skill は [Context.dev](https://context.dev) API を通じてこれらの作業をカバーします。

この Skill はデフォルトではオフで、API key を追加して有効にするまでオフのままです。呼び出しのたびに Context.dev アカウントの credits を消費するため、セットアップは意図的な操作になっています。

## Agent ができること

Skill を有効にしたら、結果を依頼して Agent にツールを選ばせます。

```text
Read every page under example.com/docs and give me the API limits in one table.

This pricing page blocks our fetch. Get its plan names and monthly prices.

Give me the logo, brand colors, and LinkedIn page for the domain in this email signature.

Watch example.com/pricing twice a day and tell me when a plan price changes.

Which NAICS code fits stripe.com?
```

能力面は 5 つのグループに分かれます。

- **ライブウェブの読み取り。** 検索、1 ページの Markdown または HTML 変換、ページ内の画像一覧、ドメインの sitemap。Bot 検出の回避とプロキシのエスカレーションは自動で行われるため、通常の fetch を拒否するページもたいてい応答します。
- **サイト全体の収集。** 最大 500 ページの同期クロール、または待つのには大きすぎる作業向けに、最大 25,000 URL の非同期バッチ。
- **スキーマ形状の抽出。** JSON Schema を渡すと、読み直さなければならない散文ではなく、その形状のデータが Agent に返ります。
- **ブランドとデザイン。** ドメイン、会社名、業務用メール、ticker、カード記述子、または 1 つのページ URL から取得する会社プロフィール（logo、色、social、業界、住所、上場情報）。サイトのデザインシステム、フォント、レンダリングされたスクリーンショット、NAICS または SIC コードも取得できます。
- **変更監視。** ページ、sitemap、または抽出を一定間隔で再チェックし、変更内容を記録するモニター。オプションで webhook も利用できます。

## セットアップ

### 1. API key を取得する

[context.dev](https://context.dev) でサインアップし、API key を作成します。key は `ctxt_secret_` で始まります。無料ティアには 500 credits が含まれており、セットアップの確認と数件のタスクの試行に十分です。

### 2. key を環境変数として保存する

**Console → Environment variables** を開き、変数を作成します。

- **Name:** `CONTEXT_DEV_API_KEY`
- **Value:** あなたの `ctxt_secret_...` key
- **Encrypted storage:** on

名前は完全に一致させる必要があります。Skill が宣言するのはこの名前だけで、他は受け付けないためです。すべての Agent に設定するか、credits を消費させる Agent を 1 つに限定したい場合は、**Console → Agents → 対象の Agent → Environment variables** でその Agent だけに設定します。スコープのルールは[環境変数](../worker-env/)を参照してください。

### 3. Skill を有効にする

**Console → Agent Library** を開き、`context-dev` を見つけて有効にします。インスタンス全体か、必要な Agent に対してです。デフォルトと上書きのモデルは[Agent Library](../skills/)を参照してください。

Skill は Agent の次の turn から有効になります。無効にすると、次の turn、次の Background Agent Job、次の Automation Job attempt から接続が取り除かれます。

### 4. 動作を確認する

有効にした Agent に、既知のドメインのブランドプロフィールなど、小さなことを依頼します。返信に `401` が含まれる場合は、key が欠落しているか間違っています。変数名が正確に `CONTEXT_DEV_API_KEY` であること、"Not set" と表示されていないこと、Agent レベルの値がグローバル値を上書きしていないことを確認してください。

## Ankole の接続方法

Context.dev は `https://mcp.context.dev/mcp` で MCP server を公開しています。`context-dev` Skill はこれを [Skill-backed MCP 依存](../mcp/)として宣言するため、接続は有効な実行が動作している間だけ存在します。Ankole は各 turn、Background Agent Job 実行、Automation attempt ごとに、プライベートで単回使用の mcporter 設定を書き込み、そのファイルには変数名だけを置きます。key の値は実行環境に残り、設定には決して入りません。

Context 公式のデスクトップ向け手順はブラウザの OAuth サインインを使いますが、ヘッドレス Worker では完了できません。Ankole は同じ server が `Authorization` ヘッダーでサポートする API key パスを使うため、対話式サインインは不要です。

この server はネイティブな model tool として登録されません。Agent は Skill を読み、1 つのツールを選び、mcporter を通じて呼び出します。このパスは[MCP ベースの Skill の使用](../using-mcp/)で説明しています。

## Credits とコスト

Context.dev は credits 単位で請求し、価格はツールによって異なります。

| 作業 | Credits |
| --- | --- |
| 1 ページを Markdown または HTML に変換、sitemap 1 件、画像一覧 1 件、解析されたファイル 1 件 | 1 |
| ウェブ検索 | 結果 1 件につき 1。最小の結果セットは 10 件 |
| クロール | ページ 1 件につき 1 |
| スクリーンショット、フォント一覧 | 5 |
| ブランドプロフィール、デザインシステム、構造化抽出、NAICS、SIC | 10 |

2 つの習慣が請求額を抑えます。1 つ目は、クロールと検索は単位ごとに請求されるため、大規模サイトの上限なしクロールは高くつく失敗です。Skill は Agent に、実際に読むページ数を予算として設定するよう指示します。2 つ目は、モニターは存在する限り毎回の実行で credits を消費することです。1 時間ごとのモニターは 1 日ごとの 24 倍のコストで、誰かが削除するまで止まりません。モニターを作成したら Agent に monitor ID を尋ね、1 つの Agent だけに消費させたい場合は **Console → Environment variables** のスコープを見直してください。

## 制限

- **credits は実費です。** 有効な Agent にオープンウェブ上の調査を依頼すると、この Skill に到達する可能性があります。それが問題になる場合は、環境変数を特定の Agent に限定してください。
- **モニターとバッチは会話より長生きします。** これらは Ankole ではなく、あなたの Context.dev アカウントに存在します。Ankole にはそれらを一覧表示するページがありません。Agent が Skill を通じて一覧表示します。
- **結果は信頼できない入力です。** スクレイプしたページはウェブコンテンツであり、指示ではありません。Ankole はそのように扱います。転送するときも同様に扱ってください。
- **workspace のファイルにはこの Skill は不要です。** すでに Agent の workspace にある PDF や画像は、[`pdf` と `ocr` Skill](../ocr/)でローカルに、無料で読み取れます。

## 次のステップ

- 引き続き第一選択となる通常の検索と fetch：[Web tools](../web-tools/)。
- レンダリングされたセッション、ログイン、クリック：[Browser automation](../browser-automation/)。
- この Skill の背後にある宣言コントラクト：[MCP server リファレンス](../mcp/)。