---
title: 재해 복구
description: Ankole 배포 복구 절차 — PostgreSQL, Base 샤드 데이터베이스, 파일 저장소, Agent Home, Function Runtime 및 배포 비밀 정보 복원과 복구 리허설.
section: Guides
order: 320
---

컨트롤 플레인 PostgreSQL 데이터베이스, 전용 Pod Base 샤드 데이터베이스(`BASE_DB_URLS`를 구성한 경우), 파일 저장소, 영구 Agent Home, `ankole-function-runtime`, 그리고 원래 배포 비밀 정보를 하나의 배포 단위로 함께 복원합니다. 보존할 데이터와 일관된 백업 절차는 [백업 가이드](../backup-and-restore/)를 참조하세요.

## 복구 전

이전 컨트롤 플레인과 Worker가 복원된 Home이나 데이터베이스에 쓸 수 없음을 확인하세요. 연결이 끊겼다는 사실만으로는 Worker 중지가 증명되지 않으며, 일시 중지된 인스턴스와 결과를 알 수 없는 생성 요청도 포함됩니다. 미확정 generation과 자격 증명은 PostgreSQL에 그대로 보존하여 플랫폼이 확정 결과를 반환할 때까지 동일한 generation으로 조정되게 합니다.

복구 훈련은 격리된 플랫폼 리소스에서 진행하세요. 운영 provider 위치가 그대로 남아 있는 데이터베이스 복사본은 실제 운영 인스턴스를 건드릴 수 있습니다. Ankole은 provider 간 또는 스토리지 레이아웃 간 자동 마이그레이션을 제공하지 않습니다.

## 복구 절차

1. 컨트롤 플레인을 중지한 상태에서 대체 인프라를 준비하고 provider 위치, `BASE_DB_URLS` 샤드 ID(`ankole_sharding`), 영구 스토리지 구성을 유지하세요. 동일 릴리스의 무상태 `ankole-function-runtime` 서비스를 준비하고, 컨트롤 플레인이 빈 볼륨을 만들기 전에 Docker Home 볼륨을 먼저 복원합니다.
2. [백업 및 복원](../backup-and-restore/)의 순서에 따라 컨트롤 플레인 PostgreSQL, `BASE_DB_URLS`의 모든 전용 Base 샤드 데이터베이스(구성된 경우), 대응하는 파일 저장소, 모든 영구 Home을 복원하세요. 전용 Base 샤드 데이터베이스를 시점 복구(PITR)로 복원할 때는 컨트롤 플레인에 물리 테이블로 기록된 Base 테이블이 샤드에서 누락되지 않도록 **모든 Base 샤드 데이터베이스의 복구 시점 타임스탬프를 컨트롤 플레인 데이터베이스 복구 타임스탬프 이상(`>=`)**으로 지정하고, PostgreSQL 로캘·정렬 규칙(collation)과 `public._ankole_shard` 샤드 ID를 보존해야 합니다. Agent UID, 볼륨 이름, 파일 소유권 및 권한도 그대로 유지합니다.
3. 시크릿 매니저에서 원래 `ANKOLE_SECRET_BASE`를 복원하세요. 이 키는 provider 비밀 정보와 미확정 generation 자격 증명을 복호화하는 데 필요합니다. 키를 분실했다면 작업을 멈추고 별도의 자격 증명 복구 계획을 먼저 세우세요. 새 provider 자격 증명을 다시 입력하는 것만으로는 미확정 generation 자격 증명이 복구되지 않습니다.
4. 나머지 시작 비밀 정보와 엔드포인트(`DATABASE_URL`, 전용 샤드 사용 시 `BASE_DB_URLS`, `ANKOLE_FUNCTION_RUNTIME_URL`, 공유 토큰 `ANKOLE_FUNCTION_RUNTIME_TOKEN`)를 구성한 뒤 `ankole-function-runtime`과 컨트롤 플레인을 시작하여 정상 조정 루프가 실제 플랫폼 상태를 점검하게 하세요. 상태를 정상처럼 보이게 하려고 generation이나 인스턴스 참조를 임의로 지우지 마세요. 미확정 결과는 `starting` 또는 `deleting` 상태로 남으며 원인은 `last_error`에 기록됩니다.
5. 복구된 Agent를 활성화하세요. 알려진 Home 파일, 드라이브 또는 Pod 파일, Pod Base 테이블을 읽고 Background Job을 재개한 뒤 실제 Turn을 실행해 검증합니다. 트래픽을 전환하기 전에 이전 배포가 계속 중지되어 있는지 다시 확인하세요.

## 복구 범위

PostgreSQL과 Base 샤드 데이터베이스는 영구 작업 상태와 Pod Base 데이터를 복원하며, Home은 작업 공간과 Codex 스레드 파일을 복원합니다. SQLite 캐시는 재구축할 수 있고 `ankole-function-runtime`은 영구 상태를 갖지 않습니다. 백업 시점 이후의 파일 쓰기, 프로세스 메모리, 진행 중이던 모델·함수 요청은 백업에 포함되지 않습니다.

Docker 호스트가 손실된 경우 로컬 볼륨 복구에는 외부 백업이 필요합니다. Cloudflare는 R2 백업과 데이터베이스 참조가 모두 필요하며, 강제 중지 시 마지막 백업 이후의 변경 사항이 유실될 수 있습니다. 프로바이더별 제한은 [Worker](../worker-management/)를 참조하세요.

계획된 호스트 이전 시에는 먼저 쓰기를 중지하고 PostgreSQL, Base 샤드, 파일 저장소, Agent Home 전체의 마지막 일관된 백업을 수행하세요. 리허설에서는 격리된 리소스에서 동일한 절차와 사용자 흐름을 검증하고 실제 복구 시점과 소요 시간을 기록합니다. Base 샤드, Home 스토리지 또는 `ANKOLE_SECRET_BASE`를 생략한 훈련은 완전한 복구를 입증하지 못합니다.
