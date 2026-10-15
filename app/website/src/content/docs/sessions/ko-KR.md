---
title: Sessions
description: Agent 실행, 공유 기록 읽기, 단일 writer 펜스와 복구.
section: Developer guide
order: 103
---

Session은 한 Agent의 실행 단위이며 키는 `{agent_uid, session_id}`입니다. 같은 Agent의 여러 Session은 병렬 실행할 수 있습니다. 각 Session은 `Ankole.Sessions`의 한 Driver가 진행합니다.

Conversation은 공유 발언을 저장합니다. 참여 Agent는 각각 독립 Session을 사용하고 AIGateway가 그 모델 기록을 저장합니다. 일반 Signal은 Conversation이 없는 Session으로도 라우팅할 수 있습니다.

## 단일 writer

DynamicSupervisor가 임시 `:gen_statem` Driver를 시작하고 `:global`이 각 Session 키에 Erlang 클러스터의 한 이름을 부여합니다. 영구 workspace의 epoch가 쓰기 펜스입니다. 수용 시 epoch를 높이고 Driver 트랜잭션이 행 잠금 안에서 확인합니다. 네트워크 분리 후 오래된 Driver는 커밋하지 못합니다.

## 영구 입력과 모델 기록

Signal은 영구 inbox입니다. AIGateway Response 체인은 모델 출력과 도구 결과를 기록합니다. control plane 도구는 부작용과 receipt를 함께 커밋합니다. Driver는 라운드 결과를 체인에 쓰고 같은 트랜잭션에서 receipt를 삭제합니다. 대체 Driver는 이 사실로 진행 상태를 복구합니다.

모델 요청 경계에서 Sessions가 현재 Conversation의 Message를 읽습니다. 실제 요청 metadata에 읽기 위치를 저장하며 현재 main과 steer Message는 배경에서 제외합니다. 공유 기록은 문맥을 제공하지만 과거 작성자의 권한을 제공하지 않습니다. 수용은 현재 요청자를 확인합니다.

Signal 완료와 최종 답장 의도는 함께 커밋됩니다. 내부 수정은 답장 소유자를 유지하며 철회나 retry 뒤에도 도구 결과를 읽을 수 있습니다. `/compress`는 feedback과 checkpoint로 완료되고 일반 최종 모델 Response를 요구하지 않습니다.

## Worker와 작업 식별자

환경 도구나 Codex가 computer를 필요로 하면 Agent Worker를 요청합니다. 환경 작업은 Agent·Session·Signal에 범위가 지정된 `RunRef`를 사용합니다. Codex의 `JobTurnRef`는 Job과 attempt도 식별합니다. 작업 자체의 식별자가 있어 대체 Driver가 진행 중인 작업을 인계할 수 있습니다.

RuntimeFabric은 Worker마다 한 Phoenix Channel을 사용하고 Phoenix Tracker가 노드 간 위치를 찾습니다. Worker의 generation과 incarnation이 오래된 경로를 거부합니다. 각 Worker는 한 Agent에 연결됩니다.

## 복구

Signals가 수용 트랜잭션에 영구 Oban 기동을 넣고 호출자의 도메인 쓰기와 함께 커밋합니다. Reconciler는 시작된 시도를 포함한 만료된 open 입력을 확인하고 기존 Driver를 깨우거나 재생성합니다. Workflow 소유자에게 사라진 RunServer와 cleanup 복구도 요청합니다. 저장된 `last_attempt_at`와 실패 예산이 반복 시도를 제어합니다.

기본·외부 채팅, 예약 작업과 업무 이벤트는 이 실행 규칙을 사용합니다. [Signals](../signals/), [Agent loop](../agent-loop/), [Agent Computer Worker](../agent-computer-worker/)도 참조하세요.
