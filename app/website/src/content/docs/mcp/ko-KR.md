---
title: MCP server 레퍼런스
description: Skill 기반 MCP dependency가 Main, Background, Automation 실행에 어떻게 들어가는지 설명합니다.
section: Reference
order: 201
---

Ankole은 도메인 통합을 위해 Skill 뒷단에서 MCP를 사용합니다. Agent 수준의 MCP registry나 영구적인 mcporter config를 유지하지 않습니다.

Skill MCP dependency는 native model tool로 등록되지 않습니다. Agent는 이들의 전체 MCP catalog를 받지 않습니다. 이렇게 하여 Skill이 라우팅 소유자로 유지되고 두 번째 tool 선택 표면이 생기지 않습니다.

## dependency 선언

Skill `openai.yaml`의 `dependencies.tools` 아래에 MCP dependency를 추가하십시오.

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-http-server
      description: "Lookup service"
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: MCP_HTTP_TOKEN
      enabled_tools:
        - lookup

    - type: mcp
      value: my-stdio-server
      transport: stdio
      command: bunx --bun @example/mcp-server
      disabled_tools:
        - delete_record
```

하나의 Skill은 최대 64개의 dependency를 선언할 수 있습니다. schema는 엄격하며 알 수 없거나 transport와 호환되지 않는 필드를 거부합니다.

### `streamable_http`

| 필드 | 의미 |
| --- | --- |
| `url` | HTTP 또는 HTTPS 서버 URL |
| `bearer_token_env_var` | bearer token을 담고 있는 environment variable 이름 |
| `enabled_tools` | 선택적, 정확한 raw-name allowlist |
| `disabled_tools` | 선택적, 정확한 raw-name denylist |

token은 [Environment variables](../worker-env/)에 저장하십시오. Skill에는 변수 이름만 넣으십시오.

### `stdio`

| 필드 | 의미 |
| --- | --- |
| `command` | 서버를 시작하는 신뢰할 수 있는 명령줄 |
| `enabled_tools` | 선택적, 정확한 raw-name allowlist |
| `disabled_tools` | 선택적, 정확한 raw-name denylist |

Agent Computer는 `/bin/sh -lc`로 명령을 실행합니다. stdio는 신뢰할 수 있는 first-party 서버 명령에만 사용하십시오.

선언에는 호출 timeout이 없습니다. Skill 또는 Automation script가 각 mcporter list 또는 call 명령에 `--timeout`을 전달합니다.

## 활성 집합과 충돌

실행은 현재 활성화된 Skill의 MCP dependency 합집합을 받습니다. 두 Skill이 같은 서버 이름을 사용할 수 있는 것은 connection, description, filter 필드가 일치할 때뿐입니다. 충돌이 있으면 실행 설정이 중지됩니다.

`ankole-runtime`은 어떤 모델이 Skill을 읽을 수 있는지 제어합니다. Main Agent는 `any`와 `main` Skill을 사용합니다. Background Agent Jobs는 `any`와 `background_job` Skill을 사용합니다. Automation Jobs는 모델을 실행하지 않으므로 `ankole-runtime` 필터 없이 현재 활성화된 모든 Skill의 dependency를 받습니다.

Skill을 비활성화하면 다음 turn, Background 실행 또는 Automation 시도에서 해당 dependency가 제거됩니다.

## 생성된 mcporter config

Agent Computer는 실행마다 고유한 `0600` config를 작성하고 그 경로를 `MCPORTER_CONFIG`로 주입합니다. 파일에는 항상 `imports: []`가 포함되므로 mcporter는 Agent Home, 프로젝트, Codex, editor 또는 호스트 configuration을 병합하지 않습니다. 파일은 실행이 끝나면 제거됩니다.

파일에는 connection 사실과 credential 변수 이름만 들어 있습니다. WorkerEnv secret 값은 절대 포함하지 않습니다.

Main Agent는 command tool을 통해 mcporter를 호출합니다. Background Agent Jobs는 Codex terminal을 통해 호출합니다. Automation Jobs는 `main.ts`에서 `Bun.spawn`으로 호출합니다.

## Native model-visible MCP 경계

현재 Ankole과 함께 번들로 제공되는 model-visible MCP server는 없습니다. 미래의 구체적인 통합은 Main과 Background에서 동일한 `mcp__<server>` 네임스페이스, tool 이름, description 및 지연 로딩 동작을 사용해야 합니다. Ankole은 server JSON Schema를 각 runtime에 변경 없이 전달합니다. Main은 자체 Responses tool owner를 사용하고, Background는 Codex native MCP를 사용하여 Codex가 해당 프로젝션을 소유하게 합니다. Ankole은 한 runtime의 schema를 다른 runtime을 모방하도록 다시 쓰지 않으며, 이 미래 사례를 위해 빈 registry나 일반 로컬 MCP loader를 추가하지 않습니다.

## tool 하나 선택 및 호출

Skill은 schema discovery 전에 domain tool 하나를 선택해야 합니다. 현재 schema가 필요할 때 해당 tool만 검사하십시오.

```bash
mcporter list 'my-http-server.lookup' --schema --json --timeout 360000
```

argument 객체를 stdin으로 전송하십시오. JSON을 shell 텍스트에 삽입하지 마십시오.

```bash
mcporter call 'my-http-server.lookup' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

Automation script도 같은 argv를 사용하고, 자식 프로세스 stdin에 JSON을 쓰고, exit code를 확인하고, stdout을 파싱합니다.

## 보안 제한

MCP 출력은 신뢰할 수 없는 input입니다. Skill 및 mcporter 경로는 Ankole의 이전 native output-schema 검증, MCP annotation 스케줄링, tool 수준 승인 UI 또는 모든 WorkerEnv secret에 대한 결과 redaction을 제공하지 않습니다. 신뢰할 수 있는 first-party MCP Skill에 사용하십시오. 원격 credential scope가 실제 읽기/쓰기 권한 경계로 남습니다.

## 다음 단계

- Skill 지침 작성은 [Writing a Skill](../writing-a-skill/)을 읽으십시오.
- bearer token 구성은 [Environment variables](../worker-env/)를 읽으십시오.
- 활성화된 기능 운영은 [Using MCP](../using-mcp/)를 읽으십시오.