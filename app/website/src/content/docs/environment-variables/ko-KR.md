---
title: Deployment 환경 변수
description: control plane과 Agent Computer Worker가 프로세스 시작 시 읽는 deployment 설정을 설명합니다.
section: Reference
order: 202
---

이 페이지는 PostgreSQL, Pod Base 샤드 데이터베이스, `ankole-function-runtime`, 배포 비밀 정보, 객체 저장소, 프로세스 설정의 시작 변수를 설명합니다. Worker provider 설정은 PostgreSQL에 YAML로 저장됩니다.

인스턴스 실행 중에 관리자가 변경할 수 있는 runtime 설정은 [애플리케이션 설정](../app-configuration/)을 참조하십시오. 그런 설정을 `.env`나 Kubernetes Secret에 넣지 마십시오.

## Bootstrap과 secret(프로세스 시작)

이 변수들은 control plane이 시작되기 전에 존재해야 합니다. Docker Compose의 경우 `.env`에, Helm chart가 읽는 경우에는 Secret에 설정하십시오.

| 변수 | 필수 | 의미 |
|---|---|---|
| `DATABASE_URL` | 예 (`prod`) | control plane(`Ankole.Repo`)용 PostgreSQL 18+ connection string |
| `BASE_DB_URLS` | 아니요 | 물리 Pod Base 샤드(`Ankole.Pod.BaseRepo`)용 선택적 `;` 구분 PostgreSQL 18+ URL 목록. 쿼리 파라미터 `ankole_sharding`, `ankole_pool_size`, `ankole_stock_only`를 지원하며, 단일 DB FOSS 배포에서 비워 두면 `DATABASE_URL`을 `base_default`로 사용하고 `sslmode`는 거부합니다 |
| `ANKOLE_SECRET_BASE` | 예 (`prod`) | 사이트 전체 secret base; 암호화 및 서명 키를 파생하는 데 사용 |
| `RELEASE_COOKIE` | 예 (`prod`) | Erlang distribution cookie; 같은 배포의 모든 컨트롤 플레인 노드가 같은 값을 사용 |
| `ANKOLE_FUNCTION_RUNTIME_TOKEN` | 예 (`prod`) | control plane과 `ankole-function-runtime`이 공유하는 내부 Bearer 시크릿 |
| `ANKOLE_FUNCTION_RUNTIME_URL` | 예 (`prod`) | `ankole-function-runtime`의 내부 HTTP URL(예: Compose의 `http://function-runtime:9000`) |
| `POSTGRES_PASSWORD` | 번들 PostgreSQL만 | PostgreSQL 비밀번호(번들 PostgreSQL이 활성화된 경우 필수, 그 외에는 `DATABASE_URL` 또는 외부 Secret이 제공) |
| `ANKOLE_HOST` | Compose | deployment가 서비스되는 공개 DNS 이름 |
| `ACME_EMAIL` | Compose | Caddy가 Let's Encrypt에 사용하는 이메일 |
| `ANKOLE_DOCKER_GID` | Compose | Docker socket 그룹 ID; control plane은 비특권 사용자로 실행되며 이 그룹을 통해 socket을 사용 |

이 값들은 `.env`나 Secret에 보관하십시오. 버전 관리에 커밋하지 마십시오. Docker Compose의 `.env.example`이 시작 구성입니다.

Worker용 key는 `.env`나 Secret에 필요하지 않습니다. control plane이 각 Worker에 고유한 자격 증명을 부여합니다.

Helm chart의 `values.yaml`에서 대응하는 설정 경로는 `secrets.ankoleSecretBase`, `secrets.releaseCookie`, `secrets.functionRuntimeToken`, `secrets.databaseURL`, `secrets.baseDBURLs`, `secrets.postgresqlPassword`, `controlPlane.siteAdminConsolePath`, `functionRuntime.*`입니다.

## Runtime 튜닝(프로세스 환경)

이 변수들은 시작 시 읽혀 control plane 또는 `ankole-function-runtime` 프로세스를 튜닝합니다. secret이 아닙니다.

