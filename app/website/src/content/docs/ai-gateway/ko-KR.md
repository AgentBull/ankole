---
title: AIGateway API
description: OpenResponses 호환 AI 경계 — HTTP, SSE, WebSocket 엔드포인트, stateless·stateful 호출, provider 라우팅.
section: Developer guide
order: 101
---

AIGateway는 Ankole 배포 인스턴스의 통합 AI 호출 경계입니다. 외부 애플리케이션, 사내 시스템, SDK는 OpenResponses 호환 API로 AIGateway를 직접 호출하며, 내부 Agent 역시 모델 추론 턴을 실행할 때 동일한 인터페이스를 사용합니다. 모든 요청은 운영자가 구성한 provider 바인딩을 통해 모델 셀렉터를 해석하며, 업스트림 자격 증명은 컨트롤 플레인 외부로 절대 노출되지 않습니다.

이 문서에서는 실제 라우트와 요청 형식, 그리고 stateless 호출과 stateful 호출의 경계를 안내합니다. 정확한 세부 사양의 기준(source of truth)은 컨트롤 플레인 라우터와 `Ankole.AIGateway` 모듈이며, 이 문서는 전체 흐름을 파악하기 위한 안내 지도입니다.

## 위치

AIGateway는 호출자와 업스트림 provider 사이에 위치합니다. 외부 연동 시스템, OIDC로 인증된 사용자(Human), Worker 측 Agent 모델 루프는 HTTP, SSE, WebSocket으로 bearer 토큰과 함께 요청을 보내며, `Ankole.Brain`이나 `Function Runtime` 같은 컨트롤 플레인 내부 서브시스템은 내장 `system` Principal(`ankole_brain`, `system`) 명의로 프로세스 안에서 직접 `Ankole.AIGateway`를 호출합니다. 모든 호출에서 AIGateway가 모델 셀렉터를 해석해 요청을 조립한 뒤 연결된 provider로 전달하고 단일 JSON 본문이나 스트림을 반환합니다. LLM, 임베딩, 리랭크, 웹 검색, 웹 페이지 읽기 기능이 모두 이 경계를 거칩니다. 또한 응답 턴에서 `programmatic_tool_calling`을 사용하는 경우, AIGateway는 `Ankole.FunctionRuntime.ProgramRunner`를 통해 `ankole-function-runtime`의 stateless isolate에서 각 `programmatic_tool_call`의 TypeScript 프로그램을 실행합니다.

핵심 원칙은 명확합니다. 컨트롤 플레인이 자격 증명과 라우팅 정책을 전담 관리하므로 호출자는 업스트림 provider 자격 증명을 볼 수 없으며, 오직 자신의 호출 주체와 모델 셀렉터만 다룹니다.

## 인증

`/api/v1/ai-gateway` 하위 HTTP 및 WebSocket 엔드포인트는 모두 `:ai_gateway_api` 파이프라인과 `RequireAIGatewayAccessToken` 플러그를 거칩니다. 네트워크 호출자는 `Authorization` 헤더에 bearer 토큰을 담아 보내야 하며, 다음 두 종류의 토큰만 허용됩니다.

- **Agent token** — 활성 Agent Principal을 주체(subject)로 하는 AIGateway API 키입니다. 호출 범위는 해당 Agent의 유효 모델 프로필과 셀렉터로 제한되며 `subject_type = "agent"`로 동작합니다.
- **OIDC Human token** — `ai_gateway.write` 권한을 가진 OIDC Client가 활성 사용자(Human)에게 발급한 토큰입니다. 해당 Client에 설정된 모델 별칭(model alias)만 호출할 수 있으며 `subject_type = "oidc_human"`으로 동작합니다.

컨트롤 플레인의 퍼스트파티 서비스(Company Brain 작업을 수행하는 `ankole_brain`과 무상태 Pod Applet `ctx.ai` 호출을 수행하는 `system`)는 외부 bearer 토큰을 발급하지 않고 BEAM 프로세스 내부에서 직접 `Ankole.AIGateway`를 호출하며, 사용량은 각 `system` Principal UID로 집계됩니다.

