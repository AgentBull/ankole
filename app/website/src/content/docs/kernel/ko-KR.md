---
title: Rust Kernel
description: 공유 네이티브 레이어 — 인가, RuntimeFabric 트랜스포트, AI 데이터 플레인 프리미티브의 단일 Rust 구현으로, Elixir 제어 플레인과 Bun worker 양쪽이 로드합니다.
section: Developer guide
order: 109
---

Ankole은 두 호스트 런타임, 즉 Elixir 제어 플레인과 Bun worker 위에서 실행되며, 몇 가지 동작은 양쪽에서 동일한 의미를 가져야 합니다. Rust Kernel이 바로 그러한 공유 네이티브 의미론이 존재하는 곳입니다. 이 페이지는 커널을 `app/kernel`의 실제 코드에 대응시킵니다.

먼저 핵심 속성을 밝힙니다: 커널은 두 바인딩 레이어를 통해 두 호스트가 로드하는 하나의 Rust 크레이트이며, Elixir 어댑터가 붙은 Bun 패키지나 Bun 어댑터가 붙은 Elixir NIF가 아닙니다. Rust가 저수준 의미론을 소유하고, 바인딩은 호스트 타입, 명명, 오류만 변환합니다. 두 런타임이 모두 신뢰해야 하는 동작은 바인딩보다 먼저 Rust로 여기에 속합니다.

## 두 호스트, 하나의 구현

크레이트는 상호 배타적 feature flag, 즉 Bun의 N-API용 `napi`와 Elixir의 Rustler용 `nif_dev`/`nif_prod` 아래 빌드되므로 동일한 소스가 두 개의 네이티브 애드온으로 컴파일됩니다. 전역 mimalloc 할당자가 명시적으로 설정되는데, 장기 실행 호스트가 로드하는 네이티브 애드온은 N-API 빌드와 NIF 빌드에서 할당자 동작을 동일하게 유지해야 하기 때문입니다.

바인딩 표면도 이를 반영합니다. Elixir 측에서 `Ankole.Kernel`은 Rustler 모듈이며, 네이티브 크레이트가 로드되기 전까지 해당 함수들은 `:erlang.nif_error(:nif_not_loaded)`로 폴백합니다 — `aead_encrypt`, `authz_authorize`, `runtime_fabric_router_start`, `universal_ai_client_open_nif`, `gen_uuid_v7`. Bun 측에서는 동일한 크레이트가 N-API 애드온으로 제공됩니다. 이름은 다르지만 동작은 같습니다.

## 공유 커널이 존재하는 이유

커널은 Bun 측과 Elixir 측이 동일한 네이티브 동작에 대해 서로 다른 의미를 발전시키는 것을 막기 위해 존재합니다. 커널이 없다면 인가 평가, fabric 프레이밍, AI 스트리밍이 두 구현 사이에서 어긋나고, 한쪽에서 내린 결정이 다른 쪽의 결정과 충돌할 수 있습니다. 신뢰할 동작을 바인딩보다 먼저 Rust에 한 번 배치하는 것이 두 런타임이 서로 정직함을 유지하는 방법입니다.

## 공유 표면

네 개의 모듈이 공유 의미론을 담당합니다:

- **`common/`** — 호스트 중립 프리미티브: AEAD 토큰 암호화·복호화, 키 파생, 해싱, 인코딩, UUID 헬퍼(`gen_uuid_v7` 포함, Elixir에는 `gen_uuid_v7/0`, Bun에는 `genUUIDv7()`로 노출), JWT 헬퍼, 전화번호 정규화. 두 런타임이 사용하는 작은 신뢰 연산입니다.
- **`authz/`** — 스냅샷 전용 인가 평가. `authorize`와 `authorize_all`은 `AuthzSnapshot`을 받아 `AuthzDecision`을 반환하며, CEL 조건 검증과 리소스 패턴 매칭도 여기에 있습니다. [Principal and AuthZ](../principal-authz/) 페이지가 제어 플레인이 스냅샷을 조립해 사용하도록 설명하는 결정적 평가기입니다.
- **`runtime_fabric/`** — `ankole.runtime_fabric.v1` protobuf 네임스페이스와 현재 wire protocol version 5: 레인, 지속성 클래스, 상관 규칙, 턴/컨트롤/진행/RPC 본문 의미론을 호스트 인코딩 protobuf 바이트로 검증합니다. 유일한 구조 선언은 `proto/envelope.proto`이며, 각 호스트는 여기서 자체 코덱을 파생합니다 — Rust의 `prost-build`, Elixir의 `protox`, TypeScript의 `protoc-gen-es`. 어떤 호스트도 구조를 새로 만들지 않습니다.
- **`universal_ai_client/`** — 준비된 AI 제공자 요청을 위한 feature-gated 네이티브 비동기 스트리밍 클라이언트: 업스트림 HTTP SSE/EventStream 및 WebSocket 트랜스포트, 제공자 응답 정규화, 다운스트림 SSE/WebSocket 청크 인코딩, 수요 크레딧, 취소. [AIGateway](../ai-gateway/)가 제공자와 통신할 때 사용하는 AI 데이터 플레인 프리미티브입니다.

