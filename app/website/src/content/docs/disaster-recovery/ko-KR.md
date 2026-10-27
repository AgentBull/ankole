---
title: 재해 복구
description: Ankole 배포 복구 절차 — PostgreSQL, Base 샤드 데이터베이스, 파일 저장소, Agent Home, Function Runtime 및 배포 시크릿 복원과 복구 리허설 가이드를 안내합니다.
section: Guides
order: 320
---

재해 복구 시에는 컨트롤 플레인 PostgreSQL 데이터베이스, 전용 Pod Base 샤드 데이터베이스(`BASE_DB_URLS`를 구성한 경우), 파일 저장소, 영속 Agent Home, `ankole-function-runtime`, 그리고 원래 배포 시크릿을 하나의 배포 단위로 묶어 함께 복원해야 합니다. 보존 대상 데이터와 일관성 있는 백업 절차는 [백업 가이드](../backup-and-restore/)를 참조하세요.

## 복구 전

먼저 이전 컨트롤 플레인과 모든 Worker가 복원 대상 Home이나 데이터베이스에 쓰기를 수행할 수 없는 상태인지 확인하세요. 단순히 네트워크 연결이 끊겼다는 사실만으로는 Worker가 완전히 멈추었다고 단정할 수 없으며, 일시 중지된 인스턴스나 성공 여부를 알 수 없는 생성 요청까지 모두 중지 여부를 확인해야 합니다. 미확정(indeterminate) generation과 자격 증명은 PostgreSQL에 그대로 남겨 두어야 플랫폼에서 최종 상태를 돌려줄 때까지 동일한 generation 기준으로 조정을 이어 갈 수 있습니다.

복구 리허설은 반드시 격리된 플랫폼 리소스에서 진행하세요. 운영 프로바이더 위치가 그대로 기록된 데이터베이스 복사본으로 컨트롤 플레인을 기동하면 실제 운영 인스턴스를 건드릴 위험이 있습니다. 또한 Ankole은 서로 다른 프로바이더 간 또는 스토리지 레이아웃 간 자동 마이그레이션을 지원하지 않습니다.

## 복구 절차

1. 컨트롤 플레인을 중지한 상태에서 대체 인프라를 준비하되 프로바이더 위치, `BASE_DB_URLS` 샤드 ID(`ankole_sharding`), 영속 스토리지 구성을 동일하게 유지하세요. 같은 릴리스 버전의 무상태 `ankole-function-runtime` 서비스를 준비하고, 컨트롤 플레인이 빈 볼륨을 자동 생성하기 전에 Docker Home 볼륨부터 먼저 복원합니다.
2. [백업 및 복원](../backup-and-restore/)에 정리된 순서에 따라 컨트롤 플레인 PostgreSQL, 구성된 모든 `BASE_DB_URLS` 전용 Base 샤드 데이터베이스, 이에 대응하는 파일 저장소, 모든 영속 Home을 복원하세요. 전용 Base 샤드 데이터베이스를 시점 복구(PITR)로 되돌릴 때는 컨트롤 플레인에 등록된 물리 Base 테이블이 샤드에서 누락되지 않도록 **모든 Base 샤드 데이터베이스의 복구 시점 타임스탬프를 컨트롤 플레인 데이터베이스 복구 타임스탬프 이상(`>=`)**으로 맞추어야 합니다. 아울러 PostgreSQL 로캘·정렬 규칙(collation)과 `public._ankole_shard` 샤드 ID는 물론 Agent UID, 볼륨 이름, 파일 소유권 및 권한도 그대로 보존합니다.
3. 시크릿 매니저에서 원래 쓰던 `ANKOLE_SECRET_BASE`를 복원하세요. 저장된 프로바이더 시크릿과 미확정 generation 자격 증명을 복호화하려면 반드시 원래 키가 필요합니다. 만약 키를 분실했다면 복구를 잠시 멈추고 별도의 자격 증명 재발급·복구 계획부터 세우세요. 새 프로바이더 자격 증명을 다시 입력하더라도 미확정 generation 자격 증명은 복구되지 않습니다.
4. 나머지 시작 시크릿과 엔드포인트(`DATABASE_URL`, 전용 샤드 사용 시 `BASE_DB_URLS`, `ANKOLE_FUNCTION_RUNTIME_URL`, 공유 토큰 `ANKOLE_FUNCTION_RUNTIME_TOKEN`)를 구성한 뒤 `ankole-function-runtime`과 컨트롤 플레인을 시작하여 정상 조정(reconciliation) 루프가 실제 플랫폼 상태를 점검하도록 합니다. 상태를 정상으로 보이게 하려고 generation이나 인스턴스 참조를 임의로 삭제하지 마세요. 결과가 아직 확정되지 않은 항목은 `starting` 또는 `deleting` 상태로 유지되며 구체적인 사유는 `last_error`에 기록됩니다.
5. 복구된 Agent를 활성화하여 정상 동작을 검증합니다. 기존에 알고 있는 Home 파일, 드라이브 또는 Pod 파일, Pod Base 테이블을 읽어 보고 Background Job을 재개한 뒤 실제 Turn을 실행해 확인하세요. 사용자 트래픽을 새 환경으로 전환하기 전에 이전 배포 환경이 여전히 중지되어 있는지 다시 한 번 점검합니다.

## 복구 범위

PostgreSQL과 Base 샤드 데이터베이스를 복원하면 영속 작업 상태와 Pod Base 데이터가 살아나고, Home을 복원하면 워크스페이스와 Codex 스레드 파일이 되살아납니다. SQLite 캐시는 언제든 재구축할 수 있으며 `ankole-function-runtime`은 자체 영속 상태를 갖지 않습니다. 반면 백업 시점 이후에 일어난 파일 쓰기, 프로세스 메모리 상태, 실행 도중이던 모델 및 함수 호출은 복구 대상에 포함되지 않습니다.

Docker 호스트 자체가 소실된 경우 로컬 볼륨을 되살리려면 외부에 보관해 둔 백업이 있어야 합니다. Cloudflare 환경에서는 R2 백업과 데이터베이스 참조가 모두 필요하며, 강제 종료 상황에서는 마지막 백업 이후의 변경분이 유실될 수 있습니다. 프로바이더별 세부 제약은 [Worker](../worker-management/)를 참조하세요.

계획된 호스트 이전을 진행할 때는 먼저 모든 쓰기를 멈추고 PostgreSQL, Base 샤드, 파일 저장소, 전체 Agent Home에 대해 최종 일관성 백업을 수행하세요. 정기 리허설에서도 격리된 리소스 위에서 동일한 복구 절차와 실제 사용자 흐름을 검증하고 실제 달성한 복구 시점(RPO)과 소요 시간(RTO)을 기록해 두세요. Base 샤드나 Home 스토리지, 또는 `ANKOLE_SECRET_BASE` 가운데 하나라도 생략한 훈련으로는 완전한 복구 체계를 입증할 수 없습니다.
