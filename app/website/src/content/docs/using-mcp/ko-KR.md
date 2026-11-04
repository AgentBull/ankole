---
title: MCP 기반 Skill 사용
description: 연결을 설정하고 Agent Skill이나 Applet Action에서 MCP 도구를 사용합니다.
section: Developer guide
order: 123
---

Agent에 필요한 Skill을 활성화하고 업무 목표를 전달합니다. Agent가 Skill을 읽고 도구를 선택한 뒤 셸에서 MCPorter를 호출합니다. 메인 Agent와 Background Agent Job은 같은 제어면 게이트웨이를 사용합니다.

## 접근 설정

GitHub, Lark, Linear의 기본 Toolkit은 Pod 연결 페이지에서 앱을 설정합니다. 개인 권한이 필요한 작업은 본인이 계정을 승인합니다. 연결이 여러 개면 사용할 연결을 명시하세요. 승인이 부족하면 승인 후 다시 시도할 수 있는 링크가 반환됩니다.

원격 HTTP Skill의 `bearer_token_env_var`는 환경 변수에 설정된 값을 참조합니다. 제어면이 값을 읽어 상위 요청에 추가하며, 해당 비밀 값은 Worker 스냅샷에서 제외됩니다. 로컬 `stdio` 서버는 선언한 명령으로 Worker 안에서 실행됩니다.

## Applet에서 사용

게시한 Action의 처리 함수에서 `AnkoleRuntime.mcp.call(tool, arguments, {server, connection})`를 호출합니다. 팀 작업은 `AnkoleRuntime.admin.mcp`를 사용하고 호스트가 호출 권한을 관리합니다. 자동화 패널에서 Job과 소스를 등록하고 Run을 확인할 수 있습니다. Applet은 Agent의 Skill 환경을 상속하지 않습니다.

셸에서 호출할 때는 JSON을 표준 입력으로 전달하고 타임아웃을 명시합니다. 통신 성공 여부와 별개로 업무 오류, 페이지 나누기, 부분 결과를 확인하세요. 부분 쓰기는 반환된 리소스 ID로 남은 작업을 처리합니다. 쓰기 결과가 불확실하면 상위 서비스의 상태를 먼저 확인한 뒤 다시 시도합니다.

[MCP 참고](../mcp/), [Automation Jobs](../automation-jobs/), [환경 변수](../worker-env/)를 참고하세요.
