---
title: 에이전트 루프
description: 제어 플레인 턴 수명 주기와 worker 측 에이전트 루프 사이의 경계 — 각 측이 소유하는 것, 통신 방식, 그리고 반복 예산과 재시도가 위치하는 곳.
section: Developer guide
order: 117
---

턴은 두 런타임에 걸친 작업 단위입니다: Elixir 제어 플레인이 이를 스케줄링하고 펜스하며, Bun worker가 그 안에서 에이전트 루프를 실행합니다. 이 페이지는 둘 사이의 경계를 문서화합니다 — 제어 플레인 `TurnLifecycle`이 소유하는 것, worker의 `runAgentLoop`이 소유하는 것, 그리고 RuntimeFabric을 통한 통신 방식. [Actor Runtime](../actor-runtime/) 및 [Agent Computer Worker](../agent-computer-worker/) 문서를 기반으로 하며, 이 페이지는 그 사이의 턴 수준 세부 사항입니다.

먼저 핵심 속성을 밝힙니다: 제어 플레인은 턴의 *정체성과 커밋*을 소유하고, worker는 턴의 *실행*을 소유합니다. worker는 루프가 언제 끝나는지 결정하고, 제어 플레인은 턴의 결과가 영구적인지 결정합니다. worker가 완료로 보고한 턴도 제어 플레인이 커밋할 때까지는 영구적이지 않습니다.

## 제어 플레인 측: TurnLifecycle

`Ankole.SignalsGateway.ActorRuntime.TurnLifecycle`은 루프 내부가 아니라 루프 주변에서 일어나는 일을 소유합니다. 책임은 다음과 같습니다:

| 책임 | 수행 내용 |
|---|---|
| **리스 관리** | 활성화가 리스를 보유함(`activation_progress_lease_seconds` = 2100초, 120초 유예 포함); watchdog이 만료된 활성화를 실패 처리하여 이벤트를 재시도할 수 있게 함 |
| **턴 시작** | 새 epoch로 `ActorSessionActivation`을 생성하고, worker를 배정하며, RuntimeFabric을 통해 턴 봉투를 전달 |
| **턴 오류 처리** | `handle_turn_error/2`가 worker의 오류 보고를 받아 분류하고 재시도 여부와 dead-letter 여부를 결정 |
| **턴 커밋** | worker가 성공을 보고하면 턴의 결과를 영구적인 사실로 기록 |
| **활성화 만료** | `fail_activation_if_expired/2`가 리스가 소진된 멈추거나 크래시한 턴을 포착 |

턴 오류 재시도 예산은 worker가 아니라 여기에 있습니다: 최대 5회 시도(`@worker_turn_error_dead_letter_attempts`)이며, 5초에서 120초 사이의 지수 백오프(`@worker_turn_error_retry_base_seconds` 및 `@max`)를 적용합니다. 실패한 시도마다 epoch가 증가하므로, 실패한 시도의 늦은 응답이 이후 재시도와 일치할 수 없습니다.

제어 플레인은 모델이 무엇을 말할지, 에이전트가 어떤 도구를 호출할지, 루프가 몇 번 반복할지를 **결정하지 않습니다**. 그것들은 worker의 것입니다.

## worker 측: runAgentLoop

`app/agent_computer/src/core/agent-loop.ts`의 `runAgentLoop`은 worker가 턴 안에서 실행하는 4단계 루프입니다:

1. **모델 호출** — 턴 범위 OpenAI Responses 어댑터(AIGateway의 상태 저장 트랜스포트)를 통해.
2. **함수 호출 로컬 실행** — 응답에 function-call 항목이 있으면 worker가 도구를 실행합니다.
3. **출력 기록** — AIGateway를 통해 기록하며, AIGateway는 이를 function-call-output 메시지로 저장합니다.
4. **저널 앵커에서 계속** — 응답이 더 이상 function-call 항목을 반환하지 않을 때까지 반복합니다.

worker는 **루프 종료와 로컬 반복 예산**을 소유합니다. 두 가지 결과가 있습니다:

- **`loop_finished`** — 모델이 추가 tool call 없이 응답했습니다. 턴이 자연스럽게 종료됩니다.
- **`iteration_exhausted`** — worker가 반복 한도에 도달했습니다. 모델은 더 많은 도구를 호출하는 대신 최종 응답을 종합하도록 유도되며(`MODEL_ITERATION_LIMIT_SYNTHESIS_TEXT`), 턴은 그 종합으로 끝납니다.

