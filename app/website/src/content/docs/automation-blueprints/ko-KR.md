---
title: 자동화 블루프린트
description: 트리거를 Agent session, automation job, background job, 시그널 라우팅 규칙과 결합합니다.
section: Guides
order: 309
---

트리거와 소비자를 별도로 선택합니다. 일정, Checkback, 콜백 엔드포인트, Connector 이벤트가 CloudEvents 입력을 만들고, Agent는 판단과 대화를, Applet Action은 정해진 처리를 담당합니다. 하나의 소스를 여러 소비자에 연결할 수도 있습니다.

## 자주 쓰는 구성

| 목표 | 구성 | 동작 |
| --- | --- | --- |
| 일일 보고 | Agent 일정, 작업, 전달 대상 | 정보를 모아 요약 전송 |
| 자주 상태 확인 | Applet Job과 소유한 일정 | 모델 턴 없이 조건 확인 |
| 한 번만 후속 확인 | Agent Checkback | 지정 시각에 원래 대화 재개 |
| 외부 변경 수신 | Connector 구독 또는 콜백 | 연결된 Job이나 Agent 실행 |
| 긴 조사 | Agent 일정과 Background Agent Job | 독립적으로 조사한 뒤 원래 대화에 보고 |
| 조용한 채널 관찰 | 기록 전용 채팅 연결과 일정 | 평소에는 기록하고 정기적으로 요약 |

## 정형 모니터 만들기

확인 로직을 Applet Action으로 게시한 뒤 자동화 패널에서 Job과 설정, 소스를 등록합니다. 입력은 `ctx.signal.data`로 읽고, 커서나 직전 값은 `ctx.state`에 저장합니다. 외부 작업은 `AnkoleRuntime.mcp`로 호출하며 연결이 여러 개면 사용할 연결을 지정합니다.

정상 상태, 조건 변화, 상위 서비스 오류를 각각 테스트하고 Run의 입력·결과·로그를 확인합니다. 알림이 필요하면 Action에서 해당 플랫폼의 메시지 도구를 명시적으로 호출하세요. Run이 성공했다고 자동으로 채팅 메시지가 전송되지는 않습니다.

매번 해석이나 답변 작성이 필요하면 Agent를, 코드로 판단할 수 있으면 Applet Job을 선택합니다. [Workflow](../workflows/)는 한 턴 안에서 제한된 병렬 판단에, [Background Agent Job](../background-jobs/)은 긴 Agent 작업에 적합합니다.

[Automation Jobs](../automation-jobs/), [일정](../schedules/), [Webhook 위임](../webhook-delegations/)을 참고하세요.