OIDC Human 토큰을 사용하려면 먼저 Console에서 `ai_gateway.write` 스코프를 가진 OIDC Client를 생성하고 허용할 그룹과 모델 별칭을 지정합니다. 이후 사용자는 PKCE를 적용한 Authorization Code 흐름으로 로그인하며, 장기 세션이 필요하면 `offline_access`를 요청해 순환 갱신되는(rotating) Refresh Token을 사용합니다. 사용자는 반드시 허용된 그룹에 속해 있어야 하며 해당 Client에 등록된 모델 별칭만 지정할 수 있고, 원시 `provider_id/model` 형식의 셀렉터는 직접 사용할 수 없습니다.

토큰이 누락되었거나 검증에 실패하면 `code: "invalid_token"`과 함께 `401` 응답을 반환하며, 익명 호출 경로는 지원하지 않습니다.

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"Summarize the open incidents."}'
```

## 엔드포인트

모든 라우트는 `/api/v1/ai-gateway` 아래에 열려 있습니다. 각 엔드포인트의 전송 방식(Transport)은 단순한 권장 사항이 아니라 API 계약의 일부입니다.

| 메서드 | 경로 | Transport | 용도 |
|---|---|---|---|
| `GET` | `/models` | HTTP | 현재 주체(subject)가 사용할 수 있는 모델 셀렉터 목록 조회 |
| `POST` | `/responses` | HTTP 또는 SSE | 응답 생성(`"stream": true` 지정 시 스트리밍 전환) |
| `GET` | `/responses` | WebSocket | 상태 보존형(stateful) 스트리밍 응답 |
| `GET` | `/responses/:response_id` | HTTP | 저장된 stateful 응답(`resp_{uuid}`) 단건 조회 |
| `POST` | `/embeddings` | HTTP | 임베딩 벡터 생성 |
| `POST` | `/rerank` | HTTP | 문서 재정렬(rerank) |
| `POST` | `/web_search` | HTTP | 웹 검색 |
| `POST` | `/web_fetch` | HTTP | 웹 페이지 본문 가져오기 |
| `POST` | `/decisions` | HTTP | 상태에 대한 유형 지정 질문에 확률과 함께 답변 |
| `POST` | `/images` | HTTP | 이미지 한 장 생성 또는 편집 |
| `POST` | `/audio/speech` | HTTP | 텍스트를 음성으로 변환 |
| `POST` | `/audio/transcriptions` | HTTP | 오디오를 텍스트로 변환 |
| `POST` | `/ocr` | HTTP | PDF 또는 문서 이미지를 Markdown으로 읽기 |
| `GET/POST/DELETE` | `/files`, `/files/:id`, `/files/:id/content` | HTTP | 파일 업로드, 조회, 다운로드, 삭제 |

이 인터페이스의 중심은 `POST /responses`입니다. 실제 모델 턴을 수행하며, 전송 프로토콜과 상태 보존 여부에 따라 동작이 분기하는 유일한 경로입니다.

## HTTP와 SSE의 stateless 응답

stateless 호출은 단일 요청-단일 응답으로 완결됩니다. 호출자가 전체 `input`을 담아 보내면 AIGateway가 셀렉터를 해석하고 업스트림 provider를 호출한 뒤 완성된 JSON 본문을 반환합니다. 요청에 `"stream": true`를 지정하면 동일한 엔드포인트가 Server-Sent Events(SSE) 모드로 전환되어 `event: <type>\ndata: <json>\n\n` 형식의 이벤트를 순차 전송하고 마지막에 `data: [DONE]`으로 스트림을 닫습니다.

```bash
curl -N https://ankole.example.com/api/v1/ai-gateway/responses \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"main","input":"Draft a release note.","stream":true}'
```

stateless HTTP와 SSE 경로에는 엄격한 제약이 있습니다. 상태 보존용 필드인 `previous_response_id`, `conversation`, `store`를 포함하면 즉시 거부됩니다. 여러 턴에 걸쳐 대화 상태를 이어 가야 하는 요청은 반드시 WebSocket 경로를 사용해야 합니다. HTTP나 SSE 요청에 stateful 필드를 넣으면 문제가 된 필드 이름과 함께 `code: "stateful_responses_require_websocket"` 오류 및 `400` 상태 코드가 반환됩니다.

## WebSocket의 stateful 응답

상태 보존형(stateful) 응답은 `GET /responses` 요청을 WebSocket으로 업그레이드하여 사용합니다. 업그레이드가 성립하면 컨트롤 플레인은 호출 주체의 identity, 30분 유휴 타임아웃(idle timeout), 프레임 압축, 128 MiB 최대 프레임 크기 제한을 적용해 연결을 `AIGatewayResponsesSocket`으로 인계합니다. 클라이언트는 모델 응답을 기다리는 동안 별도의 프레임을 보내지 않으므로, 이 30분 유휴 타임아웃이 단일 응답에 허용되는 최대 대기 시간이자 업스트림 모델의 첫 바이트 및 유휴 제한 시간과 동일하게 동작합니다. 이 WebSocket 연결에서는 `store: true`를 설정하고 `previous_response_id`나 `conversation`을 지정해 이전 대화를 그대로 이어 갈 수 있습니다.

대화 상태의 영구 수명 주기는 모두 이 경로에서 관리됩니다. 저장된 각 응답에는 `resp_{uuid}` 형식의 ID가 부여되며, 후속 턴에서는 `previous_response_id`로 직전 응답을 가리키거나 `conversation`으로 저장된 대화 스레드를 참조합니다. 연속성 검증, 영구 전사 기록, 컨텍스트 압축(compaction), 응답 투영, 장애 복구는 전적으로 컨트롤 플레인이 처리하므로 호출자가 직접 구현할 필요가 없습니다.

저장된 응답은 나중에 일반 HTTP 요청으로도 조회할 수 있습니다.

```bash
curl https://ankole.example.com/api/v1/ai-gateway/responses/resp_4f3c... \
  -H "Authorization: Bearer $AIGATEWAY_TOKEN"
