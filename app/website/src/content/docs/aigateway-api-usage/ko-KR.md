---
title: AIGateway API 사용법
description: 외부 호출자가 AIGateway REST API를 사용하는 방법 — OpenResponses 호환 endpoint, agent vs admin 토큰, 상태비저장(stateless) 및 상태보존(stateful) 호출, 작업 예시.
section: Developer guide
order: 126
---

AIGateway는 Worker가 호출하는 내부 경계일 뿐만 아니라, 외부 애플리케이션, 엔터프라이즈 시스템, SDK가 직접 호출할 수 있는 REST API입니다. 이 페이지는 호출자를 위한 실용 가이드입니다 — endpoint, 인증, 두 가지 호출 모드, 작업 예시를 다룹니다. [AIGateway](../ai-gateway/) 개념 페이지를 실사용과 함께 보완합니다.

가장 중요한 특성을 먼저 말하면: AIGateway API는 **OpenResponses 호환이며 Principal 스코프입니다**. 호출자는 bearer 토큰(agent 또는 admin)을 제시하고 OpenResponses 형태의 요청을 보내며, JSON 응답 또는 스트림을 받습니다. 호출자는 provider 자격 증명을 볼 수 없습니다 — 그 자격 증명은 control plane이 소유합니다.

## 인증

`/api/v1/ai-gateway` 아래의 모든 호출은 bearer 토큰을 필요로 합니다:

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Hello" }'
```

두 가지 토큰 종류가 허용됩니다:

- **Agent token** — 한 Agent의 모델 바인딩으로 스코프가 제한됩니다. 통합이 특정 Agent를 대신해 행동할 때 사용하세요.
- **Admin token** — 모든 provider로 스코프가 제한됩니다. 운영자 측 스크립트와 Console용입니다.

토큰이 Principal로 어떻게 해석되는지는 [Principal and AuthZ](../principal-authz/)를 참조하세요.

## 상태비저장 응답(HTTP 및 SSE)

상태비저장 호출은 요청 하나에 응답 하나입니다. 전체 입력을 보내고 완전한 본문을 돌려받습니다:

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Summarize this thread.", "store": false }'
```

스트리밍을 위해서는 `"stream": true`를 추가하면 같은 endpoint가 Server-Sent Events로 전환됩니다:

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Draft a release note.", "stream": true }'
```

상태비저장 HTTP와 SSE는 상태보존 필드(`previous_response_id`, `conversation`, `store`)를 거부합니다. 연속 작업에는 WebSocket 경로를 사용하세요.

## 기타 endpoint

| 엔드포인트 | 용도 |
|---|---|
| `GET /models` | 현재 사용 가능한 모델 나열 |
| `POST /embeddings` | 임베딩 생성 |
| `POST /rerank` | 문서 rerank |
| `POST /web_search` | 웹 검색 |
| `POST /web_fetch` | 웹 페이지 가져오기 |

각각은 [AIGateway](../ai-gateway/) 개념 페이지와 관련 User guide 기능 페이지에 문서화되어 있습니다.

## 이 가이드가 아닌 것

AIGateway 개념 페이지가 아닙니다. 전체 라우트 테이블, 상태보존 수명 주기, 오류 형식은 [AIGateway](../ai-gateway/)를 읽으세요. SDK도 아닙니다. Ankole은 클라이언트 SDK를 제공하지 않습니다. 호출자는 REST API에 표준 HTTP 클라이언트를 사용합니다.

## 다음 단계

- 전체 AIGateway 표면은 [AIGateway](../ai-gateway/)를 읽으세요.
- Provider 해석과 요청 준비는 [Provider Runtime](../provider-runtime/)을 읽으세요.
- Console API 참조는 [Console API reference](../console-api/)를 읽으세요.
