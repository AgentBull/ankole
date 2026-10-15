---
title: Agent Computer Worker
description: 환경 도구, Codex, 영구 Home 및 control plane 교체 후 복구.
section: Developer guide
order: 108
---

Agent Computer Worker는 한 Agent 자신의 컴퓨터입니다. Agent 생성 시 provider 선택과 absent Worker 행만 저장합니다. 환경 도구나 Codex가 처음 필요할 때 control plane이 시작합니다. 질문과 control plane 도구는 Worker 없이 작동합니다.

## 실행과 소유권

Bun Worker는 명령, 파일과 브라우저 도구, Skills, MCP 호출, automation script, Codex Job을 실행합니다. control plane의 `Ankole.Sessions`는 주 Agent loop, 입력 완료와 도구 결과 커밋, 최종 응답을 소유합니다. AIGateway는 영구 Response 체인과 hosted 도구를 소유합니다.

control plane은 `WORKER_ID`, RuntimeFabric URL, generation 자격 증명과 저장 설정을 제공합니다. Worker는 자신의 Agent만 처리하고 자식 프로세스 환경에서 자격 증명을 제거하며 데이터베이스에 연결하지 않습니다. 컨테이너가 Agent의 격리 경계입니다. 명령은 sudo 없이 uid 1000으로 실행됩니다.

## Worker pool과 실시간 연결

Agent에 저장한 Worker provider가 pool, 플랫폼, 인스턴스 설정과 스토리지를 선택합니다. 여러 Agent가 같은 pool을 사용할 수 있지만 플랫폼은 Agent마다 전용 컴퓨터를 만듭니다. 유휴 시 인스턴스를 삭제하거나 일시 중지해도 Home은 유지합니다. 설정과 수명 주기 규칙은 [Worker pool](../worker-management/)을 참조하세요.

Worker는 `/runtime-fabric/worker/websocket`에 인증된 WebSocket 하나를 열고 전용 Phoenix Channel에 참여합니다. RuntimeFabric protobuf envelope는 환경 호출, 결과, Codex 제어와 진행 상황을 전달합니다. generation과 incarnation 검사로 교체된 Worker를 거부합니다. 파일 바이트는 일회성 HTTP relay URL로 전달하며 영구 복구 사실은 PostgreSQL이 보관합니다.

## 작업 식별과 복구

환경 작업의 `RunRef`는 Agent, Session, 시작 입력을 지정합니다. 각 호출은 Response ID와 call ID로 식별합니다. 새 Driver는 기존 workspace를 조회하고 진행 중인 호출을 인계받거나 결과를 가져옵니다. control plane 연결이 끊겨도 명령은 계속됩니다. Worker 프로세스를 잃으면 안전한 호출만 재시도하고, 확인할 수 없는 다른 호출은 `interrupted`를 반환합니다.

Codex는 Job ID와 attempt를 포함하는 `JobTurnRef`를 사용합니다. `adopt` 요청은 동일한 실행 중 turn, thread, workspace를 유지합니다. Job owner는 attempt 펜스로 종결 쓰기를 수락하고 적용된 입력 ID를 한 트랜잭션에서 완료합니다. Codex는 자체 모델 loop를 유지합니다.

열린 환경 workspace와 실행 중인 Codex turn은 각각 Worker slot 하나를 사용합니다. 주 대화와 Workflow 모델 호출은 Worker slot을 사용하지 않습니다.

## 파일시스템 계약

Agent Home은 `/workspace`의 영구 스토리지입니다. 이전 경로 `/agents/<agent_uid>`는 Home으로 연결됩니다. 경로 검증은 심볼릭 링크를 해석한 다음 Home 경계를 확인합니다. 구조는 다음과 같습니다.

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

model은 절대 컨테이너 경로를 봅니다. Worker는 경로를 변환하지 않으며, 명령의 작업 디렉터리는 Agent Home 안에 있어야 합니다. `SOUL.md`와 `MISSION.md`는 Agent의 행동과 책임을 정의합니다. `DESIGN.md`는 시각 작업을 위한 디자인 시스템입니다. `ConfidentialityPolicy.md`는 Brain 쓰기의 공개 범위 선택을 안내합니다. [Agent Library](../agent-library/)가 네 문서를 모두 관리합니다. `installed-skills/`, `sessions/`, `jobs/`에는 Skill, 대화 workspace, Background Agent Job workspace가 들어 있습니다. PostgreSQL은 각 Session에 10000부터 시작하는 안정적인 숫자 workspace ID를 부여합니다.

Home은 인스턴스 삭제와 이미지 변경 후에도 유지됩니다. 재구축은 `/var/cache/ankole`만 삭제합니다. Docker 로컬 volume은 호스트에 의존하며 Cloudflare 강제 중지는 마지막 R2 백업 이후 쓰기를 잃을 수 있습니다. 제한은 [Worker](../worker-management/)를 참조하세요.

control plane 드라이브는 첨부 파일, 게시한 파일, Skill, Automation 스크립트를 따로 저장합니다. `ankole-files`로 읽고 씁니다. Job 작업 공간과 Codex 스레드는 영구 Home에 남습니다. Turn 전에 `installed-skills/`를 드라이브와 동기화합니다.

Codex Home은 `/workspace/.codex`입니다. 스레드 파일은 교체 후에도 유지되며 `/var/cache/ankole/codex`의 SQLite가 없어도 재개할 수 있습니다. Background Job은 `skill_view`로 Skill을 읽으며 Skill 루트를 작업 공간에 복사하지 않습니다.

## 진행 상황과 용량

Driver는 주 loop 스트리밍과 도구 표시를 소유합니다. Worker는 RuntimeFabric로 환경 결과와 Codex 진행 상황을 보냅니다. 진행 상황은 best effort이며, 복구는 PostgreSQL 완료 사실과 저장 결과에 의존합니다.

heartbeat는 active workspace, Codex turn과 빈 slot을 보고합니다. control plane은 provider YAML `idleReleaseAfter`로 idle instance를 회수합니다. `never`는 실행을 유지합니다. 재연결은 프로세스 incarnation과 진행 중인 작업을 보존합니다.

writer와 작업 펜스는 [Sessions](../sessions/), Responses는 [AIGateway](../ai-gateway/), Skills는 [Agent Library](../agent-library/), provider 상태는 [Workers](../worker-management/)를 참조하세요.
