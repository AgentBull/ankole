---
title: 자동화 블루프린트
description: 트리거를 Agent session, automation job, background job, 시그널 라우팅 규칙과 결합합니다.
section: Guides
order: 309
---

Ankole의 자동화는 세 가지 트리거와 두 가지 실행 소비자를 조합해 구성합니다. 판단이나 기억 조회, 사용자 대화가 필요한 작업은 Agent session이 맡고, 정해진 규칙에 따른 반복 점검은 결정적 스크립트인 automation job이 맡습니다. 이 문서에서는 실무에서 바로 활용할 수 있는 대표적인 자동화 설계 패턴(블루프린트)을 소개합니다.

여기서 말하는 automation job은 복잡한 워크플로 전용 언어나 단계 그래프(DAG)가 아닙니다. Agent 드라이브 폴더 안에 두는 일반 Bun `main.ts` 스크립트로서 정해진 이벤트를 기계적으로 처리할 뿐입니다. 반면 [Workflow](../workflows/)는 Main Agent가 턴 안에서 직접 호출하는 유한한 병렬 서브에이전트 오케스트레이션 도구이며, 이 역시 스케줄러나 YAML 파이프라인 또는 범용 이벤트 버스는 아닙니다.

## 세 가지 트리거

모든 자동화 블루프린트는 다음 세 가지 트리거 중 하나에서 출발합니다. 먼저 해결하려는 과제에 어떤 트리거가 맞는지 선택하세요.

| 트리거 | 발동 방식 | 전달 수단 | 구축 방법 |
|---|---|---|---|
| **Schedule** | cron 주기에 따라 반복 실행(매시간, 매일, 매주 등) | cron schedule에 정의된 `task` | [스케줄](../schedules/) |
| **자기 지연(checkback)** | Agent가 실행 턴 도중 후속 확인 시각을 직접 예약 | Agent의 `check_back_later` 도구 | [스케줄](../schedules/) |
| **이벤트 기반(webhook)** | 외부 시스템이 전용 capability URL로 HTTP POST 전송 | `webhook.received` 이벤트 | [Webhook 위임](../webhook-delegations/) |

세 트리거 모두 Agent를 직접 깨우든 스크립트를 실행하든 동일한 CloudEvents 봉투(envelope) 형식을 생성합니다. 소비자를 바꾸더라도 트리거 이벤트 자체는 달라지지 않으며, 이벤트를 받아 처리하는 주체만 바뀝니다. 또한 Agent를 직접 깨운 응답과 스크립트가 발행한 후속 이벤트 모두 소유자 session의 라우팅 규칙을 거쳐 원래 대화 채널로 전달됩니다.

## 소비자 선택

| 소비자 | 사용 시점 | 트리거 결과 |
|---|---|---|
| **Agent session** | 매 실행마다 맥락 판단, 기억 조회, 동적 도구 선택, 또는 사용자 대상 답변 작성이 필요할 때 | 트리거가 Signal을 적재하고 해당 conversation을 깨웁니다. |
| **Automation job** | 데이터 가져오기, 수치 비교, 파싱처럼 미리 정해진 기계적 처리만 수행하면 될 때 | 트리거가 영구 기록이 남는 스크립트 실행을 시작합니다. 스크립트는 조용히 종료하거나 소유자 session으로 이벤트를 발행할 수 있습니다. |

업무 처리 절차가 아직 완전히 굳어지지 않았다면 먼저 Agent를 직접 깨우는 방식으로 시작하고, 충분히 검증되어 기계적으로 처리할 수 있는 부분만 automation job으로 분리하세요. 이렇게 하면 스크립트는 단순하게 유지하면서도 모델이 변화 없는 상태를 확인하느라 불필요하게 반복 호출되는 비용을 막을 수 있습니다.

Agent session이 깨어난 뒤 분석해야 할 유한한 작업 묶음을 받았다면 그 session 안에서 Workflow를 실행할 수 있습니다. Workflow는 제3의 트리거나 소비자가 아니라, Agent가 여러 독립적인 판단 과제를 병렬로 실행한 뒤 고정된 JavaScript 코드로 결과를 취합할 때 쓰는 실행 도구입니다.

