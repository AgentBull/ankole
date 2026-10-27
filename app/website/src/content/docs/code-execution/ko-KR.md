---
title: 코드 실행
description: Ankole Agent가 대화 중 또는 영구 Background Agent Job으로 코드를 실행하는 방식.
section: Developer guide
order: 122
---

Agent는 일반 대화 도중 곧바로 셸 명령을 실행하고 파일을 편집할 수도 있고, 장시간 이어지는 작업을 Background Agent Job으로 위임할 수도 있습니다. 이 둘은 완전히 분리된 런타임 경로를 따릅니다. 일반 대화에서는 Agent Computer Worker의 포그라운드 도구를 호출하는 반면, 모든 Background Agent Job은 CodexRunner 위에서 실행됩니다. 메시지에 포함된 코드 분량이 많고 적음에 따라 경로가 자동 전환되는 것이 아니라 작업의 성격과 수명 주기에 따라 경로가 결정됩니다.

먼저 핵심 격리 원칙을 짚어 두면, **Agent의 모든 환경 명령은 해당 Agent 전용 컴퓨터 안에서 실행됩니다**. 각 Agent는 독립된 전용 Worker 컨테이너를 할당받으며 이 컨테이너 자체가 격리 경계 역할을 합니다. 명령은 추가 내부 샌드박스 없이 Worker 사용자 권한으로 실행되어 `/workspace` 아래의 전용 Agent Home을 자유롭게 읽고 쓸 수 있지만, 다른 Agent와 Worker 인스턴스, 캐시 디스크, 자격 증명을 절대 공유하지 않습니다. 반면 Pod Applet 백엔드 함수와 AIGateway 및 Workflow의 프로그래밍 방식 도구 호출(PTC) 스크립트는 Agent Computer Worker가 아니라 무상태 `ankole-function-runtime` 격리 환경(isolate)에서 실행됩니다.

## 셸 명령

Agent는 `app/agent_computer/src/tools/computer/command-tool.ts`에 구현된 `command` 도구를 통해 셸 명령을 실행합니다. 각 명령은 Worker 자체 자격 증명이 제거된 깨끗한 환경 변수를 받아 독립된 프로세스 그룹에서 실행되며, 명령이 취소되거나 제한 시간을 초과하면 해당 프로세스 그룹 전체가 함께 종료됩니다. 포그라운드 실행 제한 시간의 기본값은 180초이며 작업 디렉터리는 반드시 Agent Home 내부여야 합니다. [브라우저 자동화](../browser-automation/) 데몬과 Codex app-server, Automation 스크립트 역시 동일한 일반 사용자 권한으로 동작하므로 Worker 컨테이너에 별도의 특권 커널 권한을 부여할 필요가 없습니다.

모든 명령은 `sudo` 없이 `uid 1000`으로 실행됩니다. 따라서 Agent Home에 파일을 쓰고 사용자 수준 패키지를 설치하거나 하위 프로세스를 띄울 수는 있지만, 운영체제 시스템 패키지를 전역 설치할 수는 없습니다. 동일한 Agent에 속한 대화 Session과 백그라운드 Job은 같은 Agent Home 파일시스템을 볼 수 있습니다. 다른 Agent와의 격리는 컨테이너 인스턴스 경계가 담당하며, Worker 내부에는 데이터베이스 연결 정보나 객체 스토리지 원본 자격 증명이 존재하지 않습니다.

## 파일 읽기와 apply_patch

셸 명령 외에도 컴퓨터 도구 세트는 두 가지 전용 파일 조작 도구를 함께 제공합니다.

- **파일 읽기(`read_file`)** — `read-file-tool.ts`에 구현되어 있으며, `cat` 같은 셸 명령을 거치지 않고 파일 내용을 직접 읽어 옵니다.
- **파일 편집(`apply_patch`)** — `apply-patch-tool.ts`에 구현되어 있으며, 고정된 Codex 릴리스와 동일한 패치 문법을 받는 자유 형식 편집 도구입니다.

