---
title: 제어면 드라이브 및 객체 저장소 설정
description: Ankole.ObjectStore(Agent 드라이브, Pod file 페이지, 첨부 파일, 컴파일된 Applet 번들)에 로컬 파일, 클라우드 버킷, 데이터베이스, SFTP, WebDAV를 구성하고 이전 및 백업하는 방법을 설명합니다.
section: Guides
order: 318
---

`ANKOLE_FILES_STORE`는 컨트롤 플레인 객체 저장소(`Ankole.ObjectStore`)를 지정하는 설정입니다. 이곳에는 Worker가 중지되어 있어도 접근 가능한 Agent 드라이브를 비롯해 Pod `file` 페이지, Pod 문서/Base/Chat 및 대화 첨부 파일, 컴파일된 Applet 번들이 저장됩니다. 파일 경로와 권한 및 콘텐츠 참조는 PostgreSQL이 관리하고, 실제 콘텐츠 주소 기반(content-addressed) blob 바이트는 OpenDAL 백엔드가 보관합니다. 지원 백엔드는 `fs`, `s3`, `azblob`, `d1`, `cos`, `postgresql`, `oss`, `tos`, `gcs`, `sftp`, `webdav`입니다.

이 설정은 사이트 부팅 시점에 읽히며 사이트 내 모든 테넌트가 동일한 객체 저장소를 공유합니다. WorkerProvider의 Home 볼륨, 캐시, Cloudflare R2 백업은 이와 별도로 구성하며, 자세한 내용은 [WorkerProvider](../worker-providers/)와 [파일 관리](../file-management/)를 참조하세요.

## backend 선택

| 배포 | `ANKOLE_FILES_STORE` | 구성 |
| --- | --- | --- |
| 단일 호스트 또는 컨트롤 플레인 복제본 1개 | `fs` | 영속 볼륨 또는 로컬 디렉터리 |
| AWS S3 | `s3` | 버킷, 리전, AWS 자격 증명 체인 |
| Cloudflare R2 | `s3` | S3 API 엔드포인트, 리전 `auto`, R2 자격 증명 |
| 기타 S3 호환 서비스 | `s3` | 엔드포인트, 서명 리전, 자격 증명, 사전 호환성 검증 |

컨트롤 플레인 복제본을 여러 개 실행해야 할 때는 공유 원격 저장소를 선택하고 모든 복제본의 백엔드 위치와 루트 경로를 일치시키세요. 공식 Helm 차트에서는 `files.store: fs`일 때 복제본을 둘 이상 설정하면 배포를 거부합니다. 또한 드라이브를 S3에 두더라도 개별 WorkerProvider가 갖는 복제본 제약까지 사라지지는 않습니다.

