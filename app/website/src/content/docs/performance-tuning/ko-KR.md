---
title: 성능 튜닝
description: Worker slot, 모델 동시 실행, DB pool, Job 상한 및 idle 회수.
section: Guides
order: 319
---

주 대화와 Workflow 모델 호출은 control plane에서 실행됩니다. 질문만으로 Worker를 시작하지 않습니다. Worker 용량은 열린 환경 workspace와 실행 중 Codex turn을 셉니다. slot 수는 모든 대화의 동시 실행 상한이 아닙니다.

## 용량 owner

Driver는 모델이나 도구를 기다리는 동안 DB 연결을 반환합니다. 모델 동시 실행, provider quota, Worker slot과 DB query 동시 실행은 별도 상한입니다. 모든 control plane replica의 pool 합계를 Postgres 연결 예산보다 낮게 두고 관리와 다른 서비스용 연결도 확보하세요. pool checkout 대기를 측정한 뒤 조정하세요.

| 노브 | 기본값 | 상한 대상 |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_SLOTS` | 배포 seed에서 12(설정하지 않으면 9) | 한 Agent의 open 환경 workspace와 running Codex turn |
| `ANKOLE_DATABASE_POOL_SIZE` | 10 | 제어 플레인 데이터베이스 연결 풀 |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | Postgres `max_connections`(번들 서버) |
| `max_running_per_agent` | 3 | 에이전트당 최대 3개의 실행 중 백그라운드 Job |
| `idleReleaseAfter` | Docker / Kubernetes: `never`; Cloudflare / Vercel / Lambda / Function Compute: `15m` | Worker가 멈추고 CPU와 메모리를 해제하기까지의 유휴 시간 |

## 대기 중인 경계를 조정하기

- provider 용량을 기다리는 모델 요청은 provider quota와 credential을 확인합니다.
- `no_worker_capacity`를 기다리는 환경 도구에는 빈 slot이 필요합니다. 상한을 늘리기 전에 유지된 workspace의 실행 중 명령을 확인하세요.
- queued Background Job은 Agent Job 상한이나 Worker 용량을 기다릴 수 있습니다. Worker slot을 늘려도 Job 상한은 바뀌지 않습니다.
- DB checkout 지연은 모든 replica의 pool과 Postgres 용량을 확인합니다.

provider YAML 변경은 idle Worker를 교체할 때 적용됩니다. 기존 generation은 저장된 설정을 유지합니다. `idleReleaseAfter`는 idle resource를 회수하고 영구 Home은 provider storage에 남습니다.

[Workers](../worker-management/), [Background Jobs](../background-agent-jobs/), [cost management](../cost-management/)도 참조하세요.
