---
title: Skill 및 Control Plane Plugin 개발
description: Agent에 작업 방식을 추가하거나, 사이트 범위 adapter, 설정, 도메인 트랜잭션 hook, supervised service 및 Web UI 슬롯을 control plane에 추가하는 방법을 설명합니다.
section: Developer guide
order: 113
---

Skill과 Control Plane Plugin은 둘 다 Ankole의 기능을 확장하지만 해결하는 영역이 완전히 다릅니다. 작업을 시작하기 전에 목적에 맞는 확장 경로를 먼저 고르십시오.

| 해결하려는 과제 | 선택할 확장 방식 |
|---|---|
| 특정 업무 유형의 수행 절차를 Agent에게 알려 주기 | Skill |
| MCP 기반 도메인 워크플로와 호출 규칙을 Agent에게 제공하기 | Skill |
| 새로운 IdP, 채팅 어댑터, LLM Provider, 또는 Worker provider 종류 추가하기 | Control Plane Plugin |
| 사이트 범위 설정, 감독 대상 OTP 서비스, 도메인 트랜잭션 훅, 확장 `/api/v2` 라우트, Web UI 슬롯 추가하기 | Control Plane Plugin |
| 재시작 없이 런타임에 소비자 정책이나 기능을 동적으로 전환하기 | OpenFeature(`Ankole.Features`) |

Skill은 Agent가 필요할 때 읽어 들이는 파일 묶음이므로 control plane을 새로 빌드할 필요가 없습니다. 반면 Control Plane Plugin은 릴리스 바이너리에 함께 컴파일되는 사이트 범위의 퍼스트파티 풀스택 확장입니다(테넌트나 개별 Agent 단위로 분리되지 않습니다). `:optional` 플러그인은 `siteadmin`이 활성화한 뒤 다음 control plane 시작 시점에 반영되고, `:always` 플러그인은 소스 빌드와 함께 상시 활성으로 고정됩니다.

## Skill 작성

Skill은 `SKILL.md`를 중심으로 구성된 디렉터리이며, 보조 참조 문서나 템플릿, `agents/openai.yaml`을 함께 담을 수 있습니다.

```text
my-skill/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── reference.md
└── templates/
```

식별자는 Pod 안에서 고유해야 하며 영문 소문자나 숫자로 시작합니다. 소문자, 숫자, 마침표, 하이픈, 밑줄을 사용할 수 있습니다. 기본 Skill은 `app/library/skills/`에 두며, 사용자 정의 패키지는 **Meta Ankole → Skills**에서 만들거나 가져옵니다.

### frontmatter 작성

`SKILL.md` 상단의 YAML frontmatter가 Skill 탐색과 활성화 동작을 결정합니다.

```yaml
---
name: my-skill
description: "Use when the Agent must review a vendor contract."
default_enabled: true
category: productivity
tags: [Contracts]
ankole-runtime: background_job
platforms: [linux]
---
```

Agent는 `description` 문구를 보고 해당 Skill 본문을 펼쳐 읽을지 결정하므로, 언제 이 Skill을 써야 하는지 구체적인 발동 조건(trigger)을 적어야 합니다. 전용 워크스페이스 격리가 필요한 작업이면 `ankole-runtime: background_job`을 지정하고, Linux 전용 CLI 도구에 의존하는 경우에만 `platforms: [linux]`를 덧붙이십시오.

### 완전한 Skill 패키지

Skill은 필수 `SKILL.md`와 부속 파일로 구성됩니다. Frontmatter와 본문을 함께 편집하고, 스크립트·템플릿·바이너리 자료·참고 문서는 패키지 내 상대 경로를 유지합니다. 공식 Skill, Agent Plugin Skill, 사용자 정의 Skill의 식별자는 Pod 전체에서 고유해야 합니다.

`SKILL.md`에서 부속 파일을 명시적으로 참조하여 필요할 때 읽도록 합니다. 메인 Agent는 `/drive/Skills/<slug>/`를 사용하며 백그라운드 Job은 해당 Job에 허용된 패키지를 사용합니다. Skill을 활성화한 Agent는 패키지 전체를 읽을 수 있습니다. 열람 범위를 제한해야 하는 업무 데이터는 Brain이나 별도로 공유한 협업 페이지에 저장합니다.
### 본문 작성

기본 추론 역량은 충분하지만 조직 내부의 고유 규칙은 모르는 동료에게 업무를 인계한다는 기준으로 다음 다섯 가지를 명확히 적으십시오.

