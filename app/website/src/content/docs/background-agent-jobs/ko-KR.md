---
title: Background Agent Jobs
description: Worker 손실을 견디는 durable하고 재개 가능한 작업 — 작업 상태 머신, 입력 대기(wait-for-input), 소유자 wakeup, Sessions과의 경계를 다룹니다.
section: Developer guide
order: 105
---

Background Agent Job은 개별 Worker 인스턴스가 종료되거나 교체되더라도 중단 없이 이어지도록 설계된 장기 작업 단위입니다. 에이전트는 현재 대화 turn 안에서 바로 처리하기에는 시간이 오래 걸리거나 단계가 많거나 별도 작업 공간으로 분리해야 하는 업무를 만나면 Background Agent Job을 생성해 위임합니다. 이후 Job이 자체 일정에 따라 실행되고 필요한 경우 사람의 응답을 기다리며 일시 정지했다가 완료되는 동안에도, 작업을 위임한 메인 에이전트는 블로킹 없이 사용자와 대화를 계속 주고받을 수 있습니다. 이 문서에서는 `Ankole.BackgroundAgentJobs` 모듈의 실제 구현을 기준으로 이 수명 주기를 설명합니다.

먼저 핵심 성격을 짚어 두면, Job은 단순한 OS 자식 프로세스가 아니라 영구 보장되는(durable) 도메인 엔티티입니다. 모든 상태는 PostgreSQL에 저장되고 모든 상태 전이에는 펜싱(fencing)과 감사 기록이 적용됩니다. 또한 소유자 세션이 알아야 하는 상태 변화가 일어나면 일반 시그널과 동일한 액터 이벤트 큐를 통해 소유자 세션에 wakeup 이벤트를 전달합니다.

## Sessions과의 경계

대화 세션의 turn과 백그라운드 Job은 성격이 다른 작업이므로 런타임에서도 명확히 분리해 관리합니다. `Sessions`는 세션을 깨워 모델 루프를 실행하고 결과를 커밋하는 실시간 펜싱 turn을 담당하며, `BackgroundAgentJobs`는 그 turn에서 위임받아 장기간 재개 가능한 작업을 담당합니다. 두 계층 사이의 인계 정보는 명시적으로 기록됩니다. 모든 Job 행에 `owner_session_id`, `source_signal_id`, `source_tool_call_id`가 남으므로 어떤 turn의 어떤 도구 호출에서 Job이 시작되었고 결과가 어디로 돌아가야 하는지 언제든 정확히 재구성할 수 있습니다.

각 Job은 동일한 Agent 소속의 독립된 `job:<id>` Session에서 실행되며, 진행 결과는 `owner_session_id`로 보고합니다. 상태 머신과 재시도 예산, 보고 규칙 역시 메인 대화 세션과 별도로 관리됩니다.

## Job 상태 머신

Job은 여섯 가지 상태를 가지며, 허용된 전이 경로는 고정된 규칙 테이블로 엄격히 제한됩니다.

```text
queued → running → waiting_on_user → running → … → succeeded | failed | stopped
```

- **`queued`** — 작업이 수락되었으나 아직 에이전트의 실행 슬롯을 배정받지 못한 대기 상태입니다.
- **`running`** — 에이전트의 실행 슬롯 하나를 점유해 실제 작업을 수행 중인 상태입니다(기본값 기준 에이전트당 최대 3개).
- **`waiting_on_user`** — 사람이나 상위 에이전트의 추가 입력을 기다리며 일시 정지된 상태입니다. 점유하던 실행 슬롯을 반납하며, 답변이 도착하면 후속 turn에서 다시 이어 갑니다.
- **`succeeded`**, **`failed`**, **`stopped`** — 최종 종료 상태이며, 종료된 Job에는 활성 실행 프로세스가 남지 않습니다.

모든 상태 변경은 `transition_allowed?/2` 검증을 거치므로 `queued` 상태인 Job이 `running`을 건너뛰고 곧바로 `succeeded`가 될 수 없으며, 한 번 종료 상태에 들어간 Job은 다른 상태로 다시 전이될 수 없습니다. 애플리케이션의 어느 코드도 이 전이 규칙을 우회할 수 없습니다.

## Wakeup: 소유자에게 보고하기

Job이 소유자 세션에 알려야 하는 상태에 도달하면, Ankole은 단일 트랜잭션 안에서 상태 전환을 커밋함과 동시에 소유자 세션 앞으로 wakeup 이벤트를 적재합니다. wakeup을 발생시키는 상태는 다음 세 가지입니다.

| Job 상태 | Wakeup 이벤트 유형 |
|---|---|
| `succeeded` | `background_agent_job.completed` |
| `failed` | `background_agent_job.failed` |
| `waiting_on_user` | `background_agent_job.waiting` |

이 wakeup은 특수한 우회 경로가 아니라 일반 액터 이벤트로서, 다른 모든 시그널과 동일한 큐, 펜싱, 세션 컨트롤러를 거쳐 `owner_session_id`로 전달되며 Job에 기록된 `reply_route`(바인딩, 채널, 스레드)를 따라 라우팅됩니다. 따라서 소유자 세션은 백그라운드 상태를 폴링하며 기다릴 필요 없이 보고할 일이 생긴 정확한 시점에 깨어납니다. 반면 `queued`나 `running`으로 전환될 때는 소유자 세션이 당장 취할 조치가 없으므로 wakeup을 발생시키지 않습니다.

