---
title: Background Agent Jobs
description: 현재 대화를 계속 사용할 수 있는 상태로, 재개 가능한 백그라운드 Job에 긴 작업을 위임합니다.
section: User guide
order: 20
---

Background Agent Job은 심층 리서치, 대용량 파일 묶음 처리, 장문 문서 작성, 데이터 분석, 코드 저장소 변경처럼 시간이 오래 걸리는 업무를 처리할 때 사용합니다. 백그라운드에서 독립적으로 실행되므로 작업이 돌아가는 동안에도 메인 대화방에서 Agent와 대화를 계속 이어 갈 수 있습니다.

<a href="https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/delegation.md" target="_blank" rel="noreferrer">Hermes Agent</a>나 <a href="https://docs.openclaw.ai/subagents" target="_blank" rel="noreferrer">OpenClaw</a>에 익숙하다면 서브에이전트 개념과 가장 비슷합니다. 다만 Ankole은 위임 작업의 수명과 상호작용 방식에 따라 [Workflow](../workflows/)와 Background Agent Job을 명확히 구분합니다.

Ankole은 각 백그라운드 Job을 휘발성 함수 호출이 아니라 전체 수명 주기가 영구 보존되는 복구 가능한 연산 단위로 다룹니다. 따라서 실행 도중 Worker가 교체되거나 프로세스 충돌, 서버 재시작이 일어나더라도 마지막으로 저장된 지점부터 작업을 이어 갈 수 있습니다.

작업 도중 Main Agent가 Job에 추가 정보를 전달할 수 있으며, 대부분의 Job은 확인 질문이나 실패 알림, 최종 완료 결과를 원래 대화방으로 돌려보냅니다. 중간 알림 없이 조용히 실행하도록 지시한 경우에는 나중에 직접 결과를 조회할 수 있습니다.

## Workflow와 Background Agent Job 중 선택

| 작업 형태 | 선택 | 이유 |
|---|---|---|
| 짧은 단일 작업 | 현재 turn에서 직접 실행 | 잠시만 기다리면 바로 다음 답변에서 완성된 결과를 받을 수 있음 |
| 유한한 배치 처리 또는 다단계 병렬 분석 | [Workflow](../workflows/) | 고정된 JavaScript 코드가 독립적인 서브에이전트 turn들을 병렬로 실행하고 구조화된 결과를 취합함 |
| 지속적인 작업 문맥과 후속 대화가 필요한 장기 과제 | Background Agent Job | 전용 Codex 스레드와 로컬 workspace를 유지하며 사용자의 응답을 기다렸다가 재개할 수 있음 |

Workflow 내부 태스크에서는 또 다른 Workflow나 Background Agent Job을 중첩 생성할 수 없습니다. 실행 도중 추가 자료를 건네주거나 사람의 중간 의사결정을 받아야 하는 업무라면 Background Agent Job을 선택하세요.

## Agent에게 Job 생성을 요청

채팅창에 달성할 목표를 적고 백그라운드 작업으로 실행해 달라고 명시적으로 요청하면 됩니다. 예를 들면 다음과 같습니다.

```text
Run this as a Background Agent Job. Read these materials and prepare a decision
memo with evidence, disagreements, and open questions. Return the result here.
```

입력 자료, 완료 기준, 원하는 결과물 형식을 한 요청 안에 함께 알려 주고, 마감 시각이 중요하다면 마감 기한도 명시하세요. 구체적인 수행 절차는 Agent가 결정하지만, 백그라운드에서 실행된다고 해서 Agent에게 평소보다 넓은 접근 권한이 부여되지는 않습니다.

## Job이 실행되는 동안 대화 계속

Job이 시작된 뒤에도 원래 대화방에서 Main Agent를 통해 추가 참고 자료를 전달하거나 요구 사항을 조정하고 현재 진행 상태를 물어볼 수 있습니다. 이렇게 보낸 메시지는 실행 중인 작업의 방향을 조종(steer)하거나 답변을 기다리며 멈춰 있던 Job을 재개시킵니다.

요청할 때 Agent와 백그라운드 Job이 어떤 방식으로 소통하길 원하는지 함께 적어 두면 좋습니다.

- **끝나면 알려 줘:** 끝까지 알아서 진행할 수 있는 과제에 적합합니다. 결과가 원래 대화방에 도착할 때까지 다른 주제로 자유롭게 대화를 이어 갈 수 있습니다.
- **백그라운드에서 조사한 다음 답변을 계속해:** 지금 나누고 있는 대화의 결론을 내리기 위해 백그라운드 조사 결과가 먼저 필요할 때 사용합니다.
- **핵심 선택 전에 나에게 물어봐:** 진행 방향이나 유료 리소스 사용처럼 중요한 결정을 확인받아야 할 때 사용합니다. Job이 잠시 멈추고 원래 대화방에 질문을 남기며, 답변을 주면 다시 실행을 이어 갑니다.
- **조용히 실행해:** 파일 생성만 해 두면 되거나 나중에 직접 확인할 예정일 때 사용합니다. 알림을 보내지 말라고 지정한 뒤 나중에 대화에서 물어보거나 Console에서 결과를 확인할 수 있습니다.
- **이전 Job 계속:** 이어서 작업할 이전 Job을 지목하고 추가 요구 사항을 전달합니다. 해당 Job이 재개 가능한 상태라면 기존 작업 공간과 문맥을 그대로 살려 후속 작업을 진행합니다.

예를 들면 다음과 같이 요청할 수 있습니다.

```text
Compare these three proposals in the background. Notify me when you finish.
Ask me here before you expand the scope or use a paid data source.
```

