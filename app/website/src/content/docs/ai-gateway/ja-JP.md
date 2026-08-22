---
title: AIGateway API
description: OpenResponses 互換の AI boundary。HTTP、SSE、WebSocket endpoint、stateless と stateful の呼び出し、provider routing について説明します。
section: Developer guide
order: 101
---

AIGateway は、Ankole deployment instance の統一された AI boundary です。外部アプリケーション、エンタープライズ system、SDK は、OpenResponses 互換の API を通じて直接呼び出します。内部の agent も、model turn のために同じ surface を呼び出します。すべての呼び出しで、運用者が構成した provider binding に対して model selector が解決され、上流の credential が control plane の外に出ることはありません。

このページは、実際の route、request の形状、stateless と stateful の呼び出しの境界を解説します。source of truth は control plane の router と `Ankole.AIGateway` module です。このページは map であり、contract ではありません。

## 位置づけ

AIGateway は呼び出し元と provider の間にあります。呼び出し元、つまり agent の model loop、console の運用者、または外部の integration は、bearer token を提示して OpenResponses 形状の request を送ります。AIGateway は selector を解決し、request を準備し、bind された provider に fan-out し、単一の JSON body または stream を返します。LLM、embedding、rerank、web 検索、web fetch の能力はすべて同じ boundary を通ります。

最も重要な性質は、呼び出し元が provider の credential を決して見ないことです。control plane が credential と routing policy を所有し、呼び出し元が所有するのは自分の token と selector だけです。

## 認証

`/api/v1/ai-gateway` 配下のすべての endpoint は、`:ai_gateway_api` pipeline と `RequireAIGatewayAccessToken` plug を通ります。request は `Authorization` ヘッダに bearer token を提示する必要があり、plug は正確に 2 種類を受け付けます。

- **agent token** — active な agent Principal を主体とする AIGateway API key。呼び出しはその agent の model binding と selector に限定され、`subject_type = "agent"` になります。
- **admin token** — active な人間の管理者 console token。呼び出しは運用者の provider ビューに限定され、`subject_type = "admin_human"` になります。

token がない場合や検証できない場合は、`code: "invalid_token"` とともに `401` を返します。anonymous の経路はありません。

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"Summarize the open incidents."}'
```

## endpoint

すべての route は `/api/v1/ai-gateway` 配下にあります。endpoint が使う transport は contract の一部であり、好みではありません。

| メソッド | パス | Transport | 用途 |
|---|---|---|---|
| `GET` | `/models` | HTTP | この主体に見える model selector を一覧表示 |
| `POST` | `/responses` | HTTP または SSE | response を作成。`"stream": true` のときは stream |
| `GET` | `/responses` | WebSocket | stateful な streaming response |
| `GET` | `/responses/:response_id` | HTTP | 保存された stateful response（`resp_{uuid}`）を取得 |
| `POST` | `/embeddings` | HTTP | embedding を作成 |
| `POST` | `/rerank` | HTTP | document を rerank |
| `POST` | `/web_search` | HTTP | web を検索 |
| `POST` | `/web_fetch` | HTTP | web page を取得 |
| `GET/POST/DELETE` | `/files`、`/files/:id`、`/files/:id/content` | HTTP | file をアップロード、読み取り、削除 |

`POST /responses` はこの surface の中心です。model turn を運び、transport と状態によって分岐する唯一の endpoint です。

## HTTP と SSE 上の stateless response

stateless な呼び出しは、1 回の request、1 回の response です。呼び出し元は完全な input を送り、AIGateway が selector を解決し、provider を呼び出し、完全な body を返します。`"stream": true` を設定すると、同じ endpoint が Server-Sent Events に切り替わります。AIGateway は SSE stream を開き、`event: <type>\ndata: <json>\n\n` として型付き event を書き、`data: [DONE]` で終了します。

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"Draft a release note.","stream":true}'
```

stateless な HTTP と SSE は 1 つの厳格な規則を共有します。stateful なフィールド `previous_response_id`、`conversation`、`store` を拒否します。turn をまたいだ継続が必要な request は、WebSocket 経路を使わなければなりません。HTTP または SSE で stateful なフィールドを送った request には、`code: "stateful_responses_require_websocket"` と、問題のあるフィールドを名指しした message とともに `400` が返ります。

## WebSocket 上の stateful response

stateful な response は、WebSocket にアップグレードされた `GET /responses` 上にあります。アップグレードは、主体の identity、300 秒の idle timeout、圧縮、128 MiB の frame 上限を備えて、接続を `AIGatewayResponsesSocket` に渡します。この transport 上では、呼び出しは `store: true` を設定でき、`previous_response_id` または `conversation` で既存の会話を継続できます。

durable な lifecycle はここにあります。保存された response は `resp_{uuid}` の形式の id を得ます。以降の turn は `previous_response_id` でそれを参照します。保存された会話は `conversation` で参照されます。継続の規則、durable な履歴、compaction、response の projection、復旧はすべて control plane が所有し、どれも呼び出し元の仕事ではありません。

