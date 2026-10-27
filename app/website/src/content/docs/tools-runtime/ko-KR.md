---
title: Tool 런타임
description: 제어 플레인의 도구 선언과 Worker 환경 실행 경계.
section: Developer guide
order: 120
---

주 Agent의 모델 루프와 도구 실행 분배는 제어 플레인이 소유합니다. `Ankole.Sessions.Driver`가 AIGateway를 호출해 응답을 받고 요청된 도구를 실행해 결과를 기록한 뒤 다음 턴 단계를 이어가며, Agent Computer는 환경 도구 작업과 Codex Job 실행을 담당합니다. 자세한 구조는 [Agent loop](../agent-loop/)와 [Agent Computer Worker](../agent-computer-worker/)를 참조하세요.

## 현재 도구 집합

`Ankole.Sessions.ToolCatalog.for_run/1`은 현재 제어 플레인 도메인 선언과 `worker_tools.json`의 Worker 도구 선언을 결합해 실행 시점의 도구 집합을 조립합니다. 실행 종류, 모델 기능, 활성화된 Skill 및 플러그인, ambient 개입 권한에 따라 매번 동적으로 계산하며, Agent의 고정된 전역 도구 목록으로 따로 저장하지는 않습니다.

`Ankole.Sessions.Tool` 구조체는 모델에 노출할 스키마, 실행 담당 주체, 실행 순서, 허용된 호출자, 읽기 전용·파괴적 작업·재시도 가능 여부 메타데이터를 담습니다. 도구 호출 시에는 `Ankole.Sessions.Tools.prepare/2`가 호출자 권한을 확인하고 인수를 파싱한 뒤, 해당 도구의 소유 모듈이 값을 정규화하고 JSON Schema 검증을 거쳐 실행합니다.

## 소유자에서 실행

- Session 계획(`todo`), 스케줄, Background Agent Job, Workflow, Skill 조회(`skill_view`), 도메인 Web 도구는 제어 플레인 내 각 소유 도메인 모듈이 직접 실행합니다.
- 컴퓨터 환경 작업은 RuntimeFabric을 거쳐 해당 Agent의 Worker에 위임합니다. 환경 작업을 처음 실행할 때 Session workspace가 열리며, 실행 슬롯과 프로세스 상태는 Worker가 관리하고 영속 결과는 제어 플레인이 소유합니다.
- MCP 기반 Skill은 Worker의 컴퓨터 `command` 도구와 mcporter CLI를 통해 실행됩니다.
- Provider hosted 도구는 AIGateway를 통해 실행되며, 선택한 모델이 선언한 지원 기능을 따릅니다.

Driver는 도구 선언에 따라 병렬 또는 순차 실행을 스케줄링합니다. 영속 상태 변경이 수반되는 도구는 `Ankole.Sessions.Receipts`를 사용해 도메인 데이터 변경과 실행 결과를 단일 트랜잭션으로 함께 커밋하고, AIGateway는 다음 모델 반복에서 참조할 도구 출력을 저장합니다. 실행 도중 Worker 연결이 끊기면 Driver는 도구에 선언된 재시도 계약에 따라 결과 확인이 불확실한 환경 작업을 처리합니다.

## Workflow 작업 도구

Workflow 서브에이전트 작업에 제공되는 도구는 Web 도구, 작업 위임 및 상태 확인용 Background Agent Job 도구, `sleep`, `submit_result`로 제한됩니다. Hosted Brain이 활성화된 경우에도 읽기 전용인 `recall`과 `get_page`만 허용되며, 컴퓨터·셸 도구, Skill, 스케줄, 하위 Workflow 생성 도구는 제공되지 않습니다.

`submit_result` 호출 시에는 미리 저장된 결과 스키마로 제출 값을 검증합니다. 검증에 실패하면 서브에이전트가 값을 수정해 다시 제출할 수 있고, 통과하면 해당 작업이 종료됩니다. 단, 결과를 제출하기 전에 위임해 둔 실행 중 Background Agent Job을 먼저 정리해야 합니다. 자세한 내용은 [Workflows](../workflows/)를 참조하세요.

## 도구 추가

새 도메인 도구를 추가할 때는 제어 플레인의 담당 소유 도메인 안에 선언과 구현을 함께 둡니다. 반면 Worker 환경 도구를 추가할 때는 Worker 코드베이스에 도구를 구현한 뒤 `worker_tools.json`을 다시 생성해야 합니다. Worker 측 구현 계약은 `WorkerAgentTool`과 Zod 스키마로 정의하며, 제어 플레인 스키마와 실제 실행 경계가 정확히 일치하도록 유지해야 합니다.