```

긴 대화 이력을 맥락 손실 없이 짧은 요약 상태로 압축할 때는 별도의 전용 엔드포인트 대신 `compaction` 기능을 사용합니다. 요청 `input`에 `{"type": "compaction_trigger"}` 항목을 넣어 보내면 AIGateway가 `compaction` 타입의 출력 항목 하나를 반환합니다. 이 기능은 모든 전송 방식에서 동일하게 작동하여 일반 `POST /responses`에서는 JSON 본문으로, `"stream": true`에서는 SSE 이벤트로, WebSocket에서는 소켓 이벤트로 결과를 돌려줍니다. 트리거만 단독으로 보내면 `previous_response_id`나 `conversation`이 가리키는 저장된 대화를 압축하고 다음 턴에서 이어 쓸 체크포인트 ID를 반환하며, 대화 이력을 `input`에 함께 담아 보내면 전달된 이력 자체를 압축합니다.

## Provider 라우팅

AIGateway는 업스트림 API를 호출하기 전에 **Console → Model Profiles**에서 구성하는 3계층 희소 **모델 프로필(Model Profile)** 상속 체인(`Site -> Pod -> Agent/System`)에 따라 모델 셀렉터를 해석합니다.

- **Site, Pod 및 `system` Principal(`ankole_brain`, `system`)**은 13개의 고정 슬롯을 제공합니다. 5개는 언어 모델 슬롯(`primary`, `light`, `heavy`, `coding`, `vision_fallback`)이고 8개는 전용 capability 슬롯(`web_search`, `web_fetch`, `image_generate`, `rerank`, `decision`, `speech`, `transcription`, `ocr`)입니다.
- **Agent**는 `rerank`, `decision`, `speech`, `transcription`, `ocr`을 제외한 8개 기본 슬롯과 사용자 지정 언어 모델 별칭을 제공하며, 비워 둔 슬롯은 Pod와 Site 기본값을 자동으로 상속합니다.
- **슬롯 간 폴백**은 `coding -> heavy -> primary` 및 `light -> primary` 순서로 해석되므로 Site나 Pod에 `primary`만 구성해도 Agent와 Brain이 바로 동작하며, 필요한 경우에만 Pod·Agent·`system` Principal 단위로 개별 재정의할 수 있습니다.

권한이 허용된 관리자와 내부 호출자는 명시적 `provider_id/model` 셀렉터도 직접 지정할 수 있습니다. `GET /models`를 호출하면 현재 주체가 사용할 수 있는 셀렉터 목록이 반환되며, OpenRouter 스타일의 검색 필터(`q`, `context`, `min_price`, `max_price`, `sort`, 모달리티 필터)를 선택적으로 전달할 수 있습니다.

각 provider 행은 자체 자격 증명 풀(credential pool)을 보유하며, 풀에 속한 모든 자격 증명은 동일한 provider 종류, 기본 URL, 헤더, 공통 설정, 지원 capability 선언을 공유합니다. 모델 프로필은 특정 풀 항목이 아니라 provider 행 자체를 가리키며, 런타임에 AIGateway가 설정된 분배 전략(`fill_first`, `round_robin`, `least_used`, `random`)에 따라 정상 상태인 자격 증명을 선택합니다. Console 화면에서는 이 전략 이름을 현재 UI 언어로 번역해 보여 주지만, API와 데이터베이스는 정규 영문 키를 그대로 사용합니다. stateful 대화 스레드는 가능한 한 처음 선택된 자격 증명을 계속 유지합니다.

호출 도중 특정 자격 증명에 귀속되는 `429`, `5xx`, 또는 전송 오류가 발생하면 AIGateway는 해당 자격 증명에만 쿨다운을 걸고, 풀에서 다른 정상 자격 증명을 골라 요청을 다시 조립한 뒤 지수 백오프와 지터(jitter)를 적용해 정해진 횟수 안에서 재시도합니다. 이때 Rust 커널은 한 번에 단일 전송만 수행합니다. 만약 풀 안의 가용 자격 증명이 모두 소진되면 임의로 다른 provider로 우회(fallback)하지 않고 오류를 반환합니다.

`chatgpt_subscription` 역시 동일한 구조의 일반 provider 종류입니다. OAuth 자격 증명은 컨트롤 플레인 내부에만 보관되며 토큰 갱신은 데이터베이스 행 잠금(row lock) 아래에서 안전하게 수행되므로, Agent Computer나 외부 호출자에게 원본 토큰이 전달되지 않습니다.

`agentbull_cloud`(**AgentBull Cloud**, 기본 base URL `https://cloudapis.agentbull.com`)는 단일 API 키로 언어 모델, 임베딩, 리랭크, `web_search`, `web_fetch`, `image_generate` 기능을 모두 제공하는 내장 통합 provider입니다. 이 자격 증명 또한 컨트롤 플레인에만 보관되며, 외부 플랫폼 연결과 개인 OAuth 토큰, Skill이 선언한 원격 MCP 인증 헤더는 컨트롤 플레인의 `Ankole.Connectors` MCP 게이트웨이가 PostgreSQL에서 통합 관리합니다(`WorkerEnv`는 Agent Computer 내부의 사용자 지정 CLI 및 스크립트 환경 변수에 사용합니다).

