---
title: Console API 참조
description: Console이 사용하는 /api/v2 API에 대한 참조. 인증, 리소스 라우트, 권한 부여 동작을 다룹니다.
section: Reference
order: 203
---

Console API는 다중 계정 브라우저 세션 인증을 사용합니다. 호출 시 `Cookie` 헤더로 암호화·봉인된 세션 쿠키를 전달하고 `x-ankole-authentication` 헤더로 활성 계정을 지정합니다. 서버에서는 `RequireSiteAdminSession` 플러그가 활성 관리자 세션과 사용자(Human) 접근 상태를 확인해 `Ankole.AuthZ` 액터(`console_rest`)를 바인딩하고, 이어서 `Ankole.AuthZ.Authorizer`가 각 Ash 액션에 대해 `site_console:**` 및 `tenant_console:**` 권한을 검증합니다. 인증에 실패하면 `401`이 반환됩니다. `GET`과 `HEAD`를 제외한 상태 변경 요청에는 브라우저 셸의 `x-csrf-token` 헤더가 필수이며, CSRF 토큰이 누락·만료되었거나 권한 인가가 거부되면 `403`이 반환됩니다.

모든 Console 구성 변경, 집계 조회, 감사 대상 시크릿 작업은 `/api/v2` 경로 아래에 열려 있습니다. 사이트 전체 관리 라우트는 `/api/v2/site` 하위 경로를 쓰고, 테넌트 범위 라우트는 현재 선택된 데이터 테넌트를 대상으로 동작합니다. 아래 표에는 각 라우트의 전체 경로를 기재했습니다.

v2 요청 본문과 응답은 JSON:API 미디어 타입인 `application/vnd.api+json`을 따르며 세부 페이로드 규격은 OpenAPI 스키마에 정의되어 있습니다. 일반 리소스의 생성과 수정은 `data.type`과 `data.attributes` 구조를 사용합니다. 반면 generic 액션은 액션 인자를 `data` 바로 아래에 배치하며 표준 JSON:API 리소스 문서 대신 타입이 지정된 결과 객체를 바로 반환할 수 있습니다(예: `PUT /api/v2/worker-envs/EXAMPLE`에 `{"data":{"value":"example","secret":false}}`를 보내면 `worker_env` 객체 반환). 스키마에 키셋(keyset) 페이지네이션이 선언된 목록 엔드포인트는 `page[limit]`와 `page[after]` 쿼리 파라미터를 지원합니다.

테넌트 범위 라우트를 호출할 때는 `x-ankole-tenant: <테넌트 UUID>` 헤더로 대상 데이터 테넌트를 지정하며, 헤더를 생략하면 호출자 본인이 속한 테넌트가 기본 선택됩니다. 존재하지 않거나 비활성 상태이거나 삭제가 진행 중인 테넌트를 지정하면 `data_tenant_unavailable` 오류와 함께 `404`가 반환됩니다. 이 헤더는 조회·조작할 대상 테넌트만 바꿀 뿐 호출자의 신원이나 사이트 관리자 권한을 변경하지 않으며, 사이트 범위 라우트(`/api/v2/site/*`)의 동작에도 영향을 주지 않습니다.

Console 및 사이트 관리 작업의 전체 명세는 `/api/v2/openapi.json`과 `/api/v2/site/openapi.json`에서 제공되며, 실제 API 라우트와 동일한 관리자 인증을 거쳐야 조회할 수 있습니다. 그 밖의 브라우저 JSON:API 영역도 각각 전용 OpenAPI 3.1 문서를 게시합니다. Pod 워크스페이스 및 `pod_admin` 전용 `/api/v2/pod/admin/*` 라우트는 `/api/v2/pod/openapi.json`에서, 브라우저 로그인 및 초기 설정 라우트는 `/api/v2/browser/openapi.json`에서 확인할 수 있습니다. 파일 업로드·다운로드는 아래에 설명된 `/api/v2` 네이티브 바이너리 라우트를 사용하며, 런타임 AI 호출이나 OIDC 프로토콜, 외부 웹훅 수신은 각자의 고유 API 계약을 따릅니다.

## 구성 표면

라우트 구조는 내부 컨트롤러 구현이 아니라 운영자가 실제로 관리하는 도메인 대상을 기준으로 정리되어 있습니다.

### 프로바이더와 모델 접근

