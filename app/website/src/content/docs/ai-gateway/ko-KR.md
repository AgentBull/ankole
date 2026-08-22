---
title: AIGateway API
description: OpenResponses 호환 AI 경계 — HTTP, SSE, WebSocket 엔드포인트, stateless·stateful 호출, provider 라우팅.
section: Developer guide
order: 101
---

AIGateway는 Ankole deployment instance의 통합 AI 경계입니다. 외부 애플리케이션, 엔터프라이즈 시스템, SDK는 OpenResponses 호환 API를 통해 직접 호출하며, 내부 Agent도 모델 턴을 위해 같은 surface를 호출합니다. 모든 호출은 운영자가 구성한 provider binding에 대해 모델 셀렉터를 해석하며, 업스트림 credential은 컨트롤 플레인을 벗어나지 않습니다.

이 페이지는 실제 route, 요청 형태, 그리고 stateless 호출과 stateful 호출 사이의 경계를 다룹니다. 실제 기준(source of truth)은 컨트롤 플레인 router와 `Ankole.AIGateway` 모듈입니다. 이 페이지는 지도이지 contract가 아닙니다.

## 위치

AIGateway는 호출자와 provider 사이에 있습니다. 호출자 — Agent의 모델 루프, Console 운영자, 또는 외부 통합 — 는 bearer token을 제시하고 OpenResponses 형태의 요청을 보냅니다. AIGateway는 셀렉터를 해석하고, 요청을 준비하며, 바인딩된 provider로 보내고(fan-out), 단일 JSON body 또는 스트림을 반환합니다. LLM, embedding, rerank, web search, web fetch capability가 모두 같은 경계를 통과합니다.

결정적인 속성: 호출자는 provider credential을 결코 볼 수 없습니다. 컨트롤 플레인이 credential과 라우팅 정책을 소유하고, 호출자가 소유하는 것은 자신의 token과 셀렉터뿐입니다.

## 인증

`/api/v1/ai-gateway` 아래의 모든 엔드포인트는 `:ai_gateway_api` pipeline과 `RequireAIGatewayAccessToken` plug를 통과합니다. 요청은 `Authorization` 헤더에 bearer token을 제시해야 하며, plug는 정확히 두 종류를 받습니다:

- **an agent token** — subject가 활성 Agent Principal인 AIGateway API key입니다. 호출은 해당 Agent의 모델 binding과 셀렉터로 제한되며 `subject_type = "agent"`입니다.
- **an admin token** — 활성 인간 관리자의 Console token입니다. 호출은 운영자의 provider 보기로 제한되며 `subject_type = "admin_human"`입니다.

토큰이 없거나 검증할 수 없으면 `code: "invalid_token"`과 함께 `401`을 반환합니다. 익명 경로는 없습니다.

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"Summarize the open incidents."}'
```

## 엔드포인트

모든 route는 `/api/v1/ai-gateway` 아래에 있습니다. 엔드포인트가 사용하는 transport는 contract의 일부이지 선호가 아닙니다.

| 메서드 | 경로 | Transport | 용도 |
|---|---|---|---|
| `GET` | `/models` | HTTP | 이 subject에 보이는 모델 셀렉터 나열 |
| `POST` | `/responses` | HTTP 또는 SSE | 응답 생성. `"stream": true`이면 스트리밍 |
| `GET` | `/responses` | WebSocket | stateful 스트리밍 응답 |
| `GET` | `/responses/:response_id` | HTTP | 저장된 stateful 응답(`resp_{uuid}`) 조회 |
| `POST` | `/embeddings` | HTTP | embedding 생성 |
| `POST` | `/rerank` | HTTP | 문서 rerank |
| `POST` | `/web_search` | HTTP | 웹 검색 |
| `POST` | `/web_fetch` | HTTP | 웹 페이지 가져오기 |
| `GET/POST/DELETE` | `/files`, `/files/:id`, `/files/:id/content` | HTTP | 파일 업로드, 읽기, 삭제 |

`POST /responses`는 이 surface의 중심입니다. 모델 턴을 전달하며 transport와 상태에 따라 분기하는 유일한 엔드포인트입니다.

## HTTP와 SSE의 stateless 응답

stateless 호출은 요청 하나, 응답 하나입니다. 호출자가 전체 input을 보내면 AIGateway가 셀렉터를 해석하고 provider를 호출한 뒤 전체 body를 반환합니다. `"stream": true`를 설정하면 같은 엔드포인트가 Server-Sent Events로 전환됩니다. AIGateway는 SSE 스트림을 열어 `event: <type>\ndata: <json>\n\n` 형태의 타입 이벤트를 쓰고 `data: [DONE]`으로 끝냅니다.

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"Draft a release note.","stream":true}'
```

