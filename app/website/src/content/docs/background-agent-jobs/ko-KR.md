---
title: Background Agent Jobs
description: Worker 손실을 견디는 durable하고 재개 가능한 작업 — 작업 상태 머신, 입력 대기(wait-for-input), 소유자 wakeup, Actor Runtime과의 경계를 다룹니다.
section: Developer guide
order: 105
---

Background Agent Job은 어떤 단일 Worker보다 오래 살아남도록 설계된 작업 단위입니다. 에이전트는 자신의 turn 안에서 인라인으로 실행하기에는 너무 오래 걸리거나, 단계가 너무 많거나, 격리가 너무 필요한 일을 위해 Job을 생성합니다. 그러면 Job은 제 나름의 일정에 따라 실행되고, 입력을 기다리며 멈추고, 실패하거나 완료되는 동안, 그것을 시작한 에이전트는 계속해서 소유자와 대화할 수 있습니다. 이 페이지는 `Ankole.BackgroundAgentJobs`의 실제 코드를 기준으로 이 라이프사이클을 설명합니다.

결정적인 속성을 먼저 말하면, Job은 자식 프로세스가 아니라 durable한 작업입니다. 그 상태는 PostgreSQL에 보관되고, 모든 전환은 fencing과 감사 대상이며, 상태가 소유자가 알아야 할 방식으로 바뀌면 Job은 일반 시그널이 사용하는 것과 같은 액터 이벤트 큐를 통해 소유자 세션에 wakeup 이벤트를 추가합니다.

## Actor Runtime과의 경계

세션 turn과 백그라운드 Job은 다른 형태의 작업이며, 런타임은 둘을 분리해 둡니다. Actor Runtime은 라이브하고 fencing된 turn — 세션 깨우기, 모델 루프 한 번 실행, 커밋 — 을 소유합니다. Background Agent Job은 turn이 위임하는 durable하고 재개 가능한 작업을 소유합니다. 인계는 명시적입니다. Job은 `owner_session_id`, `source_actor_event_id`, `source_tool_call_id`를 담고 있으므로, Job을 생성한 turn에서 Job으로, 그리고 다시 돌아오는 연결은 항상 재구성할 수 있습니다.

실제 의미는 이렇습니다. Job은 두 번째 세션도 아니고 에이전트에 대한 경합 주장도 아닙니다. 소유자 세션이 요청한 작업으로, 고유한 상태 머신, 고유한 재시도 예산, 고유한 보고 방식을 가집니다.

## Job 상태 머신

Job은 여섯 가지 상태를 오가며, 전환은 고정된 테이블에 의해 제약됩니다.

```text
queued → running → waiting_on_user → running → … → succeeded | failed | stopped
```

- **`queued`** — 수용되었지만 아직 에이전트 실행 슬롯을 차지하지 않은 상태.
- **`running`** — 에이전트의 실행 슬롯 하나를 차지한 상태(에이전트당 최대 세 개).
- **`waiting_on_user`** — 사람의 입력을 기다리며 일시 정지된 상태. 실행 슬롯을 해제하고, 이후의 turn이 재개합니다.
- **`succeeded`**, **`failed`**, **`stopped`** — 종료 상태. 종료된 Job은 라이브 실행이 없습니다.

모든 전환은 `transition_allowed?/2`를 거치므로 `queued` Job은 `running`을 거치지 않고 `succeeded`로 점프할 수 없고, 종료 상태의 Job은 전혀 움직일 수 없습니다. 이 테이블이 계약이며, 애플리케이션 코드의 어떤 것도 그것을 우회할 수 없습니다.

## Wakeup: 소유자에게 보고하기

Job이 소유자가 알아야 할 상태에 도달하면, 라이프사이클은 같은 트랜잭션 안에서 전환을 커밋하고 소유자 세션에 wakeup 이벤트를 추가합니다. 세 가지 상태가 wakeup을 만들어냅니다.

