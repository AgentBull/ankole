---
title: 자동화 블루프린트
description: 트리거를 Agent session, automation job, background job, 시그널 라우팅 규칙과 결합합니다.
section: Guides
order: 309
---

Ankole의 자동화는 세 가지 트리거 중 하나와 두 가지 소비자 중 하나를 결합합니다. Agent session은 판단, memory 또는 대화가 필요한 작업을 처리합니다. automation job은 기계적인 처리를 위해 결정적 스크립트를 실행합니다. 이 페이지는 일반적인 형태에 바로 사용할 수 있는 블루프린트를 제공합니다.

Ankole은 워크플로 언어나 단계 그래프를 추가하지 않습니다. automation job은 Agent Home 안의 평범한 Bun `main.ts`입니다. 트리거 소유자는 시간이나 인그레스(ingress)를 유지하고, 선택된 소비자가 변경되지 않은 이벤트를 처리합니다. Agent는 스크립트가 이벤트를 발행하거나 실패 정책이 깨울 때만 다시 작업에 개입합니다.

## 세 가지 트리거

모든 블루프린트는 세 가지 트리거 중 하나를 사용합니다. 블루프린트를 고르기 전에 어떤 것이 필요한지 파악하세요.

| 트리거 | 발동 방식 | 전달 수단 | 구축 방법 |
|---|---|---|---|
| **Schedule** | cron 주기로(시간별, 일별, 주별) | cron schedule 위의 `task` | [스케줄](../schedules/) |
| **자기 지연(checkback)** | Agent가 turn 중에 지연 트리거를 설정 | Agent의 `check_back_later` 도구 | [스케줄](../schedules/) |
| **이벤트 기반(webhook)** | 외부 시스템이 capability URL로 POST | `webhook.received` 이벤트 | [Webhook 위임](../webhook-delegations/) |

세 트리거는 모두 Agent를 깨우든 스크립트를 실행하든 동일한 CloudEvents 봉투(envelope)를 생성합니다. 소비자 선택은 트리거 사실이 아니라 수신자를 바꿉니다. 직접 깨우기와 스크립트가 발행한 이벤트는 모두 소유자 session의 라우팅 규칙을 통해 반환됩니다.

## 소비자 선택

| 소비자 | 사용 시점 | 트리거 결과 |
|---|---|---|
| **Agent session** | 각 전달에 판단, memory, 런타임에 선택되는 도구 또는 사용자 대상 응답이 필요할 때. | 트리거가 ActorEvent를 추가하고 conversation을 깨웁니다. |
| **Automation job** | 처리가 결정적 fetch, 비교, 파싱 또는 사전 결정된 작업일 때. | 트리거가 지속 가능한 스크립트 실행을 생성합니다. 스크립트는 조용히 끝나거나 소유자 session에 이벤트를 발행할 수 있습니다. |

처리 방식이 불분명한 동안에는 직접 Agent 깨우기로 시작하세요. 입증된 기계적인 부분만 automation job으로 옮기세요. 이렇게 하면 스크립트를 작게 유지하고 model을 유휴 폴링 루프에 빠뜨리지 않습니다.

## 블루프린트: 일일 다이제스트(스케줄)

스케줄이 하루에 한 번 Agent를 깨웁니다. Agent는 요청된 정보를 수집하고 요약한 다음 결과를 바인딩된 chat channel에 게시합니다. 일일 cron 표현식을 설정하기 전에 [스케줄](../schedules/) 문서로 만들고 테스트하세요.

```bash
curl -X POST https://ankole.example.com/api/v1/agents/<agent_uid>/cron-schedules \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "owner_session_id": "<session_id>",
    "binding_name": "main",
    "name": "daily-digest",
    "schedule": { "cron": "0 9 * * *", "kind": "cron" },
    "timezone": "Asia/Shanghai",
    "delivery": { "targets": [{ "binding_name": "main", "signal_channel_id": "<signal_channel_id>" }] },
    "payload": { "task": "Produce today'\''s digest of the topics in your mission." },
    "idempotency_key": "daily-digest-1"
  }'
```

조정 가능한 부분: cron 표현식(주기), `timezone`(“오전 9시”가 언제인지), `task`(무엇을 할지), persona(어떻게 할지). 스케줄에 의존하기 전에 수동 실행으로 검증하세요.

## 블루프린트: 결정적 감시자(스케줄 + automation job)

스케줄이 자주 발동하지만 점검이 기계적이고 보통 결과가 없을 때는 automation job을 사용하세요. Agent가 스크립트를 작성하고 등록한 다음 cron schedule을 해당 `automation_job_id`에 바인딩합니다.

```json
{ "cron": "0 * * * *", "kind": "cron" }
```

스크립트는 소스를 읽고 조건이 거짓이면 `emitEvent` 없이 종료합니다. 조건이 참이면 범위가 제한된 소스 사실을 소유자 session에 발행하며, Agent가 이를 확인하고 무엇을 할지 결정합니다. 등록 전에 non-SDK 분기를 직접 테스트하고, `context()` 또는 `emitEvent`를 호출하는 모든 분기에 실제 테스트 트리거를 사용하세요.

모든 실행에 의미론적 판단이 필요하면 직접 Agent 스케줄을 유지하세요. Automation Job 계약에 대해서는 [Worker CLI capabilities](../cli-capabilities/) 문서를 읽으세요.

## 블루프린트: 지연 후속 처리(checkback)

