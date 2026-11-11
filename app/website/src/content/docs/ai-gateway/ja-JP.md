---
title: AIGateway API
description: OpenResponses 互換の AI 境界。HTTP、SSE、WebSocket の各エンドポイント、stateless / stateful 呼び出し、provider ルーティングについて説明します。
section: Developer guide
order: 101
---

AIGateway は、Ankole デプロイインスタンスにおける統一された AI 境界です。外部アプリケーション、社内システム、各種 SDK からは OpenResponses 互換 API として直接呼び出すことができ、内部の Agent もモデルターンを実行する際に同じインターフェースを利用します。どの呼び出しでも、モデルセレクターは運用者が構成した provider binding に従って解決されるため、上流プロバイダーの認証情報が control plane の外へ出ることはありません。

このページでは、実際の API ルート、リクエスト形式、stateless 呼び出しと stateful 呼び出しの境界を整理して案内します。正式な仕様（source of truth）は control plane のルーターおよび `Ankole.AIGateway` モジュールにあります。

## 位置づけ

AIGateway は呼び出し元と上流 provider の間に位置します。外部連携システム、OIDC Human、Worker 側の Agent モデルループは HTTP、SSE、または WebSocket 経由で bearer token を添えてリクエストを送り、`Ankole.Brain` や `Function Runtime` などの control plane 内部サブシステムは組み込みの `system` Principal（`ankole_brain` と `system`）としてプロセス内で直接 `Ankole.AIGateway` を呼び出します。どの呼び出しでも AIGateway がセレクターを解決してリクエストを組み立て、紐付けられた provider を呼び出して単一の JSON レスポンスまたはストリームを返します。LLM、embedding、rerank、Web 検索、Web 取得（fetch）はいずれもこの同じ境界を通ります。また、レスポンスターンで `programmatic_tool_calling` を使用する場合は、`Ankole.FunctionRuntime.ProgramRunner` を通じて `ankole-function-runtime` 上のステートレスな isolate 内で各 `programmatic_tool_call` の TypeScript プログラムを実行します。

ここで最も重要なのは、呼び出し元が上流 provider の認証情報に一切触れないという点です。認証情報とルーティングポリシーはすべて control plane が管理し、呼び出し元が扱うのは自身の認証主体とモデルセレクターだけです。

## 認証

`/api/v1/ai-gateway` 配下のすべての HTTP・WebSocket エンドポイントは、`:ai_gateway_api` パイプラインと `RequireAIGatewayAccessToken` plug を通過します。ネットワークリクエストの `Authorization` ヘッダーには bearer token が必須であり、次の 2 種類のトークンのみを受け付けます。

- **agent token** — 有効な Agent Principal を主体とする AIGateway API キーです。呼び出し対象はその Agent の有効なモデルプロファイルとセレクターに限定され、`subject_type = "agent"` として扱われます。
- **OIDC Human token** — `ai_gateway.write` スコープを持つ OIDC Client から有効な Human に対して発行されるトークンです。その Client に許可されたモデルエイリアスのみを使用でき、`subject_type = "oidc_human"` として扱われます。

一方、control plane 内部のファーストパーティサービス（Company Brain の処理を担う `ankole_brain`、および Pod Applet のステートレスな `ctx.ai` 呼び出しを担う `system`）は外部 bearer token を発行せず BEAM プロセス内で直接 `Ankole.AIGateway` を呼び出し、それぞれの `system` Principal UID に使用量を記録します。

OIDC Human token を取得するには、Console で `ai_gateway.write` スコープを持つ OIDC Client を作成し、許可するグループとモデルエイリアスを設定したうえで、Authorization Code + PKCE フローでログインします。長期間利用する場合は `offline_access` を要求し、ローテーション式の Refresh Token を使用してください。利用する人間は許可されたグループに所属している必要があり、指定できるのはその Client のモデルエイリアスのみです（`provider_id/model` 形式の直接指定はできません）。

