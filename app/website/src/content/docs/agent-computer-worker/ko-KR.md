---
title: Agent Computer Worker
description: 환경 도구, Codex, 영구 Home 및 control plane 교체 후 복구.
section: Developer guide
order: 108
---

Agent Computer Worker는 개별 Agent에게 할당되는 전용 컴퓨터 환경입니다. Agent를 처음 생성할 때는 선택한 provider와 아직 시작되지 않은(`absent`) Worker 행만 데이터베이스에 기록되며, 이후 환경 도구나 Codex 실행이 처음으로 필요해질 때 control plane이 인스턴스를 기동합니다. 단순 질의응답이나 control plane 도구 호출은 Worker 없이도 바로 처리됩니다.

## 실행과 소유권

Bun 기반 Worker는 셸 명령, 파일 및 브라우저 도구, Skill, MCP 호출, Codex Job을 실행합니다. 반면 주 Agent loop와 입력 완료 처리, 도구 결과 커밋, 최종 응답 생성은 control plane의 `Ankole.Sessions`가 담당하며, 영구 Response 체인과 hosted 도구는 AIGateway가 관리합니다.

control plane은 Worker를 시작할 때 `WORKER_ID`, RuntimeFabric URL, generation 자격 증명, 스토리지 설정을 전달합니다. 각 Worker는 지정된 단일 Agent의 작업만 처리하며, 자식 프로세스를 실행할 때 환경 변수에서 자격 증명을 제거하고 데이터베이스에도 직접 연결하지 않습니다. `root` 슈퍼바이저(`ankole-worker-supervisor`와 `root` 전용 `ankole-rclone` 데몬)는 각 실행의 전용 마운트 및 PID 네임스페이스를 구성할 때만 `/dev/fuse`와 `SYS_ADMIN`을 사용하며, 모든 명령과 Codex 자식 프로세스는 빈 Linux capability(`NoNewPrivs`, `sudo` 없음) 상태의 `uid 1000` / `gid 1000`으로 권한을 낮춰 실행합니다.

## WorkerProvider와 실시간 연결

Agent에 할당된 `WorkerProvider`(`WorkerProviders`)에 따라 사용할 플랫폼, 인스턴스 사양, 스토리지 백엔드가 결정됩니다. 여러 Agent가 동일한 `WorkerProvider`를 공유하더라도 플랫폼에서는 Agent마다 독립된 전용 컴퓨터를 생성합니다. 또한 유휴 상태인 인스턴스를 일시 중지하거나 삭제하더라도 영구 Home 데이터는 그대로 보존됩니다. 자세한 설정과 수명 주기 규칙은 [WorkerProvider](../worker-management/)를 참조하세요.

기동된 Worker는 `/runtime-fabric/worker/websocket`으로 인증된 단일 WebSocket 연결을 열고 전용 Phoenix Channel에 접속합니다. 이후 환경 도구 호출과 실행 결과, Codex 제어 명령 및 진행 상황은 모두 RuntimeFabric protobuf envelope에 실려 오갑니다. control plane은 generation과 incarnation 번호를 검사하여 이미 교체된 이전 Worker의 연결이나 메시지를 거부합니다. 대용량 파일 바이트는 일회성 HTTP relay URL을 통해 전송하며, 복구에 필요한 영구 상태는 PostgreSQL에 기록합니다.

## 작업 식별과 복구

환경 작업의 `RunRef`에는 대상 Agent, Session, 시작 입력이 담기며, 개별 도구 호출은 Response ID와 call ID의 조합으로 식별합니다. Driver가 새로 시작되면 기존 workspace를 조회하여 실행 중인 호출을 이어받거나 이미 완료된 결과를 회수합니다. control plane과의 연결이 일시적으로 끊기더라도 Worker 내부에서 실행 중인 명령은 중단되지 않습니다. 만약 Worker 프로세스 자체가 유실되면 재실행해도 안전한 호출만 자동으로 재시도하고, 부수 효과 여부를 확인할 수 없는 호출에는 `interrupted`를 반환합니다.

Codex 작업은 Job ID와 attempt 번호가 담긴 `JobTurnRef`로 식별합니다. 재연결 시 `adopt` 요청을 보내면 실행 중이던 turn, thread, workspace를 중단 없이 그대로 이어받습니다. Job owner는 attempt 펜스를 검증해 유효한 종료 쓰기만 수락하고, 반영된 입력 ID들의 완료 처리를 단일 트랜잭션으로 커밋합니다. 이때 모델 추론 루프는 Codex가 Worker 내부에서 자체적으로 유지합니다.

열려 있는 환경 workspace 하나와 실행 중인 Codex turn 하나는 각각 Worker slot을 1개씩 점유합니다. 반면 일반 대화나 Workflow의 모델 호출은 Worker slot을 소비하지 않습니다.

## 파일시스템 계약