셀렉터 해석 단계에서 발생할 수 있는 대표적인 구성 오류는 다음 두 가지입니다.

- `422 unknown_model_selector` — 요청한 셀렉터가 현재 주체(subject)에 바인딩되어 있지 않습니다.
- `422 model_binding_not_configured` — 기능 이름과 프로필은 존재하지만 연결된 provider 바인딩 구성이 불완전합니다.

연결된 provider가 요청한 기능을 지원하지 않으면 `422 unsupported_capability`가 반환되고, 운영자가 비활성화해 둔 provider를 가리키면 `422 provider_disabled`가 반환됩니다. 이러한 `422` 응답은 일시적인 네트워크 장애가 아니라 설정 문제이므로, 설정을 수정하지 않은 채 재시도해도 결과는 바뀌지 않습니다.

## 오류 형태

모든 오류 응답은 `{"error": {"code", "message"}}` 형태의 OpenAI 호환 봉투(envelope) 형식을 따르며, 실패 유형에 맞는 HTTP 상태 코드를 반환합니다. 클라이언트 구현 시 대비해야 할 주요 상태 코드는 다음과 같습니다.

- `400` — 요청 본문 검증 실패입니다. `model` 또는 `input` 누락, 잘못된 `limit`이나 `top_n` 값, 일반 HTTP 요청에 포함된 stateful 필드, 형식이 잘못된 compaction 입력 등이 해당하며 `code`에서 원인 필드를 알려 줍니다.
- `401` — bearer 토큰이 없거나 유효성을 검증할 수 없습니다.
- `429` — 선택한 provider의 자격 증명 풀이 모두 소진되었습니다. 오류 코드는 `credential_pool_exhausted`이며, 가장 빠른 쿨다운 해제 시점을 알 수 있는 경우 `retry_at` 시각이 함께 제공됩니다.
- `404` — 요청 주체 범위 안에서 지정한 저장 응답, 대화, Agent, 또는 파일을 찾을 수 없습니다.
- `422` — 요청 문법은 올바르지만 알 수 없는 셀렉터, 미완성 바인딩, 미지원 capability, 비활성 provider 등의 구성 문제로 컨트롤 플레인이 실행할 수 없습니다.
- `502` / `504` — 업스트림 provider 호출 실패입니다. `502`는 전송 오류나 비정상 응답(`upstream_transport_failed`, `invalid_upstream_response`, `ai_gateway_request_failed`)을 나타내고, `504`는 업스트림 응답 지연(`upstream_timeout`)을 나타냅니다. 업스트림 provider가 반환한 클라이언트 측 `4xx` 오류는 해당 상태 코드 그대로 전달됩니다.

