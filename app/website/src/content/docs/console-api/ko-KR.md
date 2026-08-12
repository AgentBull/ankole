---
title: Console API 참조
description: Console이 사용하는 /api/v1 REST API에 대한 참조. 인증, 리소스 라우트, 권한 부여 동작을 다룹니다.
section: Reference
order: 203
---

이 페이지는 Console API의 REST 참조입니다. 인증 게이트, `/api/v1` 아래의 라우트, 각 라우트의 권한 동작을 다룹니다.

결정적인 속성을 먼저 말하면, Console API는 무상태(stateless)이며 bearer 인증을 사용하고, 매 요청마다 호출자가 여전히 활성 관리자(admin)인지 다시 확인합니다. 사용자을 대신해 일하는 세션 쿠키는 없으며, 비활성화된 admin은 다음 로그인이 아니라 즉시 작동을 멈춥니다.

`/api/v1` 아래의 모든 라우트는 `:console_api` 파이프라인과 `RequireConsoleAccessToken` plug를 거칩니다. 이 plug는 모두 필수인 세 가지 독립 검사를 실행합니다.

1. 형식이 올바른 `Authorization: Bearer` 헤더;
2. 검증되는 console JWT;
3. JWT가 가리키는 principal이 여전히 활성 admin일 것.

성공하면 이후의 정책 검사를 위해 principal과 claims를 conn assigns로 보관합니다. 실패하면 `401`로 중단합니다. 이것은 브라우저 화면에서 세션과 CSRF가 하는 일을 쿠키 없이 요청 단위로 수행하는 것과 같습니다. 이 라우트로 들어가는 더 약한 경로는 없습니다.

## 구성 표면

구성은 컨트롤러가 아니라 구성 대상에 따라 정리됩니다. 운영자가 실제로 다루는 표면은 다음과 같습니다.

### 프로바이더와 모델 접근

실행 중인 에이전트 뒤에는 모델이 필요합니다. 운영자는 AIGateway의 프로바이더 표면과 에이전트의 모델 프로파일을 통해 이를 연결합니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/ai-gateway/provider-kinds` | 이 배포 인스턴스가 구성할 수 있는 프로바이더 종류 목록 |
| `GET` | `/ai-gateway/providers` | 구성된 프로바이더 목록 |
| `GET` | `/ai-gateway/providers/:provider_id` | 프로바이더 하나와 자격 증명 풀 상태 읽기 |
| `PUT` | `/ai-gateway/providers/:provider_id` | 프로바이더 생성 또는 교체 |
| `DELETE` | `/ai-gateway/providers/:provider_id` | 프로바이더 제거 |
| `POST` | `/ai-gateway/providers/:provider_id/credentials` | 자격 증명 풀 멤버 추가 |
| `PUT` | `/ai-gateway/providers/:provider_id/credentials/:credential_id` | 풀 멤버 갱신 또는 재인증 |
| `DELETE` | `/ai-gateway/providers/:provider_id/credentials/:credential_id` | 풀 멤버 제거 |
| `PUT` | `/ai-gateway/providers/:provider_id/credential-pool/strategy` | 풀 선택 전략 설정 |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-login` | ChatGPT device 또는 브라우저 로그인 하나 시작 |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-login/poll` | device 로그인 하나 폴링 |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-login/browser-callback` | 브라우저 붙여넣기 폴백 완료 |
| `POST` | `/ai-gateway/providers/:provider_id/chatgpt-enterprise-credentials` | Enterprise 액세스 토큰 추가 |
| `GET` | `/agents/:agent_uid/model-profiles` | 에이전트의 모델 프로파일 목록 |
| `PUT` | `/agents/:agent_uid/model-profiles/:profile` | 프로파일 생성 또는 교체 |
| `DELETE` | `/agents/:agent_uid/model-profiles/:profile` | 프로파일 제거 |