| 변수 | 기본값 | 의미 |
|---|---|---|
| `ANKOLE_ENV` | — | deployment 환경 라벨(예: `prod`, `dev`) |
| `ANKOLE_LOG_LEVEL` | `info` | log 레벨(`debug`, `info`, `warning`, `error`) |
| `POOL_SIZE` | `10` | control-plane 프로세스가 직접 읽는 `Ankole.Repo` 데이터베이스 커넥션 풀 크기 |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | Docker Compose `.env` 변수(`compose.yaml`이 `POOL_SIZE`로 매핑) |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | `300` | 번들 서버용 PostgreSQL `max_connections` 설정 |
| `ANKOLE_SITE_ADMIN_CONSOLE_PATH` | `/site-admin-console` | Site Admin Console URL 경로 |
| `ANKOLE_FUNCTION_RUNTIME_IMAGE` | 릴리스 기본값 | Docker Compose에서 사용하는 `ankole-function-runtime` 컨테이너 이미지 |
| `ANKOLE_FUNCTION_RUNTIME_MAX_CONCURRENCY` | `32` | `ankole-function-runtime` 컨테이너당 최대 동시 실행 수 |
| `ANKOLE_LIBRARY_ROOT` | chart 기본값 | 번들 Agent Library(`app/library`) 경로 |
| `ANKOLE_INTERNAL_SKILLS_ROOT` | — | 내부 skill bundle 경로 |
| `ANKOLE_AI_GATEWAY_BASE_URL` | — | AIGateway base URL override |

## 파일 저장소(프로세스 시작)

`ANKOLE_FILES_STORE`는 컨트롤 플레인 객체 저장소(`Ankole.ObjectStore`)를 설정하며, 각 Agent의 드라이브(첨부 파일, 생성된 이미지, 보낸 파일, 설치된 Skill, Automation Job 스크립트, 저장한 파일)와 더불어 Pod `file` 페이지, Pod 문서/Base/Chat 첨부 파일, 컴파일된 Applet 번들을 함께 보관합니다. Worker는 저장소 자격 증명을 받지 않으며, 파일 바이트는 컨트롤 플레인을 거쳐 이동합니다. 지원하는 모든 OpenDAL 백엔드는 [제어면 드라이브 및 객체 저장소 설정](../drive-storage/)을 참조하세요.