1. 이 Skill을 선택해야 하는 상황
2. 작업 전에 먼저 확인해야 할 입력 자료
3. 단계별 수행 순서
4. 제출해야 할 산출물 형식과 기준
5. 절대 해서는 안 되거나 사전 승인을 받아야 하는 작업

부속 참조 문서(`reference.md` 등)와 템플릿 파일은 반드시 `SKILL.md` 본문 안에서 정확한 파일 경로·이름으로 언급해 연결하십시오. Agent는 필요할 때만 부속 파일을 열어 보므로, 기본 지침에 언급되지 않은 파일은 존재 자체를 알지 못해 활용할 수 없습니다.

### MCP dependency 선언

MCP 서버 의존성은 `agents/openai.yaml` 파일에 선언합니다.

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-mcp-server
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MY_MCP_TOKEN
```

여기에 선언한 의존성은 해당 Skill이 활성 상태인 동안에만 주입됩니다. `SKILL.md` 본문에서는 사용할 도메인 도구 이름과 선택 기준을 구체적으로 밝히고, 선택한 그 도구 하나만 `mcporter list server.tool --schema --json`으로 조회한 뒤 표준 입력(stdin)으로 JSON 인수를 넘겨 호출하도록 지시하십시오. 전체 명세는 [MCP reference](../mcp/)를 참조하십시오.

### Skill 검증

작성을 마쳤다면 테스트용 Agent에서 해당 Skill을 켜고 실제 업무 요청을 보내 보십시오. Agent가 의도한 시점에 Skill을 골라 필요한 부속 파일을 읽고 완료 기준을 지키는지를 확인합니다. 만약 Skill 자체를 고르지 못한다면 `description`의 발동 조건을 더 선명하게 다듬고, 실행 순서가 흔들린다면 본문의 단계와 제약 조건을 더 구체적으로 적으십시오.

상대 경로, 실행 가능한 스크립트, 지원하는 실행 환경에서의 로드와 지원하지 않는 환경의 안내를 확인합니다. “모든 Agent에서 활성화”를 끄고 AI 동료와 내 어시스턴트의 개별 설정을 각각 검증하세요. 전체 스위치를 켰다가 꺼도 개별 설정은 유지되어야 합니다. 적용되는 개별 설정을 모두 해제하거나 상위 Plugin을 끄면 활성 카탈로그에서 제외되고 `skill_view`로도 읽을 수 없어야 합니다.

## Control Plane Plugin 개발

control plane이 직접 소유하는 사이트 범위 확장 기능을 추가할 때는 Control Plane Plugin을 작성합니다. 플러그인 모듈은 `Ankole.Plugins.Plugin` 동작(behaviour)을 구현하며, 최소 구성에서는 고유한 플러그인 ID 하나만 정의하면 됩니다.

```elixir
defmodule Ankole.Plugins.MyPlugin do
  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "my-plugin"
