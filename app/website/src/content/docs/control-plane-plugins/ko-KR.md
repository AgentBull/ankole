---
title: Control Plane Plugins
description: 컨트롤 플레인의 퍼스트파티 Elixir 확장 모델 — 활성화 모드, 서브시스템 계약, 트랜잭션 훅, Cohort 감독 트리, 그리고 다음 프로세스 시작 시 적용되는 경계를 설명합니다.
section: Developer guide
order: 110
---

Control Plane Plugins는 신뢰할 수 있는 퍼스트파티 Elixir 및 OTP 코드로 Ankole 사이트를 확장하는 메커니즘입니다. 각 플러그인은 `Ankole.Plugins`를 통해 `AppConfigure` 키, 서브시스템 어댑터, 동기식 트랜잭션 훅, 감독 대상 자식 프로세스를 컨트롤 플레인에 등록할 수 있습니다.

Control Plane Plugins는 릴리스에 함께 컴파일되는 퍼스트파티 Elixir 모듈(`:control_plane_plugin_modules`)이며, 런타임에 외부 코드를 내려받는 마켓플레이스나 비신뢰 코드용 샌드박스 격리 구조가 아닙니다. 모든 플러그인 모듈은 부팅 시점에 검색되고 검증됩니다. 그중 `:optional` 플러그인은 전역 활성화 목록에서 선택되어 다음 프로세스 시작 시점부터 켜지며, `activation: :always`를 선언한 플러그인은 해당 빌드에 포함되어 있는 한 항상 활성 상태를 유지합니다.

## 발견됨(Discovered)과 활성(Active) 단계

런타임에서 플러그인은 두 가지 단계로 구분됩니다.

- **Discovered** — 릴리스에 컴파일되어 부팅 시 검증을 통과한 모든 플러그인 모듈입니다. 운영자는 Site Admin Console에서 전체 카탈로그를 조회할 수 있습니다.
- **Active** — `activation/0`이 `:always`인 플러그인, 또는 `activation/0`이 `:optional`이면서 `plugins.enabled_ids`에 포함된 플러그인입니다(초기 설정 `setup.completed`가 완료되기 전까지는 발견된 모든 플러그인이 활성화됩니다). 활성 상태인 플러그인만 `AppConfigure` 정의를 등록하고, 서브시스템 어댑터와 도메인 훅을 게시하며, 감독 대상 자식 프로세스를 시작합니다.

발견되었더라도 비활성 상태인 플러그인은 카탈로그에 표시되고 기존에 저장된 `AppConfigure` 값도 PostgreSQL에 그대로 보존되지만, 런타임에는 어떠한 설정 정의나 어댑터, 훅, 프로세스도 등록하지 않습니다.

## 플러그인 계약

플러그인 모듈은 `Ankole.Plugins.Plugin` 동작(behaviour)을 구현하며, 필수 콜백은 하나뿐입니다.

- **`plugin_id/0`** — `~r/\A[a-z][a-z0-9_-]*\z/` 패턴과 일치하는 고유한 소문자 슬러그입니다.

나머지 콜백은 모두 선택 사항입니다.

- **`activation/0`** — `:optional | :always`를 반환합니다(기본값 `:optional`). `:optional` 플러그인은 `plugins.enabled_ids` 설정을 따르며, `:always` 플러그인은 선택된 소스 빌드에 포함되어 있는 한 항상 활성화되고 비활성화 요청이 들어오면 Ankole이 이를 거부합니다.
- **`display_name/0`**, **`description/0`** — 운영자 화면에 표시할 다국어 텍스트 맵입니다.
- **`app_config_definitions/0`**, **`app_config_patterns/0`** — 플러그인이 제공하는 `Ankole.AppConfigure` 키 및 패턴 정의입니다.
- **`adapter_declarations/0`** — 플러그인을 서브시스템 계약에 연결하는 애텀 키 선언 목록이며, 브라우저 설정 폼 스키마를 정의할 때는 `Ankole.Plugins.ConfigField`를 사용합니다.
- **`hooks/0`** — 동기식 도메인 트랜잭션 훅 `[{hook_point, module}]` 목록입니다. 각 모듈은 선언된 훅 지점(`:create_agent`, `:create_invitation`, `:enable_signal_binding`, `:enable_identity_provider`, `:store_file`, `:commit_files`, `:create_pod_page`, `:restore_pod_page`, `:insert_base_records`, `:admit_compute`)에서 `Ankole.Plugins.Hook.before_commit_in_tx/2`를 구현하며, `{:error, reason}`을 반환해 호출 측 트랜잭션을 롤백시킬 수 있습니다.
- **`children/0`** — 플러그인 런타임 슈퍼바이저 아래에서 시작할 `Supervisor.child_spec()` 목록입니다.

