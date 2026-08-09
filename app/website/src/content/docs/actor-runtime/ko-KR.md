---
title: Actor Runtime
description: 장기 실행 session이 유지되고, 깨어나고, 실패하고, 복구되는 방식 — actor key, OTP 실패 도메인, activation 펜스, RuntimeFabric 라이브 경로.
section: Developer guide
order: 103
---

Actor Runtime은 session을 요청이 아니라 오래 살아 있는 존재로 만드는 것입니다. 시그널이 도착하면 session이 깨어나고, worker가 한 turn을 실행하고, turn이 커밋되거나 실패한 다음 session은 다시 대기 상태로 돌아갑니다. 그동안 프로세스가 죽어도 PostgreSQL의 지속 가능한 기록(transcript)은 정확하게 유지됩니다. 이 페이지는 그 수명 주기를 `Ankole.SignalsGateway.ActorRuntime`의 실제 코드에 대응시켜 설명합니다.

중심 설계 선택을 먼저 밝히자면, 정확성은 프로세스가 아니라 데이터베이스에 있습니다. 라이브 프로세스는 추론과 처리량을 위한 최적화입니다. 늦게 도착하거나 session을 벗어난 응답이 상태를 손상시키지 못하게 막는 펜스는 행에 대한 단순한 동등성 검사입니다. 모든 프로세스를 잃어도 durable transcript는 그대로 유지됩니다.

## Actor key

오래 실행되는 작업의 단위는 하나의 actor key, 즉 `{agent_uid, session_id}`입니다. 하나의 agent는 여러 session을 가질 수 있고, 하나의 session은 정확히 하나의 agent에 속합니다. 이어지는 모든 것 — serial controller, activation, delivery 행, worker 할당 — 은 이 쌍을 키로 사용합니다.

session은 컨텍스트, workspace 상태, 스티어링(steering), 취소, 복구가 만나는 곳입니다. 요청도 큐 작업도 아닙니다. 몇 시간이나 며칠에 걸쳐 깨어나고, 기다리고, 재개할 수 있는 상태 저장형 작업 정체성(stateful work identity)입니다.

## 두 계층, 두 가지 보장

런타임은 두 계층을 의도적으로 분리해 둡니다. 서로 다른 보장이 필요하기 때문입니다:

- **AI-agent state** — conversations, turn, 메시지 — 는 *지속 가능한 진실(durable truth)*입니다. AIGateway가 소유한 테이블에 있으며 어떤 크래시에도 견딥니다.
- **Actor-runtime projections** — activation, delivery, 할당 — 은 더 저렴한 *런타임 힌트*입니다. 진행 중인 작업을 펜싱하며 durable 계층에서 재구성할 수 있습니다.

이 역할 분담 때문에 worker를 교체할 수 있습니다. worker가 turn을 실행하고, 펜스 행이 그 turn의 응답이 여전히 유효한지 결정합니다. 크래시했거나 대체된 worker의 늦은 응답은 펜스를 통과하지 못하고 무해하게 폐기됩니다.

## Serial controller, actor당 하나

각 actor key에 대해 `SessionController` GenServer가 dynamic supervisor에 의해 필요할 때 생성되고 `ActorDirectory`에서 고유한 이름으로 등록됩니다. 하나의 controller가 하나의 actor key에 대한 스케줄링을 직렬화하므로, 일반적인 경로에서 두 turn이 같은 session을 두고 경쟁하는 일이 없습니다.

이것은 정확성 경계가 아니라 추론을 위한 최적화입니다. controller가 크래시하고 재시작해도 actor 상태는 잃지 않습니다. 처음부터 진짜 방어선은 durable 데이터베이스 펜스였습니다. controller 시작은 멱등적(idempotent)입니다. 같은 actor에 대한 두 개의 동시 깨우기가 시작을 두고 경쟁하며, 진 사람은 `{:already_started, pid}`를 받고, 두 호출자 모두 그것을 성공으로 취급하고 라이브 pid를 반환합니다. 호출자는 누가 actor를 시작하는지 조정하지 않습니다.

## OTP 실패 도메인

감독 트리(supervision tree)는 하나의 실패가 모든 사람의 실패가 되지 않도록 구성됩니다:

- **런타임 supervisor**는 `:one_for_one`으로 실행됩니다. 그 자식들 — transport, naming, actor별 controller — 은 독립적인 관심사입니다. 하나의 자식이 크래시해도 다른 자식의 상태는 무효화되지 않습니다. durable 정확성이 이 프로세스가 아니라 PostgreSQL에 살아 있기 때문입니다.
- **세션 supervisor**는 `DynamicSupervisor`이며 역시 `:one_for_one`입니다. 각 `SessionController`는 자체 실패 단위입니다. 하나의 controller가 크래시하거나 하나의 actor가 오작동해도 다른 actor의 controller에는 손대지 않고 격리되어 재시작됩니다.

실질적인 효과는 하나의 agent가 멈추거나, 타임아웃되거나, 크래시해도 deployment 전체의 장애가 되는 대신 자체 분기에서 격리되거나 재시작된다는 것입니다. actor는 정적 자식 목록 없이 런타임에 나타났다 사라집니다.