업스트림 응답에 `error.message`가 들어 있으면 AIGateway가 그 메시지를 그대로 전달하고, 없으면 업스트림 HTTP 상태 정보를 반환합니다.

## 프로그래밍 방식 도구 호출 및 이미지 생성

`/responses` 요청에서 `programmatic_tool_calling` 도구를 선언하면 AIGateway는 대상 도구 명세들을 묶어 합성된 `program` 도구를 노출합니다. 모델이 `programmatic_tool_call`을 호출하면 AIGateway는 `Ankole.FunctionRuntime.ProgramRunner`를 통해 `ankole-function-runtime`의 stateless isolate에서 결정론적 TypeScript 프로그램을 실행하며, 중첩된 개별 도구 호출 경계에서 일시 중단했다가 재개하면서 실행 기록, 순서 보장, 취소를 직접 관리합니다.

공용 Responses 도구인 `image_generation`은 두 가지 경로 중 하나로 실행됩니다. 호출 주체에 별도의 `image_generate` 프로필이 설정되어 있으면 AIGateway가 해당 전용 provider와 모델을 호출해 이미지를 생성합니다. 별도 프로필이 없는 경우에는 주 언어 모델 provider가 네이티브 이미지 생성을 지원한다고 선언했을 때만 도구를 업스트림으로 전달합니다. 두 경로 모두 사용할 수 없으면 도구를 흉내 내어 처리하는 대신 요청 준비 단계에서 즉시 오류를 반환합니다.

