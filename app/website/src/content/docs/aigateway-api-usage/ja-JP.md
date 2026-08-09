---
title: AIGateway API の使い方
description: 外部の呼び出し側が AIGateway REST API を使う方法——OpenResponses 互換エンドポイント、agent と admin の token の違い、ステートレス/ステートフル呼び出し、実践例。
section: Developer guide
order: 126
---

AIGateway は worker が呼び出す内部境界だけではありません。外部アプリケーション、企業システム、SDK が直接呼び出せる REST API です。このページは、呼び出し側のための実践ガイドです。エンドポイント、認証、2 つの呼び出しモード、実践例を説明し、[AIGateway](../ai-gateway/) のコンセプトページを実践的な使い方で補完します。

決定的な性質を先に述べます。AIGateway API は**OpenResponses 互換であり、Principal にスコープされます**。呼び出し側は bearer token（agent または admin）を提示し、OpenResponses 形式のリクエストを送り、JSON レスポンスまたはストリームを受け取ります。呼び出し側が provider credential を見ることは決してありません——それらは control plane が所有します。

## 認証

`/api/v1/ai-gateway` 配下のすべての呼び出しには bearer token が必要です:

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Hello" }'
```

2 種類の token が受け入れられます。

- **Agent token**——1 つの Agent の model binding にスコープされます。統合が特定の Agent に代わって行動するときに使います。
- **Admin token**——すべての provider にスコープされます。オペレーター側のスクリプトと Console に使います。

token がどのように Principal に解決されるかは、[Principal and AuthZ](../principal-authz/) を参照してください。

## ステートレスレスポンス（HTTP と SSE）

ステートレス呼び出しは、1 つのリクエスト、1 つのレスポンスです。完全な input を送り、完全なボディを受け取ります:

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Summarize this thread.", "store": false }'
```

ストリーミングには `"stream": true` を追加します。同じエンドポイントが Server-Sent Events に切り替わります:

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Draft a release note.", "stream": true }'
```

ステートレス HTTP と SSE はステートフルフィールド（`previous_response_id`、`conversation`、`store`）を拒否します。続きには WebSocket パスを使ってください。

## その他のエンドポイント

| エンドポイント | 用途 |
|---|---|
| `GET /models` | 現在利用可能な model を一覧表示 |
| `POST /embeddings` | embeddings を作成 |
| `POST /rerank` | ドキュメントを再ランク付け |
| `POST /web_search` | ウェブを検索 |
| `POST /web_fetch` | ウェブページを取得 |

それぞれ [AIGateway](../ai-gateway/) コンセプトページと、関連する User guide の機能ページに文書化されています。

## このガイドではないもの

これは AIGateway のコンセプトページではありません。完全なルートテーブル、ステートフルなライフサイクル、エラーエンベロープは [AIGateway](../ai-gateway/) を読んでください。SDK でもありません。Ankole はクライアント SDK を出荷しません。呼び出し側は標準の HTTP クライアントで REST API にアクセスします。

## 次のステップ

- AIGateway の完全な面については、[AIGateway](../ai-gateway/) を読んでください。
- Provider の解決とリクエスト準備については、[Provider Runtime](../provider-runtime/) を読んでください。
- Console API リファレンスについては、[Console API reference](../console-api/) を読んでください。