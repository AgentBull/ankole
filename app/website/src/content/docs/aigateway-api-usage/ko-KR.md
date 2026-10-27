---
title: AIGateway API 사용법
description: 외부 호출자가 AIGateway REST API를 사용하는 방법 — OpenResponses 호환 endpoint, Agent 및 OIDC Human 토큰, 상태비저장(stateless) 및 상태보존(stateful) 호출, 작업 예시.
section: Developer guide
order: 126
---

AIGateway는 내부 Worker만 호출하는 전용 통로가 아니라 외부 애플리케이션, 사내 시스템, SDK에서도 직접 호출할 수 있는 REST API입니다. 이 문서는 외부 호출자를 위한 실무 가이드로서 엔드포인트 구조, 인증 방식, 두 가지 호출 모드와 실제 호출 예시를 다룹니다. [AIGateway](../ai-gateway/) 개념 문서를 보완하여 실제 API 사용법에 초점을 맞춥니다.

가장 먼저 기억할 핵심 원칙은 AIGateway API가 **OpenResponses 호환 규격을 따르며 Principal 단위로 권한 범위가 제한된다**는 점입니다. 호출자가 bearer 토큰(Agent 토큰 또는 OIDC Human 토큰)과 함께 OpenResponses 형식의 요청을 보내면 JSON 본문이나 스트림 응답을 돌려받습니다. 업스트림 provider 자격 증명은 control plane이 전담 보관하므로 호출자에게 노출되지 않습니다.

## 인증

`/api/v1/ai-gateway` 하위 엔드포인트의 모든 요청에는 bearer 토큰이 필요합니다.

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Hello" }'
```

허용되는 토큰은 다음 두 종류입니다.

- **Agent token** — 특정 Agent의 모델 바인딩 범위로 제한되는 토큰입니다. 외부 연동 시스템이 해당 Agent를 대신해 모델을 호출할 때 사용합니다.
- **OIDC Human token** — `ai_gateway.write` 권한을 가진 OIDC Client가 활성 사용자(Human)에게 발급한 토큰입니다. 해당 Client에 등록된 모델 별칭(model alias)만 호출할 수 있으며 `subject_type = "oidc_human"`으로 처리됩니다.

OIDC Human 토큰을 발급받으려면 먼저 Console에서 `ai_gateway.write` 스코프를 가진 OIDC Client를 생성하고, 접근을 허용할 그룹과 모델 별칭을 지정합니다. 이후 사용자는 PKCE를 적용한 Authorization Code 흐름으로 로그인하며, 장기 세션이 필요한 경우 `offline_access`를 요청해 순환 갱신되는(rotating) Refresh Token을 사용합니다. 사용자는 허용된 그룹의 구성원이어야 하며 Client에 정의된 모델 별칭만 사용할 수 있고, 원시 `provider_id/model` 셀렉터는 직접 지정할 수 없습니다.

제시된 토큰이 내부 Principal로 해석되는 과정은 [Principal and AuthZ](../principal-authz/)를 참조하세요.

## 상태비저장 응답(HTTP 및 SSE)

상태비저장(stateless) 호출은 요청 하나에 응답 하나로 완결됩니다. 전체 입력을 담아 전송하면 완성된 응답 본문이 반환됩니다.

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Summarize this thread.", "store": false }'
```

실시간 스트리밍이 필요할 때는 요청 본문에 `"stream": true`를 추가하면 동일한 엔드포인트가 Server-Sent Events(SSE) 스트림으로 전환됩니다.

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "model": "primary", "input": "Draft a release note.", "stream": true }'
```

상태비저장 HTTP 및 SSE 경로로 상태보존용 필드(`previous_response_id`, `conversation`, `store`)를 전달하면 요청이 거부됩니다. 여러 턴에 걸쳐 대화를 이어 가려면 WebSocket 경로를 사용하세요.

## 기타 endpoint

| 엔드포인트 | 용도 |
|---|---|
| `GET /models` | 현재 호출 주체가 사용할 수 있는 모델 목록 조회 |
| `POST /embeddings` | 임베딩 벡터 생성 |
| `POST /rerank` | 문서 재정렬(rerank) |
| `POST /web_search` | 웹 검색 |
| `POST /web_fetch` | 웹 페이지 본문 가져오기 |

각 엔드포인트의 상세 규격은 [AIGateway](../ai-gateway/) 개념 문서와 관련 User guide 문서에서 확인할 수 있습니다.

## 이 가이드가 아닌 것

이 문서는 AIGateway 전체 사양서가 아닙니다. 전체 라우트 표, 상태보존(stateful) 응답의 수명 주기, 상세 오류 코드는 [AIGateway](../ai-gateway/)를 참조하세요. 또한 별도의 전용 클라이언트 SDK를 안내하는 문서도 아닙니다. Ankole은 독자적인 클라이언트 SDK를 배포하지 않으므로 표준 HTTP 클라이언트나 OpenResponses 호환 클라이언트로 REST API를 직접 호출하면 됩니다.

## 다음 단계

- 전체 AIGateway 인터페이스와 상태보존 규격은 [AIGateway](../ai-gateway/)를 참조하세요.
- Provider 해석과 요청 조립 과정은 [Provider Runtime](../provider-runtime/)을 참조하세요.
- 관리용 Console API 명세는 [Console API reference](../console-api/)를 참조하세요.