프로바이더 자격 증명은 에이전트 환경이 아니라 컨트롤 플레인 안에 암호화된 풀 멤버로 보관됩니다. 모델 프로파일은 에이전트를 프로바이더와 모델에 바인딩합니다. AIGateway는 해당 프로바이더 안에서 정상 멤버를 선택하며, 프로젝션은 안전한 계정 사실, 상태(health), 속도 제한 데이터, 사용량만 반환합니다.

### Agent와 그 능력

에이전트는 운영자가 다른 모든 것을 구성하는 기준 단위입니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/agents` | 에이전트 목록 |
| `POST` | `/agents` | 에이전트 생성 |
| `GET` | `/agents/:agent_uid` | 에이전트 하나 읽기 |
| `PATCH` | `/agents/:agent_uid` | 에이전트 갱신 |
| `DELETE` | `/agents/:agent_uid` | 에이전트 제거 |

### 시그널 라우팅 규칙

시그널 라우팅 규칙(API 스키마의 `Signal Binding`)은 프로바이더 어댑터를 Agent에 연결하여 공유 작업이 Agent에 도달할 수 있게 합니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/signal-adapters` | 이 배포 인스턴스가 선언한 어댑터 목록 |
| `GET` | `/signal-bindings` | 라우팅 규칙 목록(`?agent=`로 Agent 필터) |
| `PUT` | `/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | 라우팅 규칙 생성 또는 교체 |
| `PATCH` | `/agents/:agent_uid/signal-bindings/:binding_name` | 라우팅 규칙 갱신 |
| `DELETE` | `/agents/:agent_uid/signal-bindings/:binding_name` | 라우팅 규칙 제거 |
| `GET` | `/signal-channels/:channel_id/standing-orders` | 채널 하나의 상시 지시 읽기 |
| `PUT` | `/signal-channels/:channel_id/standing-orders` | 채널 하나의 상시 지시 교체 |

바인딩을 비활성화하면 바인딩을 삭제하지 않고도 새 시그널이 해당 에이전트를 깨우지 않게 됩니다.

### Agent Library 능력

Agent Library는 에이전트가 할 수 있는 일, 즉 플러그인과 스킬입니다. Console은 전역 기본값과 에이전트별 재정의(override)라는 두 범위를 제공합니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/agent-library/capabilities` | 전역 라이브러리 능력 목록 |
| `PUT` | `/agent-library/agent-plugins/:id` | 플러그인의 전역 기본 상태 설정 |
| `PUT` | `/agent-library/skills/:id` | 스킬의 전역 기본 상태 설정 |
| `GET` | `/agents/:agent_uid/library-capabilities` | 에이전트의 유효 능력 목록 |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 에이전트 하나의 플러그인 재정의 |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | 에이전트 하나의 스킬 재정의 |
| `GET` | `/agents/:agent_uid/library-documents` | 에이전트의 라이브러리 문서 목록 |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | 라이브러리 문서 설정 |
| `GET` | `/agents/:agent_uid/library-skill-overlays` | 스킬 오버레이 목록 |
| `PUT` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | 스킬 오버레이 설정 |
| `DELETE` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | 스킬 오버레이 제거 |

능력은 전역으로 활성화된 다음 에이전트별로 좁히거나 넓힐 수 있습니다. 스킬 오버레이는 운영자가 스킬을 포크하지 않고 에이전트 하나에 대해 그 스킬의 동작을 사용자 지정할 수 있게 해 줍니다.

### 환경 변수(WorkerEnv)

