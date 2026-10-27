---
title: Trajectory 및 메시지 형식
description: Ankole이 대화 메시지와 백그라운드 Job 궤적을 저장하고 투영하는 방식 — 두 저장 형태, ChatML 정규 형식, 그리고 모델이 보는 투영.
section: Developer guide
order: 121
---

Ankole은 실행 성격에 따라 에이전트의 작업 기록을 두 곳에 나누어 저장합니다. AIGateway는 상태 저장형 Responses 대화가 만들어 내는 실시간 전사(대화 메시지)를 저장하고, Background Agent Jobs는 영속 Job 실행의 턴별 기록(턴 궤적)을 저장합니다. 이 문서는 두 저장 구조와 정규 ChatML 형식, 그리고 내부 프로토콜 세부 정보를 걷어 내고 모델에 전달하는 가시 투영(projection) 방식을 설명하며, [AIGateway](../ai-gateway/) 및 [Background Agent Jobs](../background-agent-jobs/) 문서를 바탕으로 합니다.

가장 중요한 원칙은 모델이 데이터베이스의 원시 저장 행을 직접 보지 않는다는 점입니다. 두 저장 형태 모두 내부 프로토콜 식별자를 제거하고 턴 범위의 로컬 별칭으로 치환한 투영본만 모델에 전달합니다. 따라서 모델은 내부 UUID나 와이어 프로토콜 필드 대신 `tool call 1 → tool result 1` 형태의 대응 관계만 보게 됩니다. 즉 원본 행은 영속성과 감사를 위한 형식이고, 투영본은 모델 추론을 위한 형식입니다.

여기서 말하는 AIGateway conversation은 개별 Session의 모델 추론 이력을 뜻하며, `Ankole.Conversations`가 관리하는 공유 Conversation 및 Message와는 별개입니다. 공개 대화 기록은 현재 턴의 배경 맥락을 제공할 뿐, 저장된 모델 응답 체인과 도구 실행 기록을 대체하지 않습니다.

## AIGateway 대화 메시지

실시간 대화 전사는 AIGateway가 소유하며, 각 메시지는 `ai_gateway_messages` 테이블의 행으로 저장됩니다.

| 필드 | 의미 |
|---|---|
| `subject_uid` | 대화를 소유한 Principal |
| `conversation_id` | 이 메시지가 속한 대화 식별자 |
| `type` | 메시지 유형(`assistant`, 도구 결과 등) |
| `role` | 전사 내에서 메시지가 맡는 역할 |
| `status` | 수명 주기 상태 |
| `previous_message_id` | 자기 참조 연속 앵커(API에서는 `previous_response_id`로 노출되어 대화 체인을 연결) |
| `content` | 메시지 본문(단순 문자열이 아닌 구조화된 JSON 값) |
| `metadata` | 불투명한 호출자 메타데이터와 AIGateway 고유 응답 기록(모델, 공급자, 사용량, 공급자 원시 응답 ID) |

`previous_message_id`는 대화의 연속성을 잇는 앵커로, 각 메시지가 직전 메시지를 가리키며 연결 리스트를 이룹니다. 외부 API에서는 `previous_response_id`로 렌더링되므로, 일반 호출자나 컨텍스트 압축(compaction) 로직이 원하는 임의의 앵커 지점부터 대화를 이어갈 수 있습니다. `metadata` 필드에는 호출자가 넘긴 불투명 메타데이터와 함께 사용된 모델·공급자, 토큰 사용량, 공급자 원시 응답 ID 등 AIGateway가 관리하는 사실만 담기며, 여기에 별도의 메시지 항목 목록을 중복 저장해서는 안 됩니다.

컨텍스트 압축([Context compression](../context-compression-and-caching/) 참조)이 실행되면 요약본 checkpoint가 새로운 가시 앵커로 저장됩니다. 압축 이전의 원본 행들도 복구와 감사를 위해 삭제하지 않고 남겨 두지만, 이후 모델에 전달되는 투영은 요약 checkpoint부터 시작하며 이전 메시지들을 다시 재생하지 않습니다.

## Background Agent Job 궤적

백그라운드 Job은 턴별 실행 내역을 정제된 시맨틱 스레드 항목으로 구성해 `background_agent_job_turn_items` 테이블에 추가 전용(append-only) 스트림으로 기록합니다. 각 행은 특정 턴에 속하며 순서, 리비전, 항목 키, 시맨틱 항목 본문을 가집니다.

| 필드 | 의미 |
|---|---|
| `turn_id` | 이 항목이 속한 Job 턴 식별자 |
| `position` | 턴 내부에서의 항목 순번 |
| `revision` | 이 항목을 수락한 시점의 턴 리비전 |
| `item_key` | 항목의 고유 키(`client:` 접두사 키는 호출자가 보낸 메시지를 나타냄) |
| `item` | 타입이 지정된 단일 시맨틱 스레드 항목 |