어느 경로로 실행되든 동일한 공용 스트림 이벤트가 발행되고 생성된 이미지가 영구 저장되며, 모델 토큰 사용량과 이미지 생성 사용량은 각각 실제로 호출된 자격 증명에 정확히 귀속됩니다.

## Web tool, 파일, 그 밖의 capability

동일한 주체와 bearer 토큰으로 보조 AI 엔드포인트들도 호출할 수 있습니다. `POST /web_search`는 길이 제한이 있는 `query`를 받아 검색 결과를 반환하고, `POST /web_fetch`는 1~5개의 공개 HTTPS URL을 받아 본문 콘텐츠를 추출해 반환합니다. 두 엔드포인트에서는 `web_search.default`와 `web_fetch.default` 셀렉터를 지정할 수 있으며, 이 경우 AIGateway가 호출한 Agent의 현재 프로필 설정을 자동으로 찾아 연결합니다.

`POST /embeddings`는 문자열, 토큰 배열, 구조화된 입력 블록을 받아 임베딩을 생성하며 명시적인 `provider_id/model` 셀렉터를 요구합니다(예컨대 `Ankole.Brain`은 임베딩 생성 시 [AppConfigure](../app-configuration/)의 사이트 단위 설정 `brain.embedding_model`을 읽습니다). `POST /rerank`는 비어 있지 않은 문서 배열과 양의 정수 `top_n`을 받아 재정렬 결과를 반환하며, 명시적 `provider_id/model` 셀렉터 또는 `default` / `rerank.default`를 허용합니다(`ankole_brain`은 자신의 유효 `rerank` 모델 프로필을 해석하고, Agent 및 Human 호출은 Pod/Site `rerank` 프로필을 해석합니다. 검색 파이프라인의 상세 동작은 [Brain](../brain/)을 참조하세요). 한편 Pod Applet 내부의 `ctx.ai` 호출은 내장 `system` Principal 명의로 `Ankole.AIGateway`를 통해 stateless 방식으로 실행되며, 유효 Pod/Site 언어 모델 프로필(`primary`, `light`, `heavy`, `coding`, `vision_fallback`)을 사용하므로 포그라운드 Agent의 토큰 할당량을 소모하지 않습니다.

`POST /web_search`는 1,024자 이하의 `query`와 선택 항목인 `limit`(1~100, 기본값 5)를 받아 `items`와 `metadata`를 반환합니다. 각 결과에는 `url`, `title`, `description`이 들어 있으며, Provider가 제공하면 `published_at`과 `score`도 함께 담깁니다. `metadata`에는 `query`, 게이트웨이에서 걸린 시간 `latency_ms`, HTTP 요청의 `request_id`가 들어 있습니다. `POST /decisions`는 주어진 `state`에 대해 유형이 지정된 질문에 답합니다. 요청 하나에 1~64개의 `questions`를 담을 수 있고, 각 질문은 `noul`(예/아니요), `choice`(2~255개의 이름 있는 선택지 중 하나), `score`(2~10단계의 순서 있는 등급) 중 하나이며, 이미지는 장당 4 MiB 이하로 최대 4장까지 첨부할 수 있습니다. 응답은 질문마다 확률이 포함된 답과 함께 답한 `model`, 토큰 `usage`를 반환합니다. `default` / `decision.default` 셀렉터는 Pod/Site의 `decision` 프로필로 해석됩니다. 이 프로필이 설정되어 있지 않으면 호출자의 `light` 언어 모델이 대신 답하며, 언어 모델이 내놓는 값은 스스로 보고한 확신도이므로 이 확률은 보정되지 않습니다. 또한 언어 모델이 답할 때는 요청 하나에 선택지와 등급을 합쳐 500개까지만 담을 수 있습니다.

