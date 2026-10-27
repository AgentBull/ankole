---
title: AIGateway API
description: OpenResponses 互換の AI 境界。HTTP、SSE、WebSocket の各エンドポイント、stateless / stateful 呼び出し、provider ルーティングについて説明します。
section: Developer guide
order: 101
---

AIGateway は、Ankole デプロイインスタンスにおける統一された AI 境界です。外部アプリケーション、社内システム、各種 SDK からは OpenResponses 互換 API として直接呼び出すことができ、内部の Agent もモデルターンを実行する際に同じインターフェースを利用します。どの呼び出しでも、モデルセレクターは運用者が構成した provider binding に従って解決されるため、上流プロバイダーの認証情報が control plane の外へ出ることはありません。

このページでは、実際の API ルート、リクエスト形式、stateless 呼び出しと stateful 呼び出しの境界を整理して案内します。正式な仕様（source of truth）は control plane のルーターおよび `Ankole.AIGateway` モジュールにあります。

## 位置づけ

AIGateway は呼び出し元と上流 provider の間に位置します。呼び出し元（Agent のモデルループ、OIDC Human、または外部連携システム）が bearer token を添えて OpenResponses 形式のリクエストを送ると、AIGateway がセレクターを解決してリクエストを組み立て、紐付けられた provider を呼び出して単一の JSON レスポンスまたはストリームを返します。LLM、embedding、rerank、Web 検索、Web 取得（fetch）はいずれもこの同じ境界を通ります。また、レスポンスターンで `programmatic_tool_calling` を使用する場合は、`Ankole.FunctionRuntime.ProgramRunner` を通じて `ankole-function-runtime` 上のステートレスな isolate 内で各 `programmatic_tool_call` の TypeScript プログラムを実行します。

ここで最も重要なのは、呼び出し元が上流 provider の認証情報に一切触れないという点です。認証情報とルーティングポリシーはすべて control plane が管理し、呼び出し元が扱うのは自身のトークンとモデルセレクターだけです。

## 認証

`/api/v1/ai-gateway` 配下のすべてのエンドポイントは、`:ai_gateway_api` パイプラインと `RequireAIGatewayAccessToken` plug を通過します。リクエストの `Authorization` ヘッダーには bearer token が必須であり、次の 2 種類のトークンのみを受け付けます。

- **agent token** — 有効な Agent Principal を主体とする AIGateway API キーです。呼び出し対象はその Agent の model binding とセレクターに限定され、`subject_type = "agent"` として扱われます。
- **OIDC Human token** — `ai_gateway.write` スコープを持つ OIDC Client から有効な Human に対して発行されるトークンです。その Client に許可されたモデルエイリアスのみを使用でき、`subject_type = "oidc_human"` として扱われます。

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

AIGateway は上流へのリクエストを行う前に、モデルセレクターを実際の provider binding へ解決します。Agent にはあらかじめ 8 つの標準プロファイル（`primary`、`light`、`heavy`、`coding`、`vision_fallback`、`web_search`、`web_fetch`、`image_generate`）が用意されており、最初の 5 つが言語モデル用、残りの 3 つが個別機能用です。さらに Agent ごとにカスタムの言語モデルプロファイルを追加することもできます。管理者は明示的な provider エントリを指定できます。現在の認証主体が解決可能なモデルの一覧は `GET /models` で確認でき、OpenRouter 形式のクエリパラメータ（`q`、`context`、`min_price`、`max_price`、`sort`、モダリティフィルタ）による絞り込みにも対応しています。

各 provider レコードは内部に credential pool を持っています。provider kind、base URL、ヘッダー、設定値、capability 宣言はプール内の全メンバーで共有されます。モデルプロファイルが参照するのはあくまで provider レコードであり、特定のプールメンバーを直接指定することはありません。AIGateway は設定された選択戦略（`fill_first`、`round_robin`、`least_used`、`random`）に従って正常なメンバーを選びます（Console 上では UI 言語に応じて翻訳表示されますが、API と永続化ではこれらの正規キーが使われます）。なお、stateful なスレッドでは可能な限り同じプールメンバーが継続して選択されます。

特定の認証情報に起因する `429`、`5xx`、または通信エラーが発生した場合は、そのリクエストに使用した認証情報だけがクールダウン対象となります。その際、AIGateway はプール内の別メンバーを選び直してリクエストを再構築し、指数バックオフとジッターを伴う回数制限付きリトライを実行します（Rust kernel 自体は 1 回につき 1 回の通信試行のみを行います）。プール内に利用可能なメンバーが残っていない場合でも、別の provider へ自動的にフェイルオーバーすることはありません。

`chatgpt_subscription` も通常の provider kind の 1 つとして扱われます。OAuth 認証情報は control plane 内に保持され、トークンのリフレッシュは行ロックのもとで安全に実行されます。Agent Computer や外部の呼び出し元にこれらのトークンが渡されることはありません。

`agentbull_cloud`（**AgentBull Cloud**、既定の base URL は `https://cloudapis.agentbull.com`）は組み込みの統合型上流 provider kind であり、1 つの API キーで言語モデル、embedding、rerank、`web_search`、`web_fetch`、`image_generate` をまとめて利用できます。この認証情報も control plane 内に保持されます（一方、Worker 上の MCP スキルが直接参照する外部 API キー類には、従来どおり `WorkerEnv` を使用します）。

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

`POST /embeddings` はテキスト、トークン配列、または入力ブロックを受け付けます。`POST /rerank` は空でないドキュメント配列と正の整数 `top_n` を受け取って再ランク付けを行います。これら 2 つのエンドポイントでは `provider_id/model` 形式による明示的なセレクター指定が必須であり、Agent プロファイル名は解決されません。Brain がこれらを呼び出す際は、[AppConfigure](../app-configuration/) のサイト設定 `brain.embedding_model` とテナント設定 `brain.rerank_model` を使用します。また、Pod Applet からの `ctx.ai` 呼び出しは、その Applet を作成した有効な Agent の権限で AIGateway を経由し、ステートレスに実行されます（言語モデルプロファイル、クォータ、使用量もすべてその Agent に帰属します）。検索の詳細については [Brain](../brain/) を参照してください。

ファイル操作も標準の API として組み込まれています。`POST /files` でアップロード、`GET /files` で一覧取得、`GET /files/:id` と `GET /files/:id/content` でメタデータとファイル本体の読み取り、`DELETE /files/:id` で削除を行えます。すべてのファイルは認証主体ごとのスコープに分離されます。

## AIGateway ではないもの

AIGateway は認証不要の公開プロキシではありません。また、呼び出し元から上流 provider の API キーを渡す場所でもありません（認証情報はすべて control plane 側で保管します）。さらに、ジョブキューやバックグラウンドランナーでもありません。長時間にわたる Agent の作業は Sessions や Background Agent Job が担当します。AIGateway はあくまでリクエスト／レスポンスの境界であり、「1 つの呼び出しを受け取り、セレクターを解決し、認証情報を外部に出さずに 1 つのレスポンスまたはストリームを返す」ことに徹しています。

## 次のステップ

- システム全体における AIGateway の位置づけについては、[architecture 概要](../architecture/) を参照してください。
- これらのルートを提供するサーバーの起動方法については、[クイックスタートの deployment セクション](../quickstart/#deployment) を参照してください。
- 最初の Provider とモデルプロファイルの設定手順については、[クイックスタート](../quickstart/#llm-providers) を参照してください。