トークンが指定されていない場合や検証に失敗した場合は、`code: "invalid_token"` を含む `401` が返されます。匿名アクセス用の経路はありません。

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"Summarize the open incidents."}'
```

## endpoint

すべてのルートは `/api/v1/ai-gateway` 配下に配置されています。各エンドポイントが使用する通信方式（Transport）は契約の一部として厳密に定まっています。

| メソッド | パス | Transport | 用途 |
|---|---|---|---|
| `GET` | `/models` | HTTP | 現在の認証主体から利用可能なモデルセレクターを一覧取得 |
| `POST` | `/responses` | HTTP または SSE | レスポンスを生成（`"stream": true` 指定時は SSE ストリーム） |
| `GET` | `/responses` | WebSocket | stateful なストリーミングレスポンスを実行 |
| `GET` | `/responses/:response_id` | HTTP | 保存済みの stateful レスポンス（`resp_{uuid}`）を取得 |
| `POST` | `/embeddings` | HTTP | embedding を生成 |
| `POST` | `/rerank` | HTTP | ドキュメントを再ランク付け（rerank） |
| `POST` | `/web_search` | HTTP | Web を検索 |
| `POST` | `/web_fetch` | HTTP | Web ページを取得 |
| `POST` | `/decisions` | HTTP | 状態に関する型付きの質問に確率付きで回答 |
| `POST` | `/images` | HTTP | 画像を 1 枚生成または編集 |
| `GET/POST/DELETE` | `/files`、`/files/:id`、`/files/:id/content` | HTTP | ファイルをアップロード・読み取り・削除 |

この API 群の中心となるのが `POST /responses` です。モデルターンを実行するエンドポイントであり、通信方式と状態の有無によって動作が分岐する唯一のルートでもあります。

## HTTP と SSE 上の stateless response

stateless な呼び出しは「1 リクエスト・1 レスポンス」で完結します。呼び出し元が入力全体を送信すると、AIGateway がセレクターを解決して provider を呼び出し、完了したレスポンスボディを返します。`"stream": true` を指定すると同じエンドポイントが Server-Sent Events（SSE）に切り替わり、`event: <type>\ndata: <json>\n\n` の形式で型付きイベントを順次送信したあと、最後に `data: [DONE]` を出力してストリームを閉じます。

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"Draft a release note.","stream":true}'
```

HTTP および SSE による stateless 呼び出しでは、stateful 用のフィールドである `previous_response_id`、`conversation`、`store` は一切使用できません。ターンをまたいで会話を継続したい場合は、必ず WebSocket 経路を使用してください。HTTP または SSE のリクエストにこれらのフィールドを含めると、`code: "stateful_responses_require_websocket"` と該当フィールド名を示すエラーメッセージとともに `400` が返されます。

## WebSocket 上の stateful response

stateful なレスポンスは、`GET /responses` を WebSocket にアップグレードして利用します。アップグレード時には認証主体の Identity、30 分のアイドルタイムアウト、フレーム圧縮、128 MiB のフレームサイズ上限が設定され、接続が `AIGatewayResponsesSocket` に引き渡されます。レスポンス待機中、クライアント側からフレームは送信されないため、このアイドルタイムアウトがそのまま 1 回のレスポンスに対する最大待機時間となり、上流モデルの初回バイト到達時間およびアイドル許容時間と揃えられています。この WebSocket 接続上では、`store: true` を指定してレスポンスを保存したり、`previous_response_id` や `conversation` を指定して既存の会話を引き継いだりできます。

永続的なライフサイクル管理はすべてこの経路で行われます。保存されたレスポンスには `resp_{uuid}` 形式の ID が付与され、後続のターンでは `previous_response_id` でその ID を参照します（保存済みの会話は `conversation` で参照します）。会話の継続ルール、永続履歴、compaction、レスポンスの投影、障害復旧はすべて control plane 側が担うため、呼び出し元で実装する必要はありません。