`decision` 프로필에서는 TypeSafe(`typesafe`, 기본 URL `https://api.typesafe.ai/v1`), Microsoft Foundry를 사용하는 Azure OpenAI(`azure_openai`), OpenRouter(`openrouter`), OpenAI(`openai`), Cloudflare(`cloudflare`)를 선택할 수 있습니다. TypeSafe의 `base_url`에는 다른 SystemOne 호환 엔드포인트도 지정할 수 있습니다. Azure Foundry는 구성한 배포 이름으로 `<resource-root>/providers/microsoft/v1/systemone`을 호출하고, OpenAI는 `gpt-6-luna`로 `/decisions`를 호출합니다. TypeSafe, Azure Foundry, OpenRouter가 사용하는 SystemOne 프로토콜은 PNG와 JPEG 자산만 받아들이며 WebP는 지원하지 않습니다. Microsoft-Decision-1은 이미지를 받아들이지 않습니다. OpenAI Decisions는 PNG, JPEG, WebP를 지원합니다. OpenAI가 질문 하나라도 거부하면 AIGateway는 부분 답변을 반환하지 않고 전체 요청을 `422 upstream_decision_refusal`로 거부합니다.

`POST /images`는 대화 밖에서 이미지 한 장을 생성하거나 편집합니다. 요청에는 `model`(`image_generate.default`, `default` 또는 명시적인 `provider_id/model`), `prompt`, 선택 항목인 참조 이미지 `images`와 `mask`, 그리고 `size`, `quality`, `output_format` 같은 `image_generation` 도구 옵션을 담습니다. 요청은 선택한 이미지 Provider로 바로 전달됩니다. OpenRouter와 AgentBull Cloud는 각자의 카탈로그에 있는 이미지 모델을, Cloudflare는 FLUX.1 [schnell]과 Black Forest Labs 모델을 제공합니다. 응답은 `created`, 이미지를 `b64_json`과 `media_type`으로 담은 `data` 한 건, 그리고 Provider의 `usage`를 반환합니다. AIGateway는 생성한 이미지와 결정 모델 호출을 한 건씩 사용량 원장에 기록하며, Agent 토큰 할당량과 Console의 모델 사용량 페이지는 언어 모델 라운드만 집계합니다.

`POST /audio/speech`는 `input` 텍스트를 음성으로 변환합니다. 요청에는 `model`(`speech.default`, `default` 또는 명시적인 `provider_id/model`)을 담고, 필요하면 `voice`, `response_format`(`mp3` 또는 `pcm`, 기본값 `mp3`), `speed`, 말투를 지시하는 `instructions`를 함께 지정할 수 있습니다. 응답 본문은 오디오 자체입니다. 콘텐츠 유형은 Provider가 알려 준 오디오 유형을 따르며, Provider가 알려 주지 않으면 `mp3`는 `audio/mpeg`, `pcm`은 `audio/pcm`이 됩니다. OpenRouter는 카탈로그에 있는 음성 합성 모델을, Cloudflare는 Deepgram Aura 모델을 제공합니다. Deepgram Aura 모델은 MP3를 반환하며 `pcm`, `speed`, `instructions`를 받지 않습니다. `POST /audio/transcriptions`는 오디오를 텍스트로 변환합니다. 요청에는 `model`(`transcription.default`, `default` 또는 명시적인 `provider_id/model`)과 `input_audio`를 담습니다. `input_audio`에는 base64로 인코딩한, 디코딩 후 25 MiB 이하의 `data`와 그 `format`이 들어가며, 필요하면 `language`, `vad_filter` 플래그, `response_format`(`json` 또는 `verbose_json`, 기본값 `json`)을 추가할 수 있습니다. 응답은 `model`, `text`, 그리고 오디오 길이를 `seconds`로 담은 `usage`를 반환하며, `verbose_json`을 지정하면 `language`, `duration`, 시간 정보가 붙은 `segments`가 추가됩니다. OpenRouter는 카탈로그에 있는 음성 인식 모델을, Cloudflare는 `@cf/openai/whisper-large-v3-turbo`처럼 base64 오디오를 받는 Workers AI 모델을 제공합니다. 두 엔드포인트 모두 폴백이 없으므로, 해당 프로필을 바인딩하기 전까지 요청은 `model_profile_not_configured`로 실패합니다. AIGateway는 음성 합성 호출을 글자 수와 함께, 음성 인식 호출을 오디오 초 수와 함께 한 건씩 사용량 원장에 기록합니다.