각 wakeup 이벤트의 source ID에는 Job ID, 도달한 상태, 시도 번호(attempt)가 함께 인코딩되므로, 재개된 Job에서 나중에 발생한 wakeup이 이전 시도의 wakeup과 섞이거나 중복 제거로 누락되지 않습니다.

완료 wakeup에는 크기가 제한된 결과 요약본이 실려 전달됩니다. 만약 저장된 전체 최종 응답이 요약 한도를 초과하면 소유자 Agent는 `result_offset: 0`을 지정해 `show_background_job_details` 도구를 호출하고, 반환된 `result.next_offset` 값을 다음 호출에 넘기면서 값이 `null`이 될 때까지 순차 조회합니다. UTF-8 경계를 안전하게 지키는 각 텍스트 조각을 순서대로 이어 붙이면 원본 응답 전체를 손실 없이 복원할 수 있어, 단일 wakeup 메시지와 개별 읽기 호출의 크기를 일정 한도 이내로 유지하면서도 대용량 결과를 온전히 전달할 수 있습니다.

## 재개와 입력 대기

`waiting_on_user`는 실행 슬롯을 점유하지 않은 채 Job의 문맥을 그대로 보존하는 일시 정지 상태입니다. 작업 도중 사람의 의사결정이 필요해지면 Job은 `waiting_on_user`로 전환되며, 최신 상태 프로젝션에는 오류 코드 `request_user_input`과 대기 중인 도구 호출 정보를 담은 `interrupted` 상태가 기록되어 다음 turn에서 정확히 어느 지점부터 재개해야 하는지 보존합니다. 이후 답변이 전달되면 Job은 다시 `running`으로 전환되어 작업을 이어 갑니다.

일시 정지 후 재개하는 것 외에도, 이미 완료된 이전 Job의 결과와 작업 공간을 이어받아 후속 Job을 시작할 수도 있습니다. 이때는 `continued_from_job_id`와 `workspace_owner_job_id` 필드가 연쇄 이력을 기록하므로, 여러 단계로 나뉜 장기 업무에서도 기존 맥락이나 로컬 파일 작업 공간을 잃지 않고 자연스럽게 작업을 이어 갈 수 있습니다.

## Worker 실패에 걸친 복구

모든 Job 상태가 PostgreSQL에 영구 저장되므로 Worker 인스턴스가 유실되더라도 데이터 손실이 아닌 복구 가능한 이벤트로 처리됩니다. 런타임은 각 Job에 총 실행 시도 최대 5회, 연속 turn 실패 최대 5회의 유한한 재시도 예산을 부여합니다. 만약 실행 시도가 정상적으로 시작되기도 전에 무산된 경우에는 `requeue_unstarted_attempt`가 소비된 시도 횟수를 되돌리고 상태를 `queued`로 복원하며, 첫 시도였다면 `started_at`까지 비워 처음 대기열에 들어온 것과 동일한 상태로 정리합니다.

실행권 획득(claim)은 상황에 따라 다음 두 트랜잭션 함수를 통해 이루어집니다.

- **`claim_attempt_in_tx`** — 새로운 실행 시도를 시작하기 위해 Job을 점유합니다.
- **`claim_continuation_in_tx`** — 일시 정지(`waiting_on_user`) 이후 실행을 이어 가기 위해 Job을 점유합니다.

두 경로 모두 반드시 해당 에이전트의 슬롯 잠금을 먼저 획득한 뒤 `FOR UPDATE`로 Job 행을 잠급니다. 잠금 획득 순서가 항상 고정되어 있으므로 동일한 에이전트에 대해 여러 디스패처가 동시에 경합하더라도 교착 상태 없이 일관되게 처리됩니다. 재시도 예산을 모두 소진하면 `failed`로, 운영자나 사용자가 취소하면 `stopped`로 종료됩니다. 또한 재시도 간 대기 시간은 최대 30초까지 백오프가 적용되므로 일시적 장애 상황에서 업스트림 프로바이더에 과도한 재시도 요청을 쏟아내지 않습니다.

만약 AIGateway 자격 증명 할당량이 소진되었는데 다음 복구 가능 시각(`retry_at`)을 알 수 있는 경우, 런타임은 Job을 `queued`로 되돌리고 Worker 할당을 해제한 뒤 해당 복구 시각에 맞춰 재디스패치를 예약합니다. 이때 이미 획득했던 시도 횟수는 차감된 채로 유지되므로 할당량 소진이 반복되더라도 5회 시도 상한 안에서 안전하게 제어됩니다. 복구 예정 시각이 이미 지났거나 제공되지 않은 경우에는 즉시 재디스패치하지 않고 일반 재시도 백오프 경로를 따릅니다.

## 디스패치와 에이전트의 플러그인