| Job 상태 | Wakeup 이벤트 유형 |
|---|---|
| `succeeded` | `background_agent_job.completed` |
| `failed` | `background_agent_job.failed` |
| `waiting_on_user` | `background_agent_job.waiting` |

wakeup은 일반 액터 이벤트입니다. 다른 시그널과 같은 큐, 같은 fencing, 같은 세션 컨트롤러를 사용하며, `owner_session_id`를 대상으로 하고 Job의 `reply_route`(바인딩, 채널, 스레드)를 통해 라우팅됩니다. 소유자 세션은 폴링하지 않습니다. 보고할 것이 있을 때 정확히 그때 깨어납니다. `queued`나 `running`으로의 전환은 wakeup을 만들지 않습니다. 소유자가 대응할 필요가 없는 상태이기 때문입니다.

wakeup 이벤트의 source id는 Job, 상태, 시도 번호를 인코딩하므로, 재개된 Job의 나중 wakeup이 이전 wakeup과 혼동될 수 없습니다.

## 재개와 입력 대기

`waiting_on_user`는 슬롯을 붙잡지 않고 Job을 살아 있는 상태로 유지하는 일시 정지입니다. Job이 사람의 결정을 필요로 하면 `waiting_on_user`로 전환합니다. 최신 상태 프로젝션은 오류 코드 `request_user_input`과 대기 중인 tool 호출과 함께 `interrupted`를 기록하므로, 소유자의 다음 turn은 재개할 정확한 지점을 갖게 됩니다. 사람이 답하면 Job은 `running`으로 돌아가 계속됩니다.

Job은 자신의 일시 정지가 아니라 이전 Job에서 이어서 계속될 수도 있습니다. `continued_from_job_id`와 `workspace_owner_job_id`가 그 연쇄를 기록합니다. 이것이 긴 작업이 흐름이나 workspace를 잃지 않고 앞으로 넘겨지는 방식입니다.

## Worker 실패에 걸친 복구

Job 상태가 durable하기 때문에 Worker 손실은 데이터 손실 사건이 아니라 복구 가능한 사건입니다. 런타임은 Job에 제한된 재시도 예산을 부여합니다. 실행 시도는 최대 다섯 번, 연속 turn 실패도 최대 다섯 번입니다. 시도가 깨끗하게 시작되지 않으면 `requeue_unstarted_attempt`가 시도 카운터를 줄이고 Job을 `queued`로 되돌리며, 첫 번째 시도의 `started_at`을 지워 처음 시작하는 것처럼 보이게 합니다.

두 가지 클레임 경로가 두 가지 복구 형태를 담당합니다.

- **`claim_attempt_in_tx`** — 새 실행 시도를 위해 Job을 클레임.
- **`claim_continuation_in_tx`** — 일시 정지 후 계속하기 위해 Job을 클레임.

둘 다 에이전트의 슬롯 잠금을 먼저 잡고 그다음 `FOR UPDATE` 아래에서 Job 행을 잡습니다. 순서는 고정되어 있습니다. 따라서 같은 에이전트에 대한 동시 디스패처는 매번 같은 방식으로 해결됩니다. 예산을 초과한 재시도 시도는 `failed`로 끝나고, 취소된 Job은 `stopped`로 끝납니다. 시도 사이의 재시도 지연은 30초로 제한되므로, 일시적으로 실패한 Job이 프로바이더를 강타하지 않습니다.

AIGateway 할당량 소진 시 미래 복구 시간이 알려져 있으면, Job을 `queued`로 되돌리고 Worker 할당을 해제하며 그 시간에 디스패치를 예약합니다. 획득한 시도는 소비된 채로 남으므로, 반복된 할당량 실패도 다섯 번 시도 예산 안에 머무릅니다. 복구 시간이 오래되었거나 없으면 즉시 디스패치 대신 일반적인 제한된 Job 재시도 경로를 사용합니다.

