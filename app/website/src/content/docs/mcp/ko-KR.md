---
title: MCP server 레퍼런스
description: Connector, 원격 HTTP, 로컬 MCP 의존성과 올바른 호출 방법을 설명합니다.
section: Reference
order: 201
---

Skill이 업무에 맞는 도구를 선택하고 MCPorter가 스키마 조회와 호출을 담당합니다. MCP 의존성을 모델의 기본 도구로 등록하지는 않습니다. Worker는 제어면의 MCP 게이트웨이를 호출하며, 게이트웨이가 자격 증명을 확인하고 외부 서비스에 연결합니다.

## 의존성 선언

`agents/openai.yaml`에 선언합니다.

```yaml
dependencies:
  tools:
    - type: mcp
      value: github
      transport: connector
      toolkit: github
      enabled_tools:
        - repos_get
    - type: mcp
      value: lookup
      transport: streamable_http
      url: https://mcp.example.com/mcp
      bearer_token_env_var: LOOKUP_TOKEN
      enabled_tools:
        - search
```

`connector`에는 `toolkit`이 필요하며 `connection`과 `account`로 연결과 앱 계정을 지정할 수 있습니다. 인증은 Pod의 연결 페이지에서 설정합니다. `streamable_http`에는 `url`이 필요합니다. `bearer_token_env_var`는 설정된 WorkerEnv 변수의 이름을 참조하지만, 실제 값을 읽어 원격 인증에 사용하는 주체는 제어면입니다. 해당 값은 Worker 환경 스냅샷에서 제외됩니다. `protocol_version`은 `auto`, `legacy`, `2026-07-28` 중 하나입니다.

신뢰할 수 있는 로컬 서버는 `stdio`와 `command`로 선언하고 Worker의 `/bin/sh -lc`로 실행합니다. 각 방식에서 `enabled_tools` 또는 `disabled_tools`를 지정할 수 있습니다. Skill당 최대 64개이며 같은 서버 이름의 설정이 충돌하면 준비 단계가 실패합니다.

## 실행과 호출

메인 Agent는 활성화된 `any`·`main` Skill을, Background Agent Job은 `any`·`background_job` Skill을 사용합니다. 임시 `MCPORTER_CONFIG`는 `imports: []`를 설정하고 내부 게이트웨이와 갱신 가능한 단기 Turn 토큰을 사용합니다. 외부 서비스의 비밀 값은 제어면에 보관합니다.

Applet Action은 Function Runtime의 `AnkoleRuntime.mcp`를, 팀 Action은 해당 `admin.mcp`를 사용하며 Agent의 Skill 환경을 상속하지 않습니다.

```bash
mcporter list 'github.repos_get' --schema --json --timeout 360000
mcporter call 'github.repos_get' --json - --output json --timeout 360000 < /absolute/path/arguments.json
```

선택한 도구의 규약을 먼저 읽고 JSON은 표준 입력으로 전달하며 작업에 맞는 타임아웃을 지정하세요. `github@work` 같은 별칭으로 연결을 선택할 수 있습니다. 결과의 페이지 나누기와 경고를 확인하고, 승인 링크 등 구조화된 오류를 유지하세요.

[MCP 사용](../using-mcp/), [Skill 작성](../writing-a-skill/), [Automation Jobs](../automation-jobs/)도 참고하세요.
