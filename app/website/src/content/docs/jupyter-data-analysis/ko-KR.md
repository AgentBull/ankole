---
title: Jupyter 데이터 분석
description: 라이브 Jupyter kernel을 통해 반복적인 Python 데이터 분석을 실행하는 agent를 설정하는 방법 — jupyter-live-kernel skill, DataFrame 검사, 작업 예시.
section: Guides
order: 304
---

데이터 분석은 반복적입니다 — DataFrame을 검사하고, 쿼리를 조정하고, 결과를 플롯하고, 다시 반복합니다. 일회성 Python 프로세스는 호출 사이에 상태를 유지할 수 없습니다. `jupyter-live-kernel` skill은 agent가 여러 셀에 걸쳐 구동하는 라이브 Jupyter kernel을 실행해 상태를 보존함으로써 이 문제를 해결합니다. 이 가이드는 데이터 분석 agent의 실용적인 형태입니다.

가장 중요한 특성을 먼저 말하면: Jupyter kernel은 **셀을 넘나들며 상태를 유지합니다(stateful across cells)**. 변수, DataFrame, import, 플롯 상태가 agent의 호출 사이에 유지됩니다. 이것이 반복 분석을 가능하게 합니다 — agent는 각 단계에서 데이터를 다시 로드하거나 라이브러리를 다시 import하지 않습니다.

## 필요한 것

- **활성화된 `jupyter-live-kernel` skill.** `default_enabled: true`입니다. [Skills](../skills/)를 참조하세요.
- **Worker 이미지.** Agent Computer Worker 이미지에는 Python, Jupyter, `hamelnb` kernel이 설치되어 있습니다. 이미지의 일부입니다.
- **바인딩된 `primary` 모델 프로필.** agent가 Python 코드를 작성하고 kernel이 이를 실행합니다.

## kernel vs 일회성 스크립트

다음 경우에 Jupyter kernel을 사용하세요:

- 작업이 **반복적**일 때 — 검사, 조정, 재검사
- **상태가 유지되어야** 할 때 — 로드된 DataFrame, 학습된 모델, import된 라이브러리
- agent가 최종 쿼리를 작성하기 전에 데이터 형태를 **탐색**해야 할 때

다음 경우에는 일회성 Python 프로세스(`command`를 통해)를 사용하세요:

- 스크립트가 **무상태(stateless)**일 때 — 한 번 실행하고 출력을 만들면 끝
- 작업이 **배치 변환**일 때 — 파일 변환, 검사 불필요

skill의 `SKILL.md`는 이렇게 말합니다: "Prefer a one-shot Python process for stateless scripts."

## kernel 작동 방식

`jupyter-live-kernel` skill은 백그라운드 job(`ankole-runtime: background_job`)으로 실행됩니다. Worker에서 Jupyter kernel을 시작하고, agent는 skill의 도구를 통해 셀을 보냅니다. 각 셀은 kernel의 지속 상태에서 실행됩니다 — 셀 1에서 정의한 변수는 셀 5에서 사용할 수 있습니다.

kernel은 백그라운드 job이 지속되는 동안 살아 있습니다. job이 끝나면 kernel은 중지되고 상태는 사라집니다 — 일시적인 실행 상태이지 지속적인 것이 아닙니다.

## 작업 예시

팀이 채널에 올리는 CSV를 분석하는 agent를 설정해 봅니다:

1. `jupyter-live-kernel` skill이 활성화되어 있는지 확인합니다(기본적으로 켜져 있습니다).
2. agent를 만들고 `MISSION.md`를 작성합니다: "When a CSV appears in the channel, load it into a DataFrame, inspect the schema and summary statistics, identify anomalies, and report findings with a plot."
3. 채널에 CSV를 업로드합니다(worker-file 라우트를 통해 또는 URL을 제공).
4. agent가 백그라운드 job에 위임하고, kernel을 시작하고, CSV를 로드하고, 반복적으로 검사하고, 플롯을 생성하고, 결과를 보고합니다.

## 이 가이드가 아닌 것

Python이나 pandas 튜토리얼이 아닙니다 — agent가 코드를 작성하고 skill이 실행 환경을 제공합니다. notebook 작성 가이드도 아닙니다 — kernel은 agent의 사용을 위한 것이지 저장된 notebook 생성을 위한 것이 아닙니다(작업이 요청하면 agent가 저장할 수는 있습니다). 그리고 skill의 `SKILL.md` 읽기를 대체하지도 않습니다 — 그 파일이 권위 있는 참조입니다.

## 다음 단계

- skill 시스템은 [Skills](../skills/)와 [Writing a skill](../writing-a-skill/)을 읽으세요.
- 셸 도구는 [Code execution](../code-execution/)을 읽으세요.
- 백그라운드 job은 [Background jobs](../background-jobs/)를 읽으세요.
- Agent용 파일 업로드는 [File management](../file-management/)를 읽으세요.