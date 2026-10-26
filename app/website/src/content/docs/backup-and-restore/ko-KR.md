---
title: 백업 및 복원
description: PostgreSQL, 파일 저장소, 영구 Agent Home, 배포 비밀 정보를 함께 백업하고 검증합니다.
section: Guides
order: 315
---

PostgreSQL(컨트롤 플레인 데이터베이스 및 `BASE_DB_URLS`의 모든 물리 Base 샤드 데이터베이스), 오브젝트 스토리지(control plane 파일 저장소), 각 Agent의 영구 Home을 함께 백업하세요. 배포 구성 및 비밀 정보는 별도 secret manager에 보관합니다. Worker 인스턴스, `ankole-function-runtime`, `/var/cache/ankole` 캐시는 재생성할 수 있지만 영구 Home과 데이터베이스는 복원해야 합니다.

## 백업 대상

| 데이터 | 내용 | 백업 원본 |
|---|---|---|
| 컨트롤 플레인 PostgreSQL | Principal, Session, Job, Pod 메타데이터 및 문서, provider 설정, 암호화 자격 증명, generation, 스토리지 참조 | `pg_dump -Fc` 또는 PITR |
| 물리 Base 샤드(`BASE_DB_URLS`) | 테넌트 물리 Base 테이블 행(`BASE_DB_URLS` 미설정 단일 DB 구성에서는 Base 테이블이 컨트롤 플레인 DB에 함께 저장되어 한 번의 원자적 `pg_dump`로 모두 백업됨) | 모든 샤드 DB의 `pg_dump -Fc` 또는 PITR |
| 오브젝트 스토리지(파일 저장소) | Pod `file` 페이지, Pod 및 대화 첨부 파일, 컴파일된 Applet 번들, 게시한 파일, Skill, Automation 스크립트 | Compose `files_data`, PVC, S3 버킷 |
| Agent Home | 작업 공간, 사용자 패키지, `/workspace/.codex`의 스레드 | provider volume, 공유 디렉터리, Drive, EFS, Cloudflare R2 백업 |
| 배포 구성 및 비밀 정보 | `ANKOLE_SECRET_BASE`, `ANKOLE_FUNCTION_RUNTIME_TOKEN`, `BASE_DB_URLS` 및 시작 자격 증명 | 별도 secret manager |

`/var/cache/ankole`과 이미지는 다시 만들 수 있습니다. Home은 캐시가 아닙니다. Docker Home 백업은 다른 호스트에도 보관하세요. Cloudflare 데이터베이스 백업은 해당 R2 백업의 `storage_ref`를 포함해야 합니다. 강제 중지는 마지막 백업 이후 쓰기를 잃을 수 있습니다.

## 일관된 백업 만들기

1. 새 요청과 예약 작업을 중단하고 Agent를 비활성화한 뒤 진행 중인 작업이 끝날 때까지 기다리세요. Worker를 종료하는 동안 control plane은 계속 실행합니다.
2. 각 플랫폼의 정상 중지 또는 삭제 작업으로 일시 중지된 인스턴스를 포함한 Worker를 종료하세요. 강제 삭제, Kubernetes 유예 0, Agent 삭제는 사용하지 않습니다. control plane이 인스턴스 부재를 확인하고 스토리지 참조를 저장할 때까지 기다리세요. Cloudflare는 디렉터리 백업 완료도 확인합니다. 미확정 생성 요청은 결과가 확정되어야 다음 단계로 진행할 수 있습니다.
3. control plane을 중지하세요. 이것만으로 별도 관리되는 Worker가 중지되지는 않습니다. Home에 쓸 수 있는 Worker가 없는지 확인하세요.
4. PostgreSQL을 실행한 상태로 아카이브를 만드세요. 단일 DB 배포(`BASE_DB_URLS` 미설정)에서는 한 번의 `pg_dump`로 컨트롤 플레인과 Base 테이블을 원자적으로 백업하며, 다중 샤드 배포(`BASE_DB_URLS` 설정)에서는 컨트롤 플레인 데이터베이스와 모든 물리 Base 샤드 데이터베이스를 함께 백업해야 합니다. 쓰기가 중단된 동안 오브젝트 스토리지와 모든 Home을 백업하세요. volume 이름, 샤드 ID, provider 설정, Agent UID, 소유권, 권한을 보존합니다.
5. control plane을 시작하고 Agent를 활성화한 뒤 알려진 Home 파일과 드라이브 파일을 확인하세요.

Compose 데이터베이스 백업:

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc > ankole-backup.dump
```

volume과 버킷은 스토리지의 백업 기능을 사용하세요. 업그레이드와 파괴적 유지보수 전에도 백업합니다. 이미지 변경은 데이터베이스 마이그레이션을 되돌리지 않습니다.

## 복원과 검증

복원 중에는 모든 control plane과 Worker를 중지하세요. 대상 데이터베이스에서 실행합니다.

```bash
docker compose exec -T postgresql \
  pg_restore -U ankole -d ankole --clean --if-exists < ankole-backup.dump
```

`BASE_DB_URLS`의 모든 물리 Base 샤드 데이터베이스도 함께 복원하세요. 다중 샤드 배포에서 시점 복구(PITR)를 사용할 때는 각 Base 샤드 복구 시점이 컨트롤 플레인 데이터베이스 복구 시점 이상(`>=`)이어야 합니다.

시작 전에 해당 오브젝트 스토리지, Home, provider 위치, `BASE_DB_URLS`, `ANKOLE_FUNCTION_RUNTIME_TOKEN`, 원래 `ANKOLE_SECRET_BASE`를 복원하세요. `ANKOLE_SECRET_BASE`는 provider 자격 증명과 미확정 generation의 재시도 자격 증명을 복호화합니다. 새 키 생성만으로 복구할 수 없습니다.

원래 스토리지 구성과 uid 1000 소유권을 유지하세요. Agent의 provider 및 provider 위치와 영구 스토리지 설정은 변경할 수 없습니다. 다른 구성으로 이동하려면 별도 마이그레이션 계획이 필요합니다.

복구 훈련에서는 복원한 플랫폼 리소스를 운영 환경과 격리하세요. 독립적인 두 control plane이 같은 Home을 관리하면 안 됩니다. 미확정 결과를 우회하려고 generation을 지우지 마세요.

알려진 작업 공간 파일과 드라이브 파일, Home에서 Job 재개, 실제 Turn을 확인하세요. 구성이나 절차가 바뀌면 훈련을 반복합니다. [재해 복구](../disaster-recovery/)와 [Worker](../worker-management/)도 참조하세요.