현재는 예약 작업 실행, 채팅 연결 유지, 스케줄러 하이드레이션 같은 컨트롤 플레인 싱글턴 프로세스가 단일 노드 기준으로 동작하므로 `controlPlane.replicaCount: 1`로 유지하세요. 공유 원격 저장소는 다중 복제본 구성의 필요조건일 뿐, 그 자체만으로 다중 복제본 운영을 보장하지는 않습니다. 자세한 내용은 [컨트롤 플레인 복제본 안내](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.md#control-plane-replicas)를 참조하세요.

## 환경 변수

| 변수 | backend | 요구 사항 |
| --- | --- | --- |
| `ANKOLE_FILES_STORE` | 전체 | 운영 환경 필수: 지원 백엔드 중 하나 선택 |
| `ANKOLE_FILES_FS_ROOT` | `fs` | 컨트롤 플레인 컨테이너 내부의 쓰기 가능한 절대 경로 |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | 미리 생성해 둔 버킷 이름 |
| `ANKOLE_FILES_S3_REGION` | `s3` | 필수. AWS는 버킷 리전, R2는 `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | `s3` | 호환 서비스 엔드포인트. AWS S3는 보통 생략 |
| `ANKOLE_FILES_S3_ROOT` | `s3` | 선택적 객체 접두사(prefix). 예: `/ankole/production/` |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID` | `s3` | 선택적 정적 자격 증명. 아래 시크릿 키와 함께 설정 |
| `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | `s3` | 선택적 정적 자격 증명. 위 액세스 키와 함께 설정 |

정적 자격 증명을 생략하면 EKS Pod Identity를 포함한 기본 AWS 자격 증명 체인을 사용합니다. 스토리지 자격 증명은 컨트롤 플레인에만 부여하세요. Worker는 RuntimeFabric을 거쳐 자신의 드라이브에 접근하므로 버킷 키가 필요하지 않습니다. 이 변수들은 프로세스 시작 시에만 읽히므로 값을 바꾼 뒤에는 컨트롤 플레인을 재시작해야 하며, 표에 없는 임의의 OpenDAL 옵션을 Ankole 환경 변수로 추가해서는 안 됩니다.

## 추가 OpenDAL backend

추가 백엔드의 환경 변수는 `ANKOLE_FILES_<SCHEME>_<FIELD>` 형식을 따르며 백엔드 이름과 필드 이름은 모두 대문자로 표기합니다. 예를 들어 Azure Blob을 쓰려면 `ANKOLE_FILES_STORE=azblob`, `ANKOLE_FILES_AZBLOB_CONTAINER`, `ANKOLE_FILES_AZBLOB_ENDPOINT`를 설정합니다. 아래 표는 Ankole이 노출하는 전체 필드 목록이며, 필수 필드가 빠져 있거나 빈 값이면 컨트롤 플레인 부팅이 실패합니다.

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

민감한 자격 증명은 컨트롤 플레인 Secret에 보관하세요. GCS의 `CREDENTIAL`에는 Base64로 인코딩한 서비스 계정 JSON을 넣고 `CREDENTIAL_PATH`에는 원본 JSON 파일 경로를 지정하며, 둘 다 생략하면 기본 Google 자격 증명 체인을 따릅니다. SFTP는 컨트롤 플레인 이미지 내장 `ssh`를 사용하며 `KEY`에는 개인 키 파일 경로를 지정합니다. 호스트 키 검증 기본값이 `strict`이므로 컨트롤 플레인 실행 계정의 `~/.ssh/known_hosts`를 미리 구성해 두어야 합니다. WebDAV는 Basic 인증 자격 증명 또는 Bearer `TOKEN`을 지원합니다.

D1과 PostgreSQL 백엔드를 쓸 때는 대상 테이블을 미리 만들어 두어야 합니다(Ankole이 자동 생성하지 않음). D1에는 `TEXT` 기본 키와 `BLOB` 값 컬럼을, PostgreSQL에는 `TEXT` 기본 키와 `BYTEA` 값 컬럼을 두고 `TABLE`, `KEY_FIELD`, `VALUE_FIELD`로 각각의 이름을 지정하세요. D1, PostgreSQL, WebDAV는 네이티브 백엔드 계층에서 객체 전체를 메모리에 버퍼링합니다. 특히 D1은 [문자열·BLOB·행 크기 상한이 2,000,000바이트](https://developers.cloudflare.com/d1/platform/limits/)이며 Ankole이 객체를 여러 행으로 쪼개 저장하지 않으므로, 대용량 파일을 다루어야 한다면 버킷 기반 백엔드를 선택하세요.

SFTP 백엔드는 대상 객체와 같은 디렉터리에 임시 파일을 기록한 뒤 파일을 닫고 이름을 바꾸는 방식으로 동작하므로, SFTP 서버가 OpenSSH `posix-rename` 같은 원자적 이름 변경을 지원해야 합니다. 쓰기 도중 컨트롤 플레인이 비정상 종료되면 `blobs/<digest>.<uuid>.tmp` 형태의 임시 파일이 남을 수 있는데, 모든 쓰기 프로세스를 내린 점검 시간에 정리하면 됩니다.

Helm 환경에서는 `files.store`로 백엔드를 고르고 일반 변수는 `controlPlane.extraEnv`에, 자격 증명 변수는 `secrets.existingSecret`에 넣으세요. 차트는 해당 Secret을 컨트롤 플레인과 마이그레이션 Job 환경 양쪽에 주입하며, 같은 Secret의 항목들을 컨트롤 플레인 컨테이너의 `/etc/ankole/bootstrap` 아래에 읽기 전용 파일로도 마운트합니다. SSH 키 권한과 `known_hosts`는 컨테이너 실행 계정인 uid `10001`에 맞춰 구성하세요. Docker Compose에서는 아래 오버라이드 방식에 따라 선택한 백엔드 변수를 `migrate`와 `control-plane` 두 서비스 모두에 전달하고, 운영 전환 전에 읽기·쓰기·덮어쓰기·삭제·대용량 전송을 반드시 검증하세요.

## 로컬 폴더와 영구 volume

```dotenv
ANKOLE_FILES_STORE=fs
ANKOLE_FILES_FS_ROOT=/var/lib/ankole/files
```

위 경로는 컨트롤 플레인 프로세스 내부에서 바라보는 경로입니다. 컨테이너가 재생성되어도 파일이 사라지지 않도록 반드시 영속 볼륨을 마운트해야 하며, 공식 이미지 실행 계정인 uid/gid `10001`에 디렉터리 생성·쓰기·이름 변경·삭제 권한이 부여되어 있어야 합니다. `fs` 백엔드는 지정한 루트 아래에 `.tmp` 작업 폴더도 함께 생성합니다.

공식 Compose 파일은 기본적으로 `files_data` 명명 볼륨을 `/var/lib/ankole/files`에 마운트합니다. 호스트 디렉터리를 직접 바인드 마운트하려면 먼저 폴더를 생성하고 uid/gid `10001` 쓰기 권한을 부여한 뒤 오버라이드 파일로 교체하세요.

```yaml
services:
  control-plane:
    volumes:
      - ./ankole-files:/var/lib/ankole/files
```

운영 중인 사이트의 마운트 경로를 바꿀 때는 기존 파일 저장소의 데이터를 먼저 새 폴더로 복사하세요. 빈 호스트 폴더를 마운트해도 기존 볼륨의 파일이 자동으로 옮겨지지는 않습니다.

Helm에서 로컬 영속 볼륨을 쓰는 설정 예시는 다음과 같습니다.

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

차트는 파일 전용 PVC를 새로 생성하거나 지정한 기존 PVC를 인계받아 `/var/lib/ankole/files`에 마운트합니다. 차트가 생성한 PVC는 릴리스를 삭제(uninstall)하더라도 자동 삭제되지 않고 보존됩니다. 기존 PVC를 연결할 때도 동일한 권한 및 백업 요건을 갖추어야 하며, Agent Home은 이 볼륨과 별개의 스토리지를 사용합니다.

## AWS S3

비공개 버킷을 생성한 뒤 지정한 prefix 아래에서 읽기, 쓰기, 삭제, 멀티파트 업로드를 수행할 수 있는 IAM 권한을 컨트롤 플레인 실행 신원에 부여하세요. 버킷에 KMS 암호화를 적용했다면 관련 KMS 키 권한도 함께 필요합니다.

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=ap-southeast-1
ANKOLE_FILES_S3_ROOT=/ankole/production/
```

AWS 워크로드 신원(EKS Pod Identity 등)을 사용하면 정적 키 환경 변수를 생략할 수 있습니다. 정적 키를 사용할 때는 `ANKOLE_FILES_S3_ACCESS_KEY_ID`와 `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` 두 값을 모두 배포 Secret에 넣어 전달하세요.

Helm 설정 예시:

```yaml
files:
  store: s3
  s3:
    bucket: ankole-files
    region: ap-southeast-1
    root: /ankole/production/
```

`secrets.existingSecret`으로 두 S3 키가 담긴 부트스트랩 Secret을 참조할 수 있습니다. 이때 해당 Secret에는 데이터베이스 자격 증명(`DATABASE_URL` 및 내장 PostgreSQL 사용 시 `POSTGRES_PASSWORD`), 원래 `ANKOLE_SECRET_BASE`, `ANKOLE_FUNCTION_RUNTIME_TOKEN`, `RELEASE_COOKIE`도 빠짐없이 함께 들어 있어야 합니다. 차트에서 `secrets.filesS3AccessKeyID`와 `secrets.filesS3SecretAccessKey` 값을 직접 받을 수도 있으나, 평문 시크릿을 `values` 파일에 커밋하지는 마세요.

## Cloudflare R2와 기타 S3 호환 서비스

Cloudflare R2 역시 `s3` 백엔드로 연결합니다.

```dotenv
ANKOLE_FILES_STORE=s3
ANKOLE_FILES_S3_BUCKET=ankole-files
ANKOLE_FILES_S3_REGION=auto
ANKOLE_FILES_S3_ENDPOINT=https://ACCOUNT_ID.r2.cloudflarestorage.com
ANKOLE_FILES_S3_ROOT=/ankole/production/
ANKOLE_FILES_S3_ACCESS_KEY_ID=YOUR_R2_ACCESS_KEY_ID
ANKOLE_FILES_S3_SECRET_ACCESS_KEY=YOUR_R2_SECRET_ACCESS_KEY
```

이때 공개 버킷 도메인이나 Cloudflare Worker URL이 아니라 계정의 S3 API 전용 엔드포인트와 R2 S3 API 자격 증명을 입력해야 합니다. `auto` 리전 설정과 호환 API 범위는 [R2 S3 API 호환성 문서](https://developers.cloudflare.com/r2/api/s3/api/)를 참조하세요. Helm에서는 `files.s3.endpoint`, `files.s3.region`, `files.s3.root` 필드를 사용합니다.

MinIO 등 다른 S3 호환 스토리지도 `s3` 백엔드에 실제 엔드포인트와 서명 리전을 지정해 연결합니다. 다만 벤더가 S3 호환을 표방한다는 이유만으로 검증을 생략하지 말고, 읽기·쓰기·삭제·멀티파트 업로드·대용량 파일 전송이 정상 동작하는지 직접 확인하세요. Ankole이 지원하는 백엔드와 시작 변수는 이 문서의 표에 정리된 항목이 전부이며, S3 가상 호스트 주소 방식(virtual-hosted-style) 전환이나 사용자 지정 서명 옵션은 별도로 노출하지 않습니다. 내부 동작은 상위 [OpenDAL S3 백엔드 문서](https://opendal.apache.org/docs/rust/opendal/services/struct.S3.html)를 참고할 수 있습니다.

## Compose에서 S3 사용

공식 `compose.yaml`에는 `ANKOLE_FILES_STORE: fs`가 명시되어 있으므로 `.env`에 `ANKOLE_FILES_STORE=s3`만 적어서는 설정이 바뀌지 않습니다. `compose.files-s3.yaml` 같은 오버라이드 파일을 만들어 `migrate`와 `control-plane` 서비스 양쪽에 동일한 S3 변수를 주입하세요. 정적 자격 증명을 쓰는 예시는 다음과 같습니다.

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

`.env` 또는 배포 환경에 실제 변수 값을 채운 뒤, 신규 사이트라면 아래 명령으로 바로 시작하면 됩니다(운영 중인 사이트라면 먼저 다음 절의 객체 이전 절차부터 완료하세요).

```sh
docker compose -f compose.yaml -f compose.files-s3.yaml up -d
```

이후 `run`, `exec`, 버전 업그레이드, Home 가져오기 명령을 실행할 때도 항상 두 `-f` 플래그를 함께 지정해야 합니다. AWS 기본 자격 증명 체인을 쓸 때는 오버라이드 파일에서 정적 키 두 줄을 빼고 컨테이너에 워크로드 신원을 연결하세요.

## backend, 버킷, prefix 변경

환경 변수만 바꾼다고 해서 기존 파일이 새 저장소로 자동 이전되지는 않습니다. 또한 PostgreSQL의 콘텐츠 참조에 대응하는 실제 객체 키는 루트(또는 prefix) 아래의 `blobs/<전체 SHA-256>` 형식이며, Agent의 논리 드라이브 경로명을 딴 일반 폴더 구조가 아닙니다.

1. 신규 유입 요청과 예약 작업을 멈추고 Agent들을 비활성화한 뒤 진행 중인 작업이 끝날 때까지 기다립니다. 이어서 모든 Worker와 컨트롤 플레인 프로세스를 중지해 파일 커밋과 가비지 컬렉션까지 완전히 멈추세요.
2. 데이터베이스, 기존 객체 저장소, Agent Home, 배포 시크릿을 한 세트로 백업합니다.
3. `blobs/` 하위 객체 전체를 키 이름을 바꾸지 않은 채 새 대상 루트(또는 prefix)로 그대로 복사합니다. `fs`에서 복사할 때는 `.tmp` 디렉터리를 제외하고, 임의로 논리 드라이브 경로명으로 바꾸지 마세요.
4. 모든 컨트롤 플레인 노드가 새 저장소를 바라보도록 설정을 맞춘 뒤 기동합니다. 기존 파일 다운로드와 내용 일치 여부, 신규 업로드, Worker에서의 읽기·쓰기, 채팅 첨부 전송을 차례로 검증합니다.
5. 이상이 없으면 작업을 재개하고, 만일의 롤백에 대비해 기존 저장소도 당분간 보존합니다. 만약 전환 이후에 새로 쓰인 파일까지 살리면서 이전 저장소로 되돌아가야 한다면 신규 객체와 데이터베이스 참조를 함께 맞춰야 합니다.

서로 독립된 두 Ankole 사이트가 같은 버킷 prefix를 공유하게 두지 마세요. 한 사이트의 가비지 컬렉션이 실행될 때 다른 사이트에서 참조 중인 객체까지 미사용 파일로 판단해 지워 버릴 수 있습니다. 반대로 같은 사이트에 속한 복제본들은 모두 동일한 저장소 설정을 공유해야 합니다.

## 백업과 정리

데이터베이스 백업에는 메타데이터와 참조만 들어 있고 실제 파일 바이트는 버킷이나 로컬 폴더에 있으므로, 백업과 복원은 항상 두 저장소를 함께 묶어 수행해야 합니다. 컨트롤 플레인의 가비지 컬렉션은 Agent 드라이브, Pod `file` 페이지, Pod 문서/Base/Chat 및 대화 첨부 파일, 컴파일된 Applet 번들 등 모든 소유 참조에서 어디에서도 가리키지 않는 미사용 blob만 골라 삭제합니다. 따라서 버킷 측에 아직 참조 중인 정상 객체까지 만료 삭제하는 수명 주기(lifecycle) 규칙을 걸어 두어서는 안 됩니다.

다만 S3 멀티파트 업로드 도중 프로세스가 끊기면 미완료 업로드 조각이 버킷에 남을 수 있으므로, 워크로드에 맞는 유예 기간 뒤에 미완료 멀티파트 업로드만 정리(abort)하는 수명 주기 규칙은 설정해 두는 것이 좋습니다. `fs` 백엔드는 저장소를 열 때 생성된 지 하루가 넘도록 갱신되지 않은 임시 파일을 스스로 정리하지만, 이러한 정리 동작이 정기 백업을 대신하지는 않습니다.

점검 시에는 먼저 Worker가 떠 있지 않은 상태에서 Console을 통해 파일을 업로드·다운로드해 보고, 이어서 Worker 하나를 띄워 파일 접근과 첨부 전송까지 확인하세요. `AccessDenied`가 나면 실행 신원과 버킷 정책을, `fs` 쓰기 오류가 나면 볼륨 마운트·uid `10001` 권한·디스크 잔여 용량을, 마이그레이션 후 기존 파일 누락이 보이면 버킷·리전·prefix 설정과 `blobs/` 복사 결과를 점검하세요. 자세한 백업 절차는 [백업과 복원](../backup-and-restore/)을, 구버전 파일 이전은 [2.0 업그레이드](../upgrade-to-2/)를 참조하세요.