부팅 시 `Ankole.Plugins.Spec.from_module/1`이 이 콜백들을 읽어 검증된 `Spec`을 생성합니다. 형태 검증 실패, 중복 ID, 계약 검증 오류가 하나라도 있으면 Ankole은 원인이 된 모듈을 명시하고 애플리케이션 부팅을 즉시 중단합니다.

## 서브시스템 계약 및 사이트 확장 지점

`Ankole.Plugins.Contracts`는 다섯 가지 서브시스템 어댑터 계약을 정의하며, 각 계약은 부팅 시점의 `validate` 검증과 선택적인 `refresh` 게시 및 `veto_disable` 트랜잭션 가드를 제공합니다.

- **`signals.adapter`** — 메시징·이벤트 어댑터를 선언합니다. `Ankole.Signals.Adapters`가 이를 검증하며, 검증을 통과한 어댑터는 Signal Bindings와 Conversations 전달에서 사용할 수 있습니다.
- **`signals.webhook_handler`** — `/webhooks/v1/:handler_id/:instance_id/:kind` 엔드포인트용 HTTP 웹훅 핸들러를 선언하며, `Ankole.Signals.WebhookHandlers`가 검증합니다.
- **`principals.identity_provider`** — 엔터프라이즈 Identity Provider 및 디렉터리 동기화 어댑터를 선언하며, `Ankole.IdentityProviders`가 검증합니다.
- **`ai_gateway.provider`** — 모델 프로바이더 어댑터를 선언합니다. `Ankole.AIGateway.Providers`가 이를 검증하고 `refresh`를 통해 활성 선언을 AI Gateway에 게시합니다.
- **`agent_workers.provider_kind`** — Agent Worker 인프라 종류(`Ankole.AgentWorkers.ProviderKind`)를 선언합니다. `refresh`를 통해 발견된 사양과 활성 사양을 게시하며, 어느 테넌트에든 해당 종류에 할당된 Worker 행이 남아 있으면 `veto_disable`(`Ankole.AgentWorkers.Providers.veto_disable_in_tx/2`)로 플러그인 비활성화를 차단합니다.

이 밖에도 사이트 빌드 전반에서 퍼스트파티 확장은 다음과 같은 컴파일 타임·사이트 범위 확장 지점을 함께 활용합니다.

- **`Ankole.Plugins.ConfigField`** — 플러그인 어댑터에서 Console 및 Pod 설정 폼으로 타입이 지정된 필드 스키마를 게시합니다.
- **도메인 트랜잭션 훅(`hooks/0`)** — 소유 도메인의 트랜잭션과 잠금 순서 안에서 `Ankole.Plugins.Hook.before_commit_in_tx/2`를 동기식으로 실행합니다.
- **외부 HTTP Plug** — 빌드에서 선택된 외부 라우터가 `AnkoleWeb.runtime_forward`를 통해 코어 라우터로 요청을 넘기기 전에 입장 챌린지 등의 요청 Plug를 먼저 실행합니다.
- **이중 범위 확장 JSON:API 라우트** — 사이트 Host와 Pod Host의 독립된 `/api/v2/*` 범위 아래에 타입화된 확장 JSON:API 라우트를 마운트하고 `Ankole.AuthZ.Authorizer`로 인가합니다.
- **타입화된 UI 슬롯(`entries.json` `overrides`)** — 공용 웹앱(`PodAppSlots`, `ConsoleAppSlots`, `AuthAppSlots`)을 감싸서 HTML 셸의 활성 사이트 플러그인 스냅샷(`ankole-active-plugins`)과 선택적 OpenFeature `when` 조건에 따라 지연 로드(lazy) 컴포넌트를 렌더링합니다.