保存されたレスポンスは、後から通常の stateless な HTTP リクエストで取得できます。

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses/resp_4f3c... \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN"
```

長くなった保存済み履歴を、文脈の流れを保ったまま短い要約状態へ圧縮するには compaction を使用します。専用の別エンドポイントはなく、`input` に `{"type": "compaction_trigger"}` アイテムを含めてリクエストを送ると、AIGateway が `compaction` 出力アイテムを 1 つ返します。この操作はどの通信方式でも利用でき、`POST /responses` なら通常のレスポンスボディ、`"stream": true` 付きなら SSE イベント、WebSocket なら同様のストリームイベントとして返されます。トリガーだけを送った場合は、`previous_response_id` または `conversation` が指す保存済み会話が圧縮され、以降の継続に使う checkpoint ID が返されます。入力履歴を一緒に送った場合は、その送信内容自体が圧縮されます。

## Provider routing

AIGateway は上流へのリクエストを行う前に、**Console → Model Profiles** で構成される 3 層の疎な**モデルプロファイル（Model Profile）**継承チェーン（`Site -> Pod -> Agent/System`）に従ってモデルセレクターを解決します。

- **Site、Pod、および `system` Principal（`ankole_brain`、`system`）**は 10 個の固定スロットを持ちます。内訳は 5 つの言語モデルスロット（`primary`、`light`、`heavy`、`coding`、`vision_fallback`）と 5 つの機能スロット（`web_search`、`web_fetch`、`image_generate`、`rerank`、`decision`）です。
- **Agent** は `rerank` と `decision` を除く 8 つの標準スロットに加え、Agent ごとのカスタム言語モデルエイリアスを持ち、未指定のスロットは Pod と Site の既定値を継承します。
- **スロット間のフォールバック**は `coding -> heavy -> primary` および `light -> primary` の順で解決されるため、Site または Pod で `primary` を設定するだけで Agent と Brain が動作し、必要な箇所だけ Pod・Agent・`system` Principal 単位で上書きできます。

また、権限のある管理者や内部呼び出し元は `provider_id/model` 形式の明示的なセレクターも指定できます。現在の認証主体が解決可能なモデルの一覧は `GET /models` で確認でき、OpenRouter 形式のクエリパラメータ（`q`、`context`、`min_price`、`max_price`、`sort`、モダリティフィルタ）による絞り込みにも対応しています。

各 provider レコードは内部に credential pool を持っています。provider kind、base URL、ヘッダー、設定値、capability 宣言はプール内の全メンバーで共有されます。モデルプロファイルが参照するのはあくまで provider レコードであり、特定のプールメンバーを直接指定することはありません。AIGateway は設定された選択戦略（`fill_first`、`round_robin`、`least_used`、`random`）に従って正常なメンバーを選びます（Console 上では UI 言語に応じて翻訳表示されますが、API と永続化ではこれらの正規キーが使われます）。なお、stateful なスレッドでは可能な限り同じプールメンバーが継続して選択されます。

特定の認証情報に起因する `429`、`5xx`、または通信エラーが発生した場合は、そのリクエストに使用した認証情報だけがクールダウン対象となります。その際、AIGateway はプール内の別メンバーを選び直してリクエストを再構築し、指数バックオフとジッターを伴う回数制限付きリトライを実行します（Rust kernel 自体は 1 回につき 1 回の通信試行のみを行います）。プール内に利用可能なメンバーが残っていない場合でも、別の provider へ自動的にフェイルオーバーすることはありません。

`chatgpt_subscription` も通常の provider kind の 1 つとして扱われます。OAuth 認証情報は control plane 内に保持され、トークンのリフレッシュは行ロックのもとで安全に実行されます。Agent Computer や外部の呼び出し元にこれらのトークンが渡されることはありません。

`agentbull_cloud`（**AgentBull Cloud**、既定の base URL は `https://cloudapis.agentbull.com`）は組み込みの統合型上流 provider kind であり、1 つの API キーで言語モデル、embedding、rerank、`web_search`、`web_fetch`、`image_generate` をまとめて利用できます。この認証情報も control plane 内に保持され、さらに外部プラットフォーム接続やメンバー個人の OAuth トークン、Skill が宣言するリモート MCP ヘッダーは control plane の `Ankole.Connectors` MCP ゲートウェイが PostgreSQL 内で一元管理します（`WorkerEnv` は Agent Computer 内のカスタム CLI やスクリプト向け環境変数に用います）。

セレクター解決の失敗には、呼び出し元でハンドリングすべき代表的なパターンが 2 つあります。

- `422 unknown_model_selector` — 指定されたセレクターがこの認証主体に紐付けられていません。
- `422 model_binding_not_configured` — capability とプロファイル名は存在するものの、provider binding の設定が完了していません。

また、紐付け先の provider が要求された機能をサポートしていない場合は `422 unsupported_capability` が返り、運用者によって provider が無効化されている場合は `422 provider_disabled` が返ります。これらはいずれも設定上の問題であり一時的なエラーではないため、設定を変更せずにリトライしても成功しません。

## エラーの形状

エラーレスポンスは OpenAI 互換のエンベロープ形式（`{"error": {"code", "message"}}`）で返され、HTTP ステータスコードがエラーの種別を表します。実装時に考慮すべき主なステータスコードは次のとおりです。