## 블루프린트: 일일 다이제스트(스케줄)

스케줄러가 하루 한 번 정해진 시각에 Agent를 깨우면, Agent가 필요한 정보를 수집·요약하여 연결된 채팅 채널에 게시하는 패턴입니다. 정기 일일 cron 표현식을 걸기 전에 먼저 [스케줄](../schedules/) 문서를 참고해 스케줄을 생성하고 수동 실행으로 결과를 검증해 보세요.

아래 Console API 요청을 실행하려면 먼저 로그인된 브라우저에서 세션 쿠키와 `x-csrf-token` 값을 확인합니다.

```bash
curl -X POST https://ankole.example.com/api/v2/agents/<agent_uid>/cron-schedules \
  -H "Cookie: $CONSOLE_COOKIE" \
  -H "x-csrf-token: $CSRF_TOKEN" \
  -H "Content-Type: application/vnd.api+json" \
  -d '{
    "data": {
      "owner_session_id": "<session_id>",
      "binding_name": "main",
      "name": "daily-digest",
      "idempotency_key": "daily-digest-1",
      "schedule": { "kind": "cron", "expression": "0 9 * * *" },
      "timezone": "Asia/Shanghai",
      "delivery": { "targets": [{ "binding_name": "main", "conversation_id": "<conversation_uuid>" }] },
      "payload": { "task": "Produce today'\''s digest of the topics in your mission." }
    }
  }'
```

조정 가능한 항목은 cron 표현식(실행 주기), `timezone`(“오전 9시”의 기준 시간대), `task`(수행할 지시 내용), 그리고 Agent의 persona(작성 어조와 방식)입니다. 정기 실행에 맡기기 전에 반드시 수동 실행으로 출력 형태를 먼저 확인하세요.

## 블루프린트: 유한한 병렬 분석(Agent session + Workflow)

하나의 요청 안에 서로 독립적으로 분석할 수 있는 대상이 여러 개 들어 있다면 Workflow를 활용하세요. 예를 들어 20개 공급업체를 각각 조사해 비교 표를 만들거나, 여러 관점의 검토 프롬프트로 동일한 제안서를 동시에 평가하는 작업에 적합합니다.

1. 채팅 요청이나 예약된 스케줄이 Agent session을 깨웁니다.
2. Agent가 유한한 입력 목록과 동시 실행 수, 총 태스크 상한을 지정해 Workflow를 시작합니다.
3. Workflow가 독립된 태스크 turn들을 병렬로 실행하고 구조화된 결과를 다음 단계로 넘깁니다.
4. 전체 실행(run)이 완료되거나 실패하면 원래 session이 자동으로 깨어나 후속 정리를 이어 갑니다.

Workflow 내부에서는 외부 상태가 바뀔 때까지 대기하거나 폴링하지 마세요. 실행 도중 추가 정보를 받아야 하거나 사용자의 의사결정을 기다려야 하거나 작업 공간을 장기간 유지해야 하는 경우에는 [Background Agent Job](../background-jobs/)을 선택하세요.

## 블루프린트: 결정적 감시자(스케줄 + automation job)

점검 주기는 짧지만 확인 로직이 단순하고 평소에는 별다른 이상이 없는 감시 업무에는 automation job을 연결하세요. Agent가 감시 스크립트를 작성해 등록한 뒤 cron 스케줄을 해당 `automation_job_id`에 바인딩합니다.

```json
{ "kind": "cron", "expression": "0 * * * *" }
```

스크립트는 외부 소스를 조회해 조건이 충족되지 않으면 `emitEvent`를 호출하지 않고 조용히 종료합니다. 조건이 충족되었을 때만 핵심 근거 데이터를 담아 소유자 session으로 이벤트를 발행하며, 이때 비로소 Agent가 깨어나 상황을 검증하고 후속 조치를 결정합니다. 등록하기 전에 일반 로직 분기를 먼저 단위 테스트하고, `context()`나 `emitEvent`를 호출하는 분기는 실제 테스트 트리거를 발생시켜 검증하세요.

