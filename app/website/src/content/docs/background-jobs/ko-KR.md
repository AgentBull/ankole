---
title: Background Agent Jobs
description: 현재 대화를 계속 사용할 수 있는 상태로, 재개 가능한 백그라운드 Job에 긴 작업을 위임합니다.
section: User guide
order: 20
---

Background Agent Job은 조사, 대용량 파일 집합, 문서 작성, 데이터 분석, 리포지토리 변경, 그리고 시간이 걸리는 기타 작업을 위한 것입니다. Job은 백그라운드에서 독립적으로 실행되므로 Agent와 계속 대화할 수 있다.

<a href="https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/delegation.md" target="_blank" rel="noreferrer">Hermes Agent</a>나 <a href="https://docs.openclaw.ai/subagents" target="_blank" rel="noreferrer">OpenClaw</a>를 사용한다면 가장 가까운 비교는 서브에이전트다: Main Agent가 독립적인 작업을 다른 실행 컨텍스트에 위임합니다.

Ankole은 시스템이 임시 호출이 아니라 완전한 수명 주기로 작업을 저장하기 때문에 이를 Background Agent Job이라고 부릅니다. Job은 Worker 중단 후에도 복구할 수 있다.

Main Agent는 추가 정보를 보낼 수 있다. 대부분의 Job은 질문, 실패 상태, 최종 결과를 원래 대화로 돌려보냅니다. 업데이트를 요청하지 않으면 Job이 조용히 있을 수도 있으므로 나중에 검사할 수 있다.

## Agent에게 Job 생성을 요청

목표를 채팅에 밝히고 백그라운드 실행을 명시적으로 요청하세요. 예:

```text
Run this as a Background Agent Job. Read these materials and prepare a decision
memo with evidence, disagreements, and open questions. Return the result here.
```

같은 요청에 입력 파일, 완료 기준, 출력 형식을 제공하세요. 마감이 중요하면 마감도 밝히세요. Agent가 작업 수행 방식을 결정하지만, 백그라운드에서 실행된다고 해서 Job에 추가 권한이 생기지는 않습니다.

## Job이 실행되는 동안 대화 계속

Job이 시작된 후 Main Agent는 추가 자료를 보내거나, 요청을 수정하거나, 현재 상태를 물을 수 있다. 메시지는 활성 작업을 조종하거나 답을 기다리는 Job을 재개할 수 있다.

요청에서 Agent와 Job이 어떻게 협력하길 원하는지 밝혀라:

- **끝나면 알려 줘:** 독립적으로 실행될 수 있는 작업에 사용하세요. 결과가 원래 대화로 돌아오는 동안 계속 채팅할 수 있다.
- **백그라운드에서 조사한 다음 답변을 계속해:** 현재 답변이 Job 결과에 의존할 때 사용하세요.
- **핵심 선택 전에 나에게 물어봐:** 방향이나 비용에 결정이 필요할 때 사용하세요. Job은 멈추고 원래 대화에서 질문하며 답변 후 재개합니다.
- **조용히 실행해:** Job이 파일만 만들면 되거나 나중에 직접 검사할 계획일 때 사용하세요. Agent에게 업데이트를 보내지 말라고 말하세요. 나중에 물어보거나 Console에서 검사할 수 있다.
- **이전 Job 계속:** 작업을 식별하고 새 요구 사항을 밝히세요. Job이 아직 재개 가능하면 Agent가 기존 컨텍스트로 계속할 수 있다.

예:

```text
Compare these three proposals in the background. Notify me when you finish.
Ask me here before you expand the scope or use a paid data source.
```

Job에 리포지토리, 문서 집합, 또는 설치된 tool이 필요한지 밝히세요. Agent가 적절한 워크스페이스를 선택합니다. 워크스페이스 템플릿 ID를 입력하거나 Job API를 호출할 필요는 없다.

## 모델 provider 선택

모든 Job은 AIGateway를 사용합니다. Job이 생성될 때 Ankole은 유효한 **Background Agent Jobs** 모델 프로필을 저장합니다. 그 프로필이 비어 있으면 Agent의 `heavy` 프로필이 폴백입니다.

ChatGPT 구독을 사용하려면 먼저 [ChatGPT subscription provider](../chatgpt-subscription-provider/)를 만드세요. 그다음 Console에서 **Agents**를 열고 Agent의 모델 프로필에서 **Background Agent Jobs**를 찾아 해당 provider, 자격이 있는 모델, reasoning effort, Fast Mode를 선택하세요. provider의 자격 증명 풀이 계정을 선택하고 순환시킵니다. Job은 계정을 선택하지 않습니다.

## Console에서 Job 검사

**Background Agent Jobs**를 여세요. 보드는 Job을 queued, active, finished 열로 그룹화합니다. Job을 열면 원래 요청, 현재 계획, turn 기록, 모델 사용량, 결과, 오류를 볼 수 있다.

| 상태 | 의미 | 해야 할 일 |
|---|---|---|
| `queued` | 승인되었고 사용 가능한 Worker를 기다리는 중 | 보통 기다립니다. 움직이지 않으면 Worker 가용성을 확인하세요. |
| `running` | 작업이 진행 중 | Job을 열어 계획과 최신 진행 상황을 확인하세요. |
| `waiting_on_user` | 답변이나 승인을 기다리는 중 | Job을 만든 대화에서 답하세요. |
| `succeeded` | 완료됨 | 결과를 읽으세요. 업데이트를 요청했다면 원래 대화가 받았는지 확인하세요. |
| `failed` | 완료하지 못함 | 오류를 읽으세요. 입력이나 구성을 고치고 Agent에게 새 Job 생성을 요청하세요. |
| `stopped` | 취소됨 | Job은 계속되지 않습니다. |

`waiting_on_user`는 실패가 아닙니다. Job은 실행 용량을 놓아주고 원래 대화에서 답한 후 재개합니다. 관련 없는 대화에서 답하지 마세요. Job이 그 답변을 자신의 질문과 연결할 수 없기 때문입니다.

## Job 취소

Job을 열고 **Cancel**을 선택하세요. 이미 시작한 turn은 멈추는 데 시간이 조금 걸릴 수 있으므로 상태가 즉시 `stopped`로 바뀌지 않을 수 있다.

취소는 Job이 이미 만든 파일이나 실행 기록을 제거하지 않습니다.

목표만 고치면 된다면 먼저 원래 대화에서 Agent에게 말하세요. 현재 Job이 잘못된 방향으로 가거나, 리소스를 소비하거나, 더 이상 필요 없을 때는 취소하고 새 Job을 만드세요.

## 일반적인 문제

- **Job이 `queued`로 남아 있음:** Worker가 하나 이상 준비되었고 다른 Job이 모든 가용 용량을 쓰고 있지 않은지 확인하세요.
- **시작하자마자 실패함:** 저장된 Background Agent Jobs 모델 프로필과 선택한 provider의 자격 증명 풀 상태를 확인하세요.
- **`waiting_on_user`인데 질문이 오지 않음:** 원래 대화의 시그널 라우팅 규칙과 Channel Provider를 확인하세요.
- **성공했는데 채팅으로 돌아오지 않음:** 먼저 조용히 있으라고 요청받지 않았는지 확인하세요. 아니라면 Job을 열고 결과가 있는지 확인한 다음 원래 대화의 라우팅 규칙을 확인하세요.
- **오래된 Job이 모델 프로필 변경을 무시함:** provider 바인딩은 Job 생성 시 고정됩니다. 프로필 변경은 새 Job에만 영향을 줍니다.