프로세스 재시작 없이 실시간으로 전환해야 하는 런타임 정책 플래그는 플러그인 활성화가 아니라 OpenFeature(`Ankole.Features`)에서 관리합니다.

## Cohort 감독 트리와 다음 시작 경계

초기 설정이 완료된 사이트에서 `:optional` 플러그인은 사이트 전체 단위로 적용되며 기본값은 비활성(fail-closed)입니다. 운영자는 PostgreSQL에 저장되는 전역 `AppConfigure` 키 `plugins.enabled_ids`를 수정해 필요한 플러그인을 명시적으로 활성화합니다.

`plugins.enabled_ids`를 변경하더라도 실행 중인 프로세스나 어댑터, 설정 정의가 즉시 교체되지는 않으며, 변경 내용은 **다음 Ankole 프로세스 시작 시점**에 반영되도록 예약됩니다. 또한 설정 쓰기 트랜잭션 내부에서 `Ankole.Plugins.Contracts.veto_disable/2`가 실행되어, 영속 상태가 의존하고 있는 플러그인은 비활성화할 수 없도록 차단합니다.

런타임에는 `Ankole.Plugins.Cohort`가 단일 불변 부팅 스냅샷을 기준으로 `:rest_for_one` 전략에 따라 `Ankole.Plugins.Registry`를 먼저 시작하고, 이어서 `Ankole.Plugins.Supervisor`를 감독합니다.

- `Ankole.Plugins.Registry`는 부팅 스냅샷을 한 번 확정한 뒤 활성 선언 검증, 플러그인 `AppConfigure` 키 등록, 서브시스템 `refresh` 호출, `:persistent_term` 스냅샷 게시를 수행합니다.
- `Ankole.Plugins.Supervisor`는 활성 플러그인이 선언한 `children/0` 프로세스를 시작합니다.
- 만약 `Ankole.Plugins.Registry`가 비정상 종료되면 `Ankole.Plugins.Cohort`가 동일한 불변 부팅 스냅샷으로 `Registry`와 `Supervisor`를 함께 재시작합니다. 덕분에 부팅 이후에 설정이 수정되었더라도 장애 복구 도중에 활성 플러그인 구성이 뒤바뀌지 않으며, 개별 플러그인 자식 프로세스의 오류는 `Ankole.Plugins.Supervisor` 내부에 격리됩니다.

## 운영자 API

사이트 관리자는 다음 두 JSON:API 라우트를 통해 Control Plane Plugins 상태를 조회하고 다음 시작 시점의 활성화 목록을 예약합니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/api/v2/site/control-plane-plugins` | 발견된 플러그인 목록과 `activation`, `configured_enabled`, `active`, `restart_required` 상태 조회 |
| `PUT` | `/api/v2/site/control-plane-plugins` | `{ "data": { "id": string, "enabled": boolean } }` 본문으로 다음 프로세스 시작 시 적용할 `:optional` 플러그인 설정 |

두 라우트 모두 특권 테넌트의 `site_console:control_plane_plugins`(`read` 및 `update`) 권한으로 보호됩니다.

## 범위와 경계

Control Plane Plugins는 컨트롤 플레인과 동일한 BEAM 노드 및 신뢰 도메인 안에서 실행됩니다. 모델이 호출하는 Agent Computer Worker 도구나 Skill은 이곳이 아니라 [Agent Library](../agent-library/)에서 관리하며, 컨트롤 플레인 어댑터와 이에 대응하는 Agent Plugin은 각각 독립적인 활성화 상태를 가집니다.

## 다음 단계

- 플러그인이 선언할 수 있는 메시징 및 웹훅 어댑터는 [Signals](../signals/) 문서를 참조하세요.
- `AppConfigure` 키와 기능 플래그 정책은 [AppConfigure](../app-configuration/) 및 [Console](../console-api/) 문서를 참조하세요.
- 사이트 관리 권한 모델은 [Principal과 AuthZ](../principal-authz/) 문서를 참조하세요.
