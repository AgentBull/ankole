---
title: Agent Computer Worker
description: 환경 도구, Codex, 영구 Home 및 control plane 교체 후 복구.
section: Developer guide
order: 108
---

Agent Computer Worker는 개별 Agent에게 할당되는 전용 컴퓨터 환경입니다. Agent를 처음 생성할 때는 선택한 provider와 아직 시작되지 않은(`absent`) Worker 행만 데이터베이스에 기록되며, 이후 환경 도구나 Codex 실행이 처음으로 필요해질 때 control plane이 인스턴스를 기동합니다. 단순 질의응답이나 control plane 도구 호출은 Worker 없이도 바로 처리됩니다.

## 실행과 소유권

Bun 기반 Worker는 셸 명령, 파일 및 브라우저 도구, Skill, MCP 호출, automation script, Codex Job을 실행합니다. 반면 주 Agent loop와 입력 완료 처리, 도구 결과 커밋, 최종 응답 생성은 control plane의 `Ankole.Sessions`가 담당하며, 영구 Response 체인과 hosted 도구는 AIGateway가 관리합니다.

control plane은 Worker를 시작할 때 `WORKER_ID`, RuntimeFabric URL, generation 자격 증명, 스토리지 설정을 전달합니다. 각 Worker는 지정된 단일 Agent의 작업만 처리하며, 자식 프로세스를 실행할 때 환경 변수에서 자격 증명을 제거하고 데이터베이스에도 직접 연결하지 않습니다. 컨테이너 자체가 Agent 간 격리 경계 역할을 하며, 내부 명령은 `sudo` 권한 없이 `uid 1000`으로 실행됩니다.

## Worker pool과 실시간 연결

Agent에 지정된 Worker provider에 따라 사용할 pool, 플랫폼, 인스턴스 사양, 스토리지가 결정됩니다. 여러 Agent가 동일한 pool을 공유하더라도 플랫폼에서는 Agent마다 독립된 전용 컴퓨터를 생성합니다. 또한 유휴 상태인 인스턴스를 일시 중지하거나 삭제하더라도 영구 Home 데이터는 그대로 보존됩니다. 자세한 설정과 수명 주기 규칙은 [Worker pool](../worker-management/)을 참조하세요.

기동된 Worker는 `/runtime-fabric/worker/websocket`으로 인증된 단일 WebSocket 연결을 열고 전용 Phoenix Channel에 접속합니다. 이후 환경 도구 호출과 실행 결과, Codex 제어 명령 및 진행 상황은 모두 RuntimeFabric protobuf envelope에 실려 오갑니다. control plane은 generation과 incarnation 번호를 검사하여 이미 교체된 이전 Worker의 연결이나 메시지를 거부합니다. 대용량 파일 바이트는 일회성 HTTP relay URL을 통해 전송하며, 복구에 필요한 영구 상태는 PostgreSQL에 기록합니다.

## 작업 식별과 복구

환경 작업의 `RunRef`에는 대상 Agent, Session, 시작 입력이 담기며, 개별 도구 호출은 Response ID와 call ID의 조합으로 식별합니다. Driver가 새로 시작되면 기존 workspace를 조회하여 실행 중인 호출을 이어받거나 이미 완료된 결과를 회수합니다. control plane과의 연결이 일시적으로 끊기더라도 Worker 내부에서 실행 중인 명령은 중단되지 않습니다. 만약 Worker 프로세스 자체가 유실되면 재실행해도 안전한 호출만 자동으로 재시도하고, 부수 효과 여부를 확인할 수 없는 호출에는 `interrupted`를 반환합니다.

Codex 작업은 Job ID와 attempt 번호가 담긴 `JobTurnRef`로 식별합니다. 재연결 시 `adopt` 요청을 보내면 실행 중이던 turn, thread, workspace를 중단 없이 그대로 이어받습니다. Job owner는 attempt 펜스를 검증해 유효한 종료 쓰기만 수락하고, 반영된 입력 ID들의 완료 처리를 단일 트랜잭션으로 커밋합니다. 이때 모델 추론 루프는 Codex가 Worker 내부에서 자체적으로 유지합니다.

