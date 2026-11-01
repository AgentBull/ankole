---
title: 대화, 신호, 실행 세션
description: Ankole의 설계 선택과 그에 따른 비용, 그리고 소스 코드를 직접 확인해 비교한 deepseek-harness, pi durable, qm 아키텍처 대조.
section: Developer guide
order: 100.5
---

Ankole은 조직을 위한 Agent를 실행합니다. Agent의 작업은 대화 발언, 예약 시각, 외부 이벤트, 또는 선행 작업 완료를 계기로 시작되며, 모든 실행에는 책임을 지는 Principal이 지정되고 프로세스가 재시작되더라도 안전하게 복구할 수 있어야 합니다.

이를 위해 세 가지 핵심 도메인 사실을 서로 다른 컴포넌트가 나누어 소유합니다. **대화(Conversation)**는 참여자의 발언을 기록하고, **신호(Signal)**는 작업을 촉발하며, **실행 세션(Execution Session)**은 실제 작업을 수행합니다. 여기에 더해 AIGateway가 모델 상태를 보관하고, Delivery가 외부 채널 전송 의도와 결과를 기록합니다.

## 네 가지 설계 선택

### 발언과 작업을 별도로 기록합니다

대화 기록에는 참여자에게 표시되는 발언만 저장하고, 작업 로그에는 모델 호출과 도구 실행 결과를 저장합니다. 대화에 참여하는 각 Agent는 고유한 실행 세션과 모델 상태를 유지하며, 대화 참여자는 모두 그 작업 내역을 열람할 수 있습니다. 하나의 실행 세션이 여러 대화를 넘나들지는 않습니다.

각 Agent는 대화마다 독립된 Session을 가지며 출력은 대화 참여자에게 공유됩니다. 대화형 턴, 사람의 메시지로 시작하는 `may_intervene`, 예약 작업과 서비스 트리거 모두 실행 Agent의 권한으로 리소스에 접근합니다. Agent 메시지는 다른 Agent를 깨우지 않습니다. 사람의 재직 상태와 지시 버전은 위임의 유효성을 계속 검증하지만, 사람과 Agent의 리소스 권한을 교차 적용하지 않습니다.

### 모든 자극을 Signals에서 접수합니다

대화 발언, 예약 시각 도달, 외부 이벤트, 백그라운드 작업 완료는 모두 동일한 접수 경로인 Signals를 거칩니다. Signals는 자극의 영속 저장, 중복 제거, 주체 귀속 및 권한 검증, 대상 해석을 일괄 담당합니다.

Signal에 대상 실행 세션을 직접 지정할 수도 있고, 지정하지 않으면 대화 참여 관계나 Signal Routing Rule에 따라 대상이 결정됩니다. 대화 호스트 어댑터는 참여자의 발언을 감지하고 Agent의 응답을 외부 채널로 전달하는 반면, 이벤트 소스 어댑터는 Signal만 생성합니다. 따라서 새로운 이벤트 출처를 추가하더라도 별도의 접수 메커니즘을 새로 만들 필요가 없습니다.

### 예약 작업에 별도 실행 세션을 사용합니다

cron 규칙은 고정된 `cron:<schedule_id>` 실행 세션을 사용하며, 백그라운드 작업 역시 자체 실행 세션을 가집니다. 두 경로 모두 결과를 대화에 발언으로 남길 수 있습니다. 이후 대화에서 이어지는 턴은 그 발언 텍스트만 읽을 뿐, 다른 실행 세션 내부의 모델 호출 이력이나 도구 실행 결과를 끌어오지 않습니다.

### 모델 상태의 owner를 하나로 유지합니다

AIGateway는 내부 Agent와 외부 클라이언트 모두에 상태 유지형(stateful) Responses 호출과 호스팅 도구를 제공합니다. 런타임은 어떤 입력과 도구를 넘길지, 실행을 어떻게 이어 가고 언제 컨텍스트를 압축할지를 결정하며, 플랫폼(AIGateway)은 모델 상태를 저장하고 실제 메커니즘을 수행합니다.

