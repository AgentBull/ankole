---
title: Skill 및 Control Plane Plugin 개발
description: Agent에 작업 방식을 추가하거나, 사이트 범위 adapter, 설정, 도메인 트랜잭션 hook, supervised service 및 Web UI 슬롯을 control plane에 추가하는 방법을 설명합니다.
section: Developer guide
order: 113
---

Skill과 Control Plane Plugin은 모두 Ankole을 확장하지만, 해결하는 문제가 서로 다릅니다. 코드를 작성하기 전에 올바른 확장 지점을 선택하십시오.

| 요구 사항 | 사용 방법 |
|---|---|
| Agent에게 특정 유형의 작업 수행 방법 가르치기 | Skill |
| Agent에게 MCP 기반 워크플로와 사용 지침 제공하기 | Skill |
| IdP, chat adapter, LLM Provider 또는 Worker provider 종류 추가하기 | Control Plane Plugin |
| 사이트 범위 설정, supervised service, 도메인 트랜잭션 hook, 확장 `/api/v2` 라우트 또는 Web UI 슬롯 추가하기 | Control Plane Plugin |
| 재시작 없이 런타임에서 소비자 정책을 동적으로 전환하기 | OpenFeature(`Ankole.Features`) |

Skill은 Agent가 읽는 파일의 집합입니다. 새로운 control-plane 빌드가 필요하지 않습니다. Control Plane Plugin은 릴리스에 컴파일되는 사이트 범위의 first-party 풀스택 확장입니다(테넌트나 개별 Agent 범위로 분리되지 않음). `:optional` Plugin은 `siteadmin`이 활성화한 뒤 다음 control plane 시작 시 활성화되며, `:always` Plugin은 소스 빌드와 함께 고정 활성화됩니다.

## Skill 작성

Skill은 `SKILL.md`를 포함하는 디렉터리입니다. references, templates, `agents/openai.yaml`도 포함할 수 있습니다.

```text
my-skill/
├── SKILL.md
├── agents/
│   └── openai.yaml
├── reference.md
└── templates/
```

디렉터리 이름에는 소문자, 숫자, 하이픈 또는 밑줄을 사용하십시오. 내장 Skill은 `app/library/skills/`에 있습니다. 설치된 Skill은 해당 Agent의 file space에 있습니다.

### frontmatter 작성

`SKILL.md` 상단의 YAML이 discovery와 enablement를 제어합니다.

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

`description`은 구체적인 trigger를 명시해야 합니다. Agent가 Skill을 읽을지 여부를 결정할 때 이 값을 사용하기 때문입니다. 작업에 Job 격리가 필요하면 `ankole-runtime: background_job`을 설정하십시오. Skill이 Linux tool을 필요로 하는 경우에만 `platforms: [linux]`를 설정하십시오.

### 배포되는 Skill을 Brain에서 발견할 수 있게 하기

모든 Prompt에 표시할 필요는 없지만 현재 작업과 의미상 관련될 때 발견해야 하는 SOP나 방법론에는 `brain-recall-only`를 사용하십시오.

```yaml
---
name: idea-lineage
description: Trace how one idea evolved through memory — first mention, best articulation, reversals, and the current live version, each cited from stored evidence.
tags:
  - idea lineage
  - how my thinking evolved
brain-recall-only: true
---
```

이 필드는 배포되는 standalone Skill과 Agent Plugin 안의 Skill만 지원합니다. Agent가 설치한 Skill은 이 발견 모드를 사용하지 않습니다. 배포되는 Skill 이름은 계속 전역에서 고유하며, Agent Plugin 소속이 namespace를 추가하지 않습니다. Brain은 표준 Skill metadata에서 `lazyload-agent-skills/<name>` 발견 레코드를 자동으로 파생합니다.

Skill에 `slug`, `type`, `title`, `aliases` 같은 Object 필드를 추가하지 마십시오. Brain은 `name`, `description`, `tags`를 검색하고 이름과 태그를 자연어 해석에 사용합니다. Skill 본문, 그 밖의 모든 Skill 파일, Agent별 교훈은 Brain에 들어가지 않습니다. 발견한 뒤에도 `skill_view`를 통해서만 읽을 수 있습니다.

### 본문 작성

우리의 로컬 규칙을 모르는 유능한 Agent를 위해 작성하십시오. 다음 사항을 명시합니다.

1. Skill을 사용해야 하는 시기.
2. 읽어야 할 input.
3. 작업 순서.
4. 필요한 결과.
5. 금지되거나 승인이 필요한 action.

각 reference와 template은 `SKILL.md`에서 이름으로 연결하십시오. Agent는 필요할 때만 이 파일들을 읽으므로, 기본 지침이 식별하지 않는 파일은 사용할 수 없습니다.

### MCP dependency 선언

MCP 실행 dependency를 `agents/openai.yaml`에 선언하십시오.

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-mcp-server
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MY_MCP_TOKEN
```

dependency는 Skill이 활성화된 동안에만 사용할 수 있습니다. `SKILL.md`에서는 domain tool과 선택 규칙을 이름으로 지정하고, Agent에게 선택한 tool만 `mcporter list server.tool --schema --json`으로 검사하고 stdin으로 JSON을 전달해 호출하라고 지시하십시오. 전체 contract는 [MCP reference](../mcp/)를 참조하십시오.

### Skill 검증

테스트용 Agent에서 Skill을 활성화하고 실제 작업을 부여하십시오. Agent가 Skill을 선택하고 필요한 파일을 읽으며 완료 기준을 따르는지 확인합니다. 선택이 실패하면 `description`을 개선하십시오. 실행이 불안정하면 순서와 제약을 명시적으로 만드십시오.

`brain-recall-only` Skill은 일반 Prompt에 표시되지 않는지, Brain이 이름, 설명, 태그로 발견할 수 있는지도 확인하십시오. `skill_view`가 호환되는 실행 표면에서는 전체 Skill을 로드하고, 호환되지 않는 표면에서는 기존 라우팅 또는 거부 동작을 유지하는지 확인하십시오. 그런 다음 Skill이나 부모 Agent Plugin을 비활성화하고 같은 Agent가 발견하거나 로드할 수 없는지 확인하십시오.

## Control Plane Plugin 개발

control plane이 소유한 사이트 범위 기능에는 Control Plane Plugin을 사용하십시오. 모듈은 `Ankole.Plugins.Plugin`을 구현합니다. 가장 작은 유효한 Plugin은 안정적인 ID 하나를 가집니다.

```elixir
defmodule Ankole.Plugins.MyPlugin do
  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "my-plugin"
