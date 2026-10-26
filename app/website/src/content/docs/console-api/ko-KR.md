---
title: Console API 참조
description: Console이 사용하는 /api/v2 API에 대한 참조. 인증, 리소스 라우트, 권한 부여 동작을 다룹니다.
section: Reference
order: 203
---

Console API는 다중 계정 브라우저 인증을 사용합니다. `Cookie` 헤더로 봉인된 session cookie를 전송하고 `x-ankole-authentication`으로 활성 계정을 선택합니다. `RequireSiteAdminSession`은 활성 관리자 세션을 확인하고 Human 접근 상태를 검사하여 `Ankole.AuthZ` 액터(`console_rest`)를 바인딩하며, `Ankole.AuthZ.Authorizer`가 각 Ash 작업을 `site_console:**` 및 `tenant_console:**` 권한으로 인가합니다. 인증 실패는 `401`을 반환합니다. GET과 HEAD 이외의 요청에는 shell의 `x-csrf-token` header가 필요하며, CSRF 증명이 없거나 유효하지 않거나 인가가 거부되면 `403`을 반환합니다.

Console 구성, 집계 보기, 감사 대상 secret 작업은 `/api/v2`를 사용합니다. 사이트 관리 라우트는 `/api/v2/site`를, 테넌트 라우트는 선택한 데이터 테넌트를 사용합니다. 표에는 각 라우트의 전체 경로를 표시합니다.

v2 요청은 `application/vnd.api+json`을 사용합니다. 각 작업의 OpenAPI schema가 요청과 응답을 정의합니다. 리소스 생성과 수정은 `data.type`과 `data.attributes`를 사용합니다. generic 작업은 action 인자를 `data` 바로 아래에 두며 JSON:API 리소스 문서 대신 타입이 있는 객체를 반환할 수 있습니다. 예를 들어 `PUT /api/v2/worker-envs/EXAMPLE`은 `{"data":{"value":"example","secret":false}}`를 받고 `worker_env` 객체를 반환합니다. 리소스 목록은 schema가 keyset 페이지네이션을 선언할 때 `page[limit]`와 `page[after]`를 사용합니다.

테넌트 라우트에서는 `x-ankole-tenant: <테넌트 UUID>`로 데이터 테넌트를 선택합니다. 헤더가 없으면 호출자의 테넌트를 사용합니다. 유효하지 않거나 사용할 수 없거나 삭제 중인 테넌트는 `404`와 `data_tenant_unavailable`을 반환합니다. 이 헤더는 호출자의 신원이나 사이트 관리 권한을 바꾸지 않으며 사이트 라우트의 범위도 선택하지 않습니다.

`/api/v2/openapi.json`과 `/api/v2/site/openapi.json`은 Console 및 사이트 관리 작업을 설명하며 해당 라우트와 같은 인증이 필요합니다. 다른 브라우저 JSON:API 범위도 각자 OpenAPI 3.1 문서를 게시합니다: `/api/v2/pod/openapi.json`(Pod 워크스페이스 및 `pod_admin`용 `/api/v2/pod/admin/*` 라우트) 및 `/api/v2/browser/openapi.json`(브라우저 인증 및 초기 설정)입니다. 파일 업로드와 다운로드는 아래의 `/api/v2` native 라우트를 사용합니다. 런타임 AI 호출, OIDC 프로토콜, 웹훅은 각각의 계약을 사용합니다.

## 구성 표면

구성은 컨트롤러가 아니라 구성 대상에 따라 정리됩니다. 운영자가 실제로 다루는 표면은 다음과 같습니다.

### 프로바이더와 모델 접근

실행 중인 에이전트 뒤에는 모델이 필요합니다. 운영자는 AIGateway의 프로바이더 표면과 에이전트의 모델 프로파일을 통해 이를 연결합니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/site/ai-gateway/provider-kinds` | 이 배포 인스턴스가 구성할 수 있는 프로바이더 종류 목록 |
| `GET` | `/api/v2/site/ai-gateway/models` | Console 설정용 capability가 포함된 provider model 목록 |
| `GET` | `/api/v2/site/ai-gateway/providers` | 구성된 프로바이더 목록 |
| `GET` | `/api/v2/site/ai-gateway/providers/:provider_id` | 프로바이더 하나와 자격 증명 풀 상태 읽기 |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id` | 프로바이더 생성 또는 교체 |
| `DELETE` | `/api/v2/site/ai-gateway/providers/:provider_id` | 프로바이더 제거 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials` | 자격 증명 풀 멤버 추가 |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | 풀 멤버 갱신 또는 재인증 |
| `DELETE` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | 풀 멤버 제거 |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id/credential-pool/strategy` | 풀 선택 전략 설정 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login` | ChatGPT device 또는 브라우저 로그인 하나 시작 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login/poll` | device 로그인 하나 폴링 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login/browser-callback` | 브라우저 붙여넣기 폴백 완료 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-enterprise-credentials` | Enterprise 액세스 토큰 추가 |
| `GET` | `/api/v2/agents/:agent_uid/model-profiles` | 에이전트의 모델 프로파일 목록 |
| `PUT` | `/api/v2/agents/:agent_uid/model-profiles/:profile` | 프로파일 생성 또는 교체 |
| `DELETE` | `/api/v2/agents/:agent_uid/model-profiles/:profile` | 프로파일 제거 |

