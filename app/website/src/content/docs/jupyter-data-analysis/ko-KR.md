---
title: Jupyter 데이터 분석
description: 라이브 Jupyter kernel을 통해 반복적인 Python 데이터 분석을 실행하는 agent를 설정하는 방법 — jupyter-live-kernel skill, DataFrame 검사, 작업 예시.
section: Guides
order: 304
---

데이터 분석은 DataFrame을 확인하고 쿼리를 다듬은 뒤 차트를 그려 보며 결과를 다시 검증하는 반복 작업입니다. 일회성 Python 프로세스는 호출이 끝날 때마다 종료되므로 이러한 중간 상태를 유지할 수 없습니다. 반면 `jupyter-live-kernel` skill은 라이브 Jupyter kernel을 띄워 상태를 보존하므로, Agent가 여러 셀에 걸쳐 이어서 분석을 진행할 수 있습니다. 이 가이드에서는 데이터 분석용 Agent를 실무에 맞게 구성하는 방법을 살펴봅니다.

핵심은 Jupyter kernel이 **여러 셀에 걸쳐 상태를 유지한다(stateful across cells)**는 점입니다. 변수, DataFrame, import한 라이브러리, 플롯 상태가 호출 사이에도 그대로 남아 있으므로, Agent가 단계마다 데이터를 다시 불러오거나 라이브러리를 새로 import할 필요가 없습니다.

## 필요한 것

- **활성화된 `jupyter-live-kernel` skill.** 기본값이 `default_enabled: true`이므로 별도로 끄지 않았다면 바로 사용할 수 있습니다. 자세한 내용은 [Skills](../skills/)를 참조하세요.
- **Worker 이미지.** Agent Computer Worker 이미지에는 Python, Jupyter, `hamelnb` kernel이 기본 포함되어 있습니다.
- **바인딩된 `primary` 모델 프로필.** Agent가 Python 코드를 작성하면 kernel이 이를 실행합니다.

## kernel vs 일회성 스크립트

다음과 같은 경우에는 Jupyter kernel을 사용하세요.

- 데이터를 확인하고 조건을 조정한 뒤 다시 확인하는 **반복 분석** 작업일 때
- 로드한 DataFrame, 학습된 모델, import한 라이브러리 등 **메모리 상태를 유지**해야 할 때
- 최종 쿼리를 작성하기 전에 데이터 구조와 분포를 먼저 **탐색**해야 할 때

반면 다음과 같은 경우에는 `command` 도구를 통한 일회성 Python 프로세스가 더 적합합니다.

- 한 번 실행해 출력을 내면 끝나는 **무상태(stateless) 스크립트**일 때
- 중간 확인 없이 파일 형식만 바꾸는 **배치 변환** 작업일 때

해당 skill의 `SKILL.md`에서도 무상태 스크립트에는 일회성 Python 프로세스를 우선 사용하도록 안내합니다("Prefer a one-shot Python process for stateless scripts.").

## kernel 작동 방식

`jupyter-live-kernel` skill은 백그라운드 Job(`ankole-runtime: background_job`) 환경에서 동작합니다. Worker에서 Jupyter kernel이 시작되면 Agent는 skill이 안내하는 도구를 통해 셀 단위로 코드를 전송합니다. 각 셀은 동일한 kernel 메모리 위에서 실행되므로, 첫 번째 셀에서 정의한 변수를 다섯 번째 셀에서 그대로 참조할 수 있습니다.

kernel은 해당 백그라운드 Job이 실행되는 동안에만 유지됩니다. Job이 종료되면 kernel 프로세스도 함께 내려가며 메모리 상태 역시 사라지므로, 영구 저장소가 아니라 실행 중 임시 상태로 이해해야 합니다.

## 작업 예시

팀원이 채널에 올린 CSV 파일을 분석하는 Agent를 설정하는 절차는 다음과 같습니다.

1. `jupyter-live-kernel` skill이 활성화되어 있는지 확인합니다(기본 활성화).
2. Agent를 생성하고 `MISSION.md`에 `"When a CSV appears in the channel, load it into a DataFrame, inspect the schema and summary statistics, identify anomalies, and report findings with a plot."`을 작성합니다.
3. 채널에 CSV 파일을 첨부하거나, Console에서 Agent 드라이브에 파일을 업로드한 뒤 해당 경로를 알려 줍니다.
4. 요청을 받은 Agent는 작업을 백그라운드 Job에 위임해 kernel을 시작하고, CSV를 불러와 반복적으로 데이터를 점검한 뒤 플롯과 함께 분석 결과를 보고합니다.

## 이 가이드가 아닌 것

이 문서는 Python이나 pandas 문법을 다루는 튜토리얼이 아니며, 코드는 Agent가 직접 작성하고 skill은 실행 환경을 제공합니다. 또한 재사용할 노트북 문서를 꾸미는 가이드도 아닙니다(물론 요청에 명시하면 Agent가 `.ipynb` 파일을 저장할 수는 있습니다). 정확한 도구 호출 규칙은 해당 skill의 `SKILL.md`가 기준이므로, 세부 동작을 확인할 때는 `SKILL.md`를 직접 참고하세요.

## 다음 단계

- Skill 시스템 전반은 [Skills](../skills/)와 [Writing a skill](../writing-a-skill/)을 참조하세요.
- 셸 도구 사용법은 [Code execution](../code-execution/)을 참조하세요.
- 백그라운드 Job 구조는 [Background jobs](../background-jobs/)를 참조하세요.
- Agent용 파일 업로드는 [File management](../file-management/)를 참조하세요.