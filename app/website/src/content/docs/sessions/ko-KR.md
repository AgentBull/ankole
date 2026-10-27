---
title: Sessions
description: Agent 실행, 공유 기록 읽기, 단일 writer 펜스와 복구.
section: Developer guide
order: 103
---

Session은 단일 Agent의 실행 단위로 `{agent_uid, session_id}` 키로 식별됩니다. 같은 Agent에 속한 여러 Session은 병렬로 실행될 수 있으며, 각 Session의 진행은 `Ankole.Sessions`의 단일 Driver가 전담합니다.

공유 대화 발언은 Conversation에 저장됩니다. 같은 대화에 여러 Agent가 참여하더라도 각 Agent는 독립된 Session을 사용하며, 그에 따른 모델 추론 이력은 AIGateway가 별도로 저장합니다. 일반 업무 Signal은 연결된 Conversation이 없는 Session으로도 라우팅할 수 있습니다.

## 단일 writer

DynamicSupervisor가 일시적인(transient) `:gen_statem` Driver 프로세스를 띄우고, `:global` 레지스트리가 각 Session 키마다 Erlang 클러스터 전체에서 유일한 이름을 부여합니다. 영구 workspace 행의 `epoch` 값이 쓰기 펜스(fence) 역할을 합니다. 새 Driver가 Session을 인수할 때 `epoch`를 올리고 이후 모든 Driver 트랜잭션이 행 잠금 안에서 이를 검증하므로, 네트워크 분리(split-brain) 이후 뒤처진 이전 Driver는 결과를 커밋할 수 없습니다.

## 영구 입력과 모델 기록

Signal은 Session의 영속 입력함(inbox)이고, AIGateway Response 체인은 모델 출력과 도구 실행 결과를 순서대로 기록합니다. control plane 도구를 실행할 때는 도메인 부작용과 receipt를 단일 트랜잭션으로 함께 커밋하며, 이후 Driver가 라운드 결과를 Response 체인에 기록하면서 같은 트랜잭션 안에서 해당 receipt를 지웁니다. 장애 발생 후 새로 기동된 대체 Driver는 이 기록들을 읽어 중단된 지점부터 실행 상태를 복구합니다.

모델 호출 경계마다 Sessions는 현재 Conversation의 Message 목록을 읽어 오며, 실제 모델 요청의 `metadata`에 마지막으로 읽은 위치를 남기고 현재 처리 중인 main 및 steer Message는 배경 문맥에서 제외합니다. 공유 대화 기록은 문맥 정보만 제공할 뿐 과거 메시지 작성자의 권한을 위임하지는 않으며, 권한 확인은 항상 현재 요청 주체를 기준으로 수행됩니다.

Signal 완료 처리와 최종 답장 전송 의도는 하나의 트랜잭션으로 함께 커밋됩니다. 도중에 내부 방향 수정(steer)이 일어나더라도 답장 소유 주체는 그대로 유지되며, 메시지 철회나 재시도가 발생한 뒤에도 이미 실행된 도구 결과를 이어서 읽을 수 있습니다. 한편 `/compress` 명령은 피드백과 요약 checkpoint 저장만으로 완료되며 별도의 최종 모델 응답을 요구하지 않습니다.

## Worker와 작업 식별자

환경 도구나 Codex 실행에 컴퓨터 환경이 필요해지면 그때 해당 Agent의 Worker를 요청합니다. 일반 환경 작업은 Agent·Session·Signal 범위로 묶인 `RunRef`를 식별자로 쓰고, Codex 실행의 `JobTurnRef`에는 Job ID와 attempt 번호까지 함께 담깁니다. 이처럼 각 작업이 고유한 영속 식별자를 가지므로, Driver가 교체되더라도 진행 중인 Worker 작업을 그대로 인계받을 수 있습니다.

RuntimeFabric은 Worker당 하나의 Phoenix Channel을 유지하고 Phoenix Tracker로 클러스터 노드 간 연결 위치를 추적합니다. 또한 Worker의 `generation`과 `incarnation` 값을 검증해 이미 교체된 구버전 연결 경로에서 오는 메시지는 거부하며, 각 Worker는 오직 하나의 Agent에만 연결됩니다.

## 복구

Signals는 신호를 수용하는 트랜잭션 안에 영속 Oban 기동 잡을 함께 넣어 호출자의 도메인 쓰기와 원자적으로 커밋합니다. 이후 Reconciler가 이미 시도가 시작된 항목을 포함해 기한이 지난 미완료 입력들을 점검하고, 살아 있는 Driver를 깨우거나 새 Driver를 기동합니다. 이와 함께 사라진 RunServer나 미완료 정리(cleanup) 작업의 복구도 Workflow 소유 모듈에 요청하며, 기록된 `last_attempt_at` 시각과 실패 예산을 바탕으로 무한 반복 재시도를 제어합니다.

기본 Pod 채팅과 외부 메신저 채널, 예약 스케줄, 각종 업무 이벤트가 모두 이 동일한 실행 및 복구 규칙 위에서 동작합니다. 관련 내용은 [Signals](../signals/), [Agent loop](../agent-loop/), [Agent Computer Worker](../agent-computer-worker/)도 함께 참조하세요.