실행 중인 에이전트가 추론을 수행하려면 업스트림 모델 연결이 필요합니다. 운영자는 AIGateway의 프로바이더 관리 라우트와 개별 에이전트의 모델 프로필 라우트를 통해 이를 구성합니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/site/ai-gateway/provider-kinds` | 현재 배포 인스턴스에서 구성할 수 있는 프로바이더 종류 목록 조회 |
| `GET` | `/api/v2/site/ai-gateway/models` | Console 설정 화면용 지원 capability가 포함된 프로바이더 모델 목록 조회 |
| `GET` | `/api/v2/site/ai-gateway/providers` | 구성된 프로바이더 목록 조회 |
| `GET` | `/api/v2/site/ai-gateway/providers/:provider_id` | 단일 프로바이더 설정 및 자격 증명 풀 상태 조회 |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id` | 프로바이더 생성 또는 전체 교체 |
| `DELETE` | `/api/v2/site/ai-gateway/providers/:provider_id` | 프로바이더 삭제 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials` | 자격 증명 풀에 새 멤버 추가 |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | 풀 멤버 정보 수정 또는 재인증 |
| `DELETE` | `/api/v2/site/ai-gateway/providers/:provider_id/credentials/:credential_id` | 풀 멤버 제거 |
| `PATCH` | `/api/v2/site/ai-gateway/providers/:provider_id/credential-pool/strategy` | 풀 선택 전략 변경 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login` | ChatGPT 디바이스 코드 또는 브라우저 로그인 시작 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login/poll` | 진행 중인 디바이스 로그인 완료 여부 폴링 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-login/browser-callback` | 브라우저 콜백 URL 붙여넣기 폴백 완료 |
| `POST` | `/api/v2/site/ai-gateway/providers/:provider_id/chatgpt-enterprise-credentials` | ChatGPT Enterprise 액세스 토큰 직접 등록 |
| `GET` | `/api/v2/agents/:agent_uid/model-profiles` | 특정 에이전트의 모델 프로필 목록 조회 |
| `PUT` | `/api/v2/agents/:agent_uid/model-profiles/:profile` | 모델 프로필 생성 또는 교체 |
| `DELETE` | `/api/v2/agents/:agent_uid/model-profiles/:profile` | 모델 프로필 삭제 |

모든 프로바이더 자격 증명은 에이전트 컨테이너가 아닌 컨트롤 플레인 내부에 암호화된 풀 멤버로 보관됩니다. 모델 프로필이 에이전트를 특정 프로바이더와 모델에 연결하면 런타임에 AIGateway가 정상 상태인 풀 멤버를 골라 호출하며, API 응답 프로젝션에는 마스킹된 안전한 계정 정보와 상태(health), 속도 제한 수치, 누적 사용량만 포함됩니다.

### Agent와 그 능력

에이전트는 다른 모든 운영 설정이 연결되는 중심 단위입니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/agents` | 에이전트 목록 조회 |
| `POST` | `/api/v2/agents` | 새 에이전트 생성 |
| `GET` | `/api/v2/agents/:agent_uid` | 단일 에이전트 상세 조회 |
| `PATCH` | `/api/v2/agents/:agent_uid` | 에이전트 속성 수정 |
| `POST` | `/api/v2/agents/:agent_uid/enable` | 비활성화된 에이전트 다시 활성화 |
| `DELETE` | `/api/v2/agents/:agent_uid` | 활성 에이전트는 비활성화하고, 이미 비활성화된 에이전트는 영구 삭제 |

### Worker 프로바이더

각 Agent는 생성 시점에 사용할 Worker 프로바이더 하나를 선택하며 저장 후에는 다른 프로바이더로 바꿀 수 없습니다. 프로바이더의 YAML 구성과 암호화된 플랫폼 자격 증명은 분리해 저장합니다. 세부 수명 주기와 스토리지 계약은 [Worker 관리](../worker-management/)를 참조하세요.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/site/worker-provider-kinds` | 지원하는 프로바이더 종류, YAML 예시, 필수 자격 증명 항목 조회 |
| `GET` | `/api/v2/site/worker-providers` | 등록된 Worker 프로바이더 목록 조회 |
| `POST` | `/api/v2/site/worker-providers` | 새 Worker 프로바이더 생성 |
| `PATCH` | `/api/v2/site/worker-providers/:provider_id` | 프로바이더 설정 또는 자격 증명 수정 |
| `GET` | `/api/v2/site/worker-providers/:provider_id/check` | 외부 플랫폼 연결 및 권한 점검 |
| `DELETE` | `/api/v2/site/worker-providers/:provider_id` | 어떤 Agent도 참조하지 않는 프로바이더 삭제 |
| `PUT` | `/api/v2/agents/:agent_uid/worker-provider` | 마이그레이션 직후 프로바이더가 미지정된 Agent에 최초 할당 |