## Activation 펜스

session이 turn을 실행하려고 깨어나면 런타임은 `ActorSessionActivation`을 생성합니다. 그것은 해당 actor session에 대한 라이브 리스(lease) projection입니다. activation은 해당 actor key의 단조 카운터인 `actor_epoch`, `lease_id`와 `lease_expires_at`, `current_actor_event_id`, 그리고 라이브 turn을 제자리에서 스티어링할 때마다 올라가는 `revision`을 가집니다.

activation 상태는 `starting → active → draining`으로 이동하며, `stopped`와 `failed`는 종료 상태입니다. 부분 고유 인덱스(partial unique index)로 인해 actor key당 한 번에 하나의 라이브 activation만 존재할 수 있습니다. 리스 실패 후의 새 activation은 더 높은 epoch를 가지며, 그 epoch는 단순 부등식으로 이전 activation의 늦은 응답이 실패하게 만드는 값싼 펜스입니다.

모든 worker 응답은 필드가 데이터베이스 행과 동등성으로 검사되는 `turn_ref`를 에코해야 합니다. 이것은 activation, actor epoch, 그리고 turn을 명명하는 delivery 행의 삼중 펜스입니다. 이로써 늦거나 session을 벗어난 worker 응답이 durable transcript를 손상시키는 대신 무해하게 실패하며, 이를 위해 인메모리 session 상태가 필요하지 않습니다. 의도적으로 남겨 둔 유일한 약점 — 재시작으로 런타임 펜스를 잃은 채 시작된 durable turn — 은 해당 메시지 행을 위한 정확한 런타임 이벤트 핸들러가 복구합니다.

## Delivery 행과 라이브 경로

큐에 있는 actor event와 worker 수락 사이에 `ActorEventDelivery` 행이 있습니다. 한 번의 worker 실행은 정확히 하나의 `actor_event_id`를 처리합니다. 펜스 5중주 — `activation_uid`, `actor_epoch`, `actor_event_id_fence`, `revision`, actor key — 는 activation에서 각 delivery 행으로 복사됩니다. 따라서 오래된 응답 검사는 인메모리 session 상태 없이 데이터베이스에 대한 단순 동등성으로 수행됩니다.

delivery 상태는 `created → sent → accepted`로 이동하며, `send_failed`와 `superseded`는 종료 상태로 무시할 수 있습니다. control plane에서 worker로 가는 라이브 경로는 RuntimeFabric — ZeroMQ 기반 라이브 transport — 을 통해 이루어지며, 디코딩된 트래픽은 소켓을 소유한 broker 위에서 라우팅됩니다. worker 수명 주기 이벤트는 직렬화되고, actor event는 해당 session별 controller로 전달되며, 독립적인 worker RPC 요청은 task supervisor 아래에서 실행됩니다. transport broker 프로세스에서는 도메인 콜백이 실행되지 않습니다.

## 리스 만료와 복구

activation은 `now < lease_expires_at`인 동안에만 유효합니다. watchdog가 만료된 in-flight activation을 실패 처리하여 해당 actor event를 재시도할 수 있게 합니다. 보통은 현재 이벤트가 nil인 웜(warm) activation을 중지합니다. turn에 오류가 있으면 이벤트는 재시도를 위해 `open` 상태로 유지되며, 반복된 worker 실패가 오버플로우 임계값을 넘으면 `dead_letter`로 이동합니다. 재시도는 5초에서 120초 사이로 제한된 지수 백오프(exponential backoff)를 사용하며, 실패한 각 시도의 epoch가 올라가므로 그 늦은 응답이 이후의 재시도와 일치할 수 없습니다.

이것이 복구 이야기의 한 문장 요약입니다. durable 이벤트는 `open`으로 유지되고, 런타임 projection은 재구성되며, 더 높은 epoch를 가진 새로운 activation이 이벤트를 다시 집어 듭니다. actor는 자신의 위치를 잃지 않습니다. 그 위치는 애초에 프로세스 안에 없었기 때문입니다.

## Actor Runtime이 아닌 것

Actor Runtime은 durable 사실을 저장하는 곳이 아닙니다. 그것들은 AI-agent state 계층과 PostgreSQL에 있습니다. worker도 아닙니다. worker는 turn을 실행하는 교체 가능한 Agent Computer Worker 프로세스입니다. 그리고 진입 표면도 아닙니다. 시그널은 [SignalsGateway](../signals-gateway/)를 통해 도착하며, 시그널이 actor event가 되면 그것을 깨우고 실행하는 것이 이 런타임의 작업입니다. 경계는 durable 큐 이벤트를 펜싱되고 복구 가능한 라이브 turn으로 변환하고, 다시 durable 커밋으로 변환하는 것입니다.

## 다음 단계

- 시그널이 actor event가 되는 방식에 대해서는 [SignalsGateway](../signals-gateway/) 문서를 읽으세요.
- worker가 깨어난 후 실행하는 model turn에 대해서는 [AIGateway API](../ai-gateway/) 문서를 읽으세요.
- 전체 시스템 관점에 대해서는 [architecture overview](../architecture/) 문서를 읽으세요.