만약 매 주기마다 맥락을 읽고 의미를 해석해야 하는 업무라면 스크립트로 분리하지 말고 Agent 직접 스케줄을 유지하세요. 상세한 스크립트 작성 규약은 [Worker CLI capabilities](../cli-capabilities/) 문서를 참조하세요.

## 블루프린트: 지연 후속 처리(checkback)

실행 턴 도중 요청을 받은 Agent가 일정 시간 뒤에 다시 상태를 확인하기로 스스로 판단할 때 쓰는 패턴입니다. 고정된 반복 cron을 만드는 대신 Agent가 직접 `check_back_later` 도구를 호출해 “1시간 뒤에 다시 확인” 같은 일회성 깨우기를 예약합니다. 예약 주체는 Agent 자신이며 Console 화면에서는 읽기 전용으로 조회 및 취소만 제공합니다.

“배포가 1시간 안에 정상 완료되었는지 확인해 줘”나 “스탠드업 미팅이 끝난 뒤 이 스레드를 다시 읽어 줘”처럼 정해진 반복 주기가 없는 단발성 후속 점검에 알맞습니다. 대기 중인 예약 목록은 `GET /api/v2/checkbacks?agent=<agent_uid>`로 조회하고, 개별 취소는 `DELETE /api/v2/agents/:agent_uid/checkbacks/:scheduled_event_id`로 수행합니다.

## 블루프린트: 리서치 후 보고(스케줄 + background job)

예약된 스케줄로 시작된 작업이 장시간의 자료 조사와 교차 검증을 요구할 때는 메인 turn을 붙잡아 두지 말고 [Deep Research Background Agent Job](../deep-research-job/)으로 위임하세요.

1. cron 스케줄이 지정된 `task`로 Agent의 turn을 깨웁니다.
2. Agent가 장기 조사가 필요하다고 판단해 `create_background_job`을 호출합니다.
3. 스케줄로 열린 메인 turn은 즉시 종료되고 백그라운드 Job이 독립적으로 조사를 수행합니다.
4. 조사가 끝나면 Job이 소유 session으로 `background_agent_job.completed` 이벤트를 보내고, 연결된 채널 바인딩을 통해 최종 보고서가 전달됩니다.

이 구성을 사용하면 메인 스케줄 turn을 한 시간 내내 열어 두지 않고도 안정적인 “주간 심층 리서치 보고서” 자동화를 운영할 수 있습니다. 스케줄러는 시작 신호만 넣고 실제 무거운 조사는 백그라운드 Job이 전담합니다.

## 블루프린트: 이벤트 기반(webhook)

코드 저장소나 CI 파이프라인 같은 외부 시스템에서 Ankole이 발급한 전용 capability URL을 호출하는 패턴입니다. 엔드포인트는 수신된 요청을 검증해 지정된 소비자 레코드를 데이터베이스에 커밋한 뒤에야 성공 응답을 반환합니다.

이벤트가 발생할 때마다 Agent가 외부 리소스의 현재 상태를 직접 조회해 맥락을 판단해야 한다면 기본값인 직접 Agent 소비자를 사용하세요. 반대로 결정적 스크립트로 노이즈를 먼저 걸러내거나 페이로드를 정제할 수 있다면 엔드포인트를 automation job에 연결하세요. 어느 경로를 택하든 외부에서 유입된 웹훅 본문은 신뢰할 수 없는 입력으로 취급하며, 중요한 판단에 쓰일 사실은 반드시 신뢰할 수 있는 정본 소스에서 다시 확인해야 합니다. capability URL의 보안과 수명 주기 규칙은 [Webhook 위임](../webhook-delegations/) 문서를 참조하세요.

## 블루프린트: 관찰 및 에스컬레이션(binding policy + schedule)

팀 어시스턴트 Agent가 평소에는 대화방을 조용히 지켜보며 맥락만 쌓아 두었다가, 정해진 시각에 핵심 내용을 요약해 브리핑하는 패턴입니다. 채널의 바인딩 정책(`may_intervene` 또는 `record_only`)으로 실시간 관찰 범위를 정하고 스케줄러로 종합 보고 시점을 제어합니다.

