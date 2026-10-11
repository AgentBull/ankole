---
title: Actor Runtime
description: 대화 Driver, 영구 입력과 Response 로그, writer 펜스 및 복구.
section: Developer guide
order: 103
---

actor key는 `{agent_uid, session_id}`입니다. 한 Agent의 여러 대화는 동시에 실행할 수 있으며, 각 대화는 `Ankole.Conversations`의 한 Driver가 순서대로 진행합니다.

## 단일 writer

DynamicSupervisor는 임시 `:gen_statem` Driver를 시작합니다. `:global`은 Erlang 클러스터 전체에서 actor key마다 하나의 이름을 부여합니다. 영구 workspace 행의 epoch가 쓰기 펜스입니다. 수락 시 epoch를 증가시키고 Driver 트랜잭션은 행 잠금 아래에서 이를 확인합니다. 네트워크 분할 후에도 이전 Driver는 커밋할 수 없습니다.

## 프로세스가 사라져도 남는 사실

ActorEvent는 영구 inbox입니다. AIGateway의 Response 체인은 모델 출력과 도구 결과를 기록합니다. control plane 도구는 효과와 receipt를 한 트랜잭션에서 커밋합니다. Driver는 전체 라운드를 체인에 기록하고 receipt를 같은 트랜잭션에서 삭제합니다. 새 Driver는 이 사실에서 진행 상황을 복구합니다.

입력 완료와 최종 응답은 함께 커밋됩니다. 마지막으로 주입된 응답 가능한 입력이 최종 응답을 소유하고, 내부 수정은 원래 owner를 유지합니다. 부수 효과 이후의 철회와 retry는 도구 기록을 보존합니다.

## Worker 식별

환경 도구나 Codex가 필요할 때만 Worker를 요청합니다. 환경 작업은 Agent, Session, 시작 입력을 지정하는 `RunRef`를 사용합니다. Codex의 `JobTurnRef`에는 Job과 attempt도 포함됩니다. 결과는 Driver epoch가 아닌 작업 자체의 식별자로 수락하므로 새 Driver가 진행 중인 작업을 인계받습니다.

RuntimeFabric는 Worker마다 하나의 Phoenix Channel을 사용합니다. Phoenix Tracker가 다른 노드의 channel을 찾고 분산 Erlang이 메시지를 전달합니다. 현재 Worker generation과 incarnation은 오래된 route를 거부합니다. 각 Worker는 자신의 Agent만 처리합니다.

## 복구

입력 owner는 domain 쓰기와 같은 트랜잭션에서 Oban wakeup을 삽입합니다. 매분 Reconciler는 이미 시작한 시도를 포함해 기한이 된 모든 open 입력을 검색합니다. 기존 Driver를 깨우거나 새 Driver를 시작합니다. Workflow owner를 통해 잃어버린 RunServer와 종결 cleanup도 복구합니다. backoff는 저장된 `last_attempt_at`부터 계산하며 실패 예산이 반복 충돌을 제한합니다.

단일 노드와 여러 노드는 같은 경로를 사용합니다. [Agent loop](../agent-loop/), [SignalsGateway](../signals-gateway/), [Worker](../agent-computer-worker/)도 참조하세요.
