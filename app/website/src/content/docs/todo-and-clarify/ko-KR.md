---
title: Todo와 clarify
section: Developer guide
order: 124
description: 제어 플레인의 작업 목록과 질문 및 Codex Job 입력 경로.
---

`todo`와 `clarify`는 `Ankole.Sessions.Tools.Session`이 소유하는 제어 플레인 도구입니다. Driver는 인수를 검증하고 AIGateway로 모델에 보이는 결과를 저장한 뒤 현재 실행에 반영합니다. Worker는 이 주 턴 도구를 소유하지 않습니다.

## 작업 목록

`todo`는 목록을 읽거나 교체하고 항목 ID로 병합합니다. 상태는 `pending`, `in_progress`, `completed`, `cancelled`이며 선언은 최대 256개 항목을 허용합니다. 지침은 3단계 이상의 복잡한 작업에서 목록을 사용하고 우선순위 순으로 배치하며 진행 중 항목을 하나로 유지하고 완료 즉시 표시하며 실패하면 수정 항목을 추가하도록 요구합니다.

목록은 `Ankole.Sessions.Run`의 작업 상태입니다. 복구 시 현재 실행 기록에 저장된 성공 도구 호출로 다시 구성합니다. 새 Session은 다른 Session의 목록을 상속하지 않습니다. Session 간 공유할 지식은 [Brain](../brain/)에 보관합니다.

## 결정 질문 하나

`clarify`는 답이 결과나 다음 행동을 선택하는 데 필요할 때만 독립적으로 이해할 수 있는 질문 하나를 합니다. Agent는 요청과 이전 대화를 먼저 사용합니다. 기존 선호를 다시 묻지 않고 안전하고 위험이 낮은 기본값이 있으면 작업을 중단하지 않습니다.

자유 답변 또는 서로 다른 2~4개 선택지를 제공할 수 있습니다. 질문은 2,000자, 라벨은 200자, 선택 설명은 500자까지입니다. 거절할 수 있는 행동에는 행동하지 않는 선택지를 포함합니다.

성공하면 정규화한 질문과 선택지를 기록하고 현재 턴을 끝냅니다. 추가 도구나 최종 답변을 내지 않으며 사용자 다음 메시지가 계속할 턴을 시작합니다. 질문과 답은 영구 대화 기록에 남습니다.

## Background Job과 운영

Native Codex Job은 별도의 입력 요청 경로를 사용합니다. 사람의 입력을 요청하면 Job이 `waiting_on_user`가 되어 실행 슬롯을 해제하고 소유자의 답변으로 계속합니다. 이는 Job 수명 주기 계약이며 Worker에서 주 Agent의 `clarify`를 실행하는 경로가 아닙니다. [Background Agent Jobs](../background-agent-jobs/)를 참조하세요.

계획 상태와 턴 종료 동작에는 Console 조정 플래그가 없습니다. 계획하거나 질문하는 방식을 바꾸려면 Agent의 지침과 기능을 조정합니다. [Agents](../agents/)와 [Agent loop](../agent-loop/)를 참조하세요.
