---
title: Control Plane Plugins
description: 퍼스트파티 Elixir 확장 모델 — discovered 및 active plugin, subsystem contract, AppConfigure key, supervised children, 그리고 next-start 활성화 경계.
section: Developer guide
order: 110
---

Control Plane Plugin은 Ankole 배포 인스턴스가 자체 control plane을 확장하는 방식입니다. signal adapter, identity provider, AppConfigure key 또는 supervised process를 추가할 때 control plane이 그것들을 일회성 코드 경로로 키우지 않아도 됩니다. 이 페이지는 `Ankole.Plugins`의 실제 코드에 비추어 모델을 설명합니다.

핵심 속성을 먼저 말하면, 이들은 설치 가능한 확장 마켓플레이스가 아니라 release에 컴파일되는 퍼스트파티 Elixir 모듈입니다. plugin은 부팅 시 발견되고 검증되며, 단일 전역 활성화 목록을 통해 선택되고, 다음 프로세스 시작 시에만 활성화됩니다. hot-load도, 타사 발견도, 격리 메커니즘도 없습니다. 이는 의도된 설계입니다.

## 의미가 다른 두 단계

plugin의 수명 주기에는 두 단계가 있으며, 이 구분은 중요한 의미를 가집니다.

- **Discovered** — 부팅 시 발견되고 검증된 모든 plugin 모듈. 활성화 여부와 관계없이 operator가 볼 수 있는 전체 카탈로그입니다.
- **Active** — 전역 활성화 목록에 있는 discovered plugin. active plugin만 AppConfigure key를 등록하고 supervised children을 시작합니다.

discovered지만 active가 아닌 plugin은 보이지만 비활성 상태입니다. 해당 선언은 그것을 소비할 subsystem에 도달하지 않으며 children도 실행되지 않습니다. 이 덕분에 operator는 하나를 선택하기 전에 전체 카탈로그를 살펴볼 수 있습니다.

## Plugin 계약

plugin은 `Ankole.Plugins.Plugin`에 대해 소수의 callback을 구현하는 Elixir 모듈입니다. 필수는 하나뿐입니다.

- **`plugin_id/0`** — plugin의 정체성. `~r/\A[a-z][a-z0-9_-]*\z/`와 일치하는 소문자 slug입니다.

나머지는 선택 사항이며 모듈이 export하지 않으면 빈 값 또는 nil로 기본 설정됩니다.

- **`display_name/0`**, **`description/0`** — operator 화면을 위한 지역화된 텍스트.
- **`app_config_definitions/0`**, **`app_config_patterns/0`** — plugin이 기여하는 AppConfigure key.
- **`adapter_declarations/0`** — plugin이 subsystem contract에 연결되게 하는 일반 envelope.
- **`children/0`** — plugin이 시작되기를 원하는 supervised child spec.

`Spec.from_module/1`은 부팅 시 이러한 callback을 읽고 `Spec`으로 정규화합니다. plugin이 소유한 형태(identity, 지역화된 텍스트, AppConfigure 선언, children, adapter 선언 envelope)에 대한 검증은 엄격하며, 오류에는 문제가 있는 모듈이 포함되므로 부팅 실패 시 책임이 있는 plugin을 가리킵니다.

## 서브시스템 계약

plugin은 이름이 있는 contract를 통해 subsystem에 연결되며, contract id에는 dot이 포함될 수 있어 subsystem이 이를 네임스페이스할 수 있습니다. 실제 사용되는 contract는 다음과 같습니다.

- **`signals_gateway.adapter`** — SignalsGateway가 adapter registry로 해석하는 Signal adapter를 선언합니다. 이것이 새 chat 또는 event provider가 binding target으로 사용 가능해지는 방식입니다.
- **`signals_gateway.webhook_handler`** — `/webhooks/v1/:handler_id/:instance_id/:kind` 전면(front door)의 handler를 선언합니다. handler는 provider 인증을 담당하고 정규화된 fact로 ingress를 호출합니다.
- **`principals.identity_provider`** — operator가 관리자 로그인용으로 구성할 수 있는 identity provider를 선언합니다.

contract별 callback 의미는 contract를 소비하는 subsystem에 남습니다. plugin registry는 일반 adapter 선언 envelope만 보유하며, subsystem(예: `SignalsGateway.Adapters`)이 자신의 contract id에 대한 선언을 읽고 해석합니다. 이 분리는 registry를 단순한 카탈로그로, subsystem을 똑똑한 소비자로 유지합니다.