`POST /ocr`는 PDF 또는 문서 이미지를 페이지별로 Markdown으로 읽어 냅니다. 요청에는 `document`를 담습니다. `document`는 PDF 또는 PNG, JPEG, WebP 이미지 한 장이며, base64 data URL로 보내거나 `content_type`과 `base64`를 가진 객체로 보냅니다. AIGateway는 50 MiB 이하의 PDF와 20 MiB 이하의 이미지를 받으며, 두 상한 모두 디코딩 후 크기를 기준으로 합니다. OCR 모델이 받는 크기는 이보다 작을 수 있습니다. PDF라면 `pages`에 0부터 시작하는 페이지 인덱스를 중복 없이 1~100개 지정할 수 있습니다. 요청에서 `pages`를 생략하면 AIGateway는 OCR 모델에 페이지 인덱스를 보내지 않습니다. 응답은 `model`, `pages`, 그리고 `usage`를 반환하며, `usage`에는 읽은 페이지 수가 `pages`로 담깁니다. `pages`의 각 항목에는 Provider가 보고한 `index`와 그 페이지의 `markdown`이 담기고, 텍스트가 없는 페이지는 `markdown`이 비어 있습니다. AIGateway는 페이지를 `index` 순으로 정렬합니다. `default` / `ocr.default` 셀렉터는 Pod/Site의 `ocr` 프로필로 해석되며, 이 프로필의 OCR 모델은 Mistral Provider가 제공합니다. 이 프로필이 설정되어 있지 않으면 이미지 입력을 지원하는 언어 모델이 대신 문서를 읽습니다. 호출자의 `vision_fallback` 프로필을 사용하고, 그 프로필도 설정되어 있지 않으면 `primary`를 사용합니다. 언어 모델은 이미지 한 장만 읽을 수 있으므로 PDF를 보내면 `unsupported_value`로 실패합니다. 또한 언어 모델이 읽은 요청은 일반 언어 모델 요청으로 집계됩니다. AIGateway는 OCR 모델 호출을 페이지 수와 함께 한 건씩 사용량 원장에 기록합니다.

파일 관리 역시 일급 API로 제공됩니다. `POST /files`로 업로드하고, `GET /files`로 목록을 조회하며, `GET /files/:id`와 `GET /files/:id/content`로 메타데이터와 파일 바이트를 읽고, `DELETE /files/:id`로 삭제합니다. 모든 파일 작업은 호출 주체(subject) 범위로 격리됩니다.

## AIGateway가 아닌 것

AIGateway는 인증 없이 열려 있는 공개 프록시가 아니며, 클라이언트가 직접 업스트림 API 키를 실어 보내는 패스스루 게이트웨이도 아닙니다. 모든 업스트림 자격 증명은 컨트롤 플레인 내부에 머뭅니다. 또한 비동기 작업 큐나 백그라운드 잡 러너도 아니므로, 장시간 이어지는 Agent 업무는 Sessions와 Background Agent Jobs에서 담당합니다. AIGateway는 어디까지나 명확한 요청/응답 경계로서, 요청 하나가 들어오면 셀렉터를 해석하고 자격 증명을 안전하게 보호한 채 단일 응답이나 스트림을 돌려줍니다.

## 다음 단계

- 전체 시스템 안에서 AIGateway의 위치를 파악하려면 [아키텍처 개요](../architecture/)를 참조하세요.
- 이 엔드포인트를 호스팅하는 서버 구동 방법은 [빠른 시작의 deployment 섹션](../quickstart/#deployment)을 참조하세요.
- 첫 Provider 등록과 모델 프로필 구성은 [빠른 시작](../quickstart/#llm-providers)을 참조하세요.
