---
title: Automation Job
description: 결정적(deterministic) 스크립트가 Cron, Checkback, Webhook 트리거를 소비하게 하세요. 기계적인 검사는 조용히 끝나고, Agent는 판단이 필요한 때만 깨어납니다.
section: User guide
order: 22
---

Cron, Checkback, webhook endpoint의 세 가지 트리거는 기본적으로 Agent 대화를 깨웁니다. automation job은 두 번째 소비자입니다. Agent가 작성하여 자신의 Agent Home 안에 유지하는 결정적 스크립트입니다. 트리거를 여기에 바인딩하면, 시스템은 Agent 턴을 시작하는 대신 실행 시점에 스크립트를 실행합니다.

스크립트는 무엇이 사용자의 주의를 받을 만한지 결정합니다. 조용히 끝날 수도 있고, `emitEvent`를 호출하여 소유자 대화로 이벤트를 보낼 수도 있습니다. 그러면 Agent는 스크립트가 준비한 바로 그 컨텍스트로 깨어납니다. 코드가 기계적인 감시를 맡고, 모델은 판단이 필요한 지점에만 남습니다.

## 언제 적합한가

처리가 결정적인 가져오기, 비교, 파싱 또는 미리 정해진 작업일 때 그 작업을 automation job에 넘기세요. 전형적인 예: 5분마다 가격을 확인하고, 임계값 위에 있는 동안은 조용히 끝내며, 떨어졌을 때만 현재 가격을 emit합니다 — 그러면 Agent가 깨어나 검증하고 사용자에게 알립니다. 각 확인은 모델 턴 한 번 대신 스크립트 실행 한 번의 비용이 듭니다.

모든 실행이 memory, 판단, 대화를 필요로 한다면 직접 Agent 깨우기를 유지하세요. 어떤 선택도 영구적이지 않습니다: 직접 깨우기로 시작하고, 처리가 기계적임이 입증되면 스크립트로 옮기거나, 다시 되돌릴 수 있습니다.

## Agent에게 생성 요청

Console이 필요하지 않습니다. 채팅에서 무엇을 확인할지, 조건, 언제 깨울지를 말하세요:

```text
Watch the price of 7709 for me: check every 5 minutes and alert me
only when it drops below 3.5. Stay silent otherwise. After market
close, report once whether the day's checks ran normally.
```

Agent는 스크립트를 Agent Home 안에 작성하고, 직접 검증한 후 automation job으로 등록하고, 여기에 바인딩된 Cron을 만들고, 시장 마감 정산용 Checkback을 설정합니다. 스크립트 편집은 재등록 없이 즉시 적용됩니다. 각 실행은 디스크에 있는 현재 파일을 실행합니다.

## 실행 기록과 실패

모든 실행은 실행 기록을 남깁니다: 시작 및 종료 시간, 상태, 종료 코드, 오류, 제한된 로그. Agent는 대화에서 이 기록을 읽을 수 있고, Console의 **Automation Jobs** 페이지도 같은 읽기 전용 보기를 제공합니다.

- 기본적으로 실패한 실행은 기록될뿐 다른 일은 일어나지 않습니다.
- 생성 시 Agent에게 `wake_on_failure`를 활성화하도록 요청하면, 모든 실패한 실행이 소유자 대화를 깨웁니다.
- 긴 감시에는 정산용 Checkback을 job과 짝지으세요: Agent가 일정에 따라 깨어나 실행 기록을 읽고, "14:00 이후로 검사가 실패했습니다" 같은 조용한 장애를 소리 내어 보고합니다.

throw, 0이 아닌 종료 코드, 타임아웃은 스크립트 자신의 결과입니다. 시스템은 이를 재시도하지 않습니다. 다음 실행은 스스로 도착합니다. 반면 Worker 실패는 실행을 재배포하므로 실행이 겹치고 전달이 반복될 수 있습니다 — Agent는 재실행이 무해하도록 스크립트를 작성합니다.

## 데이터 규율

스크립트가 `emitEvent`로 보내는 payload는 신뢰할 수 없는 입력으로 Agent에게 도달하며, webhook 수신과 같은 규칙이 적용됩니다: Agent는 중요 사실에 대해 행동하거나 답변하기 전에 권위 있는 출처에서 검증합니다.

## 정리

감시를 끝내려면 먼저 스크립트를 가리키는 Cron, Checkback 또는 webhook endpoint를 취소한 다음 automation job을 취소하세요. 취소된 job으로 실행되는 트리거는 실패한 실행으로 기록됩니다. 가리키는 트리거가 없는 job은 유지 비용이 없습니다. 목록의 한 행만 차지할 뿐입니다.

트리거는 [Schedules](../schedules/)와 [Webhook delegations](../webhook-delegations/), 일반적인 형태는 [Automation blueprints](../automation-blueprints/), 완전한 스크립트·SDK·명령 계약은 [Worker CLI capabilities](../cli-capabilities/)를 참조하세요.