worker는 또한 세 가지 복구 유도도 소유합니다: 도구 실행 후 빈 응답 유도(모델이 도구를 실행했지만 빈 응답을 반환한 경우), 도구 오류 복구 힌트, 반복 한도 종합. 이들은 턴의 영구성에 관한 것이 아니라 모델이 다음에 무엇을 하는지에 관한 것이므로 worker 측에 있습니다.

## worker가 소유하지 않는 것

agent-loop moduledoc은 명확합니다: worker는 히스토리 확장, 압축, 연속 앵커, 영구 응답 상태를 **소유하지 않습니다**. 그것들은 AIGateway에 남아 있습니다. worker는:

- 모델이 보는 히스토리 양을 결정하지 않습니다(AIGateway의 상태 저장 Responses가 압축을 포함해 이를 소유합니다);
- 대화를 저장하지 않습니다(AIGateway가 저장합니다);
- 턴의 부수 효과가 커밋되는지 결정하지 않습니다(제어 플레인이 결정합니다).

이것이 worker를 교체 가능하게 만드는 분할입니다: worker는 루프를 실행하고, AIGateway는 전사를 소유하며, 제어 플레인은 커밋을 소유합니다.

## 통신 방식

| 방향 | 경계를 넘는 것 |
|---|---|
| 제어 플레인 → worker | `TurnStart` 봉투(actor 정체성, 턴 ref, 처리할 이벤트) |
| worker → 제어 플레인 | 진행 봉투(체크포인트, 활동 요약), 실패 시 `actor_turn.abort` RPC, 또는 완료 시 `actor_turn.complete` / `actor_turn.noop` RPC |
| worker → AIGateway | 모델 호출, function-call 출력(제어 플레인을 거치지 않음) |

모든 worker 메시지는 `ActorTurnRef`(`activation_uid`, `actor_epoch`, `actor_event_id`)를 실어 나릅니다. 제어 플레인은 이를 현재 활성화와 대조하며, ref가 더 이상 일치하지 않는 메시지는 오래된 것으로 거부됩니다. 이것은 턴 수준에서 본 [Actor Runtime](../actor-runtime/) 삼중 펜스입니다.

## 재시도 경계

턴이 실패하면 worker가 아니라 제어 플레인이 재시도를 결정합니다. worker는 오류를 보고하고, `handle_turn_error`가 이를 분류합니다:

- **재시도 가능(Retryable)** (worker 트랜스포트 실패, 타임아웃) — 이벤트는 `open` 상태를 유지하고, epoch가 증가하며, 런타임이 백오프 지연 후 재전달합니다.
- **Dead-letter** — 5회 시도(또는 연속 5회 턴 실패) 후 이벤트는 `dead_letter`로 이동하고 턴은 재시도를 멈춥니다. 운영자가 이를 검사하고 해결합니다.

worker는 스스로 재시도하지 않습니다. 오류를 보고하고 재시도 결정은 제어 플레인이 소유합니다. 활성화 펜스를 다시 세울 수 있는 쪽이 제어 플레인이기 때문입니다.

## 이 가이드가 아닌 것

이 가이드는 모델 프롬프팅 가이드가 아닙니다 — 루프의 형태는 기계적이며(호출, 실행, 기록, 계속), 그 안의 모델 동작은 페르소나의 관심사입니다. 트랜스포트 가이드도 아닙니다 — RuntimeFabric이 봉투를 운반하며, 그것은 [Kernel](../kernel/) 페이지의 범위입니다. 그리고 [Actor Runtime](../actor-runtime/) 페이지를 대신하는 것도 아닙니다. 활성화 펜스는 턴 수명 주기가 그 안에서 동작하는 컨텍스트입니다.

## 다음 단계

- 활성화 펜스와 actor 모델에 대해서는 [Actor Runtime](../actor-runtime/)을 읽으세요.
- 루프를 실행하는 worker에 대해서는 [Agent Computer Worker](../agent-computer-worker/)를 읽으세요.
- 루프가 호출하는 상태 저장 Responses 트랜스포트에 대해서는 [AIGateway](../ai-gateway/)를 읽으세요.
- 압축(worker가 소유하지 않음)에 대해서는 [Context compression](../context-compression-and-caching/)을 읽으세요.
