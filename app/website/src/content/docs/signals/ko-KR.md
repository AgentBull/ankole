---
title: Signals
description: 영구 이벤트, 라우팅 규칙, 공유 대화 사실과 외부 전달.
section: Developer guide
order: 102
---

Signal은 Agent의 Session에 작업을 요청하는 영구 이벤트입니다. 메시지, 예약 기동, automation 결과 또는 업무 이벤트를 나타냅니다. Conversation과 Message를 참조할 수 있지만, 일반 업무 이벤트에 두 객체가 필수는 아닙니다.

`Ankole.Signals`는 이벤트 수용과 Signal Routing Rule을, `Ankole.Conversations`는 공유 발언·외부 관찰·전달을, `Ankole.Sessions`는 실행을 소유합니다. 원본 사실, 자극, 실행 상태를 각 소유자가 관리합니다.

## Conversation과 Message

Conversation은 공유 기록을 저장합니다. 기본 채팅과 외부 채팅은 같은 Message 모델로 작성자, 내용과 대화 내 순번을 기록합니다. `ExternalMessageRef`는 외부 Message를 provider 식별자와 원본 payload에 연결합니다.

외부 Conversation은 tenant 내 `provider_conversation_id`로 고유합니다. 여러 Agent가 같은 대화의 발언을 공유하면서 각자의 Session과 모델 기록을 유지합니다. Agent나 라우팅 규칙을 삭제해도 외부 기록은 보존됩니다.

`Conversations.Observe`가 provider 사실을 수용하고 `Conversations.External`이 Message와 외부 참조를 씁니다. 재관찰은 같은 사실을 갱신합니다. reaction은 사실만 갱신하며 모델 turn을 시작하지 않습니다. provider 삭제는 Message 소유자를 거쳐 의존 실행 사실과 같은 트랜잭션으로 처리합니다.

## 메시지에서 Signal로

adapter는 provider 요청을 검증하고 메시지, reaction, 삭제 또는 action을 정규화합니다. Observe는 Signal Routing Rule의 필터와 메시지 정책을 적용하고 필요한 경우 신원 수용을 수행합니다.

수용한 메시지는 Message가 됩니다. Agent 작업이 필요하면 같은 트랜잭션에서 해당 Agent Session의 Signal을 수용합니다. 필터에 맞지 않는 사실은 성공한 no-op입니다. reaction은 Agent를 깨우지 않습니다.

Agent를 부르지 않은 그룹 메시지는 `addressed_only`가 수용과 기록을 생략할 수 있습니다. 이후 명시적인 답장 참조에 필요한 원본 Message는 해결할 수 있습니다. 다른 그룹 활동의 판단은 [Ambient intervention](../ambient-intervention/)을 참조하세요.

## CloudEvents와 라우팅

Signal Routing Rule은 Binding으로 저장되며 Agent, adapter, 설정 참조, 필터와 대상을 선택합니다. 운영자는 Console에서 관리합니다. 규칙을 비활성화하면 새 수용이 중단되지만 기록된 대화 사실은 삭제하지 않습니다.

구조화 JSON 입구는 다음과 같습니다.

```text
POST /signals/v1/cloudevents/:token
```

이벤트는 `specversion`, `id`, `source`, `type`과 선택적인 `subject`, `time`, `data`, 확장을 포함합니다. 규칙은 고정 Conversation 또는 Session, source와 subject별 Session, 이벤트별 Session을 선택할 수 있습니다. 재전달은 같은 식별자를 사용하며 자극을 중복 생성하지 않습니다.

외부 이벤트의 type과 data는 입력 사실입니다. 내부 제어 명령이나 신뢰된 producer를 선언할 수 없습니다. kernel 이벤트의 비공개 출처는 실제 소유자가 지정합니다. Console에서 CloudEvents endpoint를 만들고 취소하며 규칙을 설정할 수 있습니다.

## provider webhook과 callback

provider handler는 다음 입구를 사용합니다.

```text
POST /webhooks/v1/:handler_id/:instance_id/:kind
```

선언된 handler가 서명이나 자격 증명을 검증합니다. controller는 `signals.webhook_handler`와 선언된 kind를 확인합니다. Signal adapter 계약은 `signals.adapter`입니다.

Agent가 만든 raw callback은 `/webhooks/v1/event-callbacks/wh_<token>`을 사용합니다. capability URL은 기록된 callback 경로를 허가하지만 body 사실을 인증하지 않습니다. Signals는 token digest를 저장하고 endpoint 결정과 `webhook.received` 또는 automation run을 함께 커밋합니다. lifecycle과 Worker bridge는 [Webhook delegations](../webhook-delegations/)를 참조하세요.

## 전달

`Conversations.Delivery`는 전송 의도를 저장하고 adapter의 `deliver`를 호출합니다. 전송 전에 실제 provider 대화와 메시지 식별자를 해결합니다. 확인된 각 Message와 외부 참조는 전달 결과와 함께 커밋합니다.

상태는 `pending`, `sent`, `failed`, `expired`, `unknown`입니다. 확인되지 않은 결과는 `unknown`으로 표시하고 자동 재전송하지 않습니다. 영구 의도와 진단으로 확인할 수 있습니다.

실행과 복구는 [Sessions](../sessions/), 설정은 [Quick start](../quickstart/), 비교는 [Conversations, Signals, and Sessions](../conversations-signals-sessions/)를 참조하세요.
