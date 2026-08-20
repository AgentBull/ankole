---
title: 백업 및 복원
description: 반드시 백업해야 하는 두 가지 — PostgreSQL과 Agent Home — 의 백업 방법, 복원 방법, 그리고 테스트하지 않은 백업은 백업이 아닌 이유.
section: Guides
order: 315
---

Ankole 배포 인스턴스는 재구성할 수 없는 두 가지를 보관합니다: PostgreSQL 데이터베이스와 Agent Home 볼륨. PostgreSQL은 영구 컨트롤 플레인 상태를 저장합니다. Agent Home은 워크스페이스, 영구 Agent 문서, 설치된 Skill, 대화 및 Job 파일을 저장합니다.

핵심 속성을 먼저 명시합니다: 데이터베이스 마이그레이션은 이미지를 롤백해도 되돌릴 수 없다. 복원해 본 적 없는 백업은 백업이 아니라 희망입니다. 이 페이지의 핵심은 복원 단계입니다 — 의존하기 전에 별도 호스트에서 테스트하세요.

## 무엇을 백업하고 무엇을 백업하지 않을지

| 백업 대상 | 이유 | 방법 |
|---|---|---|
| **PostgreSQL** (Compose에서는 `ankole_postgresql_data`, Helm에서는 외부 서버) | 모든 영구 의미적 진실 | `pg_dump -Fc` 아카이브 |
| **Agent Home** (Compose에서는 `ankole_agents_data`, Helm에서는 RWX claim) | Agent별 워크스페이스, 영구 문서, 설치된 Skill, 대화 및 Job 파일 | Ankole을 중지한 상태에서 볼륨 스냅샷 또는 파일시스템 수준 백업 |

컨테이너 이미지는 **백업하지 마세요** — 레지스트리에서 재구축할 수 있다. Caddy 데이터나 임시 Worker 상태도 백업하지 마세요. 둘 다 다시 만들 수 없는 것을 담고 있지 않다. 그리고 둘 중 하나만 백업하지 마라 — PostgreSQL은 Agent Home의 파일을 참조하고, 그것을 가리키는 데이터베이스 행이 없는 Agent Home은 고아입니다.

## PostgreSQL 백업

커스텀 포맷 아카이브를 만드세요(복원 단계가 기대하는 형태다):

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

번들 PostgreSQL이 있는 Helm에서는 PostgreSQL pod에 `kubectl exec`로 들어가 같은 `pg_dump`를 실행하세요. 외부 PostgreSQL에서는 그 서버에 대해 실행하던 곳에서 `pg_dump`를 실행하세요 — 명령 형태는 같다.

업그레이드 전, 파괴적 작업(`kit app-db rebuild`, `docker compose down -v`) 전, 그리고 데이터 손실 허용도가 요구하는 주기마다 이 백업을 받으세요. 소규모 배포 인스턴스에서 일일 아카이브가 합리적인 기본값입니다.

## Agent Home 백업

Agent Home은 데이터베이스가 아니라 파일시스템입니다 — Ankole이 **중지된** 상태에서 백업하세요. 백업 중에 Worker가 쓰지 않도록:

```bash
# Compose: snapshot the named volume, or copy it while the stack is down
docker compose down
# take your volume snapshot or filesystem-level backup of ankole_agents_data
docker compose up -d
```

Helm에서 Agent Home은 RWX claim이며 StorageClass가 제공하는 스냅샷 메커니즘을 사용하세요. 파일시스템 수준 복사(rsync, restic, 클라우드 볼륨 스냅샷)는 모두 동작합니다. 일관적이기만 하면 된다 — 한 시점에 만든 것이지 writer와 경쟁하는 것이 아닙니다.

스택을 멈추는(또는 최소한 Worker를 quiesce하는) 이유는 백업 중에 파일을 쓰는 Worker가 찢어진 복사본을 만들기 때문입니다. PostgreSQL의 `pg_dump`는 트랜잭션 일관된 아카이브를 주지만 Agent Home에는 그런 보장이 없으므로 타이밍으로 제공해야 한다.