保存された response は、後から stateless かつ素の HTTP で取得できます。

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses/resp_4f3c... \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN"
```

compaction は、長く保存された履歴を、流れを失わずに短いものへ交換する唯一の手段です。専用の endpoint はありません。input に `{"type": "compaction_trigger"}` item を含めた request を送ると、AIGateway が `compaction` output item を 1 つ返します。どの transport でも動作します。`POST /responses` は body を返し、同じ呼び出しに `"stream": true` を付けると SSE event として返り、WebSocket も同じ event を返します。trigger だけを送ると `previous_response_id` または `conversation` が指す保存済み会話を compaction し、応答には続きに使う checkpoint id が入ります。履歴を一緒に送ると、送った内容を compaction します。

## Provider routing

AIGateway は、どの上流呼び出しよりも前に、model selector を実際の provider binding に解決します。selector は呼び出し元が見るものです。たとえば `main` や、provider が所有する明示的な名前です。解決結果は主体に依存します。agent の selector は構成済みの model binding から来て、管理者は明示的な provider エントリを見ます。`GET /models` は現在の主体が解決できるものを一覧表示し、OpenRouter スタイルのフィルタ（`q`、`context`、`min_price`、`max_price`、`sort`、modal フィルタ）をオプションで受け付けます。

各 provider row は credential pool を所有します。provider kind、base URL、ヘッダ、設定、capability 宣言は、すべてのメンバーで共有されます。model profile は row を指し、pool メンバーを名指しすることはありません。AIGateway は構成済みの `fill_first`、`round_robin`、`least_used`、`random` strategy に従って健全なメンバーを選択します。Console は選択された UI 言語に合わせてこれらの strategy 名を翻訳し、API と保存された値は変わりません。stateful な thread は、可能な限り同じメンバーに留まります。

属性の付く `429`、`5xx`、または transport の失敗は、request を行った credential だけをクールダウンします。AIGateway は別のメンバーを選択し、provider の request を再構築し、指数バックオフと jitter 付きの有界 retry を実行します。Rust kernel は一度に 1 回の transport 試行を行います。pool が空のとき、AIGateway は別の provider に切り替えません。

`chatgpt_subscription` は普通の provider kind です。その OAuth credential は control plane に残り、token の refresh は row lock の下で実行されます。Agent Computer と外部呼び出し元は、これらの token を受け取りません。

resolution は、呼び出し元が処理すべき 2 つの方法で失敗します。

- `422 unknown_model_selector` — selector がこの主体に bind されていません。
- `422 model_binding_not_configured` — capability と名前は bind されていますが、provider binding が不完全です。

bind された provider が提供しない capability は、`422 unsupported_capability` として現れます。運用者が無効化した provider は、`422 provider_disabled` として現れます。これらは configuration の問題であり、一時的なものではありません。configuration を変えずに retry しても解決しません。

## エラーの形状

エラーは OpenAI 互換の envelope を使います。body は `{"error": {"code", "message"}}` で、HTTP ステータスは失敗のクラスに対応します。計画に値するクラスは次のとおりです。

- `400` — request body の validation に失敗。`model` の欠落、`input` の欠落、不正な `limit` または `top_n`、HTTP 上の stateful フィールド、形式の不正な compaction input。`code` がフィールドを指名します。
- `401` — bearer token がない、または検証できない。
- `429` — 選択された provider の credential pool が尽きました。エラー code は `credential_pool_exhausted` で、AIGateway が最も早い回復時刻を知っている場合、`retry_at` が含まれます。
- `404` — 保存された response、conversation、agent、または file がこの主体に対して見つかりませんでした。
- `422` — request は形式が正しいが、control plane が処理できない。未知の selector、未構成の binding、サポートされない capability、無効化された provider。
- `502` / `504` — 上流の provider が失敗。`502` は transport と不正な response の失敗（`upstream_transport_failed`、`invalid_upstream_response`、`ai_gateway_request_failed`）をカバーし、`504` は `upstream_timeout` です。provider からの client `4xx` は、その独自のステータスで透過されます。

上流が `error.message` を返した場合、AIGateway はその message を転送します。それ以外の場合は、上流の HTTP ステータスをそのまま報告します。

## 画像生成

`image_generation` は公開の Responses tool で、2 つの実行経路があります。主体が `image_generate` profile を持つ場合、AIGateway はその独立した provider と model で tool を実行します。profile がない場合、AIGateway はメイン provider が native 画像生成を宣言しているときにのみ tool を渡します。どちらの経路も存在しない場合、tool を模倣する代わりに request の準備が失敗します。

どちらの経路も同じ公開 stream event と生成画像の永続化を使います。model の使用量と画像の使用量は、それぞれの部分を生成した credential に帰属します。

## Web tool、file、その他の能力

同じ主体と token が隣接する能力を駆動します。`POST /web_search` は `query`（長さ制限あり）を受け取り、provider が裏付けする結果を返します。`POST /web_fetch` は 1 つから 5 つの公開 HTTPS URL を受け取り、page content を返します。`POST /embeddings` は text、token 配列、または input block を受け付けます。`POST /rerank` は空でない document 配列を rerank し、正の整数の `top_n` を受け取ります。各 request は、`web_search.default` や `web_fetch.default` のような能力固有の semantic selector を使います。AIGateway は呼び出しの到着時に現在の Agent profile を解決します。

file はファーストクラスです。`POST /files` がアップロードし、`GET /files` が一覧表示し、`GET /files/:id` と `GET /files/:id/content` が metadata と bytes を読み取り、`DELETE /files/:id` が 1 つを削除します。これらはすべて主体に限定されます。

## AIGateway ではないもの

これは公開された、認証なしの proxy ではありません。provider の credential を送る場所でもありません。それらは control plane にあります。そして queue や job runner でもありません。長時間の agent の仕事は Actor Runtime と Background Agent Job に属します。AIGateway は request/response boundary です。1 つの呼び出しが入り、1 つの response または 1 つの stream が出ます。selector は解決され、credential は内部に保たれます。

## 次のステップ

- AIGateway がシステム全体のどこに位置するかは、[architecture 概要](../architecture/) をお読みください。
- これらの route をホストする server の実行方法は、[クイックスタートの deployment セクション](../quickstart/#deployment) をお読みください。
- 最初の Provider と model profile のセットアップは、[クイックスタート](../quickstart/#llm-providers) をお読みください。