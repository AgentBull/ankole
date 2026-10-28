---
title: 성능 튜닝
description: Worker slot, 모델 동시 실행, DB pool, Job 상한 및 idle 회수.
section: Guides
order: 319
---

주 대화와 Workflow 모델 호출은 control plane에서 실행되므로, 일반 질문만으로는 Worker가 시작되지 않습니다. Worker 용량은 열려 있는 환경 workspace 수와 실행 중인 Codex turn 수를 기준으로 계산하며, slot 수가 전체 대화의 동시 실행 상한을 뜻하지는 않습니다.

## 용량 owner

Driver는 모델 응답이나 도구 실행을 기다리는 동안 DB 연결을 풀에 반환하므로, 모델 동시 실행, provider 할당량(quota), Worker slot, DB 쿼리 동시 실행은 각각 독립된 상한으로 동작합니다. 모든 control plane replica에 걸친 `Ankole.Repo`와 `Ankole.Pod.BaseRepo` 연결 풀 합계가 각 PostgreSQL 서버의 연결 한도보다 여유 있게 낮도록 구성하고, 운영·유지보수용 연결 여유분도 남겨 두세요.

`BASE_DB_URLS`를 지정하지 않은 단일 데이터베이스 배포에서는 `Ankole.Pod.BaseRepo`가 `Ankole.Repo`의 기본 10개 연결 풀과 별도로 `DATABASE_URL`에 대해 10개짜리 연결 풀을 하나 더 열므로, replica당 총 `20`개의 풀 연결을 사용합니다. 반면 `BASE_DB_URLS`로 전용 샤드 데이터베이스를 분리한 경우에는 각 샤드 서버의 `max_connections`를 `replica 수 × ankole_pool_size` 기준으로 산정하세요. 풀 크기를 늘리기 전에는 실제로 pool checkout 대기가 발생하고 있는지부터 측정하는 것이 좋습니다.

| 설정 항목 | 기본값 | 제어 대상 |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_SLOTS` | 배포 seed 기준 12(미설정 시 9) | 단일 Agent의 열린 환경 workspace 수와 실행 중인 Codex turn 수 합계 |
| `POOL_SIZE`(Compose/Helm에서는 `ANKOLE_DATABASE_POOL_SIZE`) | 10 | replica당 `Ankole.Repo` control-plane 데이터베이스 연결 풀 크기 |
| `BASE_DB_URLS`(`ankole_pool_size`) | 샤드당 10(dev/test에서는 `2`) | replica당 각 `Ankole.Pod.BaseRepo` Base 샤드 연결 풀 크기 |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | 번들 PostgreSQL 서버의 `max_connections` |
| `background_agent_jobs.max_running_per_agent` | 3 | 테넌트 범위 내 Agent당 동시 실행 가능한 최대 Background Agent Job 수 |
| `idleReleaseAfter` | 6개 공급자 모두 `15m`(`never`로 유휴 중지 비활성화 가능) | Worker가 유휴 상태로 전환되어 중지되고 CPU·메모리를 반납하기까지의 대기 시간 |

## 대기 중인 경계를 조정하기

- 모델 요청이 provider 용량을 기다리며 지연된다면 provider 할당량(quota)과 자격 증명을 점검하세요.
- 환경 도구가 `no_worker_capacity` 상태로 대기 중이라면 빈 slot이 부족한 것입니다. 상한을 높이기 전에 기존 workspace에 종료되지 않은 채 실행 중인 명령이 남아 있는지 먼저 확인하세요.
- 대기열에 쌓인 Background Job은 Agent별 동시 실행 상한이나 Worker 용량 중 하나를 기다리고 있을 수 있습니다. Worker slot만 늘려서는 Agent별 Job 동시 실행 상한이 바뀌지 않습니다.
- DB 연결 checkout 지연이 나타나면 모든 replica와 Base 샤드에 걸친 `Ankole.Repo` 및 `Ankole.Pod.BaseRepo` 풀 크기와 PostgreSQL 서버의 연결 한도를 함께 확인하세요.

provider YAML 설정을 변경하면 유휴(idle) 상태의 Worker가 교체될 때 새 설정이 반영되며, 이미 실행 중인 generation은 기존에 저장된 설정을 유지합니다. 또한 `idleReleaseAfter` 시간이 지나 유휴 리소스가 회수되더라도 영구 Home 데이터는 provider 스토리지에 그대로 남습니다.

자세한 내용은 [Workers](../worker-management/), [Background Jobs](../background-agent-jobs/), [cost management](../cost-management/)를 참조하세요.