- `400` — リクエストボディのバリデーションエラーです（`model` や `input` の欠落、不正な `limit` や `top_n`、HTTP 経由での stateful フィールド指定、不正な形式の compaction 入力など）。問題のあったフィールドは `code` で示されます。
- `401` — bearer token が指定されていないか、検証に失敗しました。
- `429` — 選択された provider の credential pool に利用可能な認証情報が残っていません。エラーコードは `credential_pool_exhausted` となり、最短の回復予定時刻が判明している場合は `retry_at` が含まれます。
- `404` — 指定された保存済みレスポンス、会話、Agent、またはファイルが、この認証主体のスコープ内に見つかりませんでした。
- `422` — リクエスト形式自体は正しいものの、control plane 側で処理できない状態です（未知のセレクター、未設定の binding、非対応の capability、無効化済みの provider など）。
- `502` / `504` — 上流 provider 側での失敗です。`502` は通信エラーや不正なレスポンス（`upstream_transport_failed`、`invalid_upstream_response`、`ai_gateway_request_failed`）を表し、`504` はタイムアウト（`upstream_timeout`）を表します。なお、上流 provider から返されたクライアント起因の `4xx` エラーは、そのままのステータスコードで透過されます。

上流レスポンスに `error.message` が含まれている場合、AIGateway はそのメッセージをそのまま転送し、含まれていない場合は上流の HTTP ステータスを報告します。

## プログラムによるツール呼び出しと画像生成

`/responses` へのリクエストで `programmatic_tool_calling` ツールが宣言されている場合、AIGateway は対象ツールの定義から `program` ツールを自動合成します。各 `programmatic_tool_call` では、`Ankole.FunctionRuntime.ProgramRunner` を通じて `ankole-function-runtime` 上のステートレスな isolate 内で決定論的な TypeScript プログラムが実行されます。ネストされたツール呼び出しの境界ごとに一時停止しつつ、履歴管理・実行順序・キャンセル処理はすべて AIGateway が制御します。

公開 Responses ツールの 1 つである `image_generation` には 2 つの実行経路があります。認証主体に `image_generate` プロファイルが設定されている場合、AIGateway はその専用 provider とモデルを使って画像生成を実行します。プロファイルが未設定の場合は、メインの言語モデル provider がネイティブ画像生成をサポートしているときに限り、ツール定義を上流へそのまま渡します。どちらの経路も利用できない場合は、擬似的にエミュレートするのではなくリクエスト準備の段階でエラーにします。

いずれの経路でも、公開されるストリームイベントの形式と生成画像の保存方式は共通です。モデルのトークン使用量と画像生成の使用量は、それぞれの処理を実行した認証情報に個別に記録されます。

## Web tool、file、その他の能力

同じ認証主体とトークンを使って、周辺の AI 機能もそのまま呼び出せます。`POST /web_search` は文字数上限付きの `query` を受け取って検索結果を返し、`POST /web_fetch` は 1〜5 件の公開 HTTPS URL を受け取ってページ本文を返します。これらのエンドポイントでは `web_search.default` や `web_fetch.default` を指定でき、AIGateway が現在の Agent プロファイルを自動的に解決します。

`POST /embeddings` はテキスト、トークン配列、または構造化入力ブロックを受け付け、`provider_id/model` 形式による明示的なセレクター指定が必要です（たとえば `Ankole.Brain` は embedding 生成時に [AppConfigure](../app-configuration/) のサイト設定 `brain.embedding_model` を読み取ります）。`POST /rerank` は空でないドキュメント配列と正の整数 `top_n` を受け取って再ランク付けを行い、明示的な `provider_id/model` セレクターまたは `default` / `rerank.default` を受け付けます（`ankole_brain` は自身の有効な `rerank` モデルプロファイルを解決し、Agent や Human の呼び出しは Pod/Site の `rerank` プロファイルを解決します。検索の詳細は [Brain](../brain/) を参照してください）。一方、Pod Applet の `ctx.ai` 呼び出しは組み込みの `system` Principal のもとで `Ankole.AIGateway` を経由してステートレスに実行され、Pod/Site の有効な言語モデルプロファイル（`primary`、`light`、`heavy`、`coding`、`vision_fallback`）を使用するため、フォアグラウンド Agent のトークンクォータを消費しません。

