---
title: 성능 튜닝
description: 용량 노브 — 동시 턴, 데이터베이스 풀, Postgres 최대 연결, worker 턴 상한, 에이전트당 Job 슬롯 — 그리고 배포 인스턴스가 한 번에 처리할 수 있는 작업량을 결정하는 이들 사이의 관계.
section: Guides
order: 319
---

Ankole의 성능은 대부분 용량 문제입니다: 한 번에 몇 개의 턴이 실행되는지, 턴들이 얼마나 많은 데이터베이스 연결을 사용할 수 있는지, 그리고 에이전트가 몇 개의 Job을 병렬로 실행할 수 있는지가 그것입니다. 이 페이지는 노브의 이름과 기본값을 제시하고, 무엇보다 중요한 부분인 노브 간의 관계를 설명합니다. 다른 노브 없이 하나만 올리면 배포 인스턴스가 느려지거나 실패하기 때문입니다.

먼저 핵심 속성을 밝힙니다: 노브들은 체인을 이룹니다. 동시 턴은 데이터베이스 연결이 필요하고, 데이터베이스 연결은 Postgres가 상한을 정하며, Job 슬롯은 에이전트가 실행할 수 있는 턴을 배가합니다. 다른 노브 없이 하나만 올리면 체인은 가장 약한 고리에서 끊어집니다 — 턴이 대기열에 쌓이거나, 연결이 고갈되거나, Postgres가 연결을 거부합니다. 노브를 하나씩 튜닝하지 말고 부하의 형태에 맞춰 세트로 튜닝하세요.

## 용량 체인

턴은 제어 플레인(데이터베이스 풀 사용), worker(모델 루프 실행), Postgres(풀에 서비스 제공)를 거칩니다. 관계를 한 줄로 표현하면 다음과 같습니다:

```text
(concurrent turns) × (connections per turn)  ≤  database pool size  ≤  Postgres max_connections
```

모든 턴은 데이터베이스 작업을 수행하고, 모든 데이터베이스 연결은 Postgres에서 옵니다. 동시 턴 설정이 풀이 허용하는 것보다 많은 연결을 요구하면 턴은 풀에서 대기합니다. 풀 크기가 Postgres가 허용하는 것보다 많은 연결을 요구하면 연결이 거부됩니다. 기본값은 단일 소형 호스트에서 작동하도록 설정되어 있습니다. 확장은 이들을 함께 올리는 것을 의미합니다.

## 노브

| 노브 | 기본값 | 상한 대상 |
|---|---|---|
| `ANKOLE_MAX_CONCURRENT_TURNS` | 9 | worker(들)가 수용하는 동시 actor 턴 |
| `ANKOLE_DATABASE_POOL_SIZE` | 10 | 제어 플레인 데이터베이스 연결 풀 |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | 300 | Postgres `max_connections`(번들 서버) |
| `agent_computer.background_agent_job.max_turns_per_worker` | 설정 가능 | 백그라운드 Job의 worker당 턴 상한 |
| `max_running_per_agent` | 3 | 에이전트당 최대 3개의 실행 중 백그라운드 Job |

기본값(턴 9개, 풀 10, Postgres 300)은 보수적이며 단일 소형 호스트에 맞습니다. 튜닝의 문제는 배포 인스턴스가 그보다 바쁠 때 무엇을 얼마나 올릴지입니다.

## 증상에 맞춘 튜닝

증상마다 가리키는 노브가 다릅니다. 무언가를 돌리기 전에 증상을 먼저 읽으세요.

### “턴 시작이 느립니다”(대기열)

Worker 풀이 가득 차면 턴이 대기합니다. `ANKOLE_MAX_CONCURRENT_TURNS`는 Worker마다의 동시 턴 상한입니다. Console에 Worker를 기다리는 턴이 표시되면, 데이터베이스 풀에 여유가 있음을 확인한 후에만 용량을 추가하세요.

### “실행 중인 턴이 느립니다”(데이터베이스 포화)

데이터베이스 연결을 점유한 턴은 풀이 고갈되면 대기합니다. `ANKOLE_DATABASE_POOL_SIZE`를 올리되 Postgres가 허용하는 범위까지만 올리세요. 번들 Postgres는 기본적으로 300개 연결을 허용하며, 외부 서버는 자체 `max_connections`를 가집니다. 풀 크기가 Postgres의 한도에 근접하면 먼저 Postgres의 한도를 올린 다음(또는 번들 서버의 `ANKOLE_POSTGRES_MAX_CONNECTIONS`를 키우고) 풀을 올리세요.

