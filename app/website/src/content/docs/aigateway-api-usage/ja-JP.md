---
title: AIGateway API の使い方
description: 外部クライアントから AIGateway REST API を呼び出す実践ガイド。OpenResponses 互換エンドポイント、Agent トークンと OIDC Human トークンの違い、ステートレス呼び出しの例を説明します。
section: Developer guide
order: 126
---

AIGateway は、Worker が内部から呼び出すためだけの境界ではありません。外部アプリケーション、社内システム、各種 SDK から直接利用できる REST API でもあります。このページでは [AIGateway](../ai-gateway/) の概念ページを補完し、外部の呼び出し元向けにエンドポイント、認証方式、呼び出しモード、具体的なリクエスト例を紹介します。

最初に押さえておきたいのは、AIGateway API が **OpenResponses 互換であり、かつ Principal ごとにスコープ分離されている**という点です。呼び出し元は bearer token（Agent 用または OIDC Human 用）を提示して OpenResponses 形式のリクエストを送り、JSON レスポンスまたはストリームを受け取ります。上流 provider の認証情報はすべて control plane が管理するため、呼び出し元が API キーなどに触れることはありません。

## 認証

`/api/v1/ai-gateway` 配下のすべてのリクエストには bearer token が必要です。

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Hello" }'
```

受け付けられるトークンは次の 2 種類です。

- **Agent token** — 特定の Agent の model binding にスコープされたトークンです。外部連携が特定の Agent として処理を実行する場合に使用します。
- **OIDC Human token** — `ai_gateway.write` スコープを持つ OIDC Client から有効な Human に発行されるトークンです。その Client に許可されたモデルエイリアスのみを使用でき、`subject_type = "oidc_human"` として扱われます。

OIDC Human token を取得するには、Console で `ai_gateway.write` スコープを持つ OIDC Client を作成し、許可するグループとモデルエイリアスを設定したうえで、Authorization Code + PKCE でログインします。長期間利用する場合は `offline_access` を要求し、ローテーション式の Refresh Token を使用してください。利用する人間は許可されたグループに所属している必要があり、指定できるのはその Client のモデルエイリアスのみです（`provider_id/model` 形式の直接指定はできません）。

トークンからどのように Principal が解決されるかについては、[Principal and AuthZ](../principal-authz/) を参照してください。

## ステートレスレスポンス（HTTP と SSE）

ステートレス呼び出しは、1 回のリクエストに対して 1 回のレスポンスが返るシンプルな方式です。入力全体を送ると、完了したレスポンスボディ全体が返されます。

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Summarize this thread.", "store": false }'
```

ストリーミングで受け取りたい場合は `"stream": true` を指定します。同じエンドポイントがそのまま Server-Sent Events（SSE）に切り替わります。

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Draft a release note.", "stream": true }'
```

なお、HTTP および SSE によるステートレス呼び出しでは、ステートフル用のフィールド（`previous_response_id`、`conversation`、`store`）は拒否されます。ターンをまたいで会話を継続したい場合は、WebSocket 経路を使用してください。

## その他のエンドポイント

| エンドポイント | 用途 |
|---|---|
| `GET /models` | 現在の認証主体から利用可能なモデルを一覧取得 |
| `POST /embeddings` | embedding を生成 |
| `POST /rerank` | ドキュメントを再ランク付け |
| `POST /web_search` | Web を検索 |
| `POST /web_fetch` | Web ページを取得 |
| `POST /decisions` | 型付きの質問に確率付きで回答 |
| `POST /images` | 画像を生成または編集 |
| `POST /audio/speech` | テキストを音声に変換 |
| `POST /audio/transcriptions` | 音声をテキストに変換 |
| `POST /ocr` | PDF または文書画像を Markdown として読み取り |

各エンドポイントの詳細については、[AIGateway](../ai-gateway/) の概念ページおよび対応するユーザーガイドの各機能ページを参照してください。

## 確率付きの判定

生成文ではなく確率が必要な場合は `POST /decisions` を使用します。`decision.default` セレクターは Pod/Site の判定モデルプロファイルに解決されます。`provider_id/model` を明示して判定モデルを直接選択することもできます。

```bash
curl https://ankole.example.com/api/v1/ai-gateway/decisions \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "decision.default",
    "state": {"ticket": "I was charged twice."},
    "questions": {
      "urgent": {"type": "noul", "instructions": "Does this need a reply today?"},
      "team": {
        "type": "choice",
        "instructions": "Which team owns this ticket?",
        "criteria": {"billing": "Payments and refunds", "support": "Product questions"}
      }
    }
  }'
```

`score` 質問の `criteria` には 2〜10 個の順序付きレベルラベルを指定します。レスポンスには `model`、`answers`、トークンの `usage` が含まれ、各回答に確率が付きます。TypeSafe、Azure Foundry、OpenRouter、OpenAI、Cloudflare の判定モデルは同じ公開リクエスト形式を使いますが、画像の対応は異なります。SystemOne は PNG/JPEG、Microsoft-Decision-1 はテキストのみ、OpenAI は WebP にも対応します。OpenAI がいずれかの質問を拒否した場合は、部分的な回答を返さず `422 upstream_decision_refusal` を返します。判定モデルプロファイルが未設定の場合は、呼び出し元の `light` 言語モデルが未較正の確率で回答します。

## このガイドではないもの

このページは AIGateway 全体の仕様書ではありません。全ルートの一覧、WebSocket 上のステートフルなライフサイクル、エラーレスポンスの詳細については [AIGateway](../ai-gateway/) を参照してください。また、Ankole では専用のクライアント SDK を配布していないため、標準の HTTP クライアントや OpenResponses 互換クライアントから直接 REST API を呼び出してください。

## 次のステップ

- AIGateway の全仕様については、[AIGateway](../ai-gateway/) を参照してください。
- Provider の解決ロジックとリクエスト準備の仕組みについては、[Provider Runtime](../provider-runtime/) を参照してください。
- Console 側の管理 API については、[Console API reference](../console-api/) を参照してください。