Agent Home은 `/workspace`에 마운트되는 영구 스토리지이며(`/agents/<agent_uid>`는 `/workspace`를 가리키는 심볼릭 링크), FUSE를 지원하는 Worker에서는 각 실행의 전용 마운트 네임스페이스 안에 통합 드라이브가 `/drive`로 마운트됩니다.

```text
/workspace/
├── .codex/
├── AGENTS.md
├── DESIGN.md
├── .ankole/turn-skills/<job-signal-id>/
├── sessions/<workspace-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── AGENTS.md
    └── temp/

/drive/
├── Public/        (읽기·쓰기)
├── MyDrive/       (읽기·쓰기, Personal Assistant 소유자 개인 공간)
├── AgentDrive/    (읽기·쓰기)
├── ChatDrive/     (읽기·쓰기, 활성 대화 범위 격리)
├── Brain/         (읽기 전용, 공개 범위 필터 적용)
├── Skills/        (읽기 전용)
├── AGENTS.md      (읽기 전용)
└── DESIGN.md      (읽기 전용)
```

`/drive` 아래에서 `Ankole.Files.Vfs`는 읽기·쓰기가 가능한 `/drive/Public`, `/drive/MyDrive`(Personal Assistant로 동작할 때), `/drive/AgentDrive`, 대화별로 격리된 `/drive/ChatDrive`와 함께 [Agent Library](../agent-library/)에 기반한 읽기 전용 `/drive/Brain`, `/drive/Skills`, `/drive/AGENTS.md`, `/drive/DESIGN.md`를 노출합니다. 백그라운드 VFS 쓰기 반영 중 `412` 또는 `422` 충돌이 발생하면 해당 범위의 `/drive-recovery` 디렉터리에 초안 바이트를 보존하며, 시작 시점 프로브에서 FUSE를 마운트할 수 없는 Worker에서는 `ankole-files` CLI로 드라이브 파일을 주고받습니다([파일 관리](../file-management/) 참조). `~/AGENTS.md`, `~/DESIGN.md`, `$CODEX_HOME/AGENTS.md` 역시 매 턴 유효 규약을 반영하며, Background Agent Job은 승인된 패키지를 `.ankole/turn-skills/<signal-id>/`에 배치합니다(초기 허용 목록은 권한 회수로 줄어들 수는 있어도 실행 중 늘어나지 않습니다). `sessions/`에는 PostgreSQL이 `10000`부터 부여하는 고정 숫자 ID별 대화 작업 공간을, `jobs/`에는 프로젝트 자체 지침 파일을 포함한 작업 공간을 둡니다.

Agent Home은 인스턴스가 삭제되거나 컨테이너 이미지가 교체되어도 유지되며, 환경을 재구축할 때는 `/var/cache/ankole`만 비워집니다. 단, Docker 로컬 볼륨은 호스트 디스크에 종속되고, Cloudflare 환경에서는 인스턴스가 강제 종료될 경우 마지막 R2 백업 이후의 쓰기가 유실될 수 있습니다. 플랫폼별 제약 사항은 [Worker](../worker-management/)를 참조하세요.

원본 Codex 스레드 파일은 `/workspace/.codex`에 영구 보존되는 반면, `AgentCodexRuntime`은 활성 Codex 런타임 항목과 `CODEX_HOME`, `/var/cache/ankole/codex` 아래의 재구축 가능한 SQLite 캐시를 실행 뷰(대화 신원을 포함하여 `ChatDrive` 및 공개 마운트가 뷰별로 분리됨) 단위로 구분해 관리합니다. 컨테이너 교체로 SQLite 캐시가 비워지더라도 `/workspace/.codex`에서 스레드를 복구해 이어 갈 수 있으며, Background Job에서는 `skill_view`를 통해 필요한 Skill을 로드합니다.

## 진행 상황과 용량

주 루프의 스트리밍 출력과 도구 실행 상태 표시는 Driver가 담당하며, Worker는 환경 도구 결과와 Codex 진행 상황을 RuntimeFabric을 통해 전달합니다. 실시간 진행 상황 전송은 최선형(best-effort)으로 동작하며, 장애 복구는 언제나 PostgreSQL에 커밋된 완료 기록과 저장된 결과를 기준으로 이루어집니다.

Worker는 주기적인 heartbeat를 통해 활성 workspace 수, 실행 중인 Codex turn 수, 남은 slot 수를 보고합니다. 이후 유휴 상태가 지속되면 control plane이 provider YAML의 `idleReleaseAfter` 설정에 따라 유휴 인스턴스를 회수하며, 이 값을 `never`로 지정하면 인스턴스를 종료하지 않고 계속 유지합니다. 일시적인 네트워크 단절 후 재연결될 때는 기존 프로세스 incarnation과 진행 중인 작업이 그대로 보존됩니다.

단일 writer 보장과 작업 펜스는 [Sessions](../sessions/), 영구 Response 체인은 [AIGateway](../ai-gateway/), Skill 관리는 [Agent Library](../agent-library/), provider 상태 관리는 [Workers](../worker-management/)를 참조하세요.
