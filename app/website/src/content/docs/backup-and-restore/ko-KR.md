---
title: 백업 및 복원
description: PostgreSQL, 파일 저장소, 영구 Agent Home, 배포 비밀 정보를 함께 백업하고 검증합니다.
section: Guides
order: 315
---

Ankole을 백업할 때는 PostgreSQL(컨트롤 플레인 데이터베이스와 `BASE_DB_URLS`에 구성된 모든 물리 Base 샤드 데이터베이스), 오브젝트 스토리지(컨트롤 플레인 파일 저장소), 각 Agent의 영구 Home을 반드시 한 세트로 함께 백업하고, 배포 환경 구성과 비밀 키는 별도의 시크릿 매니저에 안전하게 보관하세요. Worker 인스턴스와 `ankole-function-runtime`, `/var/cache/ankole` 캐시는 언제든 새로 띄워 재구축할 수 있지만 데이터베이스와 영구 Home, 파일 저장소는 백업본으로 복원해야 합니다.

## 백업 대상

| 데이터 | 내용 | 백업 원본 |
|---|---|---|
| 컨트롤 플레인 PostgreSQL | Principal, Session, Job, Pod 메타데이터 및 문서, provider 설정, 암호화된 자격 증명, generation, 스토리지 참조 | `pg_dump -Fc` 또는 PITR |
| 물리 Base 샤드(`BASE_DB_URLS`) | 테넌트별 물리 Base 테이블 행(`BASE_DB_URLS`를 설정하지 않은 단일 DB 구성에서는 Base 테이블이 컨트롤 플레인 DB 안에 함께 저장되므로 한 번의 `pg_dump`로 원자적 백업 가능) | 모든 샤드 DB의 `pg_dump -Fc` 또는 PITR |
| 오브젝트 스토리지(파일 저장소) | Pod `file` 페이지, Pod 및 대화 첨부 파일, 컴파일된 Applet 번들, 게시된 파일, Skill, Automation 스크립트 | Compose `files_data`, PVC, S3 버킷 |
| Agent Home | 작업 공간 파일, 사용자 설치 패키지, `/workspace/.codex` 스레드 데이터 | provider 볼륨, 공유 디렉터리, Drive, EFS, Cloudflare R2 백업 |
| 배포 구성 및 비밀 정보 | `ANKOLE_SECRET_BASE`, `ANKOLE_FUNCTION_RUNTIME_TOKEN`, `BASE_DB_URLS` 및 부트스트랩 자격 증명 | 외부 secret manager |

컨테이너 이미지와 `/var/cache/ankole`은 언제든 다시 생성할 수 있지만 Agent Home은 임시 캐시가 아닌 영구 데이터입니다. Docker 볼륨 기반 Home을 사용할 때는 호스트 장애에 대비해 반드시 다른 호스트나 원격 저장소에도 백업본을 복사해 두세요. 또한 Cloudflare Worker 백엔드를 사용할 때는 데이터베이스 백업 시점에 해당 R2 백업의 최신 `storage_ref`가 반영되어 있어야 하며, 인스턴스를 강제 종료하면 마지막 R2 백업 이후의 쓰기가 유실될 수 있습니다.

## 일관된 백업 만들기

