---
title: Webhook 위임
description: Agent 또는 결정적 스크립트가 폴링 없이 저빈도 외부 이벤트를 기다릴 수 있게 합니다.
section: User guide
order: 23
---

webhook 위임 기능을 사용하면 Agent가 폴링 없이 Ankole 바깥에서 일어나는 외부 작업 완료나 상태 변화를 기다릴 수 있습니다. 외부 시스템이 이벤트를 감지해 수명이 짧은 Ankole 콜백 URL을 호출하면, 기본적으로 Ankole은 수령 기록(receipt)을 저장하고 위임을 등록한 세션을 깨운 뒤 Agent가 검증한 결과를 원래 채팅 경로로 전달합니다. 모델 추론 전에 결정론적 스크립트가 먼저 수령 데이터를 걸러 내야 하는 경우에는 엔드포인트에 automation job을 대신 연결할 수도 있습니다.

콜백 수신은 어디까지나 세션을 깨우는 트리거일 뿐, 전달된 요청 본문이 곧바로 사실임을 보증하지는 않습니다. 따라서 Agent는 사용자에게 보고하거나 승인된 후속 변경을 수행하기 전에 반드시 외부 시스템의 최신 원본 객체를 직접 다시 조회해 검증합니다.

현재 정식 지원되는 대표 시나리오는 GitHub 저장소 webhook 연동입니다.

## 언제 사용하나

외부 시스템 측에서 이벤트 필터링이 잘 지원되는 저빈도 이벤트 대기에 webhook 위임을 사용하세요.

- GitHub 이슈, 댓글, Pull Request, 또는 GitHub Actions 워크플로 실행 상태 변화
- 작업이 끝났을 때 같은 대화를 한 번 깨워 이어가야 하는 단발성 이벤트
- 중복 수신되더라도 안전하게 재처리할 수 있는 상시 감시(standing watch)

초당 수십 건씩 쏟아지는 고빈도 스트림이나 단순 폴링 대체, 범용 메시지 버스 용도로는 사용하지 마세요. 이벤트 감지는 외부 시스템에 맡기고, 맥락 기억과 판단·답변만 Ankole에 두는 구성이 적합합니다.

요청할 때는 기대하는 결과, 허용할 작업 권한, 감시할 이벤트 종류, 만료 시점을 분명히 알려 주세요. 예시는 다음과 같습니다.

> 금요일까지 `owner/repository`의 pull request를 지켜보세요. 필수 체크가 실패하면 알려 주세요. 보고하기 전에 현재 pull request와 check 상태를 검증하세요. 요청하지 않는 한 코드를 변경하지 마세요.

구체적인 엔드포인트 등록과 장애 복구 절차는 GitHub Skill에 정의되어 있습니다.

## 요구 사항

Agent가 GitHub 위임을 생성하려면 먼저 다음 조건이 갖춰져야 합니다.

1. 외부에서 접근 가능한 공개 HTTPS 호스트를 Ankole control plane으로 라우팅하고, `/webhooks/v1/event-callbacks/*` 경로가 변형 없이 그대로 전달되도록 구성합니다.
2. 대상 Agent에 공개 **GitHub** Agent Plugin과 필요한 Skill을 활성화합니다(GitHub 플러그인은 기본적으로 비활성화되어 있습니다).
3. 해당 Agent의 WorkerEnv에 대상 저장소 읽기 권한과 저장소 webhook 쓰기 권한을 가진 `GITHUB_TOKEN`을 등록합니다.
4. 플러그인·Skill 또는 WorkerEnv를 변경한 뒤에는 새 Agent 턴을 시작해 변경 사항을 반영합니다.

콜백 엔드포인트 생성 명령은 활성 턴을 실행 중인 Main Agent에서만 사용할 수 있으며, Background Agent Job에는 턴 범위의 로컬 webhook 바인딩이 제공되지 않습니다.

## 수명 주기

활성 상태인 GitHub 위임 하나는 단일 저장소, 정확한 이벤트 목록 하나, 만료 시각 하나, Ankole 엔드포인트 하나, 원격 GitHub hook 하나, 그리고 상태 조정(reconciliation)용 checkback 하나로 구성됩니다.

