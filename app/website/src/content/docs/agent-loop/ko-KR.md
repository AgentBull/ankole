---
title: 에이전트 루프
description: control plane Driver, 영구 모델 및 도구 단계, Worker 실행 경계.
section: Developer guide
order: 117
---

주 Agent loop는 Elixir control plane의 `Ankole.Sessions`에서 실행되며, 각 실행 세션은 단일 `:gen_statem` Driver 프로세스가 전담해 진행합니다. 단순 질의응답이나 control plane 도구 호출에는 Worker가 필요하지 않으며, 환경 도구나 Codex 실행을 위해 컴퓨터 환경이 처음 필요해질 때만 해당 Agent의 Worker를 기동합니다.

## 한 라운드의 영구 단계

Driver는 한 라운드를 다음 순서로 실행하고 영구 저장합니다.

1. 열려 있는(open) Signal을 수락하고 PostgreSQL에서 실행 세션의 epoch를 증가시킵니다.
2. 저장된 Response 체인에서 이전 진행 상태를 복구한 뒤 모델 요청을 조립합니다.
3. AIGateway의 프로세스 내부 Responses API를 호출해 영구 Response를 엽니다.
4. 도구 호출이 발생하면 선언된 owner에 따라 control plane 도구, Worker, 또는 영구 대기 상태로 분기해 전달합니다.
5. 해당 라운드의 전체 결과, 대기 조건을 충족한 입력의 완료 처리, 처리 영수증(receipt) 삭제를 단일 트랜잭션으로 커밋합니다.
6. 라운드 경계에서 새로 도착한 추가 입력을 주입해 다음 라운드로 이어 가거나, 최종 응답과 입력 완료를 커밋하고 종료합니다.

대화 전사(transcript), 컨텍스트 압축, 기억 주입, hosted 도구는 AIGateway가 담당하고, 반복 횟수 제한, 빈 응답 복구, 반복 오류 안내, 최종 응답 판정 규칙은 Driver가 담당합니다. control plane에서 실행되는 모든 모델 루프는 이 역할 분담을 따르며, Codex만 예외적으로 Worker 내부에서 자체 루프를 유지합니다.

## 복구와 부수 효과

Driver가 새로 시작되면 미완료 Signal과 저장된 Response 체인을 읽어 직전 진행 상태를 복구합니다. control plane 도구의 부수 효과와 실행 receipt는 동일한 트랜잭션에서 함께 커밋되므로, 이미 체인에 결과가 기록된 도구 호출은 다시 실행하지 않습니다. 환경 도구 호출 역시 Worker에서 Response ID와 call ID로 식별하므로, 새 Driver가 실행 중인 호출을 그대로 인계받거나 완료된 결과를 회수할 수 있습니다. 만약 Worker 프로세스 자체가 사라진 경우에는 재실행해도 안전한 호출만 자동으로 재시도하고, 부수 효과 여부를 확인할 수 없는 호출에는 `interrupted`를 반환합니다.

실행 도중 들어오는 일반 입력은 현재 라운드가 끝나는 경계까지 대기합니다. 반면 중지 요청이나 유효한 retry 요청이 들어오면 진행 중인 작업을 즉시 중단하지만, 대상이 잘못 지정된 retry는 무시하고 현재 실행을 그대로 유지합니다. 이미 도구 호출이 실행된 뒤에 메시지를 철회하거나 대상 없는 retry를 요청한 경우에는 기존 도구 실행 기록을 보존한 채 동일한 체인에 수정 지시만 주입합니다.

## 실패 상한

단일 모델 라운드 내부의 전송 재시도는 AIGateway가 처리하고, 실행 시도(attempt) 간 재시도는 Driver가 관리합니다. 일반 입력은 여섯 번째 수락 시점에도 완료되지 못하면 dead letter로 전환됩니다. 계획된 정상 종료(예: 배포나 재조정으로 인한 양보)에서는 트랜잭션이 성공적으로 커밋되면 소비했던 시도 횟수 1회를 되돌려 주지만, 비정상 충돌로 종료되면 되돌려 주지 않습니다. Workflow와 Background Job은 각각 고유한 예산 및 재시도 정책을 따릅니다.

단일 writer 소유권은 [Sessions](../sessions/), 환경 실행과 파일 저장은 [Agent Computer Worker](../agent-computer-worker/), 영구 Response 체인은 [AIGateway](../ai-gateway/)를 참조하세요.