end
```

플러그인 ID에는 영문 소문자 슬러그를 사용하시고, 나머지 선택적 콜백은 실제로 필요한 항목만 구현하십시오.

| Callback | 역할 |
|---|---|
| `activation/0` | `:optional`(기본값, `plugins.enabled_ids`로 켜고 다음 시작 시 반영) 또는 `:always`(빌드 시 상시 활성 고정, Console 토글 없음) |
| `display_name/0`, `description/0` | Site Admin Console에 표시할 다국어 이름 및 설명 |
| `adapter_declarations/0` | IdP, 채팅 채널, LLM Provider, Worker provider(`agent_workers.provider_kind`), webhook 어댑터 선언 |
| `hooks/0` | 동기식 도메인 트랜잭션 훅(`Ankole.Plugins.Hook`을 구현한 `[{hook_point, module}]` 목록) 선언 |
| `app_config_definitions/0` | 고정 키를 갖는 AppConfigure 설정 필드 선언 |
| `app_config_patterns/0` | 동적 인스턴스 ID를 갖는 AppConfigure 설정 패턴 선언 |
| `children/0` | 플러그인 전용 supervisor 아래에서 기동할 연결 프로세스, 레지스트리, reconciler 정의 |

이에 더해 풀스택 빌드 확장에서는 코어 라우터 바깥에 요청 `Plug`를 감싸거나 타입 안전 `/api/v2/*` JSON:API 라우트를 마운트할 수 있고, 프런트엔드의 `entries.json` `overrides`를 통해 타입이 지정된 Web UI 슬롯(`PodAppSlots`, `ConsoleAppSlots`, `AuthAppSlots`)을 연결할 수도 있습니다.

### Plugin 등록

작성한 플러그인 모듈을 `config/config.exs`의 목록에 등록합니다.

```elixir
config :ankole, :control_plane_plugin_modules, [
  Ankole.Plugins.MyPlugin
]
```

등록된 플러그인은 **Site Admin Console**(`/site-admin-console`의 **Global defaults** 범위, `GET` / `PUT /api/v2/site/control-plane-plugins`)의 사이트 범위 카탈로그에 나타납니다. `siteadmin`이 `:optional` 플러그인을 활성화하면 다음 control plane 시작 시점에 불변 `:persistent_term` 부팅 스냅샷으로 확정되면서 설정 필드, 어댑터, 트랜잭션 훅, 감독 대상 프로세스가 일괄 등록됩니다(어느 테넌트에서든 해당 플러그인의 Worker provider 종류를 참조하는 동안에는 `veto_disable` 검사가 비활성화를 막습니다). `:always` 플러그인은 릴리스에 컴파일되어 있으면 별도 조작 없이 자동 활성화됩니다. 플러그인은 런타임 핫 로딩(hot loading)을 지원하지 않으므로, 재시작 없이 동적으로 전환해야 하는 정책에는 OpenFeature(`Ankole.Features`)를 사용하십시오.

### adapter 선언

서브시스템 어댑터를 추가할 때는 `adapter_declarations/0`에서 선언 맵 목록을 반환하며, 각 항목의 `contract_id`에 따라 연결될 소유 서브시스템이 정해집니다.

```elixir
@impl true
def adapter_declarations do
  [
    %{
      contract_id: "signals.adapter",
      id: "my-adapter",
      plugin_id: plugin_id()
    }
  ]
end
```

어댑터마다 요구되는 추가 필드는 각 소유 서브시스템이 정의합니다. 예를 들어 채팅 어댑터는 [Signals](../signals/) 계약을 따르고, IdP·모델 Provider·Worker provider는 각각의 기존 레지스트리에 통합됩니다. 플러그인 내부에 별도의 독자적인 설정 체계를 따로 만들지 마십시오.

### 설정, hook 및 service 선언

운영자가 런타임에 조정하는 설정은 `app_config_definitions/0` 또는 `app_config_patterns/0`으로 선언하고, 환경 변수는 PostgreSQL에 연결하기 전 부팅 단계에서 꼭 알아야 하는 초기 정보에만 사용하십시오.

주요 도메인 트랜잭션(`:create_agent`, `:create_invitation`, `:enable_signal_binding`, `:enable_identity_provider`, `:store_file`, `:commit_files`, `:create_pod_page`, `:restore_pod_page`, `:insert_base_records`, `:admit_compute`)에 동기식 승인 검사나 할당량(quota) 검증을 끼워 넣으려면 `hooks/0`을 구현하십시오. 각 훅 모듈은 `Ankole.Plugins.Hook.before_commit_in_tx/2`를 구현해 호출자의 트랜잭션 내부에서 `:ok` 또는 `{:error, reason}`을 반환하며, 오류를 반환하면 전체 트랜잭션이 즉시 롤백됩니다.

장기 실행 프로세스가 필요할 때는 `children/0`에서 표준 OTP child specification 목록을 반환해 연결 관리자와 reconciler를 플러그인 supervisor 아래에 두십시오. 해당 프로세스들은 플러그인이 활성화된 상태로 부팅될 때 함께 시작되고, 비활성화 설정 후 다음 재시작 시점부터 기동 대상에서 빠집니다.

### Plugin 검증

구현을 마친 뒤에는 control-plane 테스트와 정적 분석 검사를 실행하십시오. `:optional` 플러그인은 **Site Admin Console**(`/site-admin-console`)에서 켠 뒤 control plane을 재시작해 활성화 상태를 확인하고, `:always` 플러그인은 부팅 직후 바로 활성 상태로 올라오는지 확인합니다. 이어서 Console에 설정 필드가 정상 노출되는지, 트랜잭션 훅이 의도한 계약을 강제하는지, 선언한 각 어댑터가 실제 종단 간 연결을 맺는지 점검하십시오. 외부 프로토콜을 연동하는 플러그인이라면 해당 통합 테스트(integration test)까지 반드시 함께 실행하십시오.

## 계속 보기

- Skill 활성화, 전역 기본값 상속, 설치 구조는 [Agent Library](../skills/)를 참조하십시오.
- 플러그인 탐색과 기동 수명 주기는 [Control Plane Plugins](../control-plane-plugins/)를 참조하십시오.
- 새 LLM Provider 구현 방법은 [Add a Provider](../adding-a-provider/)를 참조하십시오.