1. Agent가 현재 대화에 연결된 콜백 엔드포인트를 생성합니다.
2. 원격 GitHub hook을 등록하기 전에 영속 checkback을 먼저 걸어, 추후 정리(cleanup) 및 상태 조정 의무를 남깁니다.
3. 발급받은 콜백 URL로 대상 저장소에 GitHub hook을 등록하면 GitHub가 초기 `ping` 이벤트를 보냅니다.
4. Agent가 GitHub delivery 로그를 조회해 `ping` 수신이 성공했는지 확인합니다.
5. 이후 조건에 맞는 delivery가 도착하면 Ankole은 응답으로 성공을 반환하기 전에 엔드포인트 상태 판정과 `webhook.received` Signal(또는 바인딩된 automation job 실행)을 단일 PostgreSQL 트랜잭션으로 커밋합니다.
6. 직접 깨어난 Agent는 수신된 페이로드를 신뢰할 수 없는 외부 입력으로 다루며, 바인딩된 automation job 역시 이벤트를 발행하기 전에 동일한 검증 원칙을 따라야 합니다.
7. 예약된 조정(reconciliation) 시점에는 원격 hook 존재 여부, 이벤트 목록, 실패한 delivery 내역, 현재 GitHub 객체 상태, 만료 시각, 다음 점검 시각을 확인합니다.
8. 위임을 해제(teardown)할 때는 먼저 원격 GitHub hook을 삭제한 뒤 Ankole 엔드포인트와 checkback을 취소합니다.

참고로 GitHub는 전송에 실패한 webhook delivery를 자동으로 재시도하지 않습니다. 대신 GitHub Skill이 최근 delivery 기록을 점검해 아직 유효한 실패 건이 있으면 GitHub의 redelivery API를 호출해 복구합니다.

## one-shot 및 standing 엔드포인트

| 모드 | 동작 계약 | 적합한 용도 |
|---|---|---|
| `one_shot` | 가장 먼저 처리된 delivery 하나만 엔드포인트를 소비하며, 뒤이어 도착한 요청에는 오류 없는 no-op 응답이 반환됨 | 단 한 번의 완료 알림만 기다릴 때 |
| `standing` | 수락된 delivery마다 지정된 소비자에게 실행 레코드를 하나씩 생성함(최소 한 번 전달 방식이므로 중복 전달 가능) | 저빈도 상태 변화 감시 |

`standing` 모드에서는 동일 이벤트에 대해 소비자 레코드가 두 번 이상 생성될 수 있으므로, 소비자 로직은 항상 외부 시스템의 현재 상태를 기준으로 판단하고 중복 실행에 멱등하게 동작해야 합니다.

## 결정적 소비자 사용

Agent가 엔드포인트를 만들 때 `--automation-job-id <id>` 옵션을 함께 넘기면, 수락된 `webhook.received` 봉투(envelope)가 대화를 직접 깨우는 대신 영속 automation job 실행의 `context().event` 입력으로 전달됩니다. 스크립트 안에서 조건에 맞지 않는 이벤트는 조용히 버리고, 결정론적 사전 확인을 통과한 경우에만 `emitEvent`를 호출해 메인 Agent를 깨울 수 있습니다.

이 경로에서도 콜백 수령 데이터는 신뢰할 수 없는 입력이므로, 스크립트는 중요한 판단 근거를 반드시 권위 있는 원본 API에서 다시 확인하고 중복 수신에도 부작용이 없도록 작성해야 합니다. 수신할 때마다 기억 조회나 모델 판단, 대화형 응답이 필요한 작업이라면 automation job 대신 기본 Agent 직접 깨우기 방식을 사용하세요. 자세한 개요는 [Automation Jobs](../automation-jobs/)에서, SDK 규격과 실패 처리 계약은 [Worker CLI 기능](../cli-capabilities/)에서 확인할 수 있습니다.

## Console

Console에서 **Webhooks** 메뉴를 열면 Agent 및 세션별로 등록된 콜백 엔드포인트를 점검할 수 있습니다. 목록에는 라벨, 모드, 현재 상태, 만료 시각, 원본 대화 경로만 표시되며, 전체 콜백 URL이나 평문 토큰, 저장된 다이제스트 값은 노출되지 않습니다.

