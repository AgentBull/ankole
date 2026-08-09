---
title: 코드 실행
description: Ankole Agent가 대화 중 또는 영구 Background Agent Job으로 코드를 실행하는 방식.
section: Developer guide
order: 122
---

Agent는 일반 대화 중에 명령을 실행하고 파일을 편집할 수 있습니다. 또한 영구 작업을 Background Agent Job에 위임할 수도 있습니다. 이들은 별개의 런타임 경로입니다: 대화는 Agent Computer Worker의 포그라운드 도구를 사용하고, 모든 Background Agent Job은 CodexRunner를 사용합니다. 메시지의 코드 양이 둘 사이를 선택하지 않습니다.

먼저 핵심 속성을 밝힙니다: 모든 명령은 제한된 환경에서 실행됩니다. 셸 명령은 bubblewrap 아래에서 `SYS_ADMIN`, 무제한 seccomp, 마스킹되지 않은 `/proc`으로 실행됩니다 — 이것은 운영자 선택이 아니라 worker의 하드 요구 사항입니다. 에이전트는 `/agents` 아래의 에이전트별 파일 시스템 안에서 작업하며, 셸을 통해 그 샌드박스를 벗어날 수 없습니다.

## bubblewrap 아래의 셸 명령

Agent는 `app/agent_computer/src/tools/computer/command-tool.ts`와 `bubblewrap.ts`의 bubblewrap 제한에 기반한 command 도구를 통해 셸 명령을 실행합니다. 모델이 요청하는 모든 명령은 `SYS_ADMIN`, 무제한 seccomp 정책, 마스킹되지 않은 `/proc`으로 bubblewrap 아래에서 실행됩니다. 마스킹되지 않은 `/proc`과 `SYS_ADMIN` 능력은 [browser](../browser-automation/) 데몬과 Jupyter 커널이 동일한 제한 환경에서 실행되게 합니다. 이 프로파일은 [Quick start](../quickstart/#deployment)에 문서화된 Worker 이미지 요구 사항이며, Agent마다 튜닝하지 않습니다.

실제로 의미하는 바: 셸 명령은 에이전트 워크스페이스 아래의 파일을 읽고 쓸 수 있고, 설치된 도구를 실행할 수 있으며, worker 이미지가 제공하는 하위 프로세스를 시작할 수 있습니다. 다른 에이전트의 워크스페이스에는 도달할 수 없고 제어 플레인 상태에도 도달할 수 없습니다. 샌드박스가 경계입니다.

## 파일 읽기와 apply_patch

컴퓨터 도구는 셸과 함께 Agent에게 두 가지 파일 프리미티브를 제공합니다:

- **파일 읽기** — `read-file-tool.ts`, `cat`으로 셸을 호출하는 대신 파일 내용을 직접 검사합니다.
- **파일 편집** — `apply-patch-tool.ts`, 고정된 Codex 릴리스와 동일한 문법을 사용하는 자유 형식 `apply_patch` 도구입니다.

Main Agent는 원시 패치를 `custom_tool_call`로 AIGateway를 통해 보냅니다. Worker는 이를 `/usr/local/bin/apply_patch`를 통해 네이티브 Codex 바이너리에 전달합니다. Background Agent Jobs는 AIGateway 모델 카드에서 동일한 자유 형식 도구를 받아 동일한 바이너리를 사용합니다. Ankole은 별도의 패치 파서를 유지하지 않습니다.

이 공유 경로는 일반 대화와 Background Agent Jobs가 하나의 편집 프로토콜을 사용하게 합니다. 일치하지 않는 패치는 네이티브 도구에서 실패하고 그 실패가 모델에게 반환됩니다. 빠른 검색에는 셸이 충분합니다. 파일 편집에는 `apply_patch`를 사용하세요.

## /agents 파일 시스템

에이전트가 읽고 쓰는 모든 것은 에이전트 키별로 배치된 `/agents` 아래에 있습니다. 에이전트는 컨테이너 경로를 직접 봅니다 — worker는 모델을 위해 경로를 변환하지 않습니다:

```text
/agents/<agent-key>/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── user-files/
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── .ankole/skills/
    └── temp/
```

`SOUL.md`, `MISSION.md`, `DESIGN.md`는 [Agent Library](../agent-library/)의 영구 문서입니다. 처음 두 개는 책임과 동작을 정의합니다. `DESIGN.md`는 시각 작업을 위한 디자인 시스템입니다. `installed-skills/`는 Agent Skills를 보관합니다. `sessions/`는 10000에서 시작하는 안정적인 PostgreSQL 소유 숫자 ID를 가진 대화 워크스페이스를 보관하고, `jobs/`는 별도의 Background Agent Job 워크스페이스를 보관합니다.

## 반복 Python을 위한 Jupyter 라이브 커널

작업이 반복적 Python일 때 — 실행 간에 유지되어야 하는 변수, 셀별로 검사하고 싶은 DataFrame, 상태 저장 REPL — 셸은 잘못된 도구입니다. `jupyter-live-kernel` 스킬이 올바른 도구입니다. 이것은 hamelnb 주변의 Ankole Unix-socket 어댑터를 기반으로 [백그라운드 Job](../background-jobs/)으로 실행되는 내장 스킬(`default_enabled: true`)입니다. 커널은 실행 간에 살아 있으므로 매 호출마다 데이터를 다시 로드하는 대신 한 단계에서 변수를 정의하고 다음 단계에서 읽을 수 있습니다.

스킬 자체의 지침이 경험칙입니다: 짧고 무상태인 Python 스크립트에는 일회성 셸 실행을 선호하고, 보통 Jupyter 노트북이나 상태 저장 Python REPL을 원할 상황에서는 이 스킬을 선호하세요. 데이터 과학, DataFrame 검사, 노트북 편집, 상태 저장 API 탐색이 이 스킬의 핵심 영역입니다. 시스템 Python, JupyterLab, ipykernel, hamelnb 헬퍼는 이미 worker 이미지에 있으므로, 새로운 에이전트는 아무것도 설치하지 않고 스킬을 사용할 수 있습니다.

## Background Agent Job을 위한 CodexRunner

CodexRunner는 모든 Background Agent Job의 실행 엔진입니다. Job은 주제를 조사하거나, 문서를 만들거나, 리포지토리를 수정하거나, 다른 장기 실행 작업을 할 수 있으며, CodexRunner를 선택하는 것은 주제가 아니라 수명 주기입니다. 러너는 `app-server-client.ts`를 통해 Codex app-server와 통신하고 별도의 Job 워크스페이스와 런타임 구성을 준비합니다.

Console은 해당 모델 프로파일을 **Background Agent Jobs**라고 부릅니다. 저장된 키와 API 이름은 현재 `coding`으로 유지됩니다. 이것은 코드 중심 대화를 감지하는 규칙이 아니라 레거시 이름입니다.

## 이 경로들이 선택되는 방식

운영자 표면은 좁습니다:

- **Computer tools**(`command`, `read_file`, `apply_patch`)는 모든 Worker와 함께 제공됩니다. 일반 대화 턴 중에 사용할 수 있습니다.
- **Jupyter live kernel**은 `default_enabled` 스킬이므로, [Agent Library](../agent-library/)를 통해 [browser](../browser-automation/) 스킬을 제어하는 것과 같은 방식으로 제어합니다. 반복 Python을 실행하면 안 되는 에이전트에는 이를 제한하세요.
- **CodexRunner**는 모든 Background Agent Job을 실행합니다. 모든 모델 호출은 AIGateway를 통과합니다. Job에 다른 제공자나 모델이 필요하면 Background Agent Jobs 프로파일을 구성하세요. 설정되지 않으면 제어 플레인은 Agent의 `heavy` 프로파일을 사용합니다.

## 다음 단계

- 이러한 도구를 실행하고 `/agents` 파일 시스템을 소유하는 Worker에 대해서는 [Agent Computer Worker](../agent-computer-worker/)를 읽으세요.
- Jupyter 스킬 뒤의 스킬 및 활성화 모델에 대해서는 [Agent Library](../agent-library/)를 읽으세요.
- 내부 키가 `coding`으로 유지되는 Background Agent Jobs 프로파일에 대해서는 [Background Agent Jobs](../background-jobs/#select-the-runtime)를 읽으세요.
- Worker 이미지가 요구하는 제한 환경에 대해서는 [Quick start](../quickstart/#deployment)를 읽으세요.