---
title: Webhook 위임
description: Agent 또는 결정적 스크립트가 폴링 없이 저빈도 외부 이벤트를 기다릴 수 있게 합니다.
section: User guide
order: 23
---

webhook 위임을 사용하면 Agent가 Ankole 밖에서 일어나는 작업을 기다릴 수 있습니다. 외부 시스템이 이벤트를 감지하고 수명이 짧은 Ankole 콜백 URL을 호출합니다. 기본적으로 Ankole은 수령(receipt)을 저장하고, 위임을 만든 session을 깨우고, Agent가 검증한 결과를 원래 chat 라우트를 통해 반환합니다. 결정적 스크립트가 먼저 수령을 소비해야 한다면 엔드포인트가 대신 automation job을 지정할 수 있습니다.

콜백은 wake-up 능력입니다. 요청 본문이 진실이라는 증명은 아닙니다. Agent는 사실을 보고하거나 승인된 변경을 하기 전에 현재 외부 객체를 읽습니다.

GitHub repository webhook이 첫 번째로 지원되는 시나리오입니다. EventBridge와 Flink는 구현되지 않았습니다.

## 언제 사용하나

외부 시스템이 잘 필터링할 수 있는 저빈도 이벤트에 webhook 위임을 사용하세요:

- GitHub issue, comment, pull request, 또는 workflow run;
- 같은 대화를 한 번 깨워야 하는 일회성 이벤트;
- 반복 처리가 안전한 상시 감시(standing watch).

고빈도 스트림, 폴링 루프, 또는 범용 이벤트 버스에는 사용하지 마세요. 감지는 외부 시스템에 맡겨 두고, 판단, memory, 답변은 Ankole에 두세요.

요청에서 결과, 권한(authority), 이벤트 집합, 종료 시간을 설명하세요. 예를 들어:

> 금요일까지 `owner/repository`의 pull request를 지켜보세요. 필수 체크가 실패하면 알려 주세요. 보고하기 전에 현재 pull request와 check 상태를 검증하세요. 요청하지 않는 한 코드를 변경하지 마세요.

GitHub Skill이 설정과 복구 세부 사항을 소유합니다.

## 요구 사항

Agent가 GitHub 위임을 만들기 전에:

1. 공개 HTTPS 호스트를 Ankole control plane으로 라우팅하세요. 호스트는 `/webhooks/v1/event-callbacks/*`를 보존해야 합니다.
2. Agent에 대해 공개 **GitHub** Agent Plugin과 필요한 Skill을 활성화하세요. GitHub는 기본적으로 비활성화되어 있습니다.
3. Agent의 WorkerEnv에 `GITHUB_TOKEN`을 추가하세요. token은 대상 repository에 대한 읽기 권한과 repository webhook에 대한 쓰기 권한이 필요합니다.
4. capability 또는 WorkerEnv 설정을 변경한 후 새 Agent 턴을 시작하세요.

엔드포인트 명령은 활성 턴 동안 Main Agent에게만 사용할 수 있습니다. Background Agent Job에는 턴 로컬 webhook 연결이 없습니다.

## 수명 주기

하나의 활성 GitHub 위임은 하나의 repository, 하나의 정확한 이벤트 집합, 하나의 만료 시각, 하나의 Ankole 엔드포인트, 하나의 GitHub hook, 하나의 조정(reconciliation) checkback을 가집니다.

1. Agent가 현재 대화용 엔드포인트를 만듭니다.
2. GitHub hook을 만들기 전에 지속적인 checkback을 만듭니다. 이것이 정리와 조정 의무를 기록합니다.
3. 콜백 URL로 repository hook을 만듭니다. GitHub가 `ping`을 보냅니다.
4. GitHub delivery 로그를 읽고 `ping`이 성공했는지 확인합니다.
5. 일치하는 delivery가 도착하면 Ankole은 성공을 반환하기 전에 엔드포인트 결정과 `webhook.received` ActorEvent 또는 바인딩된 automation job 실행을 하나의 PostgreSQL 트랜잭션으로 커밋합니다.
6. 직접 경로에서 깨어난 Agent는 수령을 신뢰할 수 없는 입력으로 취급합니다. 바인딩된 automation job은 이벤트를 emit하기 전에 같은 규칙을 적용해야 합니다.
7. 조정은 hook, 이벤트 집합, 실패한 delivery, 현재 GitHub 객체, 만료 시각, 다음 확인 시간을 검사합니다.
8. 해체(teardown)는 Ankole 엔드포인트와 checkback을 취소하기 전에 GitHub hook을 제거합니다.

GitHub는 실패한 webhook delivery를 자동으로 재시도하지 않습니다. GitHub Skill이 최근 delivery를 확인하고, 실패가 여전히 유효할 때 GitHub의 redelivery API를 사용합니다.

## one-shot 및 standing 엔드포인트