Main Agent가 원시 패치 텍스트를 `custom_tool_call` 형태로 AIGateway에 보내면 Worker가 이를 `/usr/local/bin/apply_patch`에 있는 네이티브 Codex 바이너리로 전달해 반영합니다. Background Agent Job 역시 AIGateway 모델 카드에서 동일한 자유 형식 도구 정의를 받아 같은 네이티브 바이너리를 실행합니다.

이처럼 두 경로가 동일한 편집 도구를 공유하므로 일반 대화와 Background Agent Job 어디에서든 일관된 파일 수정 프로토콜이 유지됩니다. 패치 문맥이 현재 파일 내용과 어긋나면 네이티브 바이너리가 적용을 거부하고 구체적인 실패 원인을 모델에 돌려줍니다. 빠른 문자열 검색 등에는 셸 명령을 쓰고, 실제 파일 수정에는 `apply_patch`를 사용하세요.

## /workspace 파일 시스템

Agent Home은 `/workspace`에 마운트되는 영구 스토리지이며 `/agents/<agent_uid>`는 `/workspace`를 가리키는 심볼릭 링크입니다. 경로 유효성을 검사할 때는 먼저 심볼릭 링크를 실제 경로로 해석한 뒤 Agent Home 경계 안에 속하는지 확인합니다. 기본 디렉터리 구조는 다음과 같습니다.

```text
/workspace/
├── .codex/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── ConfidentialityPolicy.md
├── installed-skills/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── AGENTS.md
    └── temp/
```

루트의 `SOUL.md`, `MISSION.md`, `DESIGN.md`, `ConfidentialityPolicy.md`는 [Agent Library](../agent-library/)에서 관리하는 네 가지 영구 문서입니다. 앞의 두 문서는 책임 범위와 행동 원칙을 정의하고, `DESIGN.md`는 시각 산출물용 디자인 시스템을 담으며, `ConfidentialityPolicy.md`는 Agent가 Brain에 지식을 기록할 때 공개 범위(audience scope)를 판단하는 기밀 유지 기준을 정의합니다. `installed-skills/`에는 설치된 Agent Skill이 동기화되고, `sessions/`에는 PostgreSQL이 `10000`부터 부여하는 고정 숫자 ID별 대화 워크스페이스가 놓이며, `jobs/`에는 개별 Background Agent Job 전용 워크스페이스가 생성됩니다.

Agent Home은 인스턴스가 삭제되거나 컨테이너 이미지가 업그레이드되어도 그대로 유지되며, 환경 재구축 시에는 `/var/cache/ankole` 캐시만 초기화됩니다. 단, Docker 로컬 볼륨은 호스트 디스크에 종속되고 Cloudflare 환경에서는 강제 종료 시 마지막 R2 백업 이후의 쓰기가 유실될 수 있으므로 플랫폼별 제약은 [Worker](../worker-management/) 문서를 참조하세요.

대화 첨부 파일, 외부 게시 파일, Skill 번들, Automation 스크립트는 컨트롤 플레인 드라이브에 별도로 보관됩니다. 드라이브 파일을 읽거나 게시할 때는 `ankole-files`를 사용하고, 컨트롤 플레인을 통해 Pod 페이지·Base 테이블·Applet을 읽거나 수정할 때는 `ankole-pod`를 사용합니다. 반면 Job 작업 공간과 Codex 스레드 데이터는 영구 Home에 남으며, 매 Turn이 시작되기 전에 `installed-skills/`가 드라이브 상태와 동기화됩니다.

Background Agent Job에서는 필요한 시점에 `skill_view`를 호출해 Skill 지침을 로드합니다.

## 반복 Python을 위한 Jupyter 라이브 커널

