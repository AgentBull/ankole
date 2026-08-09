---
title: MCP 기반 Skill 사용
description: 활성화된 Skill이 Agent 또는 Automation 스크립트를 mcporter를 통해 MCP 서버로 라우팅하는 방법.
section: Developer guide
order: 123
---

Ankole은 Skill 뒤에서 MCP를 사용합니다. Skill이 도메인 라우팅과 결과 규칙을 소유합니다. 고정된 mcporter CLI는 Skill이 선택한 하나의 도구에 대한 프로토콜 탐색과 호출을 소유합니다.

Agent별 도메인 통합에는 MCP 서버를 Agent에 직접 등록하지 마세요. 이를 선언하는 Skill을 활성화하세요. 해당 Skill을 비활성화하면 다음 실행에서 의존성이 제거됩니다.

## 메인 Agent와 Background Agent Job

Agent에게 MCP 도구 이름이 아니라 비즈니스 결과를 요청하세요. Agent는 일치하는 Skill을 읽고 도구 하나를 선택하며, 필요할 때 그 도구의 현재 스키마만 검사합니다. 그런 다음 JSON 인수 객체를 stdin으로 mcporter를 호출합니다.

메인 Agent는 자신의 command 도구를 사용합니다. Background Agent Job은 자신의 Codex 터미널을 사용합니다. 어느 경로도 완전한 MCP 카탈로그를 네이티브 모델 도구로 노출하지 않습니다.

## Automation Job

Automation Job은 Skill 지침을 읽지 않습니다. `main.ts`를 작성하는 Agent는 선택한 도구, 인수, 범위, 결과 검사를 스크립트에 인코딩해야 합니다.

각 Automation 시도는 `MCPORTER_CONFIG`를 통해 현재 활성화된 Skill 의존성을 받고, 최신 Agent WorkerEnv도 받습니다. `Bun.spawn`으로 mcporter를 호출하고, stdin에 JSON을 쓰고, 종료 코드를 확인하고, stdout을 파싱하세요. `~/.mcporter/mcporter.json`을 만들지 마세요.

## 자격 증명

Skill은 `MCP_HTTP_TOKEN` 같은 자격 증명 변수 이름을 저장합니다. 그 값을 [Environment variables](../worker-env/)에서 구성하세요. 생성된 config는 값이 아니라 변수 이름을 포함합니다.

변수가 없으면 호출이 실패합니다. 토큰을 채팅, Skill, 스크립트, 인수 파일, 셸 명령에 붙여 넣지 마세요.

## 실패와 결과 범위

잘못된 선언이나 충돌하는 서버 정의는 모델 명령이나 Automation 스크립트가 시작되기 전에 실패합니다. 전송, 프로토콜, 인수, 서버 오류는 0이 아닌 mcporter 종료를 만듭니다.

Command와 Automation 로그는 범위가 제한됩니다(bounded). Skill의 페이지네이션, 신선도, 경고, 부분 결과 규칙을 따르세요. 프로세스가 성공적으로 종료되었다 해도 비즈니스 결과가 완료되었음을 증명하지는 않습니다.

## 참조

- [MCP 서버 참조](../mcp/)가 선언과 런타임 동작을 정의합니다.
- [Writing a Skill](../writing-a-skill/)이 작성 형태를 보여 줍니다.
- [Environment variables](../worker-env/)가 자격 증명 저장을 정의합니다.