## PostgreSQL 복원

매번 먼저 별도 호스트에 복원하세요. 테스트하지 않은 복원은 인시던트에서 가장 비싼 자산입니다.

```bash
# on a test host with a fresh Ankole database
docker compose exec -T postgresql \
  pg_restore -U ankole -d ankole --clean --if-exists \
  < "ankole-YYYYMMDD.dump"
```

그다음 마이그레이션을 실행하여(`bun run control-plane:setup`을 로컬에서, 또는 Helm init 컨테이너가 수행) 스키마를 이미지 수준으로 올리세요. 마이그레이션 전에 받은 백업은 마이그레이션 전 스키마로 복원되기 때문입니다. 복원이 성공했음을 선언하기 전에 데이터 — Principal, Agent, 알려진 session — 가 기대한 대로인지 확인하세요.

## Agent Home 복원

스냅샷에서 볼륨을 같은 경로(Compose에서는 `ankole_agents_data`에서 마운트된 `/agents`, Helm에서는 RWX claim)로 복원하세요. 디렉터리 구조는 Agent 키별이므로 올바른 복원은 `/agents/<agent-key>/...`를 정확히 재현합니다. 데이터베이스 복원과 짝으로 하세요 — 데이터베이스 행은 Agent Home 아래의 파일을 참조하며, 짝이 맞지 않으면 살아 있는 것처럼 보이지만 없거나 오래된 파일을 가리키는 배포가 된다.

## 둘을 함께 테스트

README의 지침이 규칙입니다: “데이터베이스와 Agent Home 복원을 별도 호스트에서 함께 테스트하세요.” 둘은 짝입니다. 하나만 복원하는 것은 아무것도 증명하지 못합니다. 버리는 호스트에서 월간 주기로 — 어젯밤의 PostgreSQL과 Agent Home을 복원하고, 스택을 시작하고, 실제 turn 하나를 실행 — 이것이 백업과 희망의 차이입니다.

테스트 호스트에서 복원이 동작하면 프로덕션 백업은 진짜입니다. 동작하지 않으면 인시던트 중이 아니라 테스트 호스트에서 발견한 것입니다.

## 백업이 선택이 아닐 때

몇 가지 작업은 백업을 권고가 아니라 필수로 만든다:

- **모든 업그레이드** — 마이그레이션은 되돌릴 수 없다. 백업이 스키마의 유일한 롤백 경로입니다.
- **`kit app-db rebuild --yes`** — 로컬 `ankole_dev` 데이터베이스를 삭제합니다. 데이터를 실제로 버려도 되는 경우에만 실행하고, 조금이라도 중요하면 먼저 백업하세요.
- **`docker compose down -v`** — PostgreSQL과 Agent Home을 포함한 named volume을 삭제합니다. 이것은 재시작이 아니라 삭제입니다.
- **영구 상태에 영향을 줄 수 있는 모든 장애** — 수리하거나 롤백하기 전에 백업을 만드세요.

## 이 가이드가 아닌 것

백업 제품 추천이 아닙니다 — 이미 운영 중인 볼륨 스냅샷, restic, 클라우드 스냅샷 도구를 사용하세요. 복원 테스트의 대체재도 아닙니다 — 복원 단계가 전체의 핵심입니다. 그리고 관심 있는 부분만 백업하는 방법도 아닙니다 — PostgreSQL과 Agent Home은 짝이며, 부분 백업은 깨진 배포로 복원됩니다.

## 다음 단계

- 호스트 간 복구와 리허설은 [Disaster recovery](../disaster-recovery/)를 읽으세요.
- 이 볼륨들의 이름을 정하는 배포 구성은 [Quick start의 deployment 섹션](../quickstart/#deployment)을 읽으세요.