열려 있는 환경 workspace 하나와 실행 중인 Codex turn 하나는 각각 Worker slot을 1개씩 점유합니다. 반면 일반 대화나 Workflow의 모델 호출은 Worker slot을 소비하지 않습니다.

## 파일시스템 계약

Agent Home은 `/workspace`에 마운트되는 영구 스토리지이며, `/agents/<agent_uid>`는 `/workspace`를 가리키는 심볼릭 링크입니다. 경로를 검증할 때는 먼저 심볼릭 링크를 실제 경로로 해석한 뒤 Agent Home 경계 내부에 속하는지 확인합니다. 디렉터리 구조는 다음과 같습니다.

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

모델에는 컨테이너 내부의 절대 경로가 그대로 노출됩니다. Worker는 경로를 별도로 변환하지 않으며, 모든 명령의 작업 디렉터리는 반드시 Agent Home 내부여야 합니다. 루트에 놓이는 `SOUL.md`와 `MISSION.md`는 Agent의 행동 원칙과 책임을 정의하고, `DESIGN.md`는 시각 산출물용 디자인 시스템을 담으며, `ConfidentialityPolicy.md`는 Brain에 지식을 기록할 때 공개 범위를 판단하는 기준을 안내합니다. 이 네 문서는 모두 [Agent Library](../agent-library/)에서 관리합니다. `installed-skills/`, `sessions/`, `jobs/` 하위에는 각각 설치된 Skill, 대화별 workspace, Background Agent Job별 workspace가 위치하며, PostgreSQL은 각 Session에 `10000`부터 시작하는 고유 숫자형 workspace ID를 부여합니다.

Agent Home은 인스턴스가 삭제되거나 컨테이너 이미지가 교체되어도 유지되며, 환경을 재구축할 때는 `/var/cache/ankole`만 비워집니다. 단, Docker 로컬 볼륨은 호스트 디스크에 종속되고, Cloudflare 환경에서는 인스턴스가 강제 종료될 경우 마지막 R2 백업 이후의 쓰기가 유실될 수 있습니다. 플랫폼별 제약 사항은 [Worker](../worker-management/)를 참조하세요.

첨부 파일, 게시된 파일, Skill 번들, Automation 스크립트는 control plane 드라이브에 별도로 저장되며 `ankole-files` 도구로 읽고 씁니다. 반면 Job 작업 공간과 Codex 스레드 데이터는 영구 Home에 남습니다. 각 Turn이 시작되기 전에 `installed-skills/` 디렉터리는 드라이브 상태와 동기화됩니다.

Codex Home 경로는 `/workspace/.codex`입니다. 스레드 원본 파일이 영구 Home에 보존되므로, 컨테이너 교체로 `/var/cache/ankole/codex`의 SQLite 캐시가 초기화되더라도 캐시를 재구축해 작업을 이어 갈 수 있습니다. Background Job에서는 `skill_view`를 통해 필요한 Skill을 로드합니다.

## 진행 상황과 용량

주 루프의 스트리밍 출력과 도구 실행 상태 표시는 Driver가 담당하며, Worker는 환경 도구 결과와 Codex 진행 상황을 RuntimeFabric을 통해 전달합니다. 실시간 진행 상황 전송은 최선형(best-effort)으로 동작하며, 장애 복구는 언제나 PostgreSQL에 커밋된 완료 기록과 저장된 결과를 기준으로 이루어집니다.

Worker는 주기적인 heartbeat를 통해 활성 workspace 수, 실행 중인 Codex turn 수, 남은 slot 수를 보고합니다. 이후 유휴 상태가 지속되면 control plane이 provider YAML의 `idleReleaseAfter` 설정에 따라 유휴 인스턴스를 회수하며, 이 값을 `never`로 지정하면 인스턴스를 종료하지 않고 계속 유지합니다. 일시적인 네트워크 단절 후 재연결될 때는 기존 프로세스 incarnation과 진행 중인 작업이 그대로 보존됩니다.

단일 writer 보장과 작업 펜스는 [Sessions](../sessions/), 영구 Response 체인은 [AIGateway](../ai-gateway/), Skill 관리는 [Agent Library](../agent-library/), provider 상태 관리는 [Workers](../worker-management/)를 참조하세요.