각 Job에는 선택적으로 하나의 초기 workspace 템플릿을 지정할 수 있습니다. 처음으로 실제 실행이 승인(execution admission)되는 트랜잭션에서 사용할 프로바이더 및 모델 바인딩과 당시 활성화된 Agent Plugin·Skill 목록이 함께 고정 기록됩니다. 이후 재시도나 재개 시에는 이 최초 고정 목록과 해당 에이전트의 현재 유효 활성화 목록의 교집합만 허용합니다. 즉, 중간에 관리자가 특정 기능을 끄면 실행 중인 Job에서도 즉시 제외되고 다시 켜면 복원되지만, 최초 승인 시점에 없던 새 기능이 중간에 추가되지는 않습니다. 반면 프로바이더 자격 증명과 수정 가능한 Skill 파일 본문은 매 시점 최신 정본에서 읽어 옵니다. `Sessions.CodexJob`은 커널 Signal로부터 Job 실행 시도를 수락하고 실시간 조종(steer) 이벤트는 별도 경로로 분리해 처리하므로, 일반 세션 메시지 전달이 Job 조종 명령으로 오인되지 않습니다. 모든 모델 호출은 기록된 바인딩을 통해 AIGateway를 거치며, 프로바이더에 여러 자격 증명이 등록되어 있을 때의 선택·세션 친화성(affinity)·토큰 갱신·재시도는 모두 AIGateway가 전담합니다.

Background Agent Job 역시 메인 Agent와 동일한 Ankole `skill_view` 로더를 사용합니다. 백그라운드 실행과 호환되는 일반 Skill은 Job의 Skill 인덱스에 포함되며, `brain-recall-only: true`가 선언된 Skill은 인덱스에서 제외된 채 Brain 검색을 통해 발견됩니다. 모델이 해당 발견 레코드에 대해 `get_page`를 호출하면 내부적으로 `skill_view`로 위임됩니다. 로더는 `SKILL.md`나 부속 참조 파일을 읽을 때마다 컨트롤 플레인에 현재 Agent Plugin 및 Skill 유효 상태를 다시 확인하므로, 실행 도중 비활성화된 Skill은 즉시 읽기가 차단됩니다.

Job이 작업 공간을 처음 초기화할 때 러너는 선택적 workspace 템플릿을 먼저 배치한 뒤 에이전트의 `SOUL.md`, `MISSION.md`, 실행 메타데이터를 렌더링해 프로젝트의 `AGENTS.md`를 조립합니다. 이때 Codex 프로젝트 설정에서는 네이티브 서브에이전트 대기 시간의 최솟값을 1분, 기본값을 2분으로 지정하고 최댓값은 비워 두어 Codex 기본값을 따르게 합니다. 이를 통해 [openai/codex#35259](https://github.com/openai/codex/issues/35259)에서 다뤄진 짧은 빈 대기 직후 불필요한 모델 turn이 반복되는 현상을 줄입니다. 스레드가 재개될 때는 기존에 생성된 프로젝트 `AGENTS.md`를 그대로 재사용합니다.

## 운영자 표면

운영자가 백그라운드 작업을 조회하고 제어할 수 있도록 세 개의 Console API 라우트를 제공합니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/background-agent-jobs` | 백그라운드 Job 목록 조회 |
| `GET` | `/background-agent-jobs/:job_id` | 특정 Job 상세 조회 |
| `POST` | `/background-agent-jobs/:job_id/cancel` | 실행 중이거나 대기 중인 Job 취소 |

취소를 요청하면 Job 상태가 `stopped`로 전환되고 실행 중인 Worker에 취소 명령이 전달됩니다. 이후 뒤늦게 도착하는 Worker 실행 결과를 커밋할지 여부는 모두 PostgreSQL에 기록된 Job 상태, attempt 식별자, Turn revision 펜스를 기준으로 판정합니다.

## Background Agent Jobs가 아닌 것

Background Agent Job은 제약 없이 임의로 돌아가는 백그라운드 데몬이 아닙니다. 고정된 상태 전이 규칙과 유한한 재시도 예산, 결과를 보고할 단일 소유자 세션을 갖춘 엄격한 상태 머신입니다. 또한 권한 체계를 우회하는 통로도 아니어서 자신을 생성한 에이전트와 동일한 Principal 및 플러그인·스킬 제약 아래에서 실행됩니다. 마지막으로 `Sessions`를 대체하는 계층도 아닙니다. 두 계층은 동일한 액터 이벤트 큐와 펜싱 메커니즘을 공유하되, 실시간 대화 turn은 `Sessions`가 맡고 장시간 재개 가능한 위임 작업은 `BackgroundAgentJobs`가 맡으며, 계층 간 연동은 내부 상태를 직접 건드리지 않고 정의된 상태 전이와 이벤트를 통해서만 이루어집니다.

## 다음 단계

- Job을 생성하고 결과를 보고받는 실시간 대화 turn 구조는 [Sessions](../sessions/) 문서를 참조하세요.
- Job 내부에서 수행되는 모델 호출 경계는 [AIGateway API](../ai-gateway/) 문서를 참조하세요.
- Job의 wakeup 이벤트가 소유자 세션에 전달되는 과정은 [Signals](../signals/) 문서를 참조하세요.
