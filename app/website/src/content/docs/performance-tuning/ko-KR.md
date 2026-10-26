---
title: 성능 튜닝
description: Worker slot, 모델 동시 실행, DB pool, Job 상한 및 idle 회수.
section: Guides
order: 319
---

주 대화와 Workflow 모델 호출은 control plane에서 실행됩니다. 질문만으로 Worker를 시작하지 않습니다. Worker 용량은 열린 환경 workspace와 실행 중 Codex turn을 셉니다. slot 수는 모든 대화의 동시 실행 상한이 아닙니다.

## 용량 owner

Driver는 모델이나 도구를 기다리는 동안 DB 연결을 반환합니다. 모델 동시 실행, provider quota, Worker slot과 DB query 동시 실행은 별도 상한입니다. 모든 control plane replica에 걸친 `Ankole.Repo`와 `Ankole.Pod.BaseRepo` 연결 풀 합계를 각 PostgreSQL 서버의 연결 예산보다 낮게 두고 관리 및 유지보수 연결도 확보하세요. `BASE_DB_URLS`가 설정되지 않은 단일 데이터베이스 배포에서는 `Ankole.Pod.BaseRepo`가 `Ankole.Repo`의 10개 연결 풀과 별도로 `DATABASE_URL`에 대한 10개 연결 풀을 열어 replica당 총 `20`개의 풀 연결을 사용합니다. `BASE_DB_URLS`가 전용 샤드 데이터베이스를 가리키면 각 샤드 서버의 `max_connections`를 `replica 수 × ankole_pool_size`에 맞춰 산정하세요. 풀 크기를 변경하기 전에 pool checkout 대기를 먼저 측정하세요.

| 노브 | 기본값 | 상한 대상 |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_SLOTS` | 배포 seed에서 12(설정하지 않으면 9) | 한 Agent의 open 환경 workspace와 running Codex turn |
| `POOL_SIZE`(Compose/Helm에서는 `ANKOLE_DATABASE_POOL_SIZE`) | 10 | replica당 `Ankole.Repo` 제어 플레인 데이터베이스 연결 풀 |
| `BASE_DB_URLS`(`ankole_pool_size`) | 샤드당 10(dev/test에서는 `2`) | replica당 각 `Ankole.Pod.BaseRepo` Base 샤드 연결 풀 |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | Postgres `max_connections`(번들 서버) |
| `agent_computer.background_agent_job.max_running_per_agent` | 3 | Agent당 동시 실행 Background Agent Job 최대 수(테넌트 범위) |
| `idleReleaseAfter` | 6개 공급자 모두 `15m`(`never`는 유휴 중지 비활성화) | Worker가 멈추고 CPU와 메모리를 해제하기까지의 유휴 시간 |

## 대기 중인 경계를 조정하기

- provider 용량을 기다리는 모델 요청은 provider quota와 credential을 확인합니다.
- `no_worker_capacity`를 기다리는 환경 도구에는 빈 slot이 필요합니다. 상한을 늘리기 전에 유지된 workspace의 실행 중 명령을 확인하세요.
- queued Background Job은 Agent Job 상한이나 Worker 용량을 기다릴 수 있습니다. Worker slot을 늘려도 Job 상한은 바뀌지 않습니다.
- DB checkout 지연은 모든 replica와 Base 샤드에 걸친 `Ankole.Repo` 및 `Ankole.Pod.BaseRepo` 풀과 PostgreSQL 용량을 확인합니다.

provider YAML 변경은 idle Worker를 교체할 때 적용됩니다. 기존 generation은 저장된 설정을 유지합니다. `idleReleaseAfter`는 idle resource를 회수하고 영구 Home은 provider storage에 남습니다.

[Workers](../worker-management/), [Background Jobs](../background-agent-jobs/), [cost management](../cost-management/)도 참조하세요.