`POST /web_search` は 1,024 文字以内の `query` と、任意の `limit`（1〜100、既定値 5）を受け取り、`items` と `metadata` を返します。各結果には `url`、`title`、`description` が含まれ、Provider が返した場合は `published_at` と `score` も付きます。`metadata` には `query`、ゲートウェイ側の所要時間 `latency_ms`、HTTP リクエストの `request_id` が入ります。`POST /decisions` は、与えられた `state` について型付きの質問に回答します。1 回のリクエストには 1〜64 個の `questions` を指定でき、各質問は `noul`（はい／いいえ）、`choice`（2〜255 個の名前付き選択肢から 1 つ）、`score`（2〜10 段階の順序付きレベル）のいずれかです。画像は 1 枚あたり 4 MiB 以内で、4 枚まで添付できます。レスポンスは質問ごとに確率付きの回答を返し、回答した `model` とトークンの `usage` も含みます。`default` / `decision.default` セレクターは Pod/Site の `decision` プロファイルに解決されます。このプロファイルが未設定の場合は、呼び出し元の `light` 言語モデルが代わりに回答します。言語モデルが返すのは自己申告の確信度であるため、この確率は較正されていません。また、言語モデルが回答する場合、1 回のリクエストに指定できる選択肢とレベルは合計 500 個までです。

`decision` プロファイルには、TypeSafe（`typesafe`、既定 URL `https://api.typesafe.ai/v1`）、Microsoft Foundry を使う Azure OpenAI（`azure_openai`）、OpenRouter（`openrouter`）、OpenAI（`openai`）、Cloudflare（`cloudflare`）を選択できます。TypeSafe の `base_url` には SystemOne 互換エンドポイントも指定できます。Azure Foundry は設定したデプロイ名で `<resource-root>/providers/microsoft/v1/systemone` を呼び出し、OpenAI は `gpt-6-luna` で `/decisions` を呼び出します。TypeSafe、Azure Foundry、OpenRouter が使う SystemOne プロトコルは PNG と JPEG のアセットを受け付けますが、WebP は利用できません。Microsoft-Decision-1 は画像を受け付けません。OpenAI Decisions は PNG、JPEG、WebP を利用できます。OpenAI がいずれかの質問を拒否した場合、AIGateway は部分的な回答を返さず、リクエスト全体を `422 upstream_decision_refusal` で拒否します。

`POST /images` は、会話の外で画像を 1 枚生成または編集します。リクエストには `model`（`image_generate.default`、`default`、または明示的な `provider_id/model`）、`prompt`、任意の参照画像 `images` と `mask`、そして `size`、`quality`、`output_format` などの `image_generation` ツールオプションを指定します。リクエストは選択した画像 Provider へ直接送られます。OpenRouter と AgentBull Cloud はそれぞれのカタログにある画像モデルを、Cloudflare は FLUX.1 [schnell] と Black Forest Labs のモデルを提供します。レスポンスは `created`、画像を `b64_json` と `media_type` で保持する 1 件の `data`、および Provider の `usage` を返します。AIGateway は生成した画像と判定モデルの呼び出しを 1 件ずつ使用量台帳に記録します。Agent のトークンクォータと Console のモデル使用量ページが集計するのは言語モデルのラウンドだけです。

ファイル操作も標準の API として組み込まれています。`POST /files` でアップロード、`GET /files` で一覧取得、`GET /files/:id` と `GET /files/:id/content` でメタデータとファイル本体の読み取り、`DELETE /files/:id` で削除を行えます。すべてのファイルは認証主体ごとのスコープに分離されます。

## AIGateway ではないもの

AIGateway は認証不要の公開プロキシではありません。また、呼び出し元から上流 provider の API キーを渡す場所でもありません（認証情報はすべて control plane 側で保管します）。さらに、ジョブキューやバックグラウンドランナーでもありません。長時間にわたる Agent の作業は Sessions や Background Agent Job が担当します。AIGateway はあくまでリクエスト／レスポンスの境界であり、「1 つの呼び出しを受け取り、セレクターを解決し、認証情報を外部に出さずに 1 つのレスポンスまたはストリームを返す」ことに徹しています。

## 次のステップ

- システム全体における AIGateway の位置づけについては、[architecture 概要](../architecture/) を参照してください。
- これらのルートを提供するサーバーの起動方法については、[クイックスタートの deployment セクション](../quickstart/#deployment) を参照してください。
- 最初の Provider とモデルプロファイルの設定手順については、[クイックスタート](../quickstart/#llm-providers) を参照してください。
