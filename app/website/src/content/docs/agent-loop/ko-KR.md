---
title: 에이전트 루프
description: control plane Driver, 영구 모델 및 도구 단계, Worker 실행 경계.
section: Developer guide
order: 117
---

주 Agent loop는 Elixir control plane의 `Ankole.Conversations`에서 실행됩니다. 각 대화는 하나의 `:gen_statem` Driver가 진행합니다. 질문과 control plane 도구에는 Worker가 필요 없습니다. 환경 도구나 Codex에 컴퓨터가 처음 필요할 때 Agent의 Worker를 시작합니다.

## 한 라운드의 영구 단계

1. open ActorEvent를 받아 PostgreSQL의 대화 epoch를 증가시킵니다.
2. 저장된 Response 체인에서 진행 상황을 복구하고 모델 요청을 준비합니다.
3. AIGateway의 프로세스 내부 Responses API로 영구 Response를 엽니다.
4. 선언된 owner에 따라 control plane 도구, Worker 또는 영구 대기로 호출을 전달합니다.
5. 전체 라운드 결과, 대기를 충족한 입력의 완료, receipt 삭제를 한 트랜잭션에서 커밋합니다.
6. 경계에서 추가 입력을 주입하거나 최종 응답과 입력 완료를 커밋합니다.

AIGateway는 전사, 압축, 기억 주입, hosted 도구를 소유합니다. Driver는 반복 제한, 빈 응답 복구, 반복 오류 안내와 최종 응답 규칙을 소유합니다. 모든 대화 유형이 이 owner를 사용합니다. Codex는 Worker 안에서 자체 loop를 유지합니다.

## 복구와 부수 효과

새 Driver는 ActorEvent와 Response 체인에서 진행 상황을 복구합니다. control plane 도구의 효과와 receipt는 같은 트랜잭션에서 커밋됩니다. 체인에 기록된 결과는 다시 실행하지 않습니다. Worker는 Response ID와 call ID로 환경 호출을 식별하므로 새 Driver가 인계받을 수 있습니다. Worker 프로세스가 사라지면 안전한 호출만 재시도하고, 확인할 수 없는 다른 호출은 `interrupted`를 반환합니다.

일반 입력은 다음 경계를 기다립니다. 중지와 유효한 retry는 현재 작업을 중단합니다. 대상이 잘못된 retry는 현재 실행을 유지합니다. 도구 호출 이후의 철회나 대상 없는 retry는 도구 기록을 보존하고 같은 체인에 수정을 주입합니다.

## 실패 상한

한 모델 라운드 내부 재시도는 AIGateway, 시도 간 재시도는 Driver가 소유합니다. 일반 입력은 여섯 번째 수락에서 dead letter가 됩니다. 계획된 종료는 트랜잭션이 성공하면 수락된 시도 하나를 반환합니다. 충돌 종료는 반환하지 않습니다. Workflow와 Job은 각자의 예산 owner를 유지합니다.

writer 소유권은 [Actor Runtime](../actor-runtime/), 실행과 저장은 [Agent Computer Worker](../agent-computer-worker/), Responses는 [AIGateway](../ai-gateway/)를 참조하세요.