1. 새로운 요청 유입과 예약 스케줄을 멈추고 Agent들을 비활성화한 뒤 현재 실행 중인 작업이 모두 마무리될 때까지 기다립니다. Worker를 정상 종료하는 동안에는 컨트롤 플레인을 계속 켜 두어야 합니다.
2. 일시 중지된 인스턴스를 포함해 모든 Worker를 각 플랫폼의 정상 중지 또는 삭제 절차로 종료합니다. 이때 강제 종료, Kubernetes 유예 시간 `0`초(`--grace-period=0`), 또는 Agent 엔티티 삭제를 사용해서는 안 됩니다. 컨트롤 플레인이 인스턴스 종료를 확인하고 최신 스토리지 참조를 데이터베이스에 기록할 때까지 기다리세요(Cloudflare 백엔드는 R2 디렉터리 백업 완료 여부까지 확인합니다). 아직 결과가 확정되지 않은 인스턴스 생성 요청이 남아 있다면 상태가 최종 확정된 뒤에 다음 단계로 넘어가세요.
3. 이제 컨트롤 플레인을 중지합니다. 컨트롤 플레인만 끈다고 해서 외부 플랫폼의 Worker가 저절로 종료되지는 않으므로, Agent Home에 쓰기를 수행할 수 있는 활성 Worker가 한 대도 남아 있지 않은지 다시 확인하세요.
4. PostgreSQL만 실행 중인 상태에서 백업 아카이브를 생성합니다. 단일 DB 배포(`BASE_DB_URLS` 미설정)에서는 `pg_dump` 한 번으로 컨트롤 플레인과 Base 테이블이 원자적으로 함께 백업되며, 다중 샤드 배포(`BASE_DB_URLS` 설정)에서는 컨트롤 플레인 DB와 모든 물리 Base 샤드 DB를 빠짐없이 함께 덤프해야 합니다. 모든 쓰기가 멈춘 이 시점에 오브젝트 스토리지와 전체 Agent Home도 함께 백업하며, 볼륨 이름, 샤드 ID, provider 설정, Agent UID, 파일 소유권 및 권한 메타데이터를 그대로 보존합니다.
5. 백업이 끝나면 컨트롤 플레인을 다시 기동하고 Agent를 활성화한 뒤 기존 작업 공간 파일과 드라이브 파일이 정상적으로 읽히는지 점검합니다.

Docker Compose 환경의 데이터베이스 백업 예시입니다.

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc > ankole-backup.dump
```

볼륨과 오브젝트 버킷은 각 스토리지 시스템이 제공하는 스냅샷·백업 도구를 활용하세요. 버전 업그레이드나 파괴적 인프라 점검 작업 직전에도 반드시 백업을 수행해야 합니다. 컨테이너 이미지만 이전 버전으로 되돌린다고 해서 이미 적용된 데이터베이스 마이그레이션까지 자동으로 롤백되지는 않기 때문입니다.

## 복원과 검증

복원을 진행하는 동안에는 모든 컨트롤 플레인과 Worker 인스턴스를 중지해 두어야 합니다. 준비된 대상 데이터베이스에 다음과 같이 덤프를 복원합니다.

```bash
docker compose exec -T postgresql \
  pg_restore -U ankole -d ankole --clean --if-exists < ankole-backup.dump
```

`BASE_DB_URLS`에 속한 모든 물리 Base 샤드 데이터베이스도 함께 복원하세요. 다중 샤드 배포에서 시점 복구(PITR)를 사용할 때는 모든 Base 샤드의 복구 목표 시점이 컨트롤 플레인 데이터베이스의 복구 목표 시점과 같거나 그 이후(`>=`)여야 합니다.

서비스를 기동하기 전에 같은 시점의 오브젝트 스토리지, Agent Home, provider 경로, `BASE_DB_URLS`, `ANKOLE_FUNCTION_RUNTIME_TOKEN`, 그리고 원래 사용하던 `ANKOLE_SECRET_BASE`를 모두 복원하세요. Ankole은 저장된 provider 자격 증명과 미확정 generation의 재시도 자격 증명을 복호화할 때 `ANKOLE_SECRET_BASE`를 사용하므로, 새 키를 임의로 생성해서는 기존 암호화 데이터를 복구할 수 없습니다.

복원 시에는 원래의 스토리지 경로 구성과 `uid 1000` 파일 소유권을 그대로 유지해야 합니다. 기존 Agent에 연결된 provider 종류나 위치 및 영구 스토리지 설정은 임의로 바꿀 수 없으며, 다른 백엔드 구성으로 이전하려면 별도의 마이그레이션 절차를 거쳐야 합니다.

모의 복구 훈련을 실시할 때는 복원된 플랫폼 리소스가 실제 운영 환경과 겹치지 않도록 완전히 격리하세요. 두 개의 독립된 컨트롤 플레인이 동일한 Agent Home 스토리지를 동시에 건드리면 데이터가 손상될 수 있습니다. 또한 미확정 상태를 우회하려는 목적으로 데이터베이스의 generation 레코드를 임의로 삭제하지 마세요.

복원을 마친 뒤에는 기존 작업 공간 파일과 드라이브 파일 열람, Home 기반 백그라운드 Job 재개, 실제 대화 Turn 실행까지 모두 정상 작동하는지 검증하고, 인프라 구성이나 운영 절차가 바뀔 때마다 복구 훈련을 다시 수행하세요. 관련 내용은 [재해 복구](../disaster-recovery/)와 [Worker](../worker-management/) 문서도 함께 참조하세요.