agent가 turn에서 어떤 것을 요청받고, 나중에 다시 다루기로 결정합니다. 고정 cron 대신 agent 자신이 `check_back_later`로 일회성 깨우기를 설정합니다. agent 쪽에서의 형태는 “한 시간 후에 다시 보라”입니다. agent가 도구를 호출하고, operator 표면은 읽기 전용입니다.

이것은 주기가 없는 작업에 맞습니다. “배포가 한 시간 안에 끝났는지 확인하세요”, “스탠드업 후 이 스레드를 다시 읽으세요” 같은 경우입니다. agent가 타이밍을 소유합니다. 대기 중인 checkback은 `GET /agents/:agent_uid/checkbacks`로 확인하고 `DELETE`로 취소할 수 있습니다.

## 블루프린트: 리서치 후 보고(스케줄 + background job)

스케줄이 turn을 시작합니다. 작업에 긴 검색과 교차 검증이 필요하면 Agent는 turn을 열어 둔 채 기다리지 않고 [Deep Research Background Agent Job](../deep-research-job/)에 위임합니다.

1. cron 스케줄이 해당 `task`를 발동합니다.
2. agent가 작업이 길다고 판단하고 `create_background_job`을 호출합니다.
3. 스케줄의 turn이 끝나고, job이 자체적으로 실행됩니다.
4. job이 `background_agent_job.completed`를 소유 session에 다시 게시하며, binding이 이를 전달합니다.

이렇게 하면 스케줄의 turn이 한 시간 동안 실행되지 않고도 “주간 딥 리서치”를 얻을 수 있습니다. 스케줄이 발동하고, job이 작업을 수행합니다.

## 블루프린트: 이벤트 기반(webhook)

소스 저장소나 CI provider 같은 외부 시스템이 수명이 짧은 Ankole capability URL을 호출합니다. 엔드포인트는 전달을 수락하고 성공을 반환하기 전에 선택된 소비자 레코드를 커밋합니다.

Agent가 현재 외부 객체를 검사하고 이벤트를 판단해야 할 때는 기본 직접 소비자를 사용하세요. 결정적 스크립트가 수신 내용을 먼저 필터링하거나 조정할 수 있을 때는 엔드포인트를 automation job에 바인딩하세요. 두 경로 모두에서 수신 내용은 신뢰할 수 없는 것으로 취급하며, 결과에 영향을 주는 사실은 여전히 권위 있는 외부 소스에서 옵니다. capability 보안 및 수명 주기 규칙에 대해서는 [Webhook 위임](../webhook-delegations/) 문서를 읽으세요.

## 블루프린트: 관찰 및 에스컬레이션(binding policy + schedule)

팀 어시스턴트가 channel을 관찰하고, 스케줄이 관찰한 내용의 주기적 요약을 생성합니다. binding policy(`may_intervene` 또는 `record_only`)는 agent가 실시간으로 보는 것을 결정하고, 스케줄은 언제 종합할지를 결정합니다.

- Binding: `unaddressed_group_message_policy: record_only` — agent는 모든 것을 보고 아무것에도 말하지 않으며 컨텍스트를 쌓습니다.
- Schedule: “이 channel에서 무슨 일이 있었는지”에 대한 일일 또는 주간 요약.
- agent는 session의 최근 컨텍스트를 활용하여 binding을 통해 요약을 게시합니다.

이것은 관찰(지속적, 조용함)과 종합(스케줄링됨, 두드러짐)을 분리합니다. 실시간 답변이 소음이 되지만 주기적 요약은 가치 있는 channel에 적합합니다.

## 블루프린트 선택

- **시계에 맞춰 실행되길 원하나요?** Schedule. 매번 게시할지 아니면 중요한 일이 있을 때만 게시할지에 따라 다이제스트 또는 감시자 형태를 고르세요.
- **진행 중인 작업에 다시 돌아오길 원하나요?** Checkback. agent가 타이밍을 소유합니다.
- **긴 작업을 시계로 시작하길 원하나요?** Schedule + background job.
- **model turn 없이 빈번한 기계적 점검을 원하나요?** Schedule 또는 Checkback + automation job.
- **외부 시스템이 작업을 이어가길 원하나요?** 직접 Agent 또는 automation job 소비자를 사용한 Webhook delegation.
- **조용한 관찰과 주기적 종합을 원하나요?** Binding policy + schedule.

## Ankole 자동화가 아닌 것

이것은 워크플로 언어가 아닙니다. YAML 단계 목록, 플랫폼 DAG, 숨겨진 커서, 범용 이벤트 버스도 없습니다. automation job은 작은 스크립트를 실행할 수 있지만, 스크립트가 자체 상태와 반복 안전성을 책임집니다. 전달은 여전히 소유자 session의 라우팅 규칙을 사용하며, 자동화는 권한을 우회할 수 없습니다. 판단에는 Agent를 사용하고 스크립트는 기계적인 부분에만 사용하세요.

## 다음 단계

- 스케줄 표면에 대해서는 [스케줄](../schedules/) 문서를 읽으세요.
- 결정적 스크립트 소비자에 대해서는 [Automation Jobs](../automation-jobs/) 문서를 읽으세요.
- 백그라운드 실행 및 협업 선택에 대해서는 [Background Agent Jobs](../background-jobs/) 문서를 읽으세요.
- 외부 이벤트 capability에 대해서는 [Webhook 위임](../webhook-delegations/) 문서를 읽으세요.