## 활성화 경계: 다음 프로세스 시작

plugin은 인스턴스 전체에 적용되며 fail-closed이므로 operator는 하나의 영구 목록(`plugins.enabled_ids`, PostgreSQL에 저장된 AppConfigure key)을 통해 명시적으로 선택합니다. registry는 control plane이 시작될 때 `init/1`에서 이 목록을 한 번 읽습니다.

활성화 목록을 변경해도 즉시 적용되지는 **않습니다**. 다음 Ankole 프로세스 시작 시 적용됩니다. 이는 의도된 것입니다. plugin을 활성화하거나 비활성화하면 supervised children과 config key가 추가되거나 제거될 수 있는데, 이는 hot-swap이 아니라 부팅 시점의 문제입니다. 따라서 Console의 `PUT /control-plane-plugins` route는 “다음 프로세스 시작을 위해 Control Plane Plugin 하나를 구성”이라고 표시됩니다. 즉 의도를 기록하며, 재시작이 이를 적용합니다.

registry 자체는 프로세스 수명 동안 상태가 불변인 GenServer입니다. `init/1` 중 모듈 검증, 유일성 불변 조건, 또는 config 등록이 실패하면 `:stop`을 반환하며, 이는 시스템이 부분적으로 등록된 plugin 집합으로 실행되기 전에 애플리케이션 시작을 중단시킵니다. 잘못된 plugin은 조용히가 아니라 크게 부팅을 실패시킵니다.

## Operator 화면

두 개의 console 범위 route가 이 모델을 다룹니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/control-plane-plugins` | active 및 next-start plugin 상태 나열 |
| `PUT` | `/control-plane-plugins` | 다음 프로세스 시작을 위한 plugin 하나 구성 |

둘 다 Console policy(`control_plane_plugins` read 및 update action)를 통과하므로 Console의 나머지 부분과 동일한 관리자 권한 아래에 있습니다. 목록 응답은 현재 active인 것과 다음 시작을 위해 준비된 것을 모두 보여주므로 operator가 둘을 구분할 수 있습니다.

## 퍼스트파티 확장 모델과의 관계

프로젝트의 설계 규칙은 확장 모델을 신뢰된 퍼스트파티로 취급하는 것이며, Control Plane Plugin이 바로 그 표면입니다. plugin은 자신이 확장하는 코드와 함께 release에 컴파일됩니다. plugin은 control plane과 동일한 신뢰 도메인에서 실행됩니다. plugin과 control plane 사이에는 sandbox가 없습니다. plugin은 contract를 통해 스스로를 선언한 control-plane 코드이기 때문입니다.

이것이 모델이 여기서 멈추는 이유입니다. 타사 마켓플레이스도, hot-loading도, plugin별 격리도 없습니다. 그것들은 서로 다른 위협 모델을 가진 다른 제품이 되었을 것입니다. 모델이 대신 제공하는 것은 퍼스트파티 코드가 control plane이 이미 소비하는 방법을 아는 기능을 기여하는 규율 있는 방식으로, 부팅 시 검증되고 명시적인 operator 선택을 통해 활성화됩니다.

## Control Plane Plugin이 아닌 것

이들은 런타임 plugin 스토어도, operator가 검토하지 않은 코드를 배포하는 방법도 아닙니다. Agent Computer Worker tool이나 skill이 있는 곳도 아닙니다. 그것들은 [Agent Library](../agent-library/) 기능과 worker 측 툴링입니다. 또한 hot-configurable하지 않습니다. next-start 규칙이 계약이며, plugin이 변경하는 것(children, config key)이 부팅 시점의 문제이기 때문에 존재합니다. 경계는 명확합니다. 퍼스트파티 코드, contract를 통한 선언, 부팅 시 검증, 다음 시작 시 활성화입니다.

## 다음 단계

- plugin이 선언할 수 있는 signal adapter는 [SignalsGateway](../signals-gateway/) 페이지를 참조하세요.
- plugin이 기여하는 AppConfigure key는 [Console](../console-api/) 페이지를 참조하세요.
- 이 확장 표면이 놓여 있는 신뢰 모델은 [Principal과 AuthZ](../principal-authz/)를 참조하세요.