## ZeroMQ 트랜스포트

`runtime_fabric/transport/` 안에서 커널은 인증, 구성, 라우터, 딜러, 프레이밍 모듈에 걸친 ZeroMQ ROUTER/DEALER 트랜스포트를 소유합니다. 실제 제어 플레인-워커 간 fabric이 실행되는 곳이 바로 여기입니다:

- **ZAP/PLAIN worker 인증** — worker는 fabric이 트래픽을 수용하기 전에 인증 키로 인증합니다.
- **필수 경로 전송** — 라우팅할 수 없는 전송은 조용히 버리지 않고 크게 실패합니다.
- **제한된 소켓 옵션** — 소켓은 무제한 대기열과 그로 인한 실패 모드를 방지하도록 구성됩니다.
- **원시 `ANKOLE_FILE/1` worker 파일 multipart 프레임** — 제어 플레인과 worker 사이의 파일 전송은 RPC 레인과 구분되는 원시 multipart 프레임으로 동일한 트랜스포트를 사용합니다.

트랜스포트는 의도적으로 Rust가 소유합니다. 프레임이 유실되거나 경로가 잘못된 전송이 발생하면 worker 응답이 잘못된 세션에 도착할 수 있는 유일한 곳이기 때문에, 신뢰할 동작이 여기에 있으며 두 호스트가 이를 호출합니다.

## 경계

커널과 두 런타임의 경계는 날카롭고, 각 경계는 공유 의미론 규칙의 결과입니다:

- **Actor Runtime과의 경계.** 제어 플레인은 actor 상태, 활성화 펜스, 영구 전사를 소유합니다. 커널은 결정적 인가 평가와 턴, 진행, RPC 봉투를 운반하는 트랜스포트를 소유합니다. Actor Runtime이 worker 응답을 펜스에 대조할 때, Principal을 인가한 결정 로직은 커널 코드이고 펜스 행 자체는 제어 플레인 상태입니다.
- **Agent Computer Worker와의 경계.** worker는 실시간 실행을 소유합니다. 커널은 worker 턴이 제공자에 도달하기 위해 사용하는 AI 스트리밍 클라이언트와 worker의 진행 및 파일 프레임을 다시 운반하는 트랜스포트를 소유합니다. worker는 스트리밍이나 프레이밍을 재구현하지 않으며, 대칭 방향에서 제어 플레인이 호출할 것과 동일한 네이티브 표면을 호출합니다.
- **AIGateway와의 경계.** 게이트웨이는 제공자 라우팅과 자격 증명을 소유합니다. 커널은 와이어 상의 바이트, 즉 HTTP 및 WebSocket 트랜스포트, 응답 정규화, 호출자가 최종적으로 받는 청크 인코딩을 소유합니다.

## 커널이 아닌 것

커널은 호스트별 동작을 위한 곳이 아닙니다. 한 런타임만 필요한 것 — Phoenix plug, Bun 도구, Console 라우트 — 은 해당 런타임에 남으며, 커널은 양쪽이 모두 신뢰해야 하는 것만 가져갑니다. 커널은 actor 상태나 제공자 자격 증명의 두 번째 권위자도 아닙니다. 그것들은 제어 플레인의 것입니다. 그리고 호스트가 대체할 수 있는 선택적 배관도 아닙니다. 핵심은 두 런타임이 그 사이 경계를 넘는 동작에 대해 하나의 의미를 공유하며, 그 의미가 Rust라는 것입니다.

## 다음 단계

- 커널이 실행하는 인가 평가에 대해서는 [Principal and AuthZ](../principal-authz/)를 읽으세요.
- 커널이 봉투를 운반하는 트랜스포트에 대해서는 [Actor Runtime](../actor-runtime/) 및 [Agent Computer Worker](../agent-computer-worker/) 페이지를 읽으세요.
- 커널이 제공하는 AI 스트리밍에 대해서는 [AIGateway API](../ai-gateway/)를 읽으세요.
