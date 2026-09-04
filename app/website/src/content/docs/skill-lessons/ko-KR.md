---
title: Skill 교훈
description: 공유 Skill을 변경하지 않고 각 Agent에 짧은 작업상 주의 사항을 제공합니다.
section: User guide
order: 34
---

Skill 교훈은 Agent가 Skill을 읽을 때 함께 받는 날짜가 있는 짧은 주의 사항입니다. 반복되는 tool 실패, 환경 문제, 작업 방식의 오류를 피하도록 돕습니다. 공유 `SKILL.md`는 바뀌지 않습니다.

Skill 교훈은 GBrain의 Skill 최적화 실험에서 영감을 얻은 것으로, Agent가 Skill을 사용하는 과정에서 축적하는 날짜가 포함된 노트입니다. Ankole은 기계가 작성하는 내용을 리스가 있는 Agent 전용 프로세스 노트로 제한하며, Skill 본문은 절대 수정하지 않습니다.

교훈 하나는 Agent 하나와 Skill 하나에 속합니다. 모든 Agent에 적용해야 하는 규칙은 Skill 소스에 작성합니다.

## 교훈이 될 수 있는 내용

Ankole은 다음 두 종류의 작업상 주의 사항을 유지할 수 있습니다.

- 여러 Background Agent Job에서 나타난 tool 문제 또는 환경 조건.
- Job이 실행되는 동안 사람이 전달한, 다른 작업에서도 다시 사용할 수 있는 작업 방식의 수정.

교훈은 언제 중지할지, 무엇을 확인할지, tool을 어떻게 호출할지를 설명할 수 있습니다. 결과의 품질, 깊이, 완전성, 의견, 어조, style을 규정할 수는 없습니다. Ankole은 task 결과를 채점해서 교훈의 효과를 판단하지 않습니다.

한 task에만 필요한 지시는 교훈이 아닙니다. 한 번만 적용되는 범위, 형식, 용어 요구 사항은 해당 task에만 남습니다. 대부분의 증거 묶음에서는 교훈이 생기지 않습니다.

## 필요한 증거

Ankole은 종료된 Background Agent Job 중에서 실패한 command나 tool call이 있거나, Job 시작 후 사람의 message가 들어온 Job을 확인합니다. 최근 30일의 기록만 사용합니다.

Agent에 처리되지 않은 signal Job이 충분히 쌓이면 Dreaming이 reflection Job을 만듭니다. 기본 threshold는 10입니다. reflection은 조건을 충족하는 가장 최근 Job을 최대 30개까지 받습니다.

기계가 작성하는 교훈에는 보통 서로 다른 Job 두 개 이상의 증거가 필요합니다. Job 하나만으로 충분한 경우는 그 Job의 사람 message 자체가 교훈으로 요약할 재사용 가능한 수정 사항을 말할 때뿐입니다.

reflection은 로컬 환경에서 읽기 전용 검사를 실행할 수 있습니다. 파일을 변경하거나 network를 사용하거나 문제를 고칠 수는 없습니다. error와 tool output은 신뢰할 수 없는 data로 처리됩니다.

## Agent가 받는 내용

활성 교훈은 전체 Skill 지침 뒤의 `Agent-specific additions` section에 표시됩니다. 각 항목에는 날짜가 있습니다. 사람이 추가한 교훈은 Dreaming 교훈보다 먼저 표시됩니다.

폐기된 교훈과 재검토 유예 기간을 지난 기계 교훈은 전달되지 않습니다. Skill을 비활성화해도 해당 교훈이 Agent context에 들어가지 않습니다. 저장된 이력은 운영자가 계속 확인할 수 있습니다.

## 기계 교훈을 최신 상태로 유지하기

Dreaming 교훈은 7일 리스로 시작합니다. 예약된 Dreaming은 리스 만료가 가까워졌을 때, Ankole release가 바뀌었을 때, 또는 Skill 본문이 바뀌었을 때 교훈을 재검토합니다.

재검토 결과는 세 가지입니다.

