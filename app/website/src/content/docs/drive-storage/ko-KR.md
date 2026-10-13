---
title: 제어면 드라이브 저장소 설정
description: OpenDAL 기반 Agent 드라이브에 로컬 파일, 클라우드 버킷, 데이터베이스, SFTP, WebDAV를 구성하고 이전과 백업을 수행합니다.
section: Guides
order: 318
---

Agent 드라이브는 제어면이 관리하며 Worker가 중지되어도 사용할 수 있습니다. PostgreSQL은 경로, 권한, 내용 참조를 저장하고 OpenDAL backend는 파일 바이트를 저장합니다. Ankole은 `fs`, `s3`, `azblob`, `d1`, `cos`, `postgresql`, `oss`, `tos`, `gcs`, `sftp`, `webdav`를 지원합니다.

이는 사이트 시작 설정이며 모든 테넌트가 같은 객체 저장소를 사용합니다. WorkerProvider Home, 캐시, Cloudflare R2 백업은 별도 설정입니다. [WorkerProvider](../worker-providers/)와 [파일 관리](../file-management/)를 참조하세요.

## backend 선택

| 배포 | `ANKOLE_FILES_STORE` | 구성 |
| --- | --- | --- |
| 단일 호스트 또는 제어면 복제본 하나 | `fs` | 영구 volume 또는 로컬 폴더 |
| AWS S3 | `s3` | 버킷, region, AWS 자격 증명 체인 |
| Cloudflare R2 | `s3` | S3 API endpoint, region `auto`, R2 자격 증명 |
| 기타 S3 호환 서비스 | `s3` | endpoint, 서명 region, 자격 증명, 호환성 검증 |

여러 제어면 복제본은 공유 원격 저장소를 쓰고 backend 위치와 root를 일치시키세요. 공식 Helm은 `files.store: fs`에서 복제본 둘 이상을 거부합니다. S3 드라이브는 개별 WorkerProvider의 복제본 제한을 없애지 않습니다.