프로바이더 자격 증명은 에이전트 환경이 아니라 컨트롤 플레인 안에 암호화된 풀 멤버로 보관됩니다. 모델 프로파일은 에이전트를 프로바이더와 모델에 바인딩합니다. AIGateway는 해당 프로바이더 안에서 정상 멤버를 선택하며, 프로젝션은 안전한 계정 사실, 상태(health), 속도 제한 데이터, 사용량만 반환합니다.

### Agent와 그 능력

에이전트는 운영자가 다른 모든 것을 구성하는 기준 단위입니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/agents` | 에이전트 목록 |
| `POST` | `/api/v2/agents` | 에이전트 생성 |
| `GET` | `/api/v2/agents/:agent_uid` | 에이전트 하나 읽기 |
| `PATCH` | `/api/v2/agents/:agent_uid` | 에이전트 갱신 |
| `POST` | `/api/v2/agents/:agent_uid/enable` | 비활성화된 에이전트 다시 활성화 |
| `DELETE` | `/api/v2/agents/:agent_uid` | 활성 에이전트는 비활성화하고, 이미 비활성화된 에이전트는 영구 삭제 |

### Worker 프로바이더

각 Agent는 생성할 때 Worker 프로바이더 하나를 선택하며 이후에는 변경할 수 없습니다. 프로바이더의 YAML 설정과 암호화된 자격 증명은 별도로 저장합니다. 수명 주기와 스토리지 계약은 [Worker 관리](../worker-management/)를 참조하세요.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/site/worker-provider-kinds` | 프로바이더 종류, YAML 예시, 자격 증명 요구 사항 목록 |
| `GET` | `/api/v2/site/worker-providers` | 설정된 Worker 프로바이더 목록 |
| `POST` | `/api/v2/site/worker-providers` | Worker 프로바이더 생성 |
| `PATCH` | `/api/v2/site/worker-providers/:provider_id` | 설정 또는 자격 증명 갱신 |
| `GET` | `/api/v2/site/worker-providers/:provider_id/check` | 연결과 권한 확인 |
| `DELETE` | `/api/v2/site/worker-providers/:provider_id` | Agent가 사용하지 않는 프로바이더 삭제 |
| `PUT` | `/api/v2/agents/:agent_uid/worker-provider` | 마이그레이션 후 프로바이더가 없는 Agent에 할당 |

### 시그널 라우팅 규칙

시그널 라우팅 규칙(API 스키마의 `Signal Binding`)은 프로바이더 어댑터를 Agent에 연결하여 공유 작업이 Agent에 도달할 수 있게 합니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/signal-adapters` | 이 배포 인스턴스가 선언한 어댑터 목록 |
| `GET` | `/api/v2/signal-bindings` | 라우팅 규칙 목록(`?agent=`로 Agent 필터) |
| `PUT` | `/api/v2/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | 라우팅 규칙 생성 또는 교체 |
| `PATCH` | `/api/v2/agents/:agent_uid/signal-bindings/:binding_name` | 라우팅 규칙 갱신 |
| `DELETE` | `/api/v2/agents/:agent_uid/signal-bindings/:binding_name` | 라우팅 규칙 비활성화 |
| `GET` | `/api/v2/conversations/:conversation_id/standing-orders` | Conversation 하나의 상시 지시 읽기 |
| `PUT` | `/api/v2/conversations/:conversation_id/standing-orders` | Conversation 하나의 상시 지시 교체 |

바인딩을 비활성화하면 바인딩을 삭제하지 않고도 새 시그널이 해당 에이전트를 깨우지 않게 됩니다.

### Agent Library 능력

