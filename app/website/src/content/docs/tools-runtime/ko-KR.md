---
title: Tool 런타임
description: 제어 플레인의 도구 선언과 Worker 환경 실행 경계.
section: Developer guide
order: 120
---

제어 플레인은 주 Agent의 모델 루프와 도구 분배를 소유합니다. `Ankole.Sessions.Driver`는 AIGateway를 호출하고 요청한 도구를 실행하며 결과를 기록한 뒤 턴을 계속합니다. Agent Computer는 환경 작업과 Codex Job을 실행합니다. [Agent loop](../agent-loop/)와 [Agent Computer Worker](../agent-computer-worker/)를 참조하세요.

## 현재 도구 집합

`Ankole.Sessions.ToolCatalog.for_run/1`은 현재 도메인 선언과 `worker_tools.json`의 Worker 선언을 결합합니다. 실행 종류, 모델 기능, 선택한 Skill과 플러그인, ambient 권한에 따라 구성하며 Agent의 전역 도구 집합으로 저장하지 않습니다.

`Ankole.Sessions.Tool`은 모델에 보이는 schema, 실행 주체, 실행 순서, 허용된 호출자와 읽기·파괴·재시도 메타데이터를 보관합니다. `Ankole.Sessions.Tools.prepare/2`는 호출자를 확인하고 인수를 파싱한 다음 도구 소유자가 정규화하고 JSON Schema를 검증한 뒤 실행합니다.

## 소유자에서 실행

- Session 계획, 일정, Background Agent Job, Workflow, Skill 읽기와 도메인 Web 작업은 제어 플레인의 해당 소유자가 실행합니다.
- Computer 작업은 RuntimeFabric을 통해 Agent의 Worker에 위임합니다. 첫 환경 작업이 Session workspace를 엽니다. Worker는 슬롯과 프로세스 상태를, 제어 플레인은 영구 결과를 소유합니다.
- MCP-backed Skill은 Worker의 computer command 도구와 mcporter를 사용합니다.
- Provider hosted tool은 AIGateway를 통해 실행하며 선택한 모델이 선언한 기능을 따릅니다.

Driver는 선언에 따라 병렬 또는 순차 호출을 예약합니다. 영구 변경은 `Ankole.Sessions.Receipts`를 사용해 도메인 변경과 결과를 같은 트랜잭션에서 커밋합니다. AIGateway는 다음 모델 반복에 사용할 도구 출력을 저장합니다. Worker가 끊기면 Driver가 선언된 재시도 계약에 따라 결과가 불확실한 환경 작업을 처리합니다.

## Workflow 작업 도구

제한된 목록은 Web 작업, 위임 및 확인용 Background Agent Job 작업, `sleep`, `submit_result`입니다. Hosted Brain은 `recall`과 `get_page`만 허용합니다. Computer, shell, Skill, 일정, Workflow 생성 도구는 제공하지 않습니다.

`submit_result`는 저장된 결과 schema로 값을 검증합니다. 거부되면 수정할 수 있고 수락되면 작업이 끝납니다. 제출 전에 실행 중인 위임 Job을 정리해야 합니다. [Workflows](../workflows/)를 참조하세요.

## 도구 추가

도메인 도구의 선언과 구현은 제어 플레인의 소유자에 둡니다. 환경 도구는 Worker에 추가하고 `worker_tools.json`을 다시 생성합니다. `WorkerAgentTool`과 Zod는 Worker 도구 구현 계약을 정의합니다. Schema와 실행 경계를 함께 일치시켜야 합니다.