### 시그널 라우팅 규칙

시그널 라우팅 규칙(API 스키마 명칭 `Signal Binding`)은 외부 채널 어댑터를 담당 Agent와 연결해 유입된 메시지와 이벤트가 해당 Agent에 전달되도록 합니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/signal-adapters` | 현재 배포 인스턴스에 선언된 시그널 어댑터 목록 조회 |
| `GET` | `/api/v2/signal-bindings` | 라우팅 규칙 목록 조회(`?agent=` 쿼리로 특정 Agent 필터링) |
| `PUT` | `/api/v2/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name` | 라우팅 규칙 생성 또는 교체 |
| `PATCH` | `/api/v2/agents/:agent_uid/signal-bindings/:binding_name` | 라우팅 규칙 부분 수정 |
| `DELETE` | `/api/v2/agents/:agent_uid/signal-bindings/:binding_name` | 라우팅 규칙 비활성화 |
| `GET` | `/api/v2/conversations/:conversation_id/standing-orders` | 특정 Conversation의 상시 지시(standing order) 조회 |
| `PUT` | `/api/v2/conversations/:conversation_id/standing-orders` | 특정 Conversation의 상시 지시 전체 교체 |

바인딩을 비활성화하면 설정 자체를 삭제하지 않고도 해당 채널에서 새 시그널이 에이전트를 깨우지 않도록 일시 차단할 수 있습니다.

### Agent Library 능력

라이브러리 기본 활성화 상태는 선택한 테넌트 단위로 저장되며, 개별 Agent 재정의 역시 해당 테넌트 범위 안에서 적용됩니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/agent-library/capabilities` | 테넌트의 라이브러리 capability 카탈로그 및 기본값 조회 |
| `PUT` | `/api/v2/agent-library/agent-plugins/:id` | 플러그인의 테넌트 기본 활성화 상태 설정 |
| `PUT` | `/api/v2/agent-library/skills/:id` | 스킬의 테넌트 기본 활성화 상태 설정 |
| `GET` | `/api/v2/agents/:agent_uid/library-capabilities` | 특정 에이전트의 유효 capability 목록 조회 |
| `PUT` | `/api/v2/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 특정 에이전트의 플러그인 활성화 재정의 |
| `PUT` | `/api/v2/agents/:agent_uid/library-capabilities/skills/:id` | 특정 에이전트의 스킬 활성화 재정의 |
| `GET` | `/api/v2/agents/:agent_uid/library-documents` | 에이전트의 영구 라이브러리 문서 목록 조회 |
| `PUT` | `/api/v2/agents/:agent_uid/library-documents/:document_kind` | 특정 라이브러리 문서 저장 |
| `GET` | `/api/v2/agents/:agent_uid/skill-lessons` | 활성 및 폐기된 Skill 교훈 목록 조회 |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons` | 활성화된 Skill에 운영자 수동 교훈 추가 |
| `POST` | `/api/v2/agents/:agent_uid/skill-lessons/:lesson_id/retire` | 특정 Skill 교훈 폐기 |

먼저 테넌트 단위에서 기본 구성을 정한 뒤 개별 Agent마다 허용 범위를 좁히거나 넓힐 수 있습니다. Skill 교훈은 원본 `SKILL.md`를 수정하지 않고 특정 Agent에만 추가 업무 지침을 덧붙이며, 조회 결과에는 근거 기록과 폐기 이력이 함께 포함됩니다. 폐기된 교훈은 실행 시 제공되지 않으며 사람이 직접 폐기한 항목은 Dreaming이 비슷한 내용을 다시 자동 생성하지 않도록 금지 목록에 남습니다. 세부 수명 주기와 한도는 [Skill 교훈](../skill-lessons/)을 참조하세요.

### 환경 변수(WorkerEnv)