코드 저장소나 문서 모음, 특정 설치 도구가 필요하다면 요청에 함께 적어 주세요. 알맞은 작업 공간은 Agent가 알아서 준비하므로 사용자가 직접 템플릿 ID를 외우거나 Job API를 호출할 필요는 없습니다.

## 모델 provider 선택

모든 백그라운드 Job은 AIGateway를 거쳐 모델을 호출합니다. Job을 생성할 때 Ankole은 해당 Agent에 설정된 유효 **Background Agent Jobs** 모델 프로필을 기록하며, 이 프로필이 비어 있으면 Agent의 `heavy` 프로필을 기본값으로 사용합니다.

ChatGPT 구독 계정을 연결해 쓰려면 먼저 [ChatGPT subscription provider](../chatgpt-subscription-provider/)를 등록하세요. 그다음 Console에서 **Agents** 페이지를 열고 해당 Agent의 모델 프로필 중 **Background Agent Jobs** 항목에서 방금 만든 provider와 지원 모델, reasoning effort, Fast Mode 여부를 선택하면 됩니다. 여러 계정이 등록된 경우 provider의 자격 증명 풀이 알아서 계정을 선택하고 순환 사용합니다.

## Console에서 Job 검사

Console에서 **Background Agent Jobs** 페이지를 열면 대기 중(`queued`), 실행 중(`active`), 종료됨(`finished`) 열로 정리된 보드가 나타납니다. 개별 Job 카드를 클릭하면 최초 요청 내용과 현재 작업 계획, turn 이력, 모델 토큰 사용량, 최종 결과 및 오류 내역을 상세히 살펴볼 수 있습니다.

| 상태 | 의미 | 해야 할 일 |
|---|---|---|
| `queued` | 작업이 수락되어 Agent의 Worker 기동이나 빈 Job 슬롯을 기다리는 중 | 잠시 기다립니다. 계속 진행되지 않으면 **Console → Workers**에서 해당 Agent의 Worker 상태를 점검하세요. |
| `running` | 현재 작업이 실행 중 | 상세 화면을 열어 작업 계획과 최신 진행 내역을 확인합니다. |
| `waiting_on_user` | 메인 Agent 또는 사용자의 답변을 기다리는 중 | 메인 Agent가 스스로 판단할 수 있는 질문에는 직접 답하며, 사용자에게 물었다면 Job을 시작했던 원래 대화방에서 답변하세요. |
| `succeeded` | 정상 완료됨 | 최종 결과물을 확인합니다. 완료 알림을 요청했는데 오지 않았다면 원래 대화방에 메시지가 도착했는지 확인하세요. |
| `failed` | 오류로 중단됨 | 오류 메시지를 확인한 뒤 입력 자료나 설정을 보완해 새 Job 생성을 요청하세요. |
| `stopped` | 사용자 또는 관리자에 의해 취소됨 | 종료된 상태이므로 추가 실행이 일어나지 않습니다. |

`waiting_on_user`는 오류가 아닙니다. Job이 질문을 올리면 먼저 메인 Agent가 알고 있는 범위에서 직접 답변하고, 사람의 의사결정이나 승인 또는 추가 정보가 꼭 필요할 때만 사용자에게 다시 묻습니다. 대기하는 동안 Job은 점유하던 실행 슬롯을 반납하고 답변이 들어오면 즉시 재개합니다. 질문에 답할 때는 반드시 Job을 처음 요청했던 원래 대화방에서 답하세요. 다른 대화방에 답을 남기면 대기 중인 Job 질문과 연결되지 않습니다.

## Job 취소

중단하려는 Job을 열고 **Cancel**을 누르세요. 이미 실행에 들어간 현재 turn을 안전하게 정리하는 데 약간의 시간이 걸릴 수 있어 상태가 즉시 `stopped`로 바뀌지 않을 수도 있습니다.

작업을 취소하더라도 그때까지 생성된 파일이나 실행 로그 기록은 삭제되지 않습니다.

단순히 작업 방향만 조금 수정하고 싶다면 취소하기 전에 먼저 원래 대화방에서 Agent에게 지시를 전달해 보세요. 작업이 완전히 엉뚱한 방향으로 흘러가거나 불필요하게 리소스를 소모하고 있거나 과제 자체가 필요 없어진 경우에는 취소한 뒤 새 Job을 시작하는 편이 깔끔합니다.

## 일반적인 문제

- **Job이 계속 `queued` 상태에 머무름:** 해당 Agent의 Worker가 정상 기동되었는지, 같은 Agent의 다른 백그라운드 작업들이 동시 실행 슬롯(`background_agent_jobs.max_running_per_agent`)을 모두 점유하고 있지는 않은지 확인하세요.
- **시작 직후 바로 `failed`로 끝남:** Agent에 저장된 Background Agent Jobs 모델 프로필 구성과 연결된 provider의 자격 증명 풀 상태를 점검하세요.
- **`waiting_on_user` 상태인데 질문도 안 오고 진행도 멈춤:** 원래 대화방의 시그널 라우팅 규칙과 외부 Channel Provider 연결 상태를 확인하세요.
- **`succeeded`로 끝났는데 채팅방에 완료 보고가 오지 않음:** 처음 요청할 때 조용히 실행하라고 지시하지 않았는지 먼저 확인하고, 아니라면 상세 화면에 결과가 생성되어 있는지 확인한 뒤 원래 대화방의 라우팅 규칙을 점검하세요.
- **모델 프로필을 바꿨는데 기존 Job에 반영되지 않음:** 프로바이더 및 모델 바인딩은 첫 실행 승인(execution admission) 시점에 고정되므로, 프로필 변경 사항은 아직 실행 승인 전인 대기 작업이나 새로 생성한 Job부터 적용됩니다.