- 바인딩 설정: `unaddressed_group_message_policy: record_only`로 지정하면 Agent가 모든 대화를 읽고 기억에 축적하되 실시간으로는 끼어들지 않습니다.
- 스케줄 설정: “오늘(또는 이번 주) 이 채널에서 논의된 주요 내용 요약” 작업을 일간·주간 주기로 등록합니다.
- 실행 시 Agent가 축적된 최근 대화 맥락을 바탕으로 요약본을 작성해 해당 채널 바인딩으로 게시합니다.

이렇게 구성하면 상시 조용히 이루어지는 ‘관찰’과 정해진 시점에 명확히 전달되는 ‘종합 보고’를 깔끔하게 분리할 수 있습니다. 시시각각 달리는 봇 답글은 방해가 되지만 주기적인 정리 브리핑은 꼭 필요한 실무 채널에 적합합니다.

## 블루프린트 선택

- **정해진 시각이나 주기에 맞춰 실행하고 싶나요?** Schedule을 선택하세요. 매번 결과를 올릴지 이상 징후가 있을 때만 알릴지에 따라 다이제스트 패턴과 감시자 패턴 중 고르면 됩니다.
- **유한한 대상 묶음을 병렬로 분석하고 싶나요?** Agent session + Workflow 조합을 선택하고 입력 크기와 반복 상한을 먼저 확정하세요.
- **진행 중인 업무를 잠시 뒤 다시 점검하고 싶나요?** Agent가 직접 시점을 예약하는 Checkback을 사용하세요.
- **정해진 시각에 장시간 걸리는 조사·분석을 시작하고 싶나요?** Schedule + background job 조합을 사용하세요.
- **모델 턴을 소비하지 않고 잦은 기계적 상태 점검을 돌리고 싶나요?** Schedule 또는 Checkback에 automation job을 연결하세요.
- **외부 시스템 이벤트로 후속 업무를 이어 가고 싶나요?** 직접 Agent 소비자 또는 automation job을 연결한 Webhook 위임을 사용하세요.
- **평소에는 조용히 대화를 기록하고 주기적으로만 요약받고 싶나요?** Binding policy(`record_only`) + Schedule 조합을 사용하세요.

## Ankole 자동화가 아닌 것

Automation job은 범용 워크플로 엔진이 아닙니다. YAML 단계 정의나 플랫폼 차원의 DAG, 암묵적 숨은 커서, 범용 이벤트 버스를 두지 않습니다. 짧은 TypeScript 스크립트를 실행해 주지만 자체 상태 관리와 재실행 안전성(멱등성)은 스크립트 코드가 직접 책임져야 합니다. 또한 모든 외부 메시지 전달은 소유자 session의 라우팅 규칙을 거치므로 자동화 경로라고 해서 접근 권한 검증을 우회할 수는 없습니다.

마찬가지로 Workflow 역시 스케줄러나 상시 이벤트 오케스트레이터가 아닙니다. 호출 시점에 확정된 `args`와 유한한 반복 한도 안에서만 동작하며, 외부 상태 변화를 폴링하거나 실행 도중 추가 대화 메시지를 받지 않습니다. 맥락 판단은 Agent에게, 반복적인 기계적 점검은 automation job에게, 유한한 병렬 추론은 Workflow에게 각각 역할에 맞게 배분하세요.

## 다음 단계

- 예약 스케줄 구성과 관리는 [스케줄](../schedules/) 문서를 참조하세요.
- 결정적 스크립트 소비자 사용법은 [Automation Jobs](../automation-jobs/) 문서를 참조하세요.
- 장기 백그라운드 실행과 협업 방식은 [Background Agent Jobs](../background-jobs/) 문서를 참조하세요.
- 유한한 병렬 서브에이전트 실행은 [Workflows](../workflows/) 문서를 참조하세요.
- 외부 웹훅 수신 URL 관리는 [Webhook 위임](../webhook-delegations/) 문서를 참조하세요.
