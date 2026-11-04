---
title: Worker CLI 기능
description: Agent 기능을 `--help`가 계약을 담당하는 shell 명령으로 제공하고, Agent가 관련 결정을 내리는 위치에 한 문장짜리 포인터를 배치합니다.
section: Developer guide
order: 114
---

Ankole의 일부 기능은 모델에 상시 노출되는 도구(tool) 스키마 대신 Agent Computer 내부의 셸 명령어로 제공됩니다. Agent는 `kubectl`을 다루듯 셸에서 이 명령어들을 실행하며, `ankole-pod`(`pages.*`, `base.*`, `applet build|publish|pull`), `ankole-files`, `ankole-browser`, 웹훅 엔드포인트 관리 명령, automation job 관리 명령이 모두 이 방식을 따릅니다.

이 문서에서는 어떤 기능을 CLI 형태로 설계해야 하는지, 그리고 별도의 도구 등록이나 Skill 인덱스 항목, 시스템 프롬프트 상주 설명 없이도 Agent가 적시에 기능을 발견하고 정확히 사용할 수 있게 만드는 단계적 노출(disclosure) 구조를 설명합니다.

## CLI가 올바른 형태인 경우

다음 세 조건을 모두 만족하는 기능은 모델 도구보다 CLI 명령어로 제공하는 편이 적합합니다.

- Agent가 복합 셸 워크플로 안에서 다른 유틸리티 명령과 조합해 사용하며, 스크립트나 Background Agent Job에서도 그대로 호출할 수 있어야 합니다.
- 특정 의사결정 경로에 들어섰을 때만 필요한 기능입니다. 예를 들어 웹훅을 생성할 일이 없는 일반 대화의 Agent는 `create-webhook-cli`의 존재조차 미리 알 필요가 없습니다.
- 복잡한 중첩 JSON 스키마를 채울 필요 없이 몇 개의 명령줄 플래그만으로 입력을 충분히 표현할 수 있습니다.

모델에 직접 노출된 도구는 매 추론 turn마다 프롬프트 컨텍스트를 점유하지만, CLI 명령어는 Agent가 실제로 해당 작업 경로에 진입하기 전까지 컨텍스트 토큰을 전혀 소비하지 않습니다.

## 공개 아키텍처

도구 스키마 등록과 Skill 상시 인덱싱을 대신하는 세 가지 설계 원칙은 다음과 같습니다.

**`--help` 출력 자체가 정식 계약 문서입니다.** CLI의 `--help` 출력에는 해당 기능의 목적, 신뢰 경계, 보장 범위, 완결된 사용 예시까지 Agent가 올바르게 호출하는 데 필요한 모든 정보가 담깁니다. 실행 바이너리 안에 함께 패키징되므로 실제 동작 버전과 설명이 항상 일치하며 외부 문서처럼 코드와 어긋나지 않습니다. 사전 배경지식이 없는 호출자가 읽더라도 바로 이해할 수 있도록 단순 나열식 절차보다 목표와 제약 조건을 명확히 서술하세요. 좋은 작성 기준으로는 `create-webhook-cli --help`를 참고할 수 있습니다.

**관련 의사결정 지점에 한 문장짜리 포인터를 배치합니다.** Agent는 인접한 결정을 내리는 표면(유관 도구의 설명문, 특정 외부 시스템을 연동하는 Skill 본문, 또는 다른 관련 CLI의 `--help` 출력)에 놓인 짧은 안내 문장 하나를 보고 이 CLI의 존재를 발견합니다. 각 포인터는 특정 선택을 강요하지 않고 “어떤 조건일 때 이 기능이 관련되며 어디서 상세 사용법(`--help`)을 확인할 수 있는지”만 담백하게 안내합니다. CLI 형태로 제공하는 모든 기능은 관련 업무 경로에서 Agent가 반드시 거치게 되는 표면에 최소 하나 이상의 포인터를 두어야 합니다.

**공통 규약은 `--help`에, 외부 서비스별 지식은 플러그인 Skill에 둡니다.** CLI 전체에 적용되는 규칙은 `--help`에서 설명합니다. Skill은 외부 서비스의 작업 규약과 필요한 플랫폼 기능을 안내합니다. 예를 들어 Toolkit 업로드 작업은 Pod 파일 참조를 받으므로, Skill은 먼저 `pod-content`로 Worker 파일을 업로드하도록 안내합니다.

## Automation Jobs

Automation Job은 Function Runtime에서 게시된 Applet Action을 실행합니다. Agent는 `ankole-pod applet`으로 Applet을 빌드·게시하고, `ankole-pod jobs`로 Action 조회, Job 생성·설정, 일정과 Webhook 관리, Run 확인을 수행합니다. 사용 전에 `ankole-pod --help`를 읽으세요.

서버는 `{routes, actions}`를 내보냅니다. Action은 처리 함수, 멱등성, 동시 실행 정책을 선언하고 `ctx.signal`과 `ctx.job.config`를 읽으며 `ctx.state`에 상태를 저장합니다. `continueSlice()`로 같은 Run을 나누어 실행할 수 있습니다. 외부 호출은 `AnkoleRuntime.mcp`, 팀 권한은 `AnkoleRuntime.admin.mcp`를 사용합니다.

자동화 패널과 SDK의 `useAppletJobs()`·`useJobSources(jobID)`도 같은 작업을 제공합니다. 테스트 전달 후 Run의 입력·결과·오류·로그를 확인하세요. 권한과 복구 방법은 [Automation Jobs](../automation-jobs/)를 참고하세요.

## 새 CLI 기능의 요구 사항

- 코드는 `app/agent_computer/src/cli/` 아래에 명령어 패밀리별 전용 디렉터리를 만들어 배치합니다.
- 실행 중인 turn이나 네트워크 연결 없이도 `--help`와 `-h` 호출만으로 전체 계약 문서를 `stdout`에 출력하고 종료 코드 `0`으로 끝나야 합니다. 상위 래퍼가 서브커맨드를 앞에 붙일 수 있으므로 인자 배열 어느 위치에 도움말 플래그가 오더라도 인식하도록 구현하세요.
- 잘못된 인자가 들어왔을 때는 계약 문서 전문 대신 간결한 사용법(usage) 요약만 출력합니다.
- Agent가 해당 기능을 필요로 할 만한 모든 의사결정 표면에 포인터 문장을 추가하되, 특정 방식 사용을 유도하지 말고 적용 조건과 `--help` 확인 방법만 객관적으로 서술하세요.
- 플러그인 Skill에서 해당 CLI를 특정 외부 서비스와 결합할 때는 첫머리에서 `--help` 포인터를 먼저 안내하고 Skill 본문에는 외부 서비스 고유의 차이점만 기술하세요.
