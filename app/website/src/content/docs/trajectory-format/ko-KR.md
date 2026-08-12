---
title: Trajectory 및 메시지 형식
description: Ankole이 대화 메시지와 백그라운드 Job 궤적을 저장하고 투영하는 방식 — 두 저장 형태, ChatML 정규 형식, 그리고 모델이 보는 투영.
section: Developer guide
order: 121
---

Ankole은 에이전트가 수행한 작업을 두 종류의 작업에 대해 두 곳에 기록합니다: AIGateway는 대화 메시지(상태 저장 Responses 대화가 만들어내는 실시간 전사)를 저장하고, Background Agent Jobs는 턴 궤적(영구 Job 실행의 턴별 기록)을 저장합니다. 이 페이지는 두 저장 형태, 정규 ChatML 형식, 그리고 프로토콜 세부 사항을 제거하는 모델 가시 투영을 문서화합니다. [AIGateway](../ai-gateway/) 및 [Background Agent Jobs](../background-agent-jobs/) 문서를 기반으로 합니다.

먼저 핵심 속성을 밝힙니다: 모델은 원시 저장 행을 결코 보지 못합니다. 두 형태 모두 프로토콜 식별자를 제거하고 턴 로컬 호출 별칭으로 대체한 모델 가시 형태로 투영됩니다 — 모델은 내부 UUID나 와이어 프로토콜 필드가 아니라 “tool call 1 → tool result 1”을 봅니다. 저장 형태는 지속성과 감사를 위한 것이고, 투영 형태는 모델을 위한 것입니다.

## AIGateway 대화 메시지

AIGateway는 실시간 대화 전사를 소유합니다. 각 메시지는 `ai_gateway_messages`의 행입니다:

| 필드 | 의미 |
|---|---|
| `subject_uid` | 대화가 속한 Principal |
| `conversation_id` | 이 메시지가 속한 대화 |
| `type` | 메시지 유형(assistant, tool result 등) |
| `role` | 메시지가 전사에서 수행하는 역할 |
| `status` | 수명 주기 상태 |
| `previous_message_id` | 자기 참조 연속 앵커 — API에서는 `previous_response_id`로 렌더링되어 대화가 이어짐 |
| `content` | 메시지 내용(단일 문자열이 아닌 JSON 값) |
| `metadata` | 불투명한 호출자 메타데이터와 AIGateway가 소유한 응답 사실(model, provider, usage, provider raw ids) |

`previous_message_id`는 연속 앵커입니다: 각 메시지는 이전 메시지를 가리켜 연결 체인을 만듭니다. API에서는 `previous_response_id`로 렌더링되므로 호출자나 압축(compaction)이 어떤 앵커에서든 재개할 수 있습니다. `metadata` 필드는 불투명한 호출자 메타데이터와 함께 AIGateway가 소유한 사실, 즉 사용된 모델과 제공자, 토큰 사용량, 제공자의 원시 응답 id를 담습니다. 이 필드는 두 번째 항목 목록을 담아서는 안 됩니다.

압축([Context compression](../context-compression-and-caching/) 참조)은 이전 메시지를 새 앵커가 되는 요약 메시지로 대체합니다. 이전 메시지는 더 이상 모델의 가시 컨텍스트에 없으며, 요약이 새 시작점입니다.

## Background Agent Job 궤적

백그라운드 Job은 턴별 실행을 `background_agent_job_turn_trajectory_groups`의 궤적 그룹으로 저장합니다. 각 그룹은 턴에 속하며 위치, 리비전, 항목 키, 내용을 가집니다:

| 필드 | 의미 |
|---|---|
| `turn_id` | 이 궤적 그룹이 속한 Job 턴 |
| `position` | 턴 내에서 그룹의 순서 |
| `revision` | 제자리 업데이트(steer, nudge) 시 증가 |
| `item_key` | 그룹의 안정적인 키 |
| `content` | 하나 이상의 정규 ChatML 메시지 |

내용은 유효한 정규 ChatML이어야 합니다 — 스키마는 `Trajectory.valid_group_content?/1`로 이를 검증하여 정규 ChatML 메시지를 포함하지 않는 그룹을 거부합니다. `revision` 필드는 제자리 steer 또는 nudge가 새 행을 삽입하지 않고 동일한 그룹의 내용을 업데이트할 수 있게 하므로, 궤적은 해당 그룹의 최신 상태를 반영합니다.