stateless HTTP와 SSE는 한 가지 엄격한 규칙을 공유합니다. stateful 필드인 `previous_response_id`, `conversation`, `store`를 거부한다는 것입니다. 턴을 넘어 계속 이어져야 하는 요청은 WebSocket 경로를 사용해야 합니다. HTTP나 SSE로 stateful 필드를 보낸 요청에는 `code: "stateful_responses_require_websocket"`와 문제가 되는 필드를 명시한 메시지와 함께 `400`이 반환됩니다.

## WebSocket의 stateful 응답

stateful 응답은 WebSocket으로 업그레이드된 `GET /responses`에 있습니다. 업그레이드는 subject의 identity, 300초의 idle timeout, 압축, 128 MiB 프레임 상한과 함께 연결을 `AIGatewayResponsesSocket`에 넘깁니다. 이 transport에서는 호출이 `store: true`를 설정하고 `previous_response_id` 또는 `conversation`으로 기존 대화를 이어갈 수 있습니다.

내구성 있는 수명 주기가 여기에 있습니다. 저장된 응답은 `resp_{uuid}` 형태의 id를 받습니다. 이후 턴은 `previous_response_id`로 그것을 참조하고, 저장된 대화는 `conversation`으로 참조합니다. 연속 규칙, 내구성 있는 기록, compaction, 응답 projection, 복구는 모두 컨트롤 플레인이 소유하며, 어느 것도 호출자의 책임이 아닙니다.