이 화면에서는 Main Agent가 활성 턴 중 현재 응답 경로를 대상으로 생성한 원시 콜백 엔드포인트를 조회하고 취소할 수 있습니다. 반면 CloudEvents 이벤트 소스와 일반 Signal Routing Rule은 Console의 **Signals** 페이지에서 별도로 관리합니다(자세한 내용은 [Signals](../signals/) 참조).

긴급하게 콜백 수신을 차단해야 할 때는 Console에서 엔드포인트를 즉시 취소하세요. 단, Ankole 측 엔드포인트를 취소하더라도 외부 GitHub 저장소에 등록된 hook까지 자동 삭제되지는 않으므로 GitHub 측 hook은 별도로 지워야 합니다. 평상시 정상 해체 시에는 Agent에게 먼저 원격 GitHub hook부터 제거하도록 요청하세요.

## 보안 및 전달 제한

- 전체 콜백 URL은 생성 시점에 단 한 번만 반환되며, PostgreSQL에는 SHA-256 다이제스트만 저장됩니다.
- Ankole 요청 로그는 `/webhooks/v1/event-callbacks/*` 경로를 자동으로 `/webhooks/v1/event-callbacks/[REDACTED]`로 마스킹합니다. 앞단의 인그레스, 리버스 프록시, CDN 액세스 로그에서도 동일 경로가 평문으로 남지 않도록 마스킹을 설정하세요.
- 콜백 요청 본문 크기는 최대 1 MiB로 제한되며, 이를 초과하는 요청은 일반 본문 파서가 실행되기 전에 HTTP `413`을 반환합니다.
- 요청 헤더 중에서는 `content-type`, `x-hub-signature-256`, `x-github-*`, `ce-*` 같은 이벤트 메타데이터 헤더만 보존하고, `authorization` 및 그 밖의 일반 요청 헤더는 모두 폐기합니다.
- 수령 내용은 신뢰할 수 없는 데이터 경계 표시 안에 감싸져 Agent에 전달되며, 외부 본문에 포함된 리터럴 종료 태그는 이스케이프 처리됩니다.
- 콜백 URL은 세션을 깨우는 권한만 부여하므로, 설령 유효한 서명 헤더가 함께 들어왔더라도 그것만으로 비즈니스 상태 변경이 승인되지는 않습니다.

## 문제 해결

- **Agent가 GitHub Skill을 찾지 못함:** 대상 Agent에 GitHub Agent Plugin과 관련 Skill이 모두 활성화되어 있는지 확인한 뒤 새 턴을 시작하세요.
- **GitHub에서 콜백 URL로 연결하지 못함:** 공개 HTTPS 인증서, DNS 레코드, 인그레스 라우팅 규칙, 그리고 `/webhooks/v1/event-callbacks/*` 경로 전달 여부를 점검하세요.
- **원격 hook은 정상인데 Agent가 응답하지 않음:** GitHub의 delivery 로그, Console의 엔드포인트 상태, Worker 준비 상태, 생성된 영속 Signal, 발신 채팅 채널 전달 상태를 차례로 확인하세요.
- **GitHub 측에 `413` 오류가 기록됨:** 선택한 이벤트의 페이로드가 1 MiB 한도를 넘은 것입니다. GitHub hook 설정에서 구독 이벤트 범위를 좁히거나 다른 감지 방식을 사용하세요.
- **동일한 이벤트로 Agent가 두 번 깨어남:** `standing` 엔드포인트에서는 정상적인 최소 한 번(at-least-once) 전달 동작입니다. Agent가 최신 GitHub 상태를 다시 조회해 중복 실행에도 안전하게 처리하도록 지침을 유지하세요.
- **초기 설정 도중 콜백 URL을 분실함:** 이미 만들어진 원격 GitHub hook이 있다면 제거하고 이전 엔드포인트와 checkback을 취소한 뒤 새로 한 세트를 다시 생성하세요.

인그레스 소유 도메인과 트랜잭션 경계는 [Signals](../signals/)를, 플러그인 및 토큰 설정은 [Agent Library](../skills/)와 [환경 변수](../worker-env/)를 참조하세요.