Library 기본값은 선택한 테넌트에 속합니다. Agent 재정의도 해당 테넌트 안에서 적용됩니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/agent-library/capabilities` | 테넌트 라이브러리 능력 목록 |
| `PUT` | `/api/v2/agent-library/agent-plugins/:id` | 플러그인의 테넌트 기본 상태 설정 |
| `PUT` | `/api/v2/agent-library/skills/:id` | 스킬의 테넌트 기본 상태 설정 |
| `GET` | `/api/v2/agents/:agent_uid/library-capabilities` | 에이전트의 유효 능력 목록 |
| `PUT` | `/api/v2/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 에이전트 하나의 플러그인 재정의 |
| `PUT` | `/api/v2/agents/:agent_uid/library-capabilities/skills/:id` | 에이전트 하나의 스킬 재정의 |
| `GET` | `/api/v2/agents/:agent_uid/library-documents` | 에이전트의 라이브러리 문서 목록 |
| `PUT` | `/api/v2/agents/:agent_uid/library-documents/:document_kind` | 라이브러리 문서 설정 |
| `GET` | `/api/v2/agents/:agent_uid/skill-lessons` | 활성 및 폐기된 Skill 교훈 목록 |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons` | 활성화된 Skill에 사람의 교훈 추가 |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons/:lesson_id/retire` | Skill 교훈 폐기 |

능력은 테넌트에서 활성화된 다음 Agent별로 좁히거나 넓힐 수 있습니다. Skill 교훈은 Skill 소스를 변경하지 않고 Agent 하나에 추가 작업 지침을 제공합니다. 목록에는 증거와 폐기 이력도 포함됩니다. 폐기된 교훈은 전달되지 않으며, 사람이 취소한 내용은 Dreaming의 재학습 금지 목록에 남습니다. 수명 주기와 제한은 [Skill 교훈](../skill-lessons/)을 참고하십시오.

### 환경 변수(WorkerEnv)

WorkerEnv는 사이트 기본값, 테넌트 재정의, Agent 연결을 제공합니다. 다음 라우트는 메타데이터를 반환합니다. 평문은 별도의 감사 대상 복호화 작업으로 가져옵니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/site/worker-envs` | 사이트 기본값 목록 |
| `PUT` | `/api/v2/site/worker-envs/:name` | 사이트 기본값 설정 |
| `DELETE` | `/api/v2/site/worker-envs/:name` | 사이트 기본값 제거 |
| `POST` | `/api/v2/site/worker-envs/:name/decryptions` | 사이트 값 복호화 |
| `GET` | `/api/v2/worker-envs` | 테넌트 값 목록 |
| `PUT` | `/api/v2/worker-envs/:name` | 테넌트 값 설정 |
| `DELETE` | `/api/v2/worker-envs/:name` | 테넌트 값 제거 |
| `POST` | `/api/v2/worker-envs/:name/decryptions` | 테넌트 값 복호화 |
| `GET` | `/api/v2/agents/:agent_uid/worker-envs` | Agent 연결 목록 |
| `PUT` | `/api/v2/agents/:agent_uid/worker-envs/:name` | Agent에 값 연결 또는 재정의 |
| `DELETE` | `/api/v2/agents/:agent_uid/worker-envs/:name` | Agent 연결 제거 |
| `POST` | `/api/v2/agents/:agent_uid/worker-envs/:name/decryptions` | Agent 값 복호화 |

Agent 연결은 전용 값을 사용하거나 테넌트 값, 사이트 기본값 순으로 상속합니다. Worker 작업 시작 시 환경 값을 해석합니다. 기존 작업공간은 생성 시 환경을 유지합니다.

### Control Plane Plugins

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/site/control-plane-plugins` | Control Plane Plugins와 그 상태 목록 |
| `PUT` | `/api/v2/site/control-plane-plugins` | 플러그인 활성화 또는 비활성화 |

Control Plane Plugins는 컴파일 시점에 포함되는 퍼스트파티 확장으로, Signals 어댑터, Identity Provider 어댑터, AI Gateway 프로바이더, Worker 프로바이더 같은 컨트롤 플레인 기능을 추가합니다. `activation: :always`인 플러그인은 빌드와 함께 항상 활성화됩니다. `PUT /api/v2/site/control-plane-plugins`는 다음 재시작 시 적용할 `:optional` 플러그인을 전환하며, 구성된 Worker 프로바이더처럼 활성 리소스가 있는 플러그인이 비활성화되지 않도록 각 하위 시스템의 `veto_disable` 검사를 실행합니다.