여기서 AIGateway의 conversation은 모델 컨텍스트 상태를 뜻하며, 참여자들이 함께 보는 공유 대화와는 별개의 개념입니다. 만약 Agent 실행 이력을 런타임 쪽으로 옮기면 모델 상태를 관리하는 두 번째 구현체가 중복으로 생기게 됩니다.

## 소스를 확인한 비교

아래 표는 **2026-10-14**에 검증한 각 저장소 스냅샷을 기준으로 하며, 모든 링크는 확인한 커밋에 고정되어 있습니다.

| 프로젝트 | 확인 commit |
| --- | --- |
| deepseek-harness | [`571902028a75`](https://github.com/deepseek-ai/deepseek-harness/commit/571902028a75c64c1d767f4ae5fd099485f0ddf0) |
| pi (`packages/durable`) | [`910149912ca2`](https://github.com/earendil-works/pi/commit/910149912ca29d7ae4eaa945bb2b53eb84c68264) |
| qm | [`cf0e475f50c0`](https://github.com/yc-software/qm/commit/cf0e475f50c061e0ae00701999fb14a9272bba7d) |

| 항목 | deepseek-harness | pi durable | qm | Ankole |
| --- | --- | --- | --- | --- |
| 기록 모델 | 추가 전용 `SessionEvent` 로그에서 모델 기록을 파생합니다. [소스][D-session] | 불변 entries와 task 및 문서 업데이트를 원자적으로 커밋합니다. [명세][P-spec] | PostgreSQL `session_entries`. Slack과 Web UI가 동일한 기록을 표시합니다. [저장][Q-session], [설계][Q-spec] | 대화 발언과 모델 작업 로그를 분리합니다 |
| 공유 컨텍스트 | Agent / Session 기록과 플러그인이 정의한 투영을 사용합니다. [소스][D-session] | 호스트가 메시지 유형과 앱 정책을 정의합니다. [소스][P-guide] | 해당 턴의 모든 수신자에게 공개 가능한 기록만 담습니다. [소스][Q-audience] | 대화 내 Agent별 실행 세션 분리. 수신자는 공유하되 모델 상태는 독립 유지하며 턴별로 권한 적용 |
| 입력 | Agent 입력, 예약 follow-up, 별도 webhook 런타임으로 나뉩니다. [예약][D-schedule], [webhook][D-webhook] | Submission과 영구 inbox를 사용합니다. [소스][P-guide] | cron, webhook, loop 메커니즘이 분리되어 있으며 SPEC에서도 별도 loop 구현의 한계를 지적합니다. [소스][Q-spec] | 모든 출처가 단일 영속 Signal 접수 계약을 사용합니다 |
| 시간과 외부 트리거 | 영속 알림이 원래 Session으로 돌아갑니다. webhook에는 큐, 재시도, 장애 후 재생, 내장 중복 제거가 없습니다. [예약][D-schedule], [webhook][D-webhook] | 패키지가 submission / task API를 제공하고 외부 트리거는 호스트가 연결합니다. [소스][P-guide] | cron 실행마다 `cron:<id>:fire:<hash>` 세션을 새로 생성합니다. [소스][Q-cron] | 고정된 cron 실행 세션 유지. 외부 Signal을 영속 접수하고 대상 대화에 결과 전달 |
| 외부 전달 | 예약 전달 대상이 원래 Session으로 제한됩니다. [소스][D-schedule] | 외부 채널 연동은 호스트 앱이 담당합니다. [소스][P-guide] | 영속 전달 기록과 만료 처리를 지원합니다. [소스][Q-delivery] | 대화 호스트 어댑터 제공. 횟수 제한 재시도와 실패·만료·결과 불명확 상태 추적 |
| 저장과 동시성 | 로컬 JSONL 사용. OS 파일 잠금으로 Session당 단일 작성자를 보장합니다. [소스][D-store] | Memory, SQLite, JSONL, Durable Object 지원. 단일 프로세스 소유를 가정하며 프로세스 간 잠금은 없습니다. [소스][P-guide] | PostgreSQL 사용. 확인 시점 코드는 `session_entries`만 읽고 씁니다. [소스][Q-session] | PostgreSQL 단일 기준. 테넌트 격리 및 실행 시작 시점마다 권한 검증 |
| 모델 컨텍스트 | Session 로그에서 파생합니다. [소스][D-session] | 커밋된 entries에서 재구성합니다. [명세][P-spec] | 수신자 범위에 맞춰 필터링한 기록에서 구성합니다. [소스][Q-audience] | AIGateway가 저장·연속성을 담당하고 런타임이 입력 구성을 결정합니다 |

참고로 qm의 SPEC 문서는 개념 설명에 “tape”라는 용어를 사용하지만, 실제 데이터 모델로는 `session_entries` 단일 테이블 전환과 정리를 기록하고 있습니다. 위 표는 체크아웃한 커밋의 실제 구현 코드를 기준으로 비교했으며 이중 쓰기 구조를 전제하지 않습니다. [소스][Q-spec]

## 비용과 수용한 제한

- **개념과 코드 규모가 커집니다.** 대화, Signal, 실행 세션, 외부 전달, 모델 상태마다 명확한 소유 컴포넌트와 경계가 필요합니다.
- **문제 진단 시 두 기록을 함께 봐야 합니다.** 원인을 추적할 때 대화 발언 기록과 실행 세션의 작업 로그를 나란히 대조해야 할 수 있습니다.
- **공유 대화의 응답은 참여자에게 공개됩니다.** 실행 Agent가 조회해 응답에 포함한 정보는 대화의 공유 컨텍스트에 들어갑니다. 사용 가능한 도구는 도구 카탈로그가 결정하며, 도구 내부 리소스 작업은 Agent 권한으로 인가합니다. 사람의 지시 유효성은 별도로 확인합니다. qm은 수신자에 따라 기록을 필터링합니다. [qm 소스][Q-audience]
- **배포 구조가 무겁습니다.** PostgreSQL 트랜잭션과 컨트롤 플레인을 거치므로 로컬 파일 기반 하네스보다 지연 시간과 운영 부담이 늘어납니다.
- **생성 도중의 중간 텍스트는 영속 저장하지 않습니다.** 실행 중 프로세스가 비정상 종료되면 아직 완성되지 않은 응답 텍스트는 유실될 수 있습니다. 복구 시 모델 호출은 다시 실행될 수 있는 반면, 이미 기록된 도구 실행 결과는 재사용하며 결과가 불명확한 외부 동작은 임의로 재실행하지 않습니다. 외부 부수 효과에 대한 정확히 한 번(exactly-once) 실행은 보장하지 않습니다. 참고로 pi durable은 저장소 커밋이 끝난 뒤에만 진행 상태를 외부에 노출합니다. [소스][P-guide]
- **전송 계층의 제약이 따릅니다.** 상태 유지형 요청을 이어 가려면 저장된 항목을 손실 없이 다시 전달할 수 있는 전송 형식(wire format)이 필요합니다.
- **단일 접수 계약을 지켜야 합니다.** 모든 이벤트 생산자와 어댑터가 동일한 Signals 접수 계약을 준수해야 합니다.
- **고정된 cron 세션에는 이력이 누적됩니다.** 안정적인 실행 세션을 재사용하므로 컨텍스트가 계속 쌓이며 주기적인 압축이 필요합니다. 반면 qm은 매 실행마다 새 세션을 시작합니다. [소스][Q-cron]

## 다른 접근이 더 적합한 경우

- 개인 개발자가 로컬 환경에서 단일 Agent와 작업한다면 deepseek-harness나 pi 쪽이 배포 부담이 적습니다.
- 애플리케이션 내부에 재개 가능한 Agent 루프만 내장하려는 경우라면 pi durable이 더 가벼운 런타임 경계를 제공합니다.
- Slack을 중심으로 모델 관점의 단일 기록을 바로 활용하는 팀 어시스턴트를 원한다면 qm의 구조가 더 단순하고 직접적입니다.

발언에서 실제 작업 실행까지 이어지는 전체 흐름은 [아키텍처](../architecture/)를, 핵심 표준 용어는 [빠른 시작](../quickstart/#terminology)을 참조하세요.

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
