---
title: MCP server 레퍼런스
description: Skill 기반 MCP dependency가 Main, Background, Automation 실행에 어떻게 들어가는지 설명합니다.
section: Reference
order: 201
---

Ankole은 외부 도메인 통합을 위해 Skill 내부에서 MCP를 사용하며, Agent 단위의 MCP 레지스트리나 영구적인 mcporter 설정 파일을 따로 두지 않습니다.

Skill에 선언된 MCP 의존성은 네이티브 모델 도구로 등록되지 않고, 전체 MCP 도구 카탈로그가 Agent에 그대로 노출되지도 않습니다. 따라서 라우팅 소유권이 항상 Skill에 머물며, 모델 앞에 별도의 도구 선택 경로가 하나 더 생기는 일을 막을 수 있습니다.

## dependency 선언

Skill의 `openai.yaml` 파일 안 `dependencies.tools` 아래에 MCP 의존성을 선언합니다.

```yaml
dependencies:
  tools:
    - type: mcp
      value: my-http-server
      description: "Lookup service"
      transport: streamable_http
      url: https://mcp.example.com/mcp
      protocol_version: 2026-07-28
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

Skill 하나당 최대 64개의 의존성을 선언할 수 있습니다. 스키마 검증이 엄격하게 적용되므로, 정의되지 않은 필드나 선택한 전송 방식(`transport`)과 맞지 않는 필드가 있으면 거부됩니다.

### `streamable_http`

| 필드 | 의미 |
| --- | --- |
| `url` | HTTP 또는 HTTPS 서버 URL |
| `protocol_version` | 선택적 프로토콜 모드(`auto`, `legacy`, `2026-07-28`, 기본값 `auto`) |
| `bearer_token_env_var` | Bearer 토큰이 담긴 환경 변수 이름 |
| `enabled_tools` | 선택 사항, 정확한 원본 도구 이름 기준 허용 목록(allowlist) |
| `disabled_tools` | 선택 사항, 정확한 원본 도구 이름 기준 차단 목록(denylist) |

원격 서버가 특정 프로토콜 세대를 요구하는 경우에만 `protocol_version`을 고정하십시오. 실제 토큰 값은 [Environment variables](../worker-env/)에 저장하고, Skill 파일에는 환경 변수 이름만 적어야 합니다.

### `stdio`

| 필드 | 의미 |
| --- | --- |
| `command` | 서버를 기동할 신뢰할 수 있는 명령줄 |
| `enabled_tools` | 선택 사항, 정확한 원본 도구 이름 기준 허용 목록(allowlist) |
| `disabled_tools` | 선택 사항, 정확한 원본 도구 이름 기준 차단 목록(denylist) |

Agent Computer는 지정된 명령을 `/bin/sh -lc`로 실행하므로, `stdio` 방식은 신뢰할 수 있는 퍼스트파티 서버 명령에만 사용하십시오.

선언 파일 자체에는 호출 타임아웃 필드가 없습니다. 대신 Skill 지침이나 Automation 스크립트에서 `mcporter list` 또는 `mcporter call`을 실행할 때마다 `--timeout` 플래그를 직접 전달합니다.

## 활성 집합과 충돌

실행 시점에는 현재 활성화된 Skill들의 MCP 의존성 합집합이 주입됩니다. 서로 다른 두 Skill이 동일한 서버 이름을 사용하려면 연결 정보, 설명, 도구 필터 필드가 모두 일치해야 하며, 정의가 서로 충돌하면 실행 준비 단계에서 중단됩니다.

모델이 어떤 Skill을 읽을 수 있는지는 `ankole-runtime` 필드로 결정됩니다. Main Agent는 `any`와 `main` Skill을 사용하고, Background Agent Jobs는 `any`와 `background_job` Skill을 사용합니다. 반면 Automation Jobs는 모델을 실행하지 않으므로 `ankole-runtime` 구분 없이 현재 활성화된 모든 Skill의 의존성을 전달받습니다.

Skill을 비활성화하면 다음 턴이나 다음 Background 실행, 또는 다음 Automation 시도부터 해당 의존성이 제외됩니다.

## 생성된 mcporter config

Agent Computer는 매 실행마다 권한이 `0600`인 고유 설정 파일을 생성해 그 경로를 `MCPORTER_CONFIG` 환경 변수로 주입하며, 실행이 끝나면 파일을 삭제합니다. 생성된 파일에는 항상 `imports: []`가 들어가므로, mcporter가 Agent Home이나 프로젝트, Codex, 에디터, 호스트의 외부 설정을 임의로 병합하지 않습니다.

또한 이 설정 파일에는 연결 정보와 자격 증명 환경 변수 이름만 기록되며, 실제 WorkerEnv 시크릿 값은 절대 포함되지 않습니다.

실행 주체별로 Main Agent는 `command` 도구를 통해, Background Agent Jobs는 Codex 터미널을 통해, Automation Jobs는 `main.ts` 안에서 `Bun.spawn`을 통해 mcporter를 호출합니다.

## tool 하나 선택 및 호출

Skill 지침에서는 스키마를 조회하기 전에 사용할 도메인 도구 하나를 먼저 고르도록 안내해야 합니다. 현재 스키마를 확인해야 할 때도 선택한 그 도구 하나만 조회하십시오.

```bash
mcporter list 'my-http-server.lookup' --schema --json --timeout 360000
```

호출 인수는 JSON 문자열을 셸 명령줄에 직접 끼워 넣지 말고 표준 입력(stdin)으로 전달하십시오.

```bash
mcporter call 'my-http-server.lookup' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

Automation 스크립트에서도 동일한 인자 배열(`argv`)로 자식 프로세스를 실행하고, stdin에 JSON을 기록한 뒤 종료 코드(exit code)를 확인해 stdout 결과를 파싱하면 됩니다.

## 보안 제한

MCP 서버의 응답은 신뢰할 수 없는 외부 입력으로 다루어야 합니다. Skill과 mcporter 실행 경로에서는 출력 스키마 검증, MCP 어노테이션 기반 스케줄링, 도구 단위의 별도 승인 확인, 응답 본문 내 WorkerEnv 시크릿 마스킹(redaction)을 수행하지 않습니다. 따라서 신뢰할 수 있는 퍼스트파티 MCP Skill에만 사용하시고, 실제 읽기·쓰기 권한 통제는 원격 자격 증명의 권한 범위(scope)로 제한하십시오.

## 다음 단계

- Skill 지침 작성 방법은 [Writing a Skill](../writing-a-skill/)을 참조하십시오.
- Bearer 토큰 설정 방법은 [Environment variables](../worker-env/)를 참조하십시오.
- 활성화된 MCP Skill 운영 방법은 [Using MCP](../using-mcp/)를 참조하십시오.