### Identity providers와 AppConfiguration

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/identity-provider-adapters` | 이 배포 인스턴스가 지원하는 IdP 어댑터 목록 |
| `GET` | `/api/v2/identity-providers` | 구성된 identity provider 목록 |
| `PUT` | `/api/v2/identity-providers/:provider_id` | IdP 생성 또는 교체 |
| `POST` | `/api/v2/identity-providers/:provider_id/sync-runs` | IdP에서 디렉터리 그룹 동기화 |
| `GET` | `/api/v2/site/app-configurations` | 사이트 구성 키 목록 |
| `PUT` | `/api/v2/site/app-configurations/:key` | 사이트 값 설정 |
| `POST` | `/api/v2/site/app-configurations/:key/decryptions` | 사이트 비밀 복호화 |
| `GET` | `/api/v2/app-configurations` | 운영자 관리 구성 키 목록 |
| `PUT` | `/api/v2/app-configurations/:key` | 구성 값 설정 |
| `POST` | `/api/v2/app-configurations/:key/decryptions` | 비밀 구성 값 하나 복호화 |

`AppConfiguration`은 선언된 운영 설정을 사이트 또는 테넌트 범위에 저장합니다. `/api/v2/site/app-configurations`는 사이트 키를, `/api/v2/app-configurations`는 테넌트 키를 관리합니다. 두 경로 모두 목록, 개별 키 읽기, 설정, 재정의 삭제, 감사 대상 복호화를 지원합니다. 시작 자격 증명과 시작 정보는 환경 변수나 시크릿 마운트에 둡니다.

### 테넌트 관리

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/site/tenants` | 테넌트 목록 |
| `POST` | `/api/v2/site/tenants` | 테넌트 생성 |
| `PATCH` | `/api/v2/site/tenants/:tenant_id` | 테넌트 업데이트 |
| `DELETE` | `/api/v2/site/tenants/:tenant_id` | 테넌트 삭제 요청 |
| `POST` | `/api/v2/site/tenants/:tenant_id/suspension` | 테넌트 일시 중지 |
| `DELETE` | `/api/v2/site/tenants/:tenant_id/suspension` | 테넌트 재개 |
| `GET` | `/api/v2/site/privileged-tenant` | 특권 테넌트 읽기 |
| `PATCH` | `/api/v2/site/privileged-tenant` | 다른 테넌트로 사이트 관리 이전 |

## 읽기 표면

구성과 함께, Console은 나머지 시스템의 관찰 경로이기도 합니다. 이미 문서화된 각 하위 시스템은 여기에 읽기 표면을 가집니다.

- **실행 중인 Agents**: `/api/v2/agents/:agent_uid/sessions`, Agent별 cron 일정과 checkback 관리. 목록 엔드포인트는 테넌트 전체 범위이며 `agent` 필터를 받습니다.
- **Workers**: `/api/v2/agent-workers`에서 각 Agent의 Worker 상태를 확인합니다.
- **Agent drive**: `/api/v2/agents/:agent_uid/files`는 파일 목록과 삭제에, `/api/v2/agents/:agent_uid/file-moves`는 이동에 사용합니다. `POST /api/v2/agents/:agent_uid/files`는 multipart 업로드를, `GET /api/v2/agents/:agent_uid/files/content`는 바이트 다운로드를 처리합니다. native 전송에도 같은 browser session, CSRF, 테넌트 선택, 파일 권한을 적용합니다. control plane이 파일을 소유합니다.
- **Jobs**: `/api/v2/background-agent-jobs`(목록, 읽기, 취소).
- **AI 활동**: `/api/v2/ai-gateway/conversations`, 대화별 메시지.
- **Principals, AuthZ 및 OIDC 클라이언트**: `/api/v2/principals`(`PATCH /api/v2/principals/:uid/membership`, `POST /api/v2/principals/:uid/access-disables`, `POST /api/v2/principals/:uid/access-restorations` 포함), `/api/v2/principal-groups`, `/api/v2/permission-grants`, 그리고 `/api/v2/oidc-clients` — [Principal 및 AuthZ](../principal-authz/) 페이지의 권한 모델을 따릅니다.

## 여기에 없는 것에 대한 참고

`/webhooks/*`는 provider를 인증합니다. runtime `/api/v1/ai-gateway/*`는 AIGateway 인증을 사용하고 Console configuration route는 이 페이지의 session 및 CSRF 검사를 사용합니다.

## 다음 단계

- Console이 구성하는 런타임 표면은 [AIGateway API](../ai-gateway/), [Signals](../signals/), [Sessions](../sessions/)을 참고하세요.
- Console 자체가 따르는 권한 모델은 [Principal 및 AuthZ](../principal-authz/)를 참고하세요.
- 새 배포 인스턴스를 구성하려면 [Quick start의 배포 섹션](../quickstart/#deployment)을 참고하세요.