현재 배포 가이드는 예약 실행, 채팅 연결, scheduler 복구 같은 singleton 프로세스가 여러 노드에서 검증될 때까지 `controlPlane.replicaCount: 1`을 요구합니다. 여러 복제본에는 공유 원격 저장소가 필요합니다. 전체 배포의 여러 복제본 검증도 필요합니다. [제어면 복제본 설명](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md#control-plane-replicas)을 참조하세요.

## 환경 변수

| 변수 | backend | 요구 사항 |
| --- | --- | --- |
| `ANKOLE_FILES_STORE` | 전체 | 운영 환경 필수: 지원하는 backend 선택 |
| `ANKOLE_FILES_FS_ROOT` | `fs` | 제어면 내부의 쓰기 가능한 절대 경로 |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | 이미 생성한 버킷 이름 |
| `ANKOLE_FILES_S3_REGION` | `s3` | 필수. AWS는 버킷 region, R2는 `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | `s3` | 호환 서비스 endpoint. AWS S3는 보통 생략 |
| `ANKOLE_FILES_S3_ROOT` | `s3` | 선택적 객체 prefix. 예: `/ankole/production/` |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID` | `s3` | 선택적 정적 자격 증명. 다음 변수와 함께 설정 |
| `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | `s3` | 선택적 정적 자격 증명. 이전 변수와 함께 설정 |

정적 자격 증명이 없으면 설정된 EKS Pod Identity를 포함한 기본 AWS 자격 증명 체인을 사용합니다. 자격 증명은 제어면에만 제공하세요. Worker는 RuntimeFabric으로 자신의 드라이브에 접근하며 버킷 키는 필요 없습니다. 시작 시 읽는 설정이므로 변경 후 제어면을 다시 시작하세요. 다른 OpenDAL 옵션을 Ankole 환경 변수로 추가하지 마세요.

## 추가 OpenDAL backend

환경 변수는 `ANKOLE_FILES_<SCHEME>_<FIELD>` 형식이며 backend와 필드 이름은 대문자입니다. Azure Blob에는 `ANKOLE_FILES_STORE=azblob`, `ANKOLE_FILES_AZBLOB_CONTAINER`, `ANKOLE_FILES_AZBLOB_ENDPOINT`가 필요합니다. 아래는 Ankole이 제공하는 전체 필드입니다. 필수 값이 없거나 비어 있으면 시작에 실패합니다.

| backend | 필수 필드 | 선택 필드 |
| --- | --- | --- |
| `azblob` | `CONTAINER`, `ENDPOINT` | `ROOT`, `ACCOUNT_NAME`, `ACCOUNT_KEY`, `SAS_TOKEN` |
| `d1` | `ACCOUNT_ID`, `DATABASE_ID`, `TOKEN`, `TABLE`, `KEY_FIELD`, `VALUE_FIELD` | `ROOT` |
| `cos` | `BUCKET`, `ENDPOINT` | `ROOT`, `SECRET_ID`, `SECRET_KEY`, `SECURITY_TOKEN` |
| `postgresql` | `CONNECTION_STRING`, `TABLE`, `KEY_FIELD`, `VALUE_FIELD` | `ROOT` |
| `oss` | `BUCKET`, `ENDPOINT` | `ROOT`, `ACCESS_KEY_ID`, `ACCESS_KEY_SECRET`, `SECURITY_TOKEN` |
| `tos` | `BUCKET`, `ENDPOINT`, `REGION` | `ROOT`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `SECURITY_TOKEN` |
| `gcs` | `BUCKET` | `ROOT`, `ENDPOINT`, `CREDENTIAL`, `CREDENTIAL_PATH` |
| `sftp` | `ENDPOINT` | `ROOT`, `USER`, `KEY`, `KNOWN_HOSTS_STRATEGY` |
| `webdav` | `ENDPOINT` | `ROOT`, `USERNAME`, `PASSWORD`, `TOKEN` |

자격 증명은 제어면 Secret에 저장하세요. GCS `CREDENTIAL`은 Base64 인코딩한 자격 증명 JSON이며 `CREDENTIAL_PATH`는 원본 JSON 파일 경로입니다. 명시적 자격 증명이 없으면 상위 Google 자격 증명 체인을 사용합니다. SFTP는 제어면 이미지의 `ssh`를 사용하며 `KEY`는 개인 키 파일 경로입니다. 호스트 검증 기본값은 `strict`이므로 제어면 사용자의 `~/.ssh/known_hosts`를 구성하세요. WebDAV는 Basic 자격 증명 또는 bearer `TOKEN`을 지원합니다.

D1과 PostgreSQL에는 기존 테이블이 필요합니다. D1에는 `TEXT` 기본 키와 `BLOB` 값을, PostgreSQL에는 `TEXT` 기본 키와 `BYTEA` 값을 사용하고 `TABLE`, `KEY_FIELD`, `VALUE_FIELD`로 이름을 지정하세요. Ankole은 테이블을 만들지 않습니다. D1, PostgreSQL, WebDAV는 native backend에서 전체 객체를 버퍼링합니다. D1의 [문자열, BLOB, 행 제한은 2,000,000바이트](https://developers.cloudflare.com/d1/platform/limits/)이며 Ankole은 객체를 여러 행으로 분할하지 않습니다. 큰 파일에는 버킷 backend를 사용하세요.

SFTP는 객체와 같은 디렉터리의 임시 파일에 쓴 뒤 닫고 이름을 바꿉니다. 서버는 OpenSSH `posix-rename` 같은 원자적 교체를 지원해야 합니다. 제어면이 중간에 종료되면 `blobs/<digest>.<uuid>.tmp`가 남을 수 있습니다. 모든 쓰기 프로세스를 중지한 유지보수 시간에 삭제하세요.

Helm에서는 `files.store`로 backend를 선택하고 일반 변수는 `controlPlane.extraEnv`, 자격 증명 변수는 `secrets.existingSecret`에 넣으세요. Chart는 이 Secret을 제어면과 migration 환경에 로드합니다. 같은 Secret의 파일은 제어면의 `/etc/ankole/bootstrap`에 읽기 전용으로 마운트합니다. SSH 키 권한과 `known_hosts`는 uid 10001에 맞게 구성하세요. Compose에서는 아래 override 방법으로 선택한 backend의 변수를 두 서비스에 전달하세요. 배포 전에 읽기, 쓰기, 교체, 삭제, 큰 파일 전송을 검증하세요.

## 로컬 폴더와 영구 volume

```dotenv
ANKOLE_FILES_STORE=fs
ANKOLE_FILES_FS_ROOT=/var/lib/ankole/files
```

경로는 제어면 프로세스 내부 경로입니다. 컨테이너에는 영구 저장소를 mount해야 삭제 후 파일을 잃지 않습니다. 공식 이미지의 uid/gid 10001에 생성, 쓰기, 이름 변경, 삭제 권한이 필요합니다. `fs`는 루트 아래 `.tmp`도 만듭니다.

공식 Compose는 `files_data`를 `/var/lib/ankole/files`에 mount합니다. 호스트 폴더는 먼저 만들고 uid/gid 10001 쓰기 권한을 준 뒤 override로 바꾸세요.

```yaml
services:
  control-plane:
    volumes:
      - ./ankole-files:/var/lib/ankole/files
```

기존 사이트는 원래 파일 저장소를 먼저 복사하세요. 빈 폴더를 mount해도 이전 volume 내용은 자동 이전되지 않습니다.

Helm 로컬 저장소 설정:

```yaml
controlPlane:
  replicaCount: 1
files:
  store: fs
  persistence:
    size: 100Gi
    storageClass: YOUR_STORAGE_CLASS
    # existingClaim: YOUR_EXISTING_FILES_PVC
```

Chart는 파일 PVC를 생성 또는 인계하고 `/var/lib/ankole/files`에 mount합니다. Chart가 만든 PVC는 uninstall 후 유지됩니다. 기존 PVC도 권한과 백업 요건을 충족해야 합니다. Agent Home은 다른 저장소를 씁니다.

## AWS S3

비공개 버킷을 만들고 선택한 prefix의 읽기, 쓰기, 삭제, multipart upload 권한을 제어면 신원에 부여하세요. KMS 암호화를 쓰면 KMS 권한도 필요합니다.

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=ap-southeast-1
ANKOLE_FILES_S3_ROOT=/ankole/production/
```

AWS workload identity는 Ankole 정적 자격 증명 변수를 생략할 수 있습니다. 정적 자격 증명은 `ANKOLE_FILES_S3_ACCESS_KEY_ID`와 `ANKOLE_FILES_S3_SECRET_ACCESS_KEY`를 모두 배포 Secret에 제공하세요.

Helm 예시:

```yaml
files:
  store: s3
  s3:
    bucket: ankole-files
    region: ap-southeast-1
    root: /ankole/production/
```

`secrets.existingSecret`으로 두 변수를 가진 bootstrap Secret을 참조할 수 있습니다. 이 Secret에는 배포에 필요한 DB 자격 증명, 원래 `ANKOLE_SECRET_BASE`, `RELEASE_COOKIE`도 있어야 합니다. Chart는 `secrets.filesS3AccessKeyID`와 `secrets.filesS3SecretAccessKey`도 허용합니다. 실제 키를 values 파일에 커밋하지 마세요.

## Cloudflare R2와 기타 S3 호환 서비스

R2도 `s3` backend를 사용합니다.

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=auto
ANKOLE_FILES_S3_ENDPOINT=https://ACCOUNT_ID.r2.cloudflarestorage.com
ANKOLE_FILES_S3_ROOT=/ankole/production/
ANKOLE_FILES_S3_ACCESS_KEY_ID=YOUR_R2_ACCESS_KEY_ID
ANKOLE_FILES_S3_SECRET_ACCESS_KEY=YOUR_R2_SECRET_ACCESS_KEY
```

R2 S3 API 자격 증명과 계정의 S3 API endpoint를 사용하세요. 공개 버킷 도메인이나 Worker URL이 아닙니다. region `auto`와 지원 작업은 [R2 S3 API 호환성](https://developers.cloudflare.com/r2/api/s3/api/)을 참조하세요. Helm은 `files.s3.endpoint`, `files.s3.region`, `files.s3.root`를 사용합니다.

MinIO 등도 `s3`로 실제 endpoint와 서명 region을 설정합니다. S3 호환이라는 선언만으로 검증을 대신할 수 없습니다. 읽기, 쓰기, 삭제, multipart upload, 큰 파일 전송을 확인하세요. 제공하는 backend와 시작 필드는 이 페이지의 표를 참조하세요. S3 virtual-host addressing과 사용자 지정 서명 설정은 제공하지 않습니다. 상위 [S3 backend](https://opendal.apache.org/docs/rust/opendal/services/struct.S3.html)를 참조할 수 있습니다.

## Compose에서 S3 사용

공식 Compose는 YAML에 `fs`를 고정하므로 `.env`의 `ANKOLE_FILES_STORE=s3`만으로 바뀌지 않습니다. `compose.files-s3.yaml` 같은 override를 만들고 migration과 제어면에 같은 설정을 전달하세요. 다음은 정적 자격 증명 예시입니다.

```yaml
x-files-environment: &files-environment
  ANKOLE_FILES_STORE: s3
  ANKOLE_FILES_S3_BUCKET: ${ANKOLE_FILES_S3_BUCKET:?Set the files bucket}
  ANKOLE_FILES_S3_REGION: ${ANKOLE_FILES_S3_REGION:?Set the files region}
  ANKOLE_FILES_S3_ENDPOINT: ${ANKOLE_FILES_S3_ENDPOINT:-}
  ANKOLE_FILES_S3_ROOT: ${ANKOLE_FILES_S3_ROOT:-/ankole/}
  ANKOLE_FILES_S3_ACCESS_KEY_ID: ${ANKOLE_FILES_S3_ACCESS_KEY_ID:?Set the access key}
  ANKOLE_FILES_S3_SECRET_ACCESS_KEY: ${ANKOLE_FILES_S3_SECRET_ACCESS_KEY:?Set the secret key}
services:
  migrate:
    environment: *files-environment
  control-plane:
    environment: *files-environment
```

`.env` 또는 배포 환경에 값을 설정하세요. 새 사이트는 다음 명령으로 시작할 수 있습니다. 기존 사이트는 다음 절의 객체 이전을 먼저 완료하세요.

```sh
docker compose -f compose.yaml -f compose.files-s3.yaml up -d
```

이후 `run`, `exec`, 업그레이드, Home 가져오기에도 두 `-f`를 모두 사용하세요. AWS 자격 증명 체인은 override에서 정적 자격 증명 두 항목을 제거하고 실제 workload identity를 컨테이너에 제공하세요.

## backend, 버킷, prefix 변경

설정 변경은 파일을 옮기지 않습니다. PostgreSQL 내용 참조에 대응하는 객체 키는 루트나 prefix 아래의 `blobs/<전체 SHA-256>`입니다. Agent 논리 드라이브 경로로 이름 붙인 일반 폴더가 아닙니다.

1. 요청과 예약 작업을 중지하고 Agent를 비활성화한 뒤 작업 완료를 기다리세요. Worker와 모든 제어면을 중지해 파일 커밋과 정리도 멈추세요.
2. DB, 원래 객체 저장소, Home, 비밀을 함께 백업하세요.
3. `blobs/` 전체를 키 변경 없이 목표 루트 또는 prefix에 복사하세요. `fs`에서 복사할 때 `.tmp`는 제외하고 논리 드라이브 경로로 이름을 바꾸지 마세요.
4. 모든 제어면을 같은 목표로 설정하고 시작하세요. 알려진 파일의 다운로드와 내용, 새 업로드, Worker 읽기·쓰기, 첨부 전송을 검증하세요.
5. 검증 후 작업을 재개하고 원래 저장소를 롤백용으로 유지하세요. 전환 후 쓰기를 보존하며 되돌리려면 객체와 DB 참조도 함께 동기화해야 합니다.

독립 사이트끼리 같은 객체 prefix를 공유하지 마세요. 한 사이트의 미참조 내용 정리가 다른 사이트에 필요한 객체를 삭제할 수 있습니다. 같은 사이트의 복제본은 설정이 같아야 합니다.

## 백업과 정리

DB 백업에는 참조, 버킷/폴더 백업에는 바이트가 있으므로 함께 복원하세요. 제어면은 드라이브 경로나 미완료 첨부 참조가 없는 내용을 정리합니다. 아직 참조되는 객체를 삭제하는 만료 규칙을 추가하지 마세요.

S3는 multipart upload를 사용하며 프로세스 중단 후 미완료 업로드가 남을 수 있습니다. 작업에 맞는 기간으로 미완료 업로드를 중단하는 lifecycle rule을 설정하세요. `fs`는 열 때 하루 넘게 변경되지 않은 임시 파일을 정리합니다. 이것은 백업을 대신하지 않습니다.

Worker가 없을 때 Console에서 알려진 파일을 업로드·다운로드하고 이후 Worker 하나로 접근과 첨부를 검증하세요. `AccessDenied`는 신원과 버킷 권한, `fs` 쓰기 실패는 mount·uid 10001·용량, 이전 파일 누락은 버킷·region·prefix·복사 결과를 확인하세요. [백업과 복원](../backup-and-restore/) 및 이전 파일을 위한 [2.0 업그레이드](../upgrade-to-2/)를 참조하세요.