여러 단계에 걸쳐 메모리 상의 변수를 유지해야 하거나 DataFrame을 셀 단위로 살펴보고 상태 유지형 REPL로 탐색해야 하는 반복 Python 분석에는 단발성 셸 실행이 알맞지 않습니다. 이럴 때는 기본 활성화된 내장 스킬(`default_enabled: true`)인 `jupyter-live-kernel`을 사용합니다. 이 스킬은 `hamelnb`를 감싼 Ankole 전용 Unix 소켓 어댑터 위에서 [Background Agent Job](../background-jobs/)으로 실행되며, 호출 간에도 Python 커널 프로세스가 살아 있어 앞 단계에서 적재한 대용량 데이터와 변수를 다음 단계에서 다시 읽지 않고 바로 이어 쓸 수 있습니다.

선택 기준은 스킬 지침에 정리된 그대로입니다. 짧고 상태를 남기지 않는 일회성 Python 스크립트는 일반 셸에서 바로 실행하고, 평소 사람이 Jupyter 노트북이나 대화형 Python REPL을 열었을 법한 데이터 분석·DataFrame 점검·노트북 편집·상태 기반 API 탐색 작업에는 `jupyter-live-kernel` 스킬을 사용하세요. 시스템 Python과 JupyterLab, `ipykernel`, `hamelnb` 헬퍼가 워커 이미지에 기본 설치되어 있어 새로 만든 Agent에서도 별도 패키지 설치 없이 즉시 사용할 수 있습니다.

## Background Agent Job을 위한 CodexRunner

모든 Background Agent Job의 실행 엔진은 CodexRunner입니다. 자료 조사, 보고서 작성, 코드 저장소 수정 등 어떤 주제의 장기 업무든 모두 CodexRunner가 구동합니다. 즉, 소프트웨어 코딩 과제일 때만 선택되는 것이 아니라 장기 실행과 중단 복구라는 수명 주기 특성 때문에 모든 백그라운드 Job이 이 엔진을 사용합니다. CodexRunner는 `app-server-client.ts`를 통해 로컬 Codex app-server와 통신하며 독립된 Job 워크스페이스와 런타임 구성을 준비합니다.

Console UI에서는 이 백그라운드 전용 모델 프로필을 **Background Agent Jobs**라고 표시하며, 데이터베이스 저장 키와 API 필드 이름은 `coding`을 사용합니다.

## 이 경로들이 선택되는 방식

운영자가 관리해야 할 설정 지점은 간결합니다.

- **Computer tools**(`command`, `read_file`, `apply_patch`)는 모든 Worker에 기본 탑재되어 일반 대화 턴에서 바로 사용됩니다.
- **Jupyter live kernel**은 `default_enabled` 내장 스킬이므로 [Agent Library](../agent-library/)에서 [브라우저 자동화](../browser-automation/) 스킬과 동일한 방식으로 제어합니다. 대화형 Python 실행을 허용하지 않을 Agent에서는 해당 스킬을 비활성화하세요.
- **CodexRunner**는 모든 Background Agent Job을 구동하며 모든 모델 호출은 AIGateway를 거칩니다. 백그라운드 작업에 별도의 모델이나 제공자를 지정하려면 **Background Agent Jobs** 프로필을 설정하고, 비워 두면 컨트롤 플레인이 해당 Agent의 `heavy` 프로필을 대신 사용합니다.

## 다음 단계

- 이 도구들을 실행하고 `/workspace` 파일시스템을 관리하는 런타임 구조는 [Agent Computer Worker](../agent-computer-worker/)를 참조하세요.
- Jupyter 스킬을 비롯한 스킬 카탈로그와 활성화 모델은 [Agent Library](../agent-library/)를 참조하세요.
- 내부 키가 `coding`인 백그라운드 전용 모델 프로필 설정은 [Background Agent Jobs](../background-jobs/#모델-provider-선택)를 참조하세요.
- Worker의 격리 경계와 보안 강화 방안은 [Security hardening](../security-hardening/)을 참조하세요.