도구 결과 메시지의 metadata는 `execution_mechanism`을 기록합니다. 모델 Provider가 실행한 도구에는 `provider_hosted`를 사용하고, Codex가 호출한 Ankole 동적 도구에는 `local_dynamic`을 사용합니다. 이 안정적인 사실로 표시 이름이 같은 도구도 구분할 수 있습니다.

이것은 AIGateway 대화 메시지와 별개의 저장 형태입니다. 백그라운드 Job의 궤적은 대화가 아니라 Job에 속하기 때문입니다. Job의 턴은 자체 스레드이며, Job이 보고하는 대화는 궤적이 아니라 결과를 받습니다.

## 모델 가시 투영

모델은 저장된 행을 보지 못합니다. worker의 `modelVisibleTrajectory`는 궤적을 모델이 봐야 하는 형태로 투영합니다:

- **저장된 프로토콜 식별자 제거** — 내부 메시지 id, 와이어 프로토콜 필드, 모델이 행동해서는 안 되는 모든 것.
- **tool-call id를 턴 로컬 별칭으로 대체** — `call_1`, `call_2` 등. 모델은 이를 연결하는 내부 UUID 없이 어떤 tool result가 어떤 tool call에 속하는지(유일하게 유용한 관계)를 봅니다.
- **내용과 역할 보존** — 실제 메시지, tool call과 그 결과를 발생 순서대로 유지합니다.
- **제한 콘텐츠 사실 보존** — 궤적 수준의 `metadata.redacted`와 `metadata.content_truncated`가 계속 보입니다. 제어 플레인 투영은 페이지 한도를 맞추기 위해 선택된 메시지 내용을 줄여야 할 때 `content_truncated`를 설정합니다.

moduledoc은 명확합니다: “턴 로컬 호출 별칭은 유일하게 유용한 관계, 즉 어떤 tool result가 어떤 tool call에 속하는지를 보존합니다.” 저장 행이 담는 나머지 모든 것은 모델이 아니라 시스템을 위한 것입니다.

## 두 형태의 관계

| | AIGateway 메시지 | 백그라운드 Job 궤적 |
|---|---|---|
| 저장 내용 | 실시간 대화 전사 | 턴별 Job 실행 기록 |
| 소유자 | AIGateway | Background Agent Jobs |
| 정규 형식 | AIGateway의 메시지 스키마 | ChatML 그룹 |
| 모델이 보는 경로 | 상태 저장 Responses API | `modelVisibleTrajectory` 투영 |
| 압축 | AIGateway 압축이 이전 메시지 대체 | 압축 없음(Job은 재시도 예산으로 제한됨) |

두 형태는 섞이지 않습니다. 대화의 메시지는 AIGateway의 것이고, Job의 궤적은 Job의 것입니다. Job은 대화의 메시지 저장소에 쓰는 것이 아니라 웨이크업 이벤트를 통해([Background Agent Jobs](../background-agent-jobs/) 참조) 소유 대화에 결과를 보고합니다.

## 이 가이드가 아닌 것

이 가이드는 ChatML 명세가 아닙니다 — 정규 ChatML 형식은 표준이며, Ankole의 검증(`valid_group_content?/1`)은 그 형태를 재정의하지 않고 확인합니다. 궤적을 읽기 위한 소비자 대상 API도 아닙니다 — Console 라우트(`/ai-gateway/conversations/:id/messages`, `/background-agent-jobs/:id`)는 [Console API reference](../console-api/)에 문서화된 운영자 표면입니다. 그리고 저장 페이지를 대신하는 것도 아닙니다. 이 가이드는 두 저장소에 걸친 형식 수준의 관점입니다.

## 다음 단계

- 대화 메시지 저장소에 대해서는 [AIGateway](../ai-gateway/)를 읽으세요.
- Job 궤적 저장소에 대해서는 [Background Agent Jobs](../background-agent-jobs/)를 읽으세요.
- 압축(이전 메시지를 대체)에 대해서는 [Context compression](../context-compression-and-caching/)을 읽으세요.
- 이들을 읽는 Console 라우트에 대해서는 [Console API reference](../console-api/)를 읽으세요.