Agent Computer Worker는 API 키나 토큰 같은 환경 변수가 필요할 수 있습니다. Console은 이 기능을 **Environment variables**라고 부릅니다. API는 리소스 이름으로 `WorkerEnv`를 사용합니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/worker-envs` | 이름 있는 WorkerEnv 항목 목록 |
| `GET` | `/worker-envs/:name` | 항목 하나 읽기(메타데이터, 평문 아님) |
| `PUT` | `/worker-envs/:name` | 항목 생성 또는 갱신 |
| `DELETE` | `/worker-envs/:name` | 항목 제거 |
| `GET` | `/agents/:agent_uid/worker-envs` | 에이전트에 연결된 항목 목록 |
| `PUT` | `/agents/:agent_uid/worker-envs/:name` | 항목을 에이전트에 연결 |
| `DELETE` | `/agents/:agent_uid/worker-envs/:name` | 항목 연결 해제 |
| `POST` | `/worker-envs/:name/decryptions` | 항목 하나 복호화(감사 대상, 권한 필요) |

복호화는 별도의 감사 대상 작업입니다. 목록과 읽기는 비밀 값이 아니라 메타데이터를 반환합니다. Worker는 turn이 시작될 때만 환경을 받습니다. 변경 사항은 이미 실행 중인 turn이 아니라 다음 turn에 적용됩니다.

### Control Plane Plugins

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/control-plane-plugins` | Control Plane Plugins와 그 상태 목록 |
| `PUT` | `/control-plane-plugins` | 플러그인 활성화 또는 비활성화 |

Control Plane Plugins는 컨트롤 플레인 자체가 하는 일을 바꾸는 퍼스트파티 확장입니다. 시그널 어댑터나 Brain 소스 커넥터가 그 예입니다.

### Identity providers와 AppConfiguration

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/identity-provider-adapters` | 이 배포 인스턴스가 지원하는 IdP 어댑터 목록 |
| `GET` | `/identity-providers` | 구성된 identity provider 목록 |
| `PUT` | `/identity-providers/:provider_id` | IdP 생성 또는 교체 |
| `POST` | `/identity-providers/:provider_id/sync-runs` | IdP에서 디렉터리 그룹 동기화 |
| `GET` | `/app-configurations` | 운영자 관리 구성 키 목록 |
| `PUT` | `/app-configurations/:key` | 구성 값 설정 |
| `POST` | `/app-configurations/:key/decryptions` | 비밀 구성 값 하나 복호화 |

`AppConfiguration`은 운영자가 관리하는 설정, 즉 선언된 `Ankole.AppConfigure` 키를 위한 것입니다. 부트스트랩 구성(프로세스 시작 사실과 자격 증명)은 프로젝트 경계 요구 사항대로 여기에 포함되지 않고 환경 또는 시크릿 마운트에 남아 있습니다.

## 읽기 표면

구성과 함께, Console은 나머지 시스템의 관찰 경로이기도 합니다. 이미 문서화된 각 하위 시스템은 여기에 읽기 표면을 가집니다.

- **실행 중인 Agents**: `/agents/:agent_uid/sessions`, 세션별 cron 일정과 checkback.
- **Workers**: `/agent-computer-workers`, Worker별 파일 업로드, 이동, 목록.
- **Jobs**: `/background-agent-jobs`(목록, 읽기, 취소).
- **AI 활동**: `/ai-gateway/conversations`, 대화별 메시지.
- **Memory**: 전체 `/brain/*` 표면 — 항목, 소스, 감사 로그, dreaming 실행과 적합도(fitness), 복원(restoration).
- **Principals 및 AuthZ**: `/principals`, `/principal-groups`, `/permission-grants` — [Principal 및 AuthZ](../principal-authz/) 페이지의 권한 모델.

## 여기에 없는 것에 대한 참고

`/webhooks/*`와 `/api/v1/ai-gateway/*` 라우트는 의도적으로 `console_api` 아래에 있지 않습니다. 웹훅 수신은 admin이 아니라 프로바이더를 인증하고, AIGateway 런타임 API는 라이브 AI 호출을 위해 에이전트 또는 admin 토큰을 인증합니다. Console은 운영자의 구성 표면이며, 배포 인스턴스의 동작을 바꾸기 위해 admin bearer 토큰을 신뢰하는 유일한 표면입니다.

## 다음 단계

- Console이 구성하는 런타임 표면은 [AIGateway API](../ai-gateway/), [SignalsGateway](../signals-gateway/), [Actor Runtime](../actor-runtime/)을 참고하세요.
- Console 자체가 따르는 권한 모델은 [Principal 및 AuthZ](../principal-authz/)를 참고하세요.
- 새 배포 인스턴스를 구성하려면 [Quick start의 배포 섹션](../quickstart/#deployment)을 참고하세요.