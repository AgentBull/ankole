---
title: MCP 기반 Skill 사용
description: 활성화된 Skill이 Agent 또는 Automation 스크립트를 mcporter를 통해 MCP 서버로 라우팅하는 방법.
section: Developer guide
order: 123
---

Ankole에서는 MCP 서버를 모델 앞에 직접 노출하지 않고 Skill 내부를 통해서만 사용합니다. 도메인 라우팅과 결과 해석 규칙은 Skill이 소유하며, 버전이 고정된 mcporter CLI는 Skill이 고른 단일 도구의 스키마 조회와 호출만 담당합니다.

따라서 Agent별로 외부 도메인을 연동할 때는 MCP 서버를 Agent에 직접 등록하려 하지 말고, 해당 의존성을 선언한 Skill을 활성화하세요. 나중에 그 Skill을 비활성화하면 다음 실행부터 해당 MCP 의존성도 함께 빠집니다.

## 메인 Agent와 Background Agent Job

사용자는 구체적인 MCP 도구 이름을 지정할 필요 없이 원하는 업무 결과만 요청하면 됩니다. 요청을 받은 Agent는 조건에 맞는 Skill 지침을 읽고 사용할 도구 하나를 고른 뒤, 필요한 경우에만 그 도구의 현재 스키마를 조회하고 JSON 인수 객체를 표준 입력(stdin)으로 넘겨 mcporter를 실행합니다.

이때 메인 Agent는 `command` 도구를 사용하고 Background Agent Job은 Codex 터미널을 사용하며, 어느 실행 경로에서도 전체 MCP 도구 카탈로그가 네이티브 모델 도구로 등록되지는 않습니다.

## Automation Job

Automation Job은 모델을 실행하지 않으므로 런타임에 Skill 문서를 읽지 않습니다. 따라서 `main.ts` 스크립트를 작성하는 Agent가 처음부터 호출할 도구 이름, 전달 인수, 조회 범위, 응답 검증 로직을 코드 안에 직접 구현해 넣어야 합니다.

각 Automation 실행 시도에는 현재 활성화된 모든 Skill의 MCP 의존성이 `MCPORTER_CONFIG` 환경 변수로 주입되며 최신 Agent WorkerEnv도 함께 전달됩니다. 스크립트에서는 `Bun.spawn`으로 mcporter를 실행해 stdin에 JSON을 쓰고, 종료 코드를 확인한 뒤 stdout을 파싱하세요. 별도로 `~/.mcporter/mcporter.json` 파일을 직접 생성해서는 안 됩니다.

## 자격 증명

Skill 선언 파일에는 실제 토큰 대신 `MCP_HTTP_TOKEN` 같은 환경 변수 이름만 적고, 실제 시크릿 값은 [Environment variables](../worker-env/) 화면에서 등록하세요. 런타임이 생성하는 임시 mcporter 설정 파일에도 값 원문이 아니라 변수 이름만 기록됩니다.

지정한 환경 변수가 설정되어 있지 않으면 호출은 즉시 실패합니다. 채팅 메시지나 Skill 본문, 스크립트 코드, 인수 JSON 파일, 셸 명령줄에 토큰 문자열을 직접 붙여 넣지 마세요.

## 실패와 결과 범위

선언 형식이 잘못되었거나 활성 Skill 간 서버 정의가 충돌하면, 모델 명령이나 Automation 스크립트가 시작되기도 전에 실행 준비 단계에서 실패합니다. 실행 중 전송 오류, 프로토콜 불일치, 잘못된 인수, 원격 서버 오류가 발생하면 mcporter 프로세스가 `0`이 아닌 종료 코드로 끝납니다.

`command` 도구와 Automation 실행 로그는 일정 크기로 잘리므로(bounded), Skill에 정의된 페이지네이션, 데이터 최신성 확인, 경고 처리, 부분 결과 검증 규칙을 그대로 따르세요. 단순히 mcporter 프로세스의 종료 코드가 `0`이라고 해서 원격 비즈니스 작업이 의도대로 완료되었다고 단정해서는 안 됩니다.

## 참조

- 선언 문법과 런타임 동작 명세는 [MCP 서버 참조](../mcp/)를 확인하세요.
- Skill 파일 작성 구조는 [Writing a Skill](../writing-a-skill/)을 확인하세요.
- 자격 증명 환경 변수 보관은 [Environment variables](../worker-env/)를 확인하세요.