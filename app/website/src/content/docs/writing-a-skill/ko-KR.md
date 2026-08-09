---
title: Skill 및 Control Plane Plugin 개발
description: Agent에 작업 방식을 추가하거나, identity, channel, configuration 및 supervised service를 control plane에 추가하는 방법을 설명합니다.
section: Developer guide
order: 113
---

Skill과 Control Plane Plugin은 모두 Ankole을 확장하지만, 해결하는 문제가 서로 다릅니다. 코드를 작성하기 전에 올바른 확장 지점을 선택하십시오.

| 요구 사항 | 사용 방법 |
|---|---|
| Agent에게 특정 유형의 작업 수행 방법 가르치기 | Skill |
| Agent에게 MCP 기반 워크플로와 사용 지침 제공하기 | Skill |
| IdP, chat adapter 또는 Provider 종류 추가하기 | Control Plane Plugin |
| control plane에 설정 또는 supervised service 추가하기 | Control Plane Plugin |

Skill은 Agent가 읽는 파일의 집합입니다. 새로운 control-plane 빌드가 필요하지 않습니다. Control Plane Plugin은 control plane에 컴파일되는 first-party Elixir 모듈입니다. 등록이 필요하며, 다음 control plane 시작 시 활성화됩니다.

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

dependency는 Skill이 활성화된 동안에만 사용할 수 있습니다. native model tool로 등록되지 않습니다. `SKILL.md`에서는 domain tool과 선택 규칙을 이름으로 지정하고, Agent에게 선택한 tool만 `mcporter list server.tool --schema --json`으로 검사하고 stdin으로 JSON을 전달해 호출하라고 지시하십시오. 전체 contract는 [MCP reference](../mcp/)를 참조하십시오.

### Skill 검증

테스트용 Agent에서 Skill을 활성화하고 실제 작업을 부여하십시오. Agent가 Skill을 선택하고 필요한 파일을 읽으며 완료 기준을 따르는지 확인합니다. 선택이 실패하면 `description`을 개선하십시오. 실행이 불안정하면 순서와 제약을 명시적으로 만드십시오.

## Control Plane Plugin 개발

control plane이 소유한 기능에는 Control Plane Plugin을 사용하십시오. 모듈은 `Ankole.Plugins.Plugin`을 구현합니다. 가장 작은 유효한 Plugin은 안정적인 ID 하나를 가집니다.

```elixir
defmodule Ankole.Plugins.MyPlugin do
  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "my-plugin"
end
```

Plugin ID에는 소문자 slug를 사용하십시오. 다른 callback은 필요할 때만 구현하십시오.

| Callback | 목적 |
|---|---|
| `display_name/0`, `description/0` | Console에 표시되는 이름과 설명 |
| `adapter_declarations/0` | IdP, chat 및 기타 adapter 선언 |
| `app_config_definitions/0` | 고정 AppConfigure 설정 선언 |
| `app_config_patterns/0` | 동적 ID를 가진 설정 선언 |
| `children/0` | connection, registry, reconciler 시작 |

### Plugin 등록

모듈을 `config/config.exs`에 추가하십시오.

```elixir
config :ankole, :control_plane_plugin_modules, [
  Ankole.Plugins.MyPlugin
]
```

그러면 Plugin이 Console catalog에 표시됩니다. 관리자가 Plugin을 활성화한 후, 다음 control-plane 시작 시 설정, adapter, supervised process가 등록됩니다. Plugin은 hot loading을 지원하지 않습니다.

### adapter 선언

`adapter_declarations/0`는 adapter 선언을 반환합니다. `contract_id`가 각 선언을 읽는 subsystem을 선택합니다.

```elixir
@impl true
def adapter_declarations do
  [
    %{
      contract_id: "signals_gateway.adapter",
      id: "my-adapter",
      plugin_id: plugin_id()
    }
  ]
end
```

adapter별 필드는 소유 subsystem이 정의합니다. chat adapter는 [SignalsGateway](../signals-gateway/) contract를 따릅니다. IdP와 model Provider는 기존 registry를 사용합니다. Plugin 내부에 병렬 configuration 경로를 만들지 마십시오.

### 설정과 service 선언

운영자가 runtime에 관리하는 설정에는 `app_config_definitions/0` 또는 `app_config_patterns/0`을 사용하십시오. environment variable은 database를 사용할 수 있기 전에 존재해야 하는 시작 시점의 사실에만 사용하십시오.

`children/0`는 표준 OTP child specification을 반환합니다. connection과 reconciler는 Plugin supervisor 아래에 두십시오. 이들은 Plugin이 활성화될 때 시작되고, 다음 control-plane 시작 시 비활성화된 후 중지됩니다.

### Plugin 검증

control-plane 테스트와 정적 검사를 실행하십시오. Console에서 Plugin을 활성화하고 control plane을 다시 시작합니다. Plugin이 활성 상태이고 설정이 표시되며, 선언된 각 adapter가 실제 connection을 완료하는지 확인합니다. Plugin이 외부 protocol을 구현하는 경우 관련 integration test를 실행하십시오.

## 계속 보기

- Skill의 enablement, inheritance, installation에 대해서는 [Agent Library](../skills/)를 참조하십시오.
- discovery와 activation에 대해서는 [Control Plane Plugins](../control-plane-plugins/)를 참조하십시오.
- 새 LLM Provider에 대해서는 [Add a Provider](../adding-a-provider/)를 참조하십시오.