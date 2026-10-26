---
title: 대화, 신호, 실행 세션
description: Ankole의 설계 선택과 비용 및 소스를 확인한 deepseek-harness, pi durable, qm 비교.
section: Developer guide
order: 100.5
---

Ankole는 조직을 위해 Agent를 실행합니다. 작업은 발언, 시간, 외부 이벤트, 작업 완료에서 시작됩니다. 책임을 지는 Principal과 프로세스 재시작 후 복구가 필요합니다.

세 가지 사실은 서로 다른 컴포넌트가 소유합니다. **대화**는 참여자의 발언을 저장하고 **신호**는 작업을 시작하며 **실행 세션**은 작업을 실행합니다. AIGateway는 모델 상태를 저장하고 Delivery는 외부 전송의 의도와 결과를 기록합니다.

## 네 가지 설계 선택

### 발언과 작업을 별도로 기록합니다

대화 기록은 참여자에게 보이는 발언을 저장하고 작업 로그는 모델 호출과 도구 결과를 저장합니다. 대화의 각 Agent는 자신의 실행 세션과 모델 상태를 가지며 모든 참여자가 그 작업을 볼 수 있습니다. 실행 세션은 여러 대화를 넘나들지 않습니다.

대화형 턴과 사람이 트리거한 턴(사람의 발언으로 깨어난 `may_intervene` 개입 턴을 포함하며, Agent 발언은 다른 Agent를 절대 깨우지 않음)은 **`Human ∩ Agent` 권한 교집합**(`%Ankole.AuthZ.Actor{principal: agent, interactive_principal: human}`)으로 실행됩니다. 대화형 사람이 없는 자율 비인간 턴(`cron`, `webhook`, 백그라운드 서비스 트리거)은 Agent 자신의 권한으로 실행됩니다. 공개 범위는 대화를 따르고, 실행 권한은 해당 턴의 `AuthZ.Actor`를 따릅니다.

### 모든 자극을 Signals에서 접수합니다

발언, 시간, 외부 이벤트, 작업 완료는 동일한 접수 owner를 사용합니다. 영구 저장, 중복 제거, 귀속과 권한, 대상 해석을 수행합니다.

signal은 실행 세션을 직접 지정할 수 있습니다. 그렇지 않으면 참여 관계나 Signal Routing Rule이 대상을 선택합니다. 대화 호스트 어댑터는 발언을 관찰하고 응답을 전달합니다. 이벤트 소스 어댑터는 signal만 생성합니다. 새 출처에 별도의 접수 메커니즘이 필요하지 않습니다.

### 예약 작업에 별도 실행 세션을 사용합니다

cron 규칙은 안정적인 `cron:<schedule_id>` 실행 세션을 사용하며 백그라운드 작업도 자체 실행 세션을 가집니다. 둘 다 대화에 결과를 발언할 수 있습니다. 대화의 다음 턴은 해당 발언을 읽고 다른 실행 세션의 모델 호출과 도구 결과는 가져오지 않습니다.

### 모델 상태의 owner를 하나로 유지합니다

AIGateway는 내부 Agent와 외부 클라이언트에 상태가 있는 Responses 호출과 hosted tools를 제공합니다. 런타임은 입력, 도구, 이어 가기, 압축을 결정합니다. 플랫폼은 모델 상태를 저장하고 해당 메커니즘을 실행합니다.

AIGateway conversation은 모델 상태를 의미하며 참여자의 공유 대화와는 별개입니다. Agent 기록을 런타임으로 옮기면 두 번째 모델 상태 구현이 생깁니다.

## 소스를 확인한 비교

아래 표는 **2026-10-14**에 다시 확인한 저장소 스냅샷입니다. 링크는 확인한 commit으로 고정되어 있습니다.