### “백그라운드 Job이 대기합니다”(에이전트 슬롯 포화)

각 에이전트는 최대 `max_running_per_agent`(3)개의 Job을 동시에 실행합니다. 에이전트에 `running` 상태 Job이 3개 있고 `queued` 상태가 더 있다면, 제한 요소는 상한입니다 — worker도 풀도 아닙니다. 대기열을 받아들이거나 작업을 더 많은 에이전트로 분산하세요(각 에이전트는 자신만의 3개 슬롯을 가집니다). `max_running_per_agent`를 올리는 것은 거의 옳은 선택이 아닙니다. worker당 턴 상한(`max_turns_per_worker`)과 전역 턴 상한이 어차피 이를 가둡니다.

### “제공자 호출이 병목입니다”(Ankole 노브가 아님)

`/ai-gateway/conversations`에 모델 호출이 턴 시간의 대부분을 차지하는 것으로 표시되면, 병목은 Ankole이 아니라 제공자입니다. 어떤 용량 노브도 이를 고칠 수 없습니다 — 모델 측 레버(더 저렴한 `primary`, 더 낮은 `reasoning_effort`)는 [Cost management](../cost-management/)를 참조하세요. 이러한 레버는 턴을 더 빠르게 만들기도 합니다.

## 구체적 용량 산정 예시

더 바쁜 배포 인스턴스를 예로 들어 보겠습니다. 활성 Agent 5개가 각각 1~2개의 Job을 실행하고 채널에서 응답하는 경우:

- **동시 턴** — 이론적 최대치가 아니라 현실적 피크(15~20)에 맞춰 `ANKOLE_MAX_CONCURRENT_TURNS`를 올리세요.
- **데이터베이스 풀** — 풀이 대기 지점이 되지 않도록 `ANKOLE_DATABASE_POOL_SIZE`를 올리세요(이 부하에서 20~30).
- **Postgres** — `ANKOLE_POSTGRES_MAX_CONNECTIONS`(300)이 풀과 worker 자체 연결, 여유분을 합친 것보다 넉넉히 크도록 확인하세요. 대개 충분하지만, 외부 서버는 자체 `max_connections`를 올려야 할 수 있습니다.
- **에이전트당 Job 슬롯** — 3으로 유지하세요. 상한을 올리기보다 작업을 에이전트들에 분산하세요.

이 숫자들은 고정된 답이 아닙니다. 한 번에 하나의 상한만 변경하세요. 변경할 때마다 대기열, Background Agent Job 상태, 데이터베이스 지표를 비교하세요. 실제 피크를 처리할 수 있는 가장 작은 용량을 유지하세요.

## Worker 용량뿐 아니라 Worker 수

Kubernetes에서 worker는 수평 확장할 수 있는 Deployment입니다 — 각각 자체 `ANKOLE_MAX_CONCURRENT_TURNS`를 가진 worker pod를 더 늘리는 방식입니다. 용량 계산은 `worker pod 수 × worker당 턴 수`가 되며, 여전히 데이터베이스 풀과 Postgres에 의해 제한됩니다. Compose(단일 호스트)에서는 worker가 하나뿐이며, 확장은 호스트와 데이터베이스가 허용하는 범위까지 턴 상한을 올리는 것을 의미합니다.

단일 worker의 호스트가 한계일 때는 worker 수평 확장이 더 깔끔한 경로이고, 데이터베이스가 한계이고 호스트에 여유가 있을 때는 수직 확장(한 worker의 상한 올리기)이 더 깔끔한 경로입니다.

## 성능 튜닝이 아닌 것

성능 튜닝은 모든 상한을 최대로 설정하는 것을 의미하지 않습니다. 다음 레이어를 초과하는 용량은 병목을 옮길 뿐입니다. Console의 턴 및 Job 상태로 대기열을 식별한 다음 해당 레이어를 변경하세요. 더 높은 동시성은 더 많은 모델 호출과 데이터베이스 연결을 사용하므로 [Cost management](../cost-management/)도 검토하세요.

## 다음 단계

- 노브를 환경 변수로 보려면 [Environment variables](../environment-variables/)를 읽으세요.
- 턴 및 Job 엔드포인트에 대해서는 [Console API reference](../console-api/)를 읽으세요.
- 속도에도 영향을 주는 모델 측 레버에 대해서는 [Cost management](../cost-management/)를 읽으세요.
- 턴을 실행하는 worker에 대해서는 [Agent Computer Worker](../agent-computer-worker/)를 읽으세요.