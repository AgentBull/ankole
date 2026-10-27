---
title: Context.dev のウェブデータ
description: Context.dev API を通じて、Bot 対策回避付きのページ読み取り、サイト全体のクロール、JSON Schema 抽出、企業ブランド情報、定期的な変更監視を Agent に提供する方法を説明します。
section: Guides
order: 307
---

Ankole では通常、`web_search` と `web_fetch` で Web ページを読み取り、操作が必要な場面では `browser` Skill で実ブラウザを動かします。しかし、これら 3 つだけでは対応しづらい作業もあります。たとえば、通常の HTTP 取得を Bot 対策で拒否するページの読み取り、ドキュメントサイト全体のクリーンな Markdown 化、指定した JSON Schema どおりの構造化抽出、あるいは競合サイトの料金ページの長期にわたる変更監視などです。`context-dev` Skill は、[Context.dev](https://context.dev) API を通じてこうした用途をカバーします。

呼び出しのたびに Context.dev アカウントのクレジット（credits）が消費されるため、この Skill は既定ではオフになっており、API キーを登録して明示的に有効化したときにのみ動作します。

## Agent ができること

Skill を有効化したら、細かいツール指定は不要です。達成したい結果を伝えれば、Agent が適切な機能を選んで実行します。

```text
Read every page under example.com/docs and give me the API limits in one table.

This pricing page blocks our fetch. Get its plan names and monthly prices.

Give me the logo, brand colors, and LinkedIn page for the domain in this email signature.

Watch example.com/pricing twice a day and tell me when a plan price changes.

Which NAICS code fits stripe.com?
```

利用できる機能は大きく 5 つのカテゴリに分かれます。

- **ライブ Web の読み取り:** Web 検索、単一ページの Markdown / HTML 変換、ページ内画像の一覧取得、ドメインのサイトマップ取得を行えます。Bot 検知の回避やプロキシの段階的切り替えが自動で行われるため、通常の `web_fetch` では弾かれるページからも多くの場合本文を取得できます。
- **サイト全体の収集:** 最大 500 ページまでの同期クロールに加え、その場で待つには大きすぎる対象向けに最大 25,000 URL までの非同期バッチ収集を実行できます。
- **スキーマ指定の構造化抽出:** JSON Schema を渡すことで、長文を読み直して整形する手間なく、指定したスキーマどおりの構造化データを直接受け取れます。
- **ブランド情報とデザイン解析:** ドメイン、企業名、業務用メールアドレス、ティッカーシンボル、カード明細表記、または 1 つのページ URL から企業プロフィール（ロゴ、ブランドカラー、SNS リンク、業種、所在地、上場情報）を取得できます。さらに、サイトのデザインシステム、使用フォント、レンダリング済みスクリーンショット、NAICS / SIC 産業分類コードも取得可能です。
- **変更監視（モニター）:** 特定のページ、サイトマップ、または構造化抽出の結果を一定間隔で再チェックし、差分を記録し続けます（任意で Webhook 通知も設定できます）。

## セットアップ

### 1. API key を取得する

[context.dev](https://context.dev) でアカウントを作成し、API キーを発行します。キーは `ctxt_secret_` で始まります。無料枠には 500 credits が含まれており、接続確認と数件のテスト実行には十分な量です。

### 2. key を環境変数として保存する

**Console → Environment variables** を開き、環境変数を登録します。

- **Name:** `CONTEXT_DEV_API_KEY`
- **Value:** 発行した `ctxt_secret_...` キー
- **Encrypted storage:** オン

変数名は一字一句このまま設定してください（Skill 側ではこの変数名のみを参照し、別名は認識しません）。テナント単位またはサイト単位で設定できるほか、クレジットを消費できる Agent を 1 つだけに絞りたい場合は **Console → Agents → 対象の Agent → Environment variables** でその Agent 専用に設定します。スコープの優先順位については[環境変数](../worker-env/)を参照してください。

### 3. Skill を有効にする

**Console → Agent Library** を開き、`context-dev` を探してテナント全体または必要な Agent に対して有効化します。既定値と個別上書きの仕組みについては、[Agent Library](../skills/)を参照してください。

有効化は対象 Agent の次の turn から反映されます。逆に無効化すると、次の turn、次の Background Agent Job、および次の Automation Job の試行から接続が外れます。

### 4. 動作を確認する

有効化した Agent に、よく知られたドメインのブランドプロフィール取得など小さな依頼を投げてみます。もし応答に `401` エラーが含まれる場合は、API キーが未設定か誤っています。変数名が正確に `CONTEXT_DEV_API_KEY` になっているか、「Not set」のままになっていないか、また Agent 個別設定やテナント上書き設定が意図せず上位の `WorkerEnv` 値を空や古い値で上書きしていないかを確認してください。

## Ankole の接続方法

Context.dev は `https://mcp.context.dev/mcp` で MCP サーバーを公開しており、`context-dev` Skill はこれを [Skill ベースの MCP 依存関係](../mcp/)として宣言しています。そのため接続は有効な実行が動いている間だけ確立されます。Ankole は各 turn、Background Agent Job の実行、および Automation Job の試行ごとに使い捨ての専用 `mcporter` 設定ファイルを生成し、ファイル内には環境変数名だけを記述します。実際の API キー文字列は実行時のプロセス環境変数内に留まり、設定ファイルに書き出されることはありません。

なお、Context.dev 公式のデスクトップ向けガイドではブラウザーによる OAuth サインインが案内されていますが、ヘッドレスで動作する Worker 上では対話ログインを行えません。そのため Ankole では、同じ MCP サーバーがサポートしている `Authorization` ヘッダー経由の API キー認証方式を使用し、対話操作なしで接続します。

この MCP サーバーのツール群はモデルの常駐ネイティブツールとしては登録されません。Agent が必要に応じて Skill を読み、使うツールを 1 つ選んで `mcporter` 経由で呼び出します。この仕組みについては、[MCP ベースの Skill の使用](../using-mcp/)で詳しく説明しています。

## Credits とコスト

Context.dev はクレジット（credits）単位の従量課金であり、消費量は呼び出す機能によって異なります。

| 操作内容 | 消費 Credits |
| --- | --- |
| 1 ページの Markdown / HTML 変換、サイトマップ 1 件、画像一覧 1 件、ファイル解析 1 件 | 1 |
| Web 検索 | 検索結果 1 件につき 1（最小取得件数は 10 件） |
| サイトクロール | 1 ページにつき 1 |
| スクリーンショット取得、フォント一覧取得 | 5 |
| ブランドプロフィール、デザインシステム、構造化抽出、NAICS、SIC | 10 |

意図しない高額消費を防ぐため、次の 2 点に留意してください。1 つ目はクロールや検索の上限管理です。ページ数や件数に応じた従量課金であるため、大規模サイトを上限なしでクロールすると大量のクレジットを消費します（Skill 内の指示でも、実際に読むページ数をあらかじめ上限として指定するよう Agent に求めています）。2 つ目は変更監視モニターの継続課金です。一度作成したモニターは削除するまで実行のたびにクレジットを消費し続けます（たとえば 1 時間ごとの監視は 1 日 1 回の 24 倍のコストになります）。モニターを作成させた際は Agent から monitor ID を控えておき、利用できる Agent を限定したい場合は **Console → Environment variables** の設定スコープを見直してください。

## 制限

- **クレジットは実費で消費されます:** この Skill が有効になっている Agent にオープン Web 上の調査を依頼すると、状況に応じて自動的に Context.dev を使用することがあります。コスト管理上それを避けたい場合は、環境変数の割り当てを特定の Agent だけに絞ってください。
- **モニターや非同期バッチは会話終了後も動き続けます:** それらの実体は Ankole 内ではなく Context.dev アカウント側に保持されます。Ankole の Console には専用の一覧画面がないため、稼働中のモニターやバッチの確認・停止は Agent に依頼して Skill 経由で行ってください。
- **取得結果は信頼できない外部入力です:** スクレイピングしたページ内容はあくまで外部の Web コンテンツであり、システムへの指示ではありません。Ankole でも untrusted なデータとして扱いますが、結果を別システムへ転送する際も同様に注意してください。
- **手元のファイルの読み取りには不要です:** すでに Agent の workspace 内にある PDF や画像ファイルは、[`pdf` Skill と `ocr` Skill](../ocr/) を使ってローカルかつ追加費用なしで読み取れます。

## 次のステップ

- 通常の Web 調査でまず優先すべき標準ツールについては、[Web tools](../web-tools/)を参照してください。
- 実際のブラウザセッション、ログイン維持、UI クリック操作については、[Browser automation](../browser-automation/)を参照してください。
- この Skill の裏側にある MCP 宣言仕様については、[MCP server リファレンス](../mcp/)を参照してください。