저장된 응답은 나중에 stateless 방식으로 평범한 HTTP에서 조회할 수 있습니다:

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses/resp_4f3c... \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN"
```

compaction은 흐름을 잃지 않고 긴 저장 기록을 짧은 기록으로 교환하는 유일한 도구입니다. 전용 endpoint가 없습니다. input에 `{"type": "compaction_trigger"}` 항목을 넣은 요청을 보내면 AIGateway가 `compaction` output 항목 하나를 돌려줍니다. 모든 transport에서 동작합니다. `POST /responses`는 body를 반환하고, 같은 호출에 `"stream": true`를 더하면 SSE event로, WebSocket도 같은 event로 반환합니다. trigger만 보내면 `previous_response_id` 또는 `conversation`이 가리키는 저장된 대화를 compaction하고, 응답에는 이어서 사용할 checkpoint id가 담깁니다. 기록을 함께 보내면 보낸 내용을 compaction합니다.

## Provider 라우팅

AIGateway는 업스트림 호출 전에 모델 셀렉터를 실제 provider binding으로 해석합니다. 셀렉터는 호출자가 보는 것입니다. 예를 들어 `main` 또는 provider가 소유한 명시적 이름이며, 해석은 subject에 따라 달라집니다. Agent의 셀렉터는 구성된 모델 binding에서 나오고, admin은 명시적 provider 항목을 봅니다. `GET /models`는 현재 subject가 해석할 수 있는 것을 나열하며 OpenRouter 스타일 필터(`q`, `context`, `min_price`, `max_price`, `sort`, modality 필터)를 선택적으로 받습니다.

각 provider 행은 credential 풀을 소유합니다. provider kind, base URL, 헤더, 설정, capability 선언은 모든 멤버가 공유합니다. 모델 profile은 행을 가리키며 풀 멤버를 지명하지 않습니다. AIGateway는 구성된 `fill_first`, `round_robin`, `least_used`, `random` strategy에 따라 정상 멤버를 선택합니다. Console은 선택된 UI 언어에 맞춰 이 strategy 이름들을 번역하며, API와 저장된 값은 그대로 유지됩니다. stateful thread는 가능하면 같은 멤버에 머무릅니다.

귀속된 `429`, `5xx`, 또는 transport 실패는 요청을 만든 credential만 쿨다운합니다. AIGateway는 다른 멤버를 선택하고 provider 요청을 다시 구성한 뒤 지수 백오프와 지터가 있는 유계(bounded) 재시도를 수행합니다. Rust kernel은 한 번에 하나의 transport 시도만 수행합니다. 풀이 비어 있으면 AIGateway는 다른 provider로 전환하지 않습니다.

`chatgpt_subscription`은 평범한 provider kind입니다. 그 OAuth credential은 컨트롤 플레인에 남으며, 토큰 갱신은 row lock 아래에서 실행됩니다. Agent Computer와 외부 호출자는 이 토큰들을 받지 않습니다.

해석은 호출자가 처리해야 하는 두 가지 방식으로 실패할 수 있습니다:

- `422 unknown_model_selector` — 이 subject에 셀렉터가 바인딩되어 있지 않습니다.
- `422 model_binding_not_configured` — capability와 이름은 바인딩되었지만 provider binding이 완전하지 않습니다.

바인딩된 provider가 제공하지 않는 capability는 `422 unsupported_capability`로 나타납니다. 운영자가 비활성화한 provider는 `422 provider_disabled`로 나타납니다. 이것들은 일시적인 문제가 아니라 구성 문제입니다. 구성을 바꾸지 않고 재시도해도 해결되지 않습니다.

## 오류 형태

오류는 OpenAI 호환 envelope을 사용합니다. body는 `{"error": {"code", "message"}}`이고 HTTP 상태는 실패 클래스에 대응합니다. 계획에 포함할 만한 클래스는 다음과 같습니다:

- `400` — 요청 body 검증 실패: `model` 누락, `input` 누락, 잘못된 `limit` 또는 `top_n`, HTTP 위의 stateful 필드, 잘못된 형태의 compaction input. `code`가 필드를 지목합니다.
- `401` — bearer token이 없거나 검증할 수 없습니다.
- `429` — 선택된 provider의 credential 풀이 소진되었습니다. 오류 code는 `credential_pool_exhausted`이며, AIGateway가 가장 이른 복구 시각을 알 때 `retry_at`이 포함됩니다.
- `404` — 이 subject에 대해 저장된 응답, 대화, Agent, 파일을 찾지 못했습니다.
- `422` — 요청은 형식이 올바르지만 컨트롤 플레인이 처리할 수 없습니다: 알 수 없는 셀렉터, 구성되지 않은 binding, 지원되지 않는 capability, 비활성화된 provider.
- `502` / `504` — 업스트림 provider가 실패했습니다. `502`는 transport와 잘못된 응답 실패(`upstream_transport_failed`, `invalid_upstream_response`, `ai_gateway_request_failed`)를 포함하고, `504`는 `upstream_timeout`입니다. provider의 클라이언트 `4xx`는 그 자체 상태로 그대로 전달됩니다.

업스트림이 `error.message`를 반환하면 AIGateway는 그 메시지를 전달합니다. 그 외에는 업스트림 HTTP 상태를 그대로 보고합니다.

## 이미지 생성

`image_generation`은 두 가지 실행 경로가 있는 공용 Responses tool입니다. subject가 `image_generate` profile을 가지면 AIGateway는 그 별도의 provider와 모델로 tool을 실행합니다. profile이 없으면 AIGateway는 메인 provider가 네이티브 이미지 생성을 선언한 경우에만 tool을 전달합니다. 두 경로가 모두 없으면 tool을 흉내 내는 대신 요청 준비가 실패합니다.

두 경로 모두 같은 공용 스트림 이벤트와 생성 이미지 영속화를 사용합니다. 모델 사용량과 이미지 사용량은 각 부분을 만든 credential에 귀속됩니다.

## Web tool, 파일, 그 밖의 capability

같은 subject와 token이 인접한 capability를 구동합니다. `POST /web_search`는 `query`(길이 제한 있음)를 받아 provider가 뒷받침하는 결과를 반환하고, `POST /web_fetch`는 1개에서 5개의 공용 HTTPS URL을 받아 페이지 콘텐츠를 반환합니다. `POST /embeddings`는 텍스트, token 배열, 또는 input 블록을 받습니다. `POST /rerank`는 비어 있지 않은 문서 배열을 rerank하며 양의 정수 `top_n`을 받습니다. 각 요청은 `web_search.default`나 `web_fetch.default` 같은 capability별 semantic selector를 사용합니다. AIGateway는 호출이 도착할 때 현재 Agent profile을 해석합니다.

파일은 first-class입니다. `POST /files`가 업로드하고, `GET /files`가 나열하며, `GET /files/:id`와 `GET /files/:id/content`가 메타데이터와 바이트를 읽고, `DELETE /files/:id`가 하나를 삭제합니다. 모두 subject 범위로 제한됩니다.

## AIGateway가 아닌 것

공개된 무인증 proxy가 아닙니다. provider credential을 보내는 곳도 아닙니다. 그 credential들은 컨트롤 플레인에 있습니다. queue나 job runner도 아닙니다. 오래 걸리는 Agent 작업은 Actor Runtime과 Background Agent Jobs에 속합니다. AIGateway는 요청/응답 경계입니다. 호출 하나가 들어오면 응답 하나 또는 스트림 하나가 나가고, 셀렉터는 해석되며 credential은 내부에 유지됩니다.

## 다음 단계

- AIGateway가 전체 시스템에서 어디에 있는지 보려면 [아키텍처 개요](../architecture/)를 읽으십시오.
- 이 route들을 호스팅하는 서버를 실행하려면 [빠른 시작의 deployment 섹션](../quickstart/#deployment)을 읽으십시오.
- 첫 Provider와 모델 profile 설정은 [빠른 시작](../quickstart/#llm-providers)을 읽으십시오.