## 디스패치와 에이전트의 플러그인

Job은 선택적 workspace 템플릿 하나를 유지하지만, 각 실행은 생성 시점에 동결된 스냅샷이 아니라 에이전트의 *현재* 활성화된 Agent Plugins와 호환되는 Skills를 사용합니다. 디스패치 경로(`BackgroundAgentJobDispatch.process`)는 액터 이벤트에서 Job을 해석하고 turn 런타임에 넘기며, steer 이벤트는 별도로 처리해서 세션에 대한 라이브 전달이 Job steer로 오인되지 않게 합니다. 모든 모델 turn은 생성 시 Job이 저장한 프로바이더 바인딩으로 AIGateway를 거칩니다. 해당 프로바이더에 자격 증명이 여러 개 있으면 선택, 친화성(affinity), 갱신, 재시도는 AIGateway가 소유합니다. Job에는 계정(account) 필드나 계정 동시성 슬롯이 없습니다.

Job이 처음 workspace를 초기화할 때 러너는 프로젝트의 `AGENTS.md`를 구성합니다. 선택적 workspace 템플릿이 먼저 오고, 그다음 렌더링된 Job 컨텍스트 — 에이전트의 SOUL과 MISSION, durable Brain 컨텍스트, 실행 사실 — 가 옵니다. 공유된 `app/library/templates/AGENT_JOB.md`는 확장 지점으로 남지만, 배포되는 파일은 비어 있으므로 러너는 Job Guidance 섹션을 생략합니다. Codex 프로젝트 구성은 네이티브 서브에이전트 대기 최솟값을 1분, 기본값을 2분으로 설정합니다. 최댓값은 설정하지 않으므로 Codex가 기본값을 유지합니다. 이것은 [openai/codex#35259](https://github.com/openai/codex/issues/35259)에서 추적되는, 빈 대기 후 반복되는 모델 turn을 줄여 줍니다. 재개된 스레드는 기존 `AGENTS.md`를 유지합니다.

## 운영자 표면

운영자에게 필요한 것을 세 개의 Console 범위 라우트가 담당합니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/background-agent-jobs` | Job 목록 |
| `GET` | `/background-agent-jobs/:job_id` | Job 하나 읽기 |
| `POST` | `/background-agent-jobs/:job_id/cancel` | Job 취소 |

취소는 Job을 `stopped`로 이끕니다. 실행 중인 turn 아래에서 라이브 Worker를 빼앗지는 않습니다. turn은 스스로 완료되거나 실패하며, 모든 Worker 쓰기가 거치는 것과 같은 활성화(activation) 및 리비전 검사로 fencing됩니다.

## Background Agent Jobs가 아닌 것

Job은 자유 형식의 백그라운드 프로세스가 아닙니다. 고정된 전환 테이블, 제한된 재시도 예산, 그리고 보고 대상이 되는 단일 소유자 세션을 가진 상태 머신입니다. 권한 경계 밖에서 작업을 실행하는 방법도 아닙니다. Job은 같은 플러그인과 스킬 아래에서 자신의 에이전트로 실행됩니다. Actor Runtime의 대체물도 아닙니다. 둘은 액터 이벤트 큐와 fencing 메커니즘을 공유하지만, Job은 재개 가능한 작업을 소유하고 런타임은 라이브 turn을 소유합니다. 이 경계는 의도적이며, 경계를 넘는 일은 다른 계층의 내부를 직접 건드리는 것이 아니라 문서화된 전환을 통해 이루어집니다.

## 다음 단계

- Job이 생성되고 보고하는 라이브 turn은 [Actor Runtime](../actor-runtime/) 페이지를 참고하세요.
- Job 실행이 수행하는 모델 turn은 [AIGateway API](../ai-gateway/)를 참고하세요.
- Job의 wakeup이 일반 시그널로 소유자에게 도달하는 방식은 [SignalsGateway](../signals-gateway/) 페이지를 참고하세요.