`WorkerEnv`는 사이트 기본값, 테넌트 재정의, 개별 Agent 연결의 3단계 계층을 제공합니다. 일반 조회 라우트는 메타데이터만 반환하며, 실제 평문 값은 감사 기록이 남는 전용 복호화(`decryptions`) 엔드포인트를 호출해야 확인할 수 있습니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/site/worker-envs` | 사이트 범위 기본 환경 변수 목록 조회 |
| `PUT` | `/api/v2/site/worker-envs/:name` | 사이트 기본값 설정 |
| `DELETE` | `/api/v2/site/worker-envs/:name` | 사이트 기본값 삭제 |
| `POST` | `/api/v2/site/worker-envs/:name/decryptions` | 사이트 환경 변수 평문 복호화 |
| `GET` | `/api/v2/worker-envs` | 테넌트 범위 환경 변수 목록 조회 |
| `PUT` | `/api/v2/worker-envs/:name` | 테넌트 환경 변수 설정 |
| `DELETE` | `/api/v2/worker-envs/:name` | 테넌트 환경 변수 삭제 |
| `POST` | `/api/v2/worker-envs/:name/decryptions` | 테넌트 환경 변수 평문 복호화 |
| `GET` | `/api/v2/agents/:agent_uid/worker-envs` | 특정 Agent에 연결된 환경 변수 목록 조회 |
| `PUT` | `/api/v2/agents/:agent_uid/worker-envs/:name` | 특정 Agent에 환경 변수 연결 또는 전용 값 재정의 |
| `DELETE` | `/api/v2/agents/:agent_uid/worker-envs/:name` | 특정 Agent의 환경 변수 연결 해제 |
| `POST` | `/api/v2/agents/:agent_uid/worker-envs/:name/decryptions` | 특정 Agent의 환경 변수 평문 복호화 |

Agent에 연결된 변수는 전용 재정의 값이 있으면 그 값을 우선 사용하고, 없으면 테넌트 값 → 사이트 기본값 순서로 상속합니다. 환경 변수 값은 Worker 작업이 시작될 때 해석되어 주입되며 이미 열려 있는 기존 작업 공간은 처음 생성될 때 받은 환경을 그대로 유지합니다.

### Control Plane Plugins

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/site/control-plane-plugins` | 설치된 Control Plane Plugins 목록과 활성 상태 조회 |
| `PUT` | `/api/v2/site/control-plane-plugins` | 선택형 플러그인 활성화 또는 비활성화 예약 |

Control Plane Plugins는 릴리스 컴파일 시점에 함께 포함되는 퍼스트 파티 확장 모듈로서 Signals 어댑터, Identity Provider 어댑터, AI Gateway 프로바이더, Worker 프로바이더 같은 컨트롤 플레인 기능을 추가합니다. `activation: :always`로 선언된 플러그인은 항상 켜져 있으며, `PUT /api/v2/site/control-plane-plugins`는 다음 재시작부터 반영될 `:optional` 플러그인의 활성 여부를 전환합니다. 이때 현재 사용 중인 Worker 프로바이더처럼 활성 리소스가 남아 있는 플러그인이 실수로 꺼지지 않도록 각 서브시스템의 `veto_disable` 검사를 먼저 수행합니다.

### Identity providers와 AppConfiguration

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/identity-provider-adapters` | 현재 배포 인스턴스가 지원하는 IdP 어댑터 목록 조회 |
| `GET` | `/api/v2/identity-providers` | 구성된 Identity Provider 목록 조회 |
| `PUT` | `/api/v2/identity-providers/:provider_id` | IdP 생성 또는 교체 |
| `POST` | `/api/v2/identity-providers/:provider_id/sync-runs` | IdP에서 조직 디렉터리 및 그룹 동기화 실행 |
| `GET` | `/api/v2/site/app-configurations` | 사이트 범위 런타임 설정 키 목록 조회 |
| `PUT` | `/api/v2/site/app-configurations/:key` | 사이트 범위 설정값 저장 |
| `POST` | `/api/v2/site/app-configurations/:key/decryptions` | 사이트 범위 암호화 설정 복호화 |
| `GET` | `/api/v2/app-configurations` | 테넌트 범위 런타임 설정 키 목록 조회 |
| `PUT` | `/api/v2/app-configurations/:key` | 테넌트 범위 설정값 저장 |
| `POST` | `/api/v2/app-configurations/:key/decryptions` | 테넌트 범위 암호화 설정 복호화 |

`AppConfiguration`은 코드에 선언된 런타임 운영 설정을 사이트 또는 테넌트 범위로 저장합니다. 사이트 키는 `/api/v2/site/app-configurations`에서, 테넌트 키는 `/api/v2/app-configurations`에서 다루며 두 경로 모두 목록 조회, 단건 조회, 값 저장, 재정의 초기화, 감사 대상 복호화를 지원합니다. 반면 데이터베이스 접속 정보처럼 부트스트랩 단계에 필요한 비밀 값은 배포 환경 변수나 시크릿 마운트로 주입합니다.

### 테넌트 관리

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/site/tenants` | 전체 테넌트 목록 조회 |
| `POST` | `/api/v2/site/tenants` | 새 테넌트 생성 |
| `PATCH` | `/api/v2/site/tenants/:tenant_id` | 테넌트 속성 수정 |
| `DELETE` | `/api/v2/site/tenants/:tenant_id` | 테넌트 삭제 요청 |
| `POST` | `/api/v2/site/tenants/:tenant_id/suspension` | 테넌트 일시 중지 |
| `DELETE` | `/api/v2/site/tenants/:tenant_id/suspension` | 일시 중지된 테넌트 재개 |
| `GET` | `/api/v2/site/privileged-tenant` | 현재 사이트 관리 권한을 가진 특권 테넌트 조회 |
| `PATCH` | `/api/v2/site/privileged-tenant` | 사이트 관리 특권을 다른 테넌트로 이전 |