| 모드 | 계약 | 용도 |
|---|---|---|
| `one_shot` | 동시 delivery 하나가 엔드포인트를 차지합니다. 이후 delivery는 성공적인 no-op을 받습니다. | 수령이 정확히 한 번 기대됨 |
| `standing` | 수락된 delivery마다 선택된 소비자를 위한 레코드 하나를 만듭니다. 전달은 최소 한 번(at least once)이고 중복이 보입니다. | 저빈도 엣지 이벤트 |

standing 전달은 소비자 레코드를 둘 이상 만들 수 있습니다. 소비자는 현재 외부 상태를 권위로 사용하고 반복 처리를 멱등하게 유지합니다.

## 결정적 소비자 사용

Agent는 엔드포인트를 만들 때 `--automation-job-id <id>`를 전달할 수 있습니다. 그러면 수락된 `webhook.received` 봉투(envelope)는 대화를 직접 깨우는 대신 지속적인 automation job 실행의 `context().event`가 됩니다. 스크립트는 무관한 수령을 조용히 버리거나, 결정적 확인을 마친 후 `emitEvent`를 호출할 수 있습니다.

수령은 여전히 신뢰할 수 없는 입력입니다. 스크립트는 결과에 영향을 주는 사실을 권위 있는 소스에서 검증하고 반복 delivery를 무해하게 만들어야 합니다. delivery에 memory, 판단, 또는 대화가 필요하면 직접 Agent wake를 사용하세요. 소개는 [Automation Jobs](../automation-jobs/)를, SDK와 실패 계약은 [Worker CLI 기능](../cli-capabilities/)을 읽으세요.

## Console

Console에서 **Webhooks**를 열어 Agent와 session별로 엔드포인트를 검사하세요. 페이지에는 라벨, 모드, 상태, 만료 시각, 소스 라우트가 표시됩니다. 콜백 URL, 평문 token, 저장된 digest는 표시되지 않습니다.

Console은 엔드포인트를 나열하고 취소할 수 있습니다. 만들 수는 없습니다. 만들려면 현재 대화 라우트가 필요하므로 활성 Agent 턴에 속합니다.

긴급 credential 회수가 필요하면 Console에서 취소하세요. 이것은 외부 GitHub hook을 삭제하지 않습니다. 그 hook은 별도로 제거하세요. 일반 해체에서는 Agent에게 먼저 GitHub hook을 제거하라고 요청하세요.

## 보안 및 전달 제한

- Ankole은 전체 콜백 URL을 한 번만 반환합니다. PostgreSQL은 그 SHA-256 digest만 저장합니다.
- Ankole 요청 로그는 `/webhooks/v1/event-callbacks/*`를 `/webhooks/v1/event-callbacks/[REDACTED]`로 대체합니다. ingress, proxy, CDN도 같은 경로를 숨기도록 구성하세요.
- 콜백 본문 제한은 1 MiB입니다. 너무 큰 요청은 일반 본문 파서가 실행되기 전에 `413`을 반환합니다.
- Ankole은 이벤트 메타데이터 헤더만 유지합니다: `content-type`, `x-hub-signature-256`, `x-github-*`, `ce-*`. authorization과 일반 요청 헤더는 버립니다.
- Agent는 신뢰할 수 없는 데이터 경계 안의 제한된 수령을 봅니다. 외부 데이터의 리터럴 종료 태그는 이스케이프됩니다.
- 콜백 URL은 wake-up만 승인합니다. 서명 헤더가 있어도 비즈니스 효과를 승인하지 않습니다.

## 문제 해결

- **Agent가 GitHub Skill을 찾지 못함:** 이 Agent에 GitHub Agent Plugin과 Skill이 활성화되어 있는지 확인한 다음 새 턴을 시작하세요.
- **GitHub가 콜백에 도달하지 못함:** 공개 HTTPS 인증서, DNS, ingress 라우트, `/webhooks/v1/event-callbacks/*` 전달을 확인하세요.
- **hook은 존재하지만 Agent 답변이 없음:** GitHub delivery 로그, Console의 엔드포인트 상태, Worker 준비 상태, 지속적인 actor 이벤트, 발신 chat 전달을 검사하세요.
- **GitHub가 `413`을 보고함:** 선택한 이벤트 페이로드가 1 MiB보다 큽니다. GitHub에서 이벤트 형태를 좁히거나 다른 감지기를 사용하세요.
- **같은 이벤트가 Agent를 두 번 깨움:** standing 엔드포인트에서는 유효한 동작입니다. Agent는 현재 GitHub 상태를 다시 읽고 반복 처리를 안전하게 만들어야 합니다.
- **설정 중 콜백 URL을 잃음:** 일치하는 GitHub hook을 제거하고, 이전 엔드포인트와 checkback을 취소한 다음, 교체용 하나를 만드세요.

ingress 소유자와 트랜잭션 경계는 [SignalsGateway](../signals-gateway/)를, capability 설정은 [Agent Library](../skills/)와 [환경 변수](../worker-env/)를 읽으세요.