- **갱신**: 조건이 여전히 존재하거나 새 증거가 없을 때 교훈을 유지합니다.
- **더 이상 유효하지 않음**: 환경에 조건이 없어졌거나 Skill 본문이 이미 교훈을 포함할 때 폐기합니다.
- **리스 만료**: 최근 실행에서 조건을 확인할 수 없고 더 이상 유효하지 않다고 판단할 수도 없을 때 만료된 교훈을 폐기합니다.

재검토 결과를 받지 못한 교훈은 7일 유예 기간 뒤에 전달을 중지합니다. 기록은 이력에 남으므로 운영자가 경위를 확인할 수 있습니다.

사람이 추가한 교훈에는 리스가 없습니다. Dreaming은 이를 변경하거나 폐기하지 않습니다.

## 교훈 추가 또는 폐기

1. Console에서 **Agent Library**를 엽니다.
2. 범위를 **전역 기본값**에서 대상 Agent로 바꿉니다.
3. Agent Plugin 또는 **Skills**에서 대상 Skill을 찾습니다.
4. **교훈 추가**를 선택하고 조건을 먼저 적은 다음 실행할 action을 적습니다.
5. 교훈이 잘못되었거나 오래되었거나 더 이상 필요하지 않으면 **폐기**를 선택합니다.

활성화된 Skill에만 사람의 교훈을 추가할 수 있습니다. 사람의 교훈에는 기계용 길이 제한이 없지만 URL을 포함할 수 없습니다. 교훈을 수정하려면 이전 항목을 폐기하고 새 항목을 추가합니다. 교훈 본문은 변경할 수 없습니다.

Console은 작성자, 작성 시간, 재검토 날짜, 확인된 release, 증거 Job, 폐기 이유를 보여 줍니다. 사람이 취소한 내용은 Dreaming의 재학습 금지 목록에 남으므로 Dreaming은 동등한 교훈을 다시 추가하지 않습니다. Agent는 다음 turn부터 폐기된 교훈을 읽지 않습니다.

## 학습 설정 및 상태 확인

다음 `brain.*` 설정이 Skill 교훈을 제어합니다.

| 설정 | 기본값 | 효과 |
|---|---|---|
| `brain.skill_learning_enabled` | `true` | reflection, 재검토, 교훈 전달을 활성화합니다. `false`로 설정하면 저장된 사람의 교훈과 Dreaming 교훈을 삭제하지 않고 숨깁니다. |
| `brain.skill_learning_reflection_threshold` | `10` | reflection Job 하나를 시작하는 데 필요한 미처리 signal Job 수를 설정합니다. 최솟값은 `2`입니다. |
| `brain.maintainer_agent_uid` | 설정되지 않음 | Brain 유지보수 Agent를 선택하고 해당 Agent의 `heavy` profile로 리스가 있는 교훈을 재검토합니다. 사용 가능한 `heavy` profile이 없으면 model 기반 재검토를 건너뜁니다. |
| `brain.dreaming_task_cron` | `0 5 * * *` | Dreaming이 reflection trigger를 평가하고 만료가 가까운 교훈을 재검토할 시간을 설정합니다. |

**Brain → 상태**를 열면 Skill 학습의 활성 상태, Agent별 활성 교훈 수, 최근 7일 동안 추가되거나 폐기된 교훈 수, 가장 오래된 활성 Dreaming 교훈의 나이를 확인할 수 있습니다.

## 제한과 안전

- 기계 교훈은 1～3개의 짧은 영어 문장으로 구성되며 최대 100 token입니다. 조건, action, 선택적 확인 방법을 포함합니다.
- reflection 한 번은 Skill 하나에 교훈을 최대 2개까지 추가할 수 있습니다. 해당 Skill에 활성 교훈이 이미 10개 있으면 Dreaming은 더 추가하지 않습니다.
- 기계 교훈에는 URL이나 injection 검사와 일치하는 내용을 포함할 수 없습니다.
- 교훈은 Agent별로 유지됩니다. Ankole은 Agent 사이에서 교훈을 공유하지 않습니다.
- task를 다시 실행하지 않으면 교훈이 맞는지 증명하거나 그 효과를 예측할 수 없습니다. 날짜와 조건이 있는 문장은 Agent가 실행 전에 현재 환경을 확인하도록 합니다.