| 프로젝트 | 확인 commit |
| --- | --- |
| deepseek-harness | [`571902028a75`](https://github.com/deepseek-ai/deepseek-harness/commit/571902028a75c64c1d767f4ae5fd099485f0ddf0) |
| pi (`packages/durable`) | [`910149912ca2`](https://github.com/earendil-works/pi/commit/910149912ca29d7ae4eaa945bb2b53eb84c68264) |
| qm | [`cf0e475f50c0`](https://github.com/yc-software/qm/commit/cf0e475f50c061e0ae00701999fb14a9272bba7d) |

| 항목 | deepseek-harness | pi durable | qm | Ankole |
| --- | --- | --- | --- | --- |
| 기록 모델 | 추가 전용 `SessionEvent` 로그에서 모델 기록을 파생합니다. [소스][D-session] | 불변 entries와 task 및 문서 업데이트를 원자적으로 커밋합니다. [명세][P-spec] | PostgreSQL `session_entries`. Slack과 Web UI는 같은 기록을 표시합니다. [저장][Q-session], [설계][Q-spec] | 대화 발언과 모델 작업 로그를 분리합니다 |
| 공유 컨텍스트 | Agent / Session 기록과 플러그인이 정의한 투영입니다. [소스][D-session] | 호스트가 메시지 유형과 앱 정책을 정의합니다. [소스][P-guide] | 기록은 턴의 모든 수신자에게 보여도 되는 내용이어야 합니다. [소스][Q-audience] | 대화의 Agent마다 실행 세션. 수신자는 공유하고 모델 상태는 독립적이며 권한은 턴별로 적용 |
| 입력 | Agent 입력, 예약 follow-up, 별도 webhook 런타임입니다. [예약][D-schedule], [webhook][D-webhook] | Submission과 영구 inbox입니다. [소스][P-guide] | cron, webhook, loop의 메커니즘이 다르며 SPEC은 별도 loop 구현을 비판합니다. [소스][Q-spec] | 모든 출처가 하나의 영구 signal 접수 계약을 사용합니다 |
| 시간과 외부 트리거 | 영구 알림은 원래 Session으로 돌아갑니다. webhook은 큐, 재시도, 충돌 후 재생, 내장 중복 제거가 없습니다. [예약][D-schedule], [webhook][D-webhook] | 패키지는 submission / task API, 외부 트리거는 호스트가 제공합니다. [소스][P-guide] | cron 실행마다 `cron:<id>:fire:<hash>`를 사용합니다. [소스][Q-cron] | 안정적인 cron 실행 세션. 외부 signal을 영구 접수하고 대상 대화에 결과 전달 |
| 외부 전달 | 예약 전달은 원래 Session으로 제한됩니다. [소스][D-schedule] | 외부 채널은 호스트 앱이 제공합니다. [소스][P-guide] | 영구 전달 기록과 만료 처리가 있습니다. [소스][Q-delivery] | 대화 호스트 어댑터. 제한된 재시도와 실패, 만료, 결과 불명확 상태 |
| 저장과 동시성 | 로컬 JSONL. Session마다 작성자 하나를 OS 잠금으로 보호합니다. [소스][D-store] | Memory, SQLite, JSONL, Durable Object. 한 프로세스가 소유하며 프로세스 간 잠금은 없습니다. [소스][P-guide] | PostgreSQL. 현재 코드는 `session_entries`만 읽고 씁니다. [소스][Q-session] | PostgreSQL이 기준. 테넌트 격리. 실행을 시작할 때마다 권한 확인 |
| 모델 컨텍스트 | Session 로그에서 파생합니다. [소스][D-session] | 커밋된 entries에서 구성합니다. [명세][P-spec] | 수신자 범위로 필터링한 기록에서 구성합니다. [소스][Q-audience] | AIGateway가 저장하고 이어 가며 런타임이 입력을 결정합니다 |

qm의 SPEC은 설계 용어로 “tape”를 계속 쓰지만 `session_entries` 전환과 이후의 기존 테이블 정리를 기록합니다. 이 비교는 현재 코드를 사용하며 예전의 이중 쓰기 설계를 현황으로 취급하지 않습니다. [소스][Q-spec]

## 비용과 수용한 제한

- **개념과 코드가 늘어납니다.** 대화, signal, 실행 세션, 전달, 모델 상태에 각각 owner가 필요합니다.
- **두 기록을 확인합니다.** 진단에는 대화 발언과 실행 세션의 작업 로그가 함께 필요할 수 있습니다.
- **공유 작업은 그룹에 결과를 공개합니다.** 해당 턴의 권한으로 얻은 데이터는 대화의 공유 컨텍스트에 들어갑니다. 도구 호출 권한(`agent:<uid>:tool:<tool_name>` 리소스의 `invoke` 액션 및 `context.request.args`)과 Pod 작업은 현재 턴의 `AuthZ.Actor`를 기준으로 평가됩니다. 반면 qm은 수신자 범위에 따라 기록을 필터링합니다. [qm 소스][Q-audience]
- **배포가 무겁습니다.** PostgreSQL 트랜잭션과 컨트롤 플레인은 로컬 파일 harness보다 지연과 운영 작업을 늘립니다.
- **중간 텍스트는 영구 저장하지 않습니다.** 충돌하면 미완성 텍스트를 잃을 수 있습니다. 복구 시 모델 호출은 반복될 수 있고 기록된 도구 결과는 재사용합니다. 결과가 불명확한 동작은 무조건 반복하지 않습니다. 외부 부수 효과에 exactly-once 보장은 없습니다. pi durable은 저장 커밋 후에만 진행 상태를 공개합니다. [소스][P-guide]
- **플랫폼 제약이 있습니다.** 상태가 있는 요청은 저장 항목을 손실 없이 재생할 수 있는 wire가 필요합니다.
- **모든 출처에 대한 단일 접수 계약.** 모든 생산자와 어댑터가 동일한 Signals 접수 계약을 준수해야 합니다.
- **cron 기록이 쌓입니다.** 안정적인 실행 세션은 컨텍스트를 유지하며 압축이 필요합니다. qm은 실행마다 새 실행 세션을 시작합니다. [소스][Q-cron]

## 다른 접근이 더 적합한 경우

- 개인 개발자가 로컬에서 하나의 Agent와 작업한다면 deepseek-harness나 pi는 배포 작업이 더 적습니다.
- 재개 가능한 Agent loop를 앱에 포함한다면 pi durable은 더 작은 런타임 경계를 제공합니다.
- Slack 중심이며 모델 관점의 기록을 기준으로 하는 팀 도우미라면 qm의 구조가 더 직접적입니다.

발언에서 작업으로 이어지는 흐름은 [아키텍처](../architecture/), 표준 용어는 [빠른 시작](../quickstart/#terminology)을 참조하십시오.

[D-session]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/core/session/README.md
[D-store]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/session/session-persistence-jsonl/README.md
[D-schedule]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/schedule/schedule/README.md
[D-webhook]: https://github.com/deepseek-ai/deepseek-harness/blob/571902028a75c64c1d767f4ae5fd099485f0ddf0/packages/experimental/webhook/README.md
[P-guide]: https://github.com/earendil-works/pi/blob/910149912ca29d7ae4eaa945bb2b53eb84c68264/packages/durable/README.md
[P-spec]: https://github.com/earendil-works/pi/blob/910149912ca29d7ae4eaa945bb2b53eb84c68264/packages/durable/docs/spec.md
[Q-session]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/sessions/postgres-session-store.ts
[Q-audience]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/resolution/context-filter.ts
[Q-cron]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/cron/scheduler.ts
[Q-delivery]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/src/delivery/delivery-store.ts
[Q-spec]: https://github.com/yc-software/qm/blob/cf0e475f50c061e0ae00701999fb14a9272bba7d/docs/SPEC.md