모든 행은 추가 전용이므로, 중간에 steer나 nudge 입력이 들어오더라도 기존 행을 덮어쓰지 않고 새 행을 뒤에 덧붙입니다. 조회 시점에는 모든 리더(reader)가 저장된 항목을 정규 ChatML 메시지로 투영하며, ChatML 메시지로 직접 변환되지 않는 내부 항목이라도 스레드 재생을 위해 테이블에는 그대로 보관됩니다. 기록된 항목 행이 하나도 없는 턴은 빈 궤적으로 표시됩니다.

도구 결과 메시지의 `metadata`에는 실행 경로를 나타내는 `execution_mechanism`이 기록됩니다. 모델 Provider 측에서 직접 실행한 도구에는 `provider_hosted`가, Codex가 호출한 Ankole 동적 도구에는 `local_dynamic`이 기록되므로 표시 이름이 같은 도구라도 이 필드로 실행 주체를 명확히 구분할 수 있습니다.

백그라운드 Job의 궤적은 채팅방 대화가 아니라 해당 Job 자체에 귀속되기 때문에 AIGateway 대화 메시지와 저장소를 분리합니다. 즉 Job의 각 턴은 독립된 자체 스레드로 돌고, 작업을 의뢰한 상위 대화방에는 상세 궤적 대신 최종 요약 결과만 전달됩니다.

## 모델 가시 투영

제어 플레인은 `Ankole.Sessions.Tools.Jobs.visible_trajectory/1`을 통해 저장된 Job 항목들을 모델 가시 형태로 투영하며, 이 과정에서 다음 규칙을 적용합니다.

- **저장된 내부 프로토콜 식별자 제거:** 내부 메시지 ID나 와이어 프로토콜 전용 필드처럼 모델이 참조하거나 추론 근거로 삼아서는 안 되는 값을 모두 걷어 냅니다.
- **도구 호출 ID를 턴 로컬 별칭으로 치환:** 내부 UUID를 노출하는 대신 `call_1`, `call_2` 같은 순차 별칭으로 바꾸어, 어떤 도구 결과가 어떤 도구 호출에 대응하는지(모델에 실제로 필요한 유일한 관계)만 명확히 보여 줍니다.
- **본문과 역할 순서 보존:** 실제 메시지, 도구 호출, 도구 결과를 발생 순서 그대로 유지합니다.
- **검열·절단 상태 메타데이터 유지:** 궤적 수준의 `metadata.redacted`와 `metadata.content_truncated` 표시는 그대로 노출됩니다. 특히 조회 페이지 크기 한도를 맞추기 위해 메시지 본문 일부를 잘라내야 할 때 제어 플레인 투영이 `content_truncated`를 설정합니다.

## 두 형태의 관계

| 구분 | AIGateway 메시지 | 백그라운드 Job 궤적 |
|---|---|---|
| 저장 대상 | 실시간 대화 전사 | 턴별 Job 실행 기록 |
| 소유 도메인 | AIGateway | Background Agent Jobs |
| 정규 형식 | AIGateway 메시지 스키마 | 시맨틱 항목의 ChatML 투영 |
| 모델 노출 경로 | 상태 저장형 Responses API | `visible_trajectory/1` 투영 |
| 컨텍스트 압축 | 새 가시 checkpoint를 추가하고 이전 행은 보존 | 별도 압축 없음(재시도 예산으로 범위 제한) |

두 저장소는 서로 섞이지 않습니다. 일반 대화 메시지는 AIGateway가 소유하고 Job 궤적은 Background Agent Jobs가 소유하며, Job이 완료되면 대화 메시지 테이블에 직접 행을 쓰는 대신 wake-up 이벤트를 발행해([Background Agent Jobs](../background-agent-jobs/) 참조) 소유 대화에 결과를 보고합니다.

## 이 가이드가 아닌 것

이 문서는 ChatML 자체의 표준 문법 명세가 아니며, Ankole의 읽기 시점 투영은 표준 ChatML 구조를 변형하지 않고 그대로 따릅니다. 또한 일반 최종 사용자용 API 안내서도 아닙니다. 전사와 궤적을 조회하는 `/api/v2/ai-gateway/conversations/:id/messages` 및 `/api/v2/background-agent-jobs/:id` 라우트는 운영자용 인터페이스이며 자세한 명세는 [Console API reference](../console-api/)에 정리되어 있습니다. 개별 도메인의 상세 동작은 아래 문서를 함께 확인하세요.

## 다음 단계

- 대화 메시지 저장 구조는 [AIGateway](../ai-gateway/)를 참조하세요.
- Job 궤적 저장 구조는 [Background Agent Jobs](../background-agent-jobs/)를 참조하세요.
- 컨텍스트 압축과 가시 checkpoint 동작은 [Context compression](../context-compression-and-caching/)을 참조하세요.
- 관련 조회용 Console API 경로는 [Console API reference](../console-api/)를 참조하세요.