end
```

Plugin ID에는 소문자 slug를 사용하십시오. 선택적 callback은 필요할 때만 구현하십시오.

| Callback | 목적 |
|---|---|
| `activation/0` | `:optional`(기본값, `plugins.enabled_ids`로 선택해 다음 시작 시 적용) 또는 `:always`(빌드와 함께 고정 활성화, Console 토글 없음) |
| `display_name/0`, `description/0` | Site Admin Console에 표시되는 현지화된 이름과 설명 |
| `adapter_declarations/0` | IdP, chat, LLM Provider, Worker provider(`agent_workers.provider_kind`) 또는 webhook adapter 선언 |
| `hooks/0` | 동기식 도메인 트랜잭션 hook(`Ankole.Plugins.Hook`을 구현하는 `[{hook_point, module}]`) 선언 |
| `app_config_definitions/0` | 고정 AppConfigure 설정 선언 |
| `app_config_patterns/0` | 동적 ID를 가진 설정 선언 |
| `children/0` | Plugin supervisor 아래에서 connection, registry, reconciler 시작 |

풀스택 빌드 확장은 코어 라우터 바깥에 요청 Plug를 감싸거나, 타입 지정 `/api/v2/*` JSON:API 라우트를 마운트하거나, `entries.json`의 `overrides`를 통해 타입 지정 Web UI 슬롯(`PodAppSlots`, `ConsoleAppSlots`, `AuthAppSlots`)을 바인딩할 수도 있습니다.

### Plugin 등록

모듈을 `config/config.exs`에 추가하십시오.

```elixir
config :ankole, :control_plane_plugin_modules, [
  Ankole.Plugins.MyPlugin
]
```

그러면 Plugin이 **Site Admin Console**(`/site-admin-console`의 **Global defaults** 범위, `GET` / `PUT /api/v2/site/control-plane-plugins`)의 사이트 범위 catalog에 표시됩니다. `siteadmin`이 `:optional` Plugin을 활성화하면 다음 control-plane 시작 시 불변 `:persistent_term` 부트 스냅샷으로 확정되며 설정, adapter, hook, supervised process가 등록됩니다(어느 테넌트든 해당 Worker provider 종류를 참조하는 동안에는 `veto_disable`이 비활성화를 차단합니다). `:always` Plugin은 릴리스에 컴파일되어 있으면 자동으로 활성화됩니다. Plugin은 hot loading을 지원하지 않으므로, 재시작 없이 동적으로 전환해야 하는 정책에는 OpenFeature(`Ankole.Features`)를 사용하십시오.

### adapter 선언

`adapter_declarations/0`는 adapter 선언을 반환합니다. `contract_id`가 각 선언을 읽는 subsystem을 선택합니다.

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

adapter별 필드는 소유 subsystem이 정의합니다. chat adapter는 [Signals](../signals/) contract를 따릅니다. IdP, 모델 Provider, Worker provider는 기존 registry를 사용합니다. Plugin 내부에 병렬 configuration 경로를 만들지 마십시오.

### 설정, hook 및 service 선언

운영자가 runtime에 관리하는 설정에는 `app_config_definitions/0` 또는 `app_config_patterns/0`을 사용하십시오. environment variable은 database를 사용할 수 있기 전에 존재해야 하는 시작 시점의 사실에만 사용하십시오.

도메인 트랜잭션(`:create_agent`, `:create_invitation`, `:enable_signal_binding`, `:enable_identity_provider`, `:store_file`, `:commit_files`, `:create_pod_page`, `:restore_pod_page`, `:insert_base_records`, `:admit_compute`)에 동기식 승인 또는 쿼터 검사를 연결하려면 `hooks/0`을 사용하십시오. 각 hook 모듈은 `Ankole.Plugins.Hook.before_commit_in_tx/2`를 구현하며 호출자의 트랜잭션 안에서 `:ok` 또는 `{:error, reason}`을 반환합니다(오류 반환 시 트랜잭션이 롤백됩니다).

`children/0`는 표준 OTP child specification을 반환합니다. connection과 reconciler는 Plugin supervisor 아래에 두십시오. 이들은 Plugin이 활성화될 때 시작되고, 다음 control-plane 시작 시 비활성화된 후 중지됩니다.

### Plugin 검증

control-plane 테스트와 정적 검사를 실행하십시오. `:optional` Plugin은 **Site Admin Console**(`/site-admin-console`)에서 활성화한 뒤 control plane을 다시 시작하고, `:always` Plugin은 시작 시 바로 활성화되는지 확인합니다. Plugin이 활성 상태이고 설정이 표시되며 hook이 계약을 강제하고, 선언된 각 adapter가 실제 connection을 완료하는지 확인합니다. Plugin이 외부 protocol을 구현하는 경우 관련 integration test를 실행하십시오.

## 계속 보기

- Skill의 enablement, inheritance, installation에 대해서는 [Agent Library](../skills/)를 참조하십시오.
- discovery와 activation에 대해서는 [Control Plane Plugins](../control-plane-plugins/)를 참조하십시오.
- 새 LLM Provider에 대해서는 [Add a Provider](../adding-a-provider/)를 참조하십시오.
