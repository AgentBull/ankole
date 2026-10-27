---
title: Signals
description: 영구 이벤트, 라우팅 규칙, 공유 대화 사실과 외부 전달.
section: Developer guide
order: 102
---

Signal은 특정 Agent의 Session에 작업 실행을 요청하는 영속 이벤트로, 채팅 메시지, 스케줄 기동, 자동화 스크립트 결과, 각종 업무 이벤트를 나타냅니다. 필요한 경우 Conversation과 Message를 참조할 수 있지만, 일반 업무 이벤트에서는 두 객체가 없어도 Signal을 생성할 수 있습니다.

소유권도 명확히 나뉘어 있습니다. 이벤트 수용과 Signal Routing Rule은 `Ankole.Signals`가 맡고, 공유 발언 저장·외부 채널 관찰·메시지 전달은 `Ankole.Conversations`가 맡으며, 실제 세션 실행은 `Ankole.Sessions`가 맡습니다. 즉 원본 사실, 실행 트리거, 실행 상태를 각 도메인 소유자가 분리해 관리합니다.

## Conversation과 Message

Conversation은 참여자 간 공유 대화 기록을 저장합니다. 기본 Pod 채팅과 외부 메신저 채팅 모두 동일한 Message 모델을 사용해 작성자, 본문, 대화 내 순번을 기록하며, 외부 채널에서 들어온 Message는 `ExternalMessageRef`를 통해 외부 provider 식별자 및 원본 페이로드와 연결됩니다.

외부 Conversation은 테넌트 안에서 `provider_conversation_id`를 기준으로 유일하게 유지됩니다. 한 대화방에 여러 Agent가 함께 참여하더라도 발언 기록은 공유하면서 각자의 Session과 모델 추론 이력은 독립적으로 유지하며, 나중에 특정 Agent나 라우팅 규칙을 삭제하더라도 기록된 외부 대화 내역은 보존됩니다.

외부 이벤트가 들어오면 `Conversations.Observe`가 provider 사실을 받아들이고 `Conversations.External`이 Message와 외부 참조 레코드를 기록합니다. 동일 항목이 다시 관찰되면 기존 레코드를 갱신하며, 이모지 리액션(reaction)은 상태만 갱신할 뿐 새 모델 턴을 시작하지 않습니다. 외부 플랫폼에서 메시지가 삭제된 경우에는 Message 소유 모듈을 거쳐 이에 의존하는 실행 상태까지 단일 트랜잭션으로 함께 정리합니다.

## 메시지에서 Signal로

어댑터는 외부 provider 요청의 서명·자격 증명을 검증한 뒤 메시지, 리액션, 삭제, 액션을 정규화된 형식으로 변환합니다. 이어서 `Observe`가 Signal Routing Rule의 필터와 메시지 정책을 적용하고, 필요한 경우 발신자 신원 매핑까지 처리합니다.

수용된 메시지는 Message로 저장되며, 그에 따라 Agent 실행이 필요하면 같은 트랜잭션 안에서 대상 Agent Session의 Signal이 함께 기록됩니다. 필터 조건에 해당하지 않는 이벤트는 오류 없이 no-op으로 처리되며, 리액션 역시 Agent를 깨우지 않습니다.

그룹 메시지 정책이 `addressed_only`로 설정되어 있으면 Agent를 멘션하지 않은 일반 그룹 메시지는 수용과 기록을 생략할 수 있습니다. 다만 이후 Agent를 향한 명시적 답글에서 앞선 메시지를 참조할 때는 필요한 원본 Message를 조회해 연결할 수 있습니다. 멘션 없는 그룹 대화에 선제 개입하는 판정 흐름은 [Ambient intervention](../ambient-intervention/)을 참조하세요.

## CloudEvents와 라우팅

Signal Routing Rule은 내부적으로 Binding 레코드로 저장되며 대상 Agent, 어댑터, 설정 참조, 필터, 라우팅 대상을 정의합니다. 운영자는 Console에서 규칙을 관리하며, 규칙을 비활성화하면 새로운 이벤트 수용만 멈출 뿐 이미 기록된 대화 사실은 삭제되지 않습니다.

구조화된 JSON 이벤트는 다음 엔드포인트로 수신합니다.

```text
POST /signals/v1/cloudevents/:token
```

수신 본문에는 필수 필드인 `specversion`, `id`, `source`, `type`과 선택 필드인 `subject`, `time`, `data` 및 확장 속성이 담깁니다. 라우팅 규칙에 따라 고정 Conversation이나 고정 Session으로 보낼 수도 있고, `source`·`subject` 조합별 Session이나 개별 이벤트별 새 Session으로 분기할 수도 있습니다. 동일한 이벤트 식별자로 재전달되면 멱등하게 처리되어 Signal이 중복 생성되지 않습니다.

외부에서 들어온 이벤트의 `type`과 `data`는 어디까지나 외부 입력 사실로 취급되므로, 이를 통해 내부 제어 명령을 사칭하거나 신뢰된 내부 발행자(producer)를 선언할 수 없습니다. 시스템 내부 커널 이벤트의 비공개 출처는 실제 도메인 소유 모듈만 지정할 수 있습니다. CloudEvents 엔드포인트 생성·폐기 및 규칙 설정은 Console에서 수행합니다.

## provider webhook과 callback

외부 채널·플랫폼용 webhook 핸들러는 다음 인그레스 경로를 사용합니다.

```text
POST /webhooks/v1/:handler_id/:instance_id/:kind
```

선언된 핸들러가 요청 서명이나 자격 증명을 검증하며, 컨트롤러는 `signals.webhook_handler` 계약과 선언된 `kind` 일치 여부를 확인합니다(일반 Signal 어댑터 계약 식별자는 `signals.adapter`입니다).

반면 Agent가 작업 중 동적으로 생성한 원시 콜백은 `/webhooks/v1/event-callbacks/wh_<token>` 경로를 사용합니다. 이 capability URL은 등록된 콜백 경로로의 수신 권한만 부여할 뿐 요청 본문(body)의 진위까지 증명하지는 않습니다. Signals는 토큰 원문 대신 다이제스트만 저장하며, 콜백 도착 시 엔드포인트 상태 판정과 `webhook.received` Signal(또는 바인딩된 automation run) 생성을 단일 트랜잭션으로 함께 커밋합니다. 전체 수명 주기와 Worker 브리지 계약은 [Webhook delegations](../webhook-delegations/)를 참조하세요.

## 전달

외부 채널로 응답을 보낼 때는 `Conversations.Delivery`가 먼저 영속 전송 의도를 저장한 뒤 어댑터의 `deliver` 콜백을 호출합니다. 실제 전송에 앞서 대상 provider의 대화 ID와 메시지 식별자를 해석하며, 전송이 확인된 각 Message와 외부 참조 레코드를 전달 결과와 함께 커밋합니다.

전달 상태는 `pending`, `sent`, `failed`, `expired`, `unknown` 다섯 가지로 관리됩니다. 전송 성공 여부를 확정할 수 없는 경우에는 중복 발송을 막기 위해 `unknown`으로 기록하고 자동 재전송하지 않으며, 운영자는 저장된 전송 의도와 진단 로그를 통해 실제 결과를 확인할 수 있습니다.

실행 및 장애 복구는 [Sessions](../sessions/), 초기 채널 연결은 [Quick start](../quickstart/), 세 개념 간의 역할 비교는 [Conversations, Signals, and Sessions](../conversations-signals-sessions/)를 참조하세요.