| 변수 | 필수 | 의미 |
|---|---|---|
| `ANKOLE_FILES_STORE` | 예 | `fs`는 컨트롤 플레인 영구 볼륨의 디렉터리, `s3`는 Amazon S3 또는 Cloudflare R2 같은 S3 호환 저장소 |
| `ANKOLE_FILES_FS_ROOT` | `fs` | 저장소의 절대 경로. Docker Compose는 `/var/lib/ankole/files`에 마운트한 `files_data` 볼륨을 사용합니다 |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | 버킷 |
| `ANKOLE_FILES_S3_REGION` | `s3` | 리전. Cloudflare R2는 `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | 아니요 | S3 호환 저장소의 엔드포인트 |
| `ANKOLE_FILES_S3_ROOT` | 아니요 | 버킷 안의 키 접두사 |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID`, `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | 아니요 | 정적 자격 증명. 설정하지 않으면 EKS Pod Identity를 포함한 기본 AWS 자격 증명 체인을 사용합니다 |

`fs` 저장소는 컨트롤 플레인 복제본 하나만 허용합니다. 복제본을 둘 이상 실행하려면 `s3`를 사용합니다.

`s3`에 쓰는 큰 파일은 멀티파트 업로드입니다. 업로드 중에 컨트롤 플레인이 멈추면 파트가 버킷에 남으므로, 완료되지 않은 멀티파트 업로드를 중단하는 수명 주기 규칙을 버킷에 설정하세요.

## Worker Provider 초기 설정

시작 값은 배포와 대상 Worker 이미지를 지정합니다. 각 provider는 **Console → Workers → Providers**의 YAML로 설정하며 자격 증명은 별도로 암호화해 저장합니다. 생성 후에는 유형, 위치, 영구 스토리지를 변경할 수 없습니다. 인스턴스 설정은 Agent가 유휴 상태일 때 적용합니다.

| 변수 | 의미 |
|---|---|
| `ANKOLE_AGENT_COMPUTER_IMAGE` | control plane 릴리스에 해당하는 Worker 이미지 |
| `ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT` | 기본 RuntimeFabric WebSocket URL |
| `ANKOLE_WORKER_INSTALLATION` | 배포 레이블. 기본값은 `ankole` |
| `ANKOLE_WORKER_PROVIDERS_FILE` | 선택적 provider seed YAML. 최초 가져오기와 기존 Agent 할당은 같은 트랜잭션 |

`bun dev`의 소스와 내부 Skill 마운트는 `config/dev.exs`에서 설정합니다. 릴리스에는 개발용 마운트가 없습니다.

## Provider egress 프록시

model-provider 트래픽이 아웃바운드 proxy를 사용해야 할 때 control-plane 프로세스에 이러한 표준 변수를
설정하십시오. `https_proxy` 같은 소문자 형식도 동작합니다.

| 변수 | 의미 |
|---|---|
| `HTTPS_PROXY` | HTTPS 및 보안 WebSocket(`wss`) provider 요청용 proxy |
| `HTTP_PROXY` | HTTP 및 WebSocket(`ws`) provider 요청용 proxy; `HTTPS_PROXY`나 `ALL_PROXY` 값이 없으면 보안 요청도 이를 사용합니다 |
| `ALL_PROXY` | protocol별 변수가 없을 때 provider 요청용 대체(fallback) proxy |
| `NO_PROXY` | 직접 연결해야 하는 쉼표로 구분된 호스트 또는 도메인 접미사 |

proxy URL은 `http`, `https`, `socks5` 또는 `socks5h`를 사용할 수 있으며, proxy가 인증을
요구하면 임베디드 credential도 포함할 수 있습니다. `NO_PROXY`가 항상 우선합니다.
보안 요청의 경우 Ankole은 `HTTPS_PROXY`, 그다음 `ALL_PROXY`, 그다음
`HTTP_PROXY` 순으로 시도합니다. 일반 요청은 `HTTP_PROXY`, 그다음 `ALL_PROXY` 순으로
시도합니다. 이 변수들을 변경한 후 control plane을 다시 시작하십시오.

## Worker 전용 환경(Agent Computer Worker)

control plane이 Worker를 만들 때 이 변수들을 설정합니다. 운영자는 설정하지 않습니다. Worker는 `WORKER_ID`로 자신의 Agent를 알고, Session과 Turn은 환경이 아니라 각 `turn_start`로 전달됩니다.

| 변수 | 의미 |
|---|---|
| `WORKER_ID` | Agent UID; Worker는 이 Agent만 서비스합니다 |
| `ANKOLE_RUNTIME_FABRIC_ENDPOINT` | Worker가 연결하는 `ws://` 또는 `wss://` RuntimeFabric URL |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | generation의 무작위 자격 증명. control plane은 해시와 암호화된 재시도 값을 저장 |
| `ANKOLE_WORKER_STORAGE` | provider가 지정하는 스토리지 준비 모드 |

Worker 환경은 provider YAML의 `env` 또는 Kubernetes `podTemplate`에 설정합니다. `ANKOLE_MAX_CONCURRENT_SLOTS`는 Worker의 환경 workspace와 Codex turn을 제한하며 기본값은 12입니다. model turn은 Worker slot을 쓰지 않습니다. 설정을 바꾸면 유휴 시 교체합니다.

Worker image는 browser와 Skill 경로를 설정합니다. 여기에는 `ANKOLE_BROWSER_*`와 `ANKOLE_BUILTIN_SKILLS_ROOT`가 포함됩니다. 관리자는 이 경로들을 변경할 수 없습니다.

`PATH`, `HOME`, `DATABASE_URL`, `ANKOLE_`로 시작하는 이름은 Agent 환경 편집기에서 예약됩니다. provider YAML의 지원 설정은 지정할 수 있습니다. [환경 변수](../worker-env/)를 참조하세요.

## Deployment 환경 변수 변경

시작 변수는 Compose `.env` 또는 Helm values에서 변경하고 해당 프로세스를 재시작하세요. provider는 Console에서 변경합니다. 이미 가져온 seed 파일은 기존 설정을 덮어쓰지 않습니다. 이미지나 인스턴스 설정을 변경하면 Agent가 유휴 상태일 때 Worker를 교체합니다.

## 다음 단계

- Agent가 사용하는 사용자 정의 값은 [Environment variables](../worker-env/)를 읽으십시오.
- runtime 설정과 전체 AppConfigure key 목록은 [AppConfigure](../app-configuration/)를 읽으십시오.
- 맥락 속의 deployment 변수는 [Quick start의 deployment 섹션](../quickstart/#deployment)을 읽으십시오.