## 읽기 표면

Console API는 구성 변경뿐 아니라 시스템 전반의 운영 상태를 모니터링하는 조회 통로 역할도 함께 수행합니다. 각 서브시스템의 주요 관측 라우트는 다음과 같습니다.

- **실행 중인 Agents**: `/api/v2/agents/:agent_uid/sessions` 및 Agent별 cron 스케줄·checkback 조회·관리 라우트(목록 엔드포인트는 테넌트 전체 범위이며 `agent` 쿼리 필터 지원).
- **Workers**: `/api/v2/agent-workers`에서 각 Agent에 할당된 Worker 인스턴스 상태를 조회합니다.
- **Agent drive**: 파일 목록 조회와 삭제는 `/api/v2/agents/:agent_uid/files`, 경로 이동은 `/api/v2/agents/:agent_uid/file-moves`를 사용하며, 실제 파일 바이트 전송은 네이티브 라우트인 `POST /api/v2/agents/:agent_uid/files`(멀티파트 업로드)와 `GET /api/v2/agents/:agent_uid/files/content`(스트림 다운로드)로 처리합니다. 네이티브 파일 라우트에도 동일한 브라우저 세션, CSRF, 테넌트 헤더, 파일 권한 검증이 적용되며 파일 소유권은 컨트롤 플레인에 있습니다.
- **Jobs**: `/api/v2/background-agent-jobs`에서 백그라운드 작업의 목록 조회, 상세 확인, 취소를 수행합니다.
- **AI 활동**: `/api/v2/ai-gateway/conversations`에서 AIGateway 대화 목록과 대화별 메시지 이력을 조회합니다.
- **Principals, AuthZ 및 OIDC 클라이언트**: `/api/v2/principals`(`PATCH /api/v2/principals/:uid/membership`, `POST /api/v2/principals/:uid/access-disables`, `POST /api/v2/principals/:uid/access-restorations` 포함), `/api/v2/principal-groups`, `/api/v2/permission-grants`, `/api/v2/oidc-clients`를 통해 조회·관리하며 [Principal 및 AuthZ](../principal-authz/)의 권한 모델을 따릅니다.

## 여기에 없는 것에 대한 참고

외부 인바운드 `/webhooks/*` 경로는 각 외부 플랫폼이나 capability 토큰 고유의 검증 방식을 사용하며, 런타임 AI 호출 경로인 `/api/v1/ai-gateway/*`는 AIGateway bearer 토큰 인증을 사용합니다. 본 문서에서 다룬 브라우저 세션 및 CSRF 검증은 `/api/v2` 관리 라우트에 적용됩니다.

## 다음 단계

- Console을 통해 설정하는 실제 런타임 동작은 [AIGateway API](../ai-gateway/), [Signals](../signals/), [Sessions](../sessions/)를 참조하세요.
- Console API 인가에 적용되는 권한 체계는 [Principal 및 AuthZ](../principal-authz/)를 참조하세요.
- 신규 배포 인스턴스의 초기 구성 절차는 [Quick start의 배포 섹션](../quickstart/#deployment)을 참조하세요.
