---
title: Deployment 환경 변수
description: 컨트롤 플레인과 Agent Computer Worker가 프로세스 시작 시 읽는 배포 환경 변수를 정리합니다.
section: Reference
order: 202
---

이 문서는 PostgreSQL, Pod Base 샤드 데이터베이스, `ankole-function-runtime`, 배포 시크릿, 객체 저장소, 프로세스 튜닝을 위해 시작 시점에 읽는 환경 변수를 설명합니다. 참고로 Worker 프로바이더 구성은 환경 변수가 아니라 PostgreSQL에 YAML 형태로 저장됩니다.

인스턴스가 실행 중인 상태에서 관리자가 실시간으로 변경할 수 있는 런타임 설정은 [애플리케이션 설정](../app-configuration/)을 참조하세요. 그러한 운영 설정을 `.env` 파일이나 Kubernetes Secret에 넣지 마세요.

## Bootstrap과 secret(프로세스 시작)

아래 변수들은 컨트롤 플레인이 부팅되기 전에 반드시 준비되어 있어야 합니다. Docker Compose에서는 `.env`에, Kubernetes에서는 Helm 차트가 참조하는 Secret에 설정하세요.

| 변수 | 필수 | 의미 |
|---|---|---|
| `DATABASE_URL` | 예 (`prod`) | 컨트롤 플레인(`Ankole.Repo`)용 PostgreSQL 18+ 연결 문자열 |
| `BASE_DB_URLS` | 아니요 | 물리 Pod Base 샤드(`Ankole.Pod.BaseRepo`)용 선택적 `;` 구분 PostgreSQL 18+ URL 목록. 쿼리 파라미터 `ankole_sharding`, `ankole_pool_size`, `ankole_stock_only`를 지원하며, 단일 DB FOSS 배포에서 비워 두면 `DATABASE_URL`을 `base_default`로 사용하고 `sslmode`가 포함되면 부팅을 거부합니다 |
| `ANKOLE_SECRET_BASE` | 예 (`prod`) | 사이트 전체 마스터 시크릿. 암호화 키와 서명 키를 파생하는 데 사용합니다 |
| `RELEASE_COOKIE` | 예 (`prod`) | Erlang 분산 쿠키. 같은 배포에 속한 모든 컨트롤 플레인 노드가 동일한 값을 사용해야 합니다 |
| `ANKOLE_FUNCTION_RUNTIME_TOKEN` | 예 (`prod`) | 컨트롤 플레인과 `ankole-function-runtime`이 공유하는 내부 Bearer 시크릿 |
| `ANKOLE_FUNCTION_RUNTIME_URL` | 예 (`prod`) | `ankole-function-runtime`의 내부 HTTP URL(예: Compose의 `http://function-runtime:9000`) |
| `POSTGRES_PASSWORD` | 번들 PostgreSQL만 | PostgreSQL 비밀번호(번들 PostgreSQL을 켰을 때 필수이며, 외부 DB를 쓸 때는 `DATABASE_URL` 또는 외부 Secret으로 제공) |
| `ANKOLE_HOST` | Compose | 배포 인스턴스가 서비스되는 공개 DNS 호스트명 |
| `ACME_EMAIL` | Compose | Caddy가 Let's Encrypt 인증서 발급·안내에 사용하는 이메일 주소 |
| `ANKOLE_DOCKER_GID` | Compose | Docker 소켓 그룹 ID. 비특권 사용자로 실행되는 컨트롤 플레인이 이 그룹 권한으로 소켓에 접근합니다 |

이 값들은 `.env` 파일이나 Secret에만 보관하고 버전 관리 저장소에는 절대 커밋하지 마세요. Docker Compose 배포는 `.env.example`을 복사해 시작하면 됩니다.

Worker 인증용 키를 `.env`나 Secret에 따로 넣을 필요는 없습니다. 컨트롤 플레인이 각 Worker를 생성할 때 고유한 자격 증명을 직접 발급합니다.

Helm 차트의 `values.yaml`에서 이에 대응하는 설정 경로는 `secrets.ankoleSecretBase`, `secrets.releaseCookie`, `secrets.functionRuntimeToken`, `secrets.databaseURL`, `secrets.baseDBURLs`, `secrets.postgresqlPassword`, `controlPlane.siteAdminConsolePath`, `functionRuntime.*`입니다.

## Runtime 튜닝(프로세스 환경)

아래 변수들은 프로세스 시작 시 읽혀 컨트롤 플레인 또는 `ankole-function-runtime`의 동작을 조정합니다. 민감한 시크릿이 아닌 일반 환경 값입니다.

| 변수 | 기본값 | 의미 |
|---|---|---|
| `ANKOLE_ENV` | — | 배포 환경 레이블(예: `prod`, `dev`) |
| `ANKOLE_LOG_LEVEL` | `info` | 로그 출력 레벨(`debug`, `info`, `warning`, `error`) |
| `POOL_SIZE` | `10` | 컨트롤 플레인 프로세스가 직접 읽는 `Ankole.Repo` 데이터베이스 커넥션 풀 크기 |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | Docker Compose `.env`용 변수(`compose.yaml`에서 `POOL_SIZE`로 매핑됨) |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | `300` | 번들 PostgreSQL 서버의 `max_connections` 설정값 |
| `ANKOLE_SITE_ADMIN_CONSOLE_PATH` | `/site-admin-console` | Site Admin Console 접속 URL 경로 |
| `ANKOLE_FUNCTION_RUNTIME_IMAGE` | 릴리스 기본값 | Docker Compose에서 실행할 `ankole-function-runtime` 컨테이너 이미지 |
| `ANKOLE_FUNCTION_RUNTIME_MAX_CONCURRENCY` | `32` | `ankole-function-runtime` 컨테이너당 최대 동시 실행 수 |
| `ANKOLE_LIBRARY_ROOT` | 차트 기본값 | 번들 Agent Library(`app/library`) 경로 |
| `ANKOLE_INTERNAL_SKILLS_ROOT` | — | 내부 전용 Skill 번들 경로 |
| `ANKOLE_AI_GATEWAY_BASE_URL` | — | AIGateway 기본 URL 재정의 |

## 파일 저장소(프로세스 시작)

`ANKOLE_FILES_STORE`는 컨트롤 플레인 객체 저장소(`Ankole.ObjectStore`) 백엔드를 지정합니다. 이곳에는 각 Agent의 드라이브(수신 첨부 파일, 생성된 이미지, 발신 첨부 파일, 설치된 Skill, Automation Job 스크립트, 직접 저장한 파일)는 물론 Pod `file` 페이지, Pod 문서/Base/Chat 첨부 파일, 컴파일된 Applet 번들까지 함께 보관됩니다. Worker에는 스토리지 자격 증명이 전달되지 않으며 모든 파일 바이트는 컨트롤 플레인을 경유해 오갑니다. 지원하는 전체 OpenDAL 백엔드 목록과 설정법은 [제어면 드라이브 및 객체 저장소 설정](../drive-storage/)을 참조하세요.

| 변수 | 필수 | 의미 |
|---|---|---|
| `ANKOLE_FILES_STORE` | 예 | `fs`는 컨트롤 플레인 영속 볼륨 내 로컬 디렉터리, `s3`는 Amazon S3 또는 Cloudflare R2 같은 S3 호환 스토리지 |
| `ANKOLE_FILES_FS_ROOT` | `fs` | 로컬 파일 저장소의 절대 경로. Docker Compose는 `/var/lib/ankole/files`에 마운트된 `files_data` 볼륨을 사용합니다 |
| `ANKOLE_FILES_S3_BUCKET` | `s3` | 대상 S3 버킷 이름 |
| `ANKOLE_FILES_S3_REGION` | `s3` | 버킷 리전. Cloudflare R2는 `auto` |
| `ANKOLE_FILES_S3_ENDPOINT` | 아니요 | S3 호환 스토리지의 엔드포인트 URL |
| `ANKOLE_FILES_S3_ROOT` | 아니요 | 버킷 내부 객체 키 접두사(prefix) |
| `ANKOLE_FILES_S3_ACCESS_KEY_ID`, `ANKOLE_FILES_S3_SECRET_ACCESS_KEY` | 아니요 | 정적 자격 증명. 생략하면 EKS Pod Identity를 포함한 기본 AWS 자격 증명 체인을 따릅니다 |

`fs` 백엔드는 컨트롤 플레인 복제본이 하나일 때만 사용할 수 있습니다. 복제본을 둘 이상 띄우려면 `s3` 등 공유 원격 백엔드를 사용하세요.

`s3`에 큰 파일을 기록할 때는 멀티파트 업로드를 사용합니다. 업로드 도중 컨트롤 플레인이 중단되면 미완료 조각이 버킷에 남을 수 있으므로, 미완료 멀티파트 업로드를 자동 정리하는 수명 주기 규칙을 버킷에 설정하세요.

## Worker Provider 초기 설정

아래 부트스트랩 변수들은 배포 식별자와 기본 Worker 이미지를 지정합니다. 개별 프로바이더는 **Console → Workers → Providers**에서 YAML로 관리하며 자격 증명은 별도로 암호화해 저장합니다. 한 번 생성한 프로바이더의 종류, 위치, 영속 스토리지 모드는 바꿀 수 없으며, 인스턴스 사양을 수정하면 해당 Agent가 유휴 상태가 되었을 때 새 설정으로 반영됩니다.

| 변수 | 의미 |
|---|---|
| `ANKOLE_AGENT_COMPUTER_IMAGE` | 컨트롤 플레인 릴리스와 짝을 이루는 Worker 컨테이너 이미지 |
| `ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT` | 기본 RuntimeFabric WebSocket URL |
| `ANKOLE_WORKER_INSTALLATION` | 배포 설치 레이블(기본값 `ankole`) |
| `ANKOLE_WORKER_PROVIDERS_FILE` | 선택적 프로바이더 시드 YAML 경로. 최초 가져오기와 등록된 Agent 할당을 단일 트랜잭션으로 처리합니다 |

`bun dev` 로컬 개발 환경의 소스 코드 및 내부 Skill 마운트는 `config/dev.exs`에서 구성되며, 프로덕션 릴리스 이미지에는 개발용 마운트가 포함되지 않습니다.

## Provider egress 프록시

모델 프로바이더로 나가는 아웃바운드 트래픽이 프록시를 거쳐야 할 때는 컨트롤 플레인 프로세스에 다음 표준 환경 변수를 설정하세요(`https_proxy`처럼 소문자로 표기해도 동일하게 인식됩니다).

| 변수 | 의미 |
|---|---|
| `HTTPS_PROXY` | HTTPS 및 보안 WebSocket(`wss`) 프로바이더 요청용 프록시 |
| `HTTP_PROXY` | HTTP 및 일반 WebSocket(`ws`) 프로바이더 요청용 프록시(`HTTPS_PROXY`와 `ALL_PROXY`가 모두 없을 때는 보안 요청도 이 값을 사용) |
| `ALL_PROXY` | 프로토콜별 프록시 변수가 지정되지 않았을 때 사용할 대체(fallback) 프록시 |
| `NO_PROXY` | 프록시를 거치지 않고 직접 연결할 호스트명 또는 도메인 접미사 목록(쉼표로 구분) |

프록시 URL 스킴으로는 `http`, `https`, `socks5`, `socks5h`를 사용할 수 있으며, 프록시 인증이 필요할 때는 URL 안에 자격 증명을 포함할 수 있습니다. 어떤 경우든 `NO_PROXY`에 매칭되는 대상이 항상 우선합니다. 보안 연결(`https`/`wss`)에서는 `HTTPS_PROXY` → `ALL_PROXY` → `HTTP_PROXY` 순서로 적용 대상을 찾고, 일반 연결(`http`/`ws`)에서는 `HTTP_PROXY` → `ALL_PROXY` 순서로 찾습니다. 프록시 변수를 수정한 뒤에는 컨트롤 플레인을 재시작하세요.

## Worker 전용 환경(Agent Computer Worker)

아래 변수들은 컨트롤 플레인이 Worker 인스턴스를 기동할 때 직접 주입하는 전용 변수이므로 운영자가 수동으로 설정하지 않습니다. Worker는 `WORKER_ID`를 보고 자신이 담당할 Agent를 식별하며, 개별 Session과 Turn 정보는 환경 변수가 아니라 매 `turn_start` 메시지로 전달받습니다.

| 변수 | 의미 |
|---|---|
| `WORKER_ID` | 담당 Agent UID. 해당 Worker는 오직 이 Agent의 작업만 처리합니다 |
| `ANKOLE_RUNTIME_FABRIC_ENDPOINT` | Worker가 접속할 `ws://` 또는 `wss://` RuntimeFabric 주소 |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | 해당 generation 전용 무작위 인증 키(컨트롤 플레인은 해시와 재시도용 암호화 값만 보관) |
| `ANKOLE_WORKER_STORAGE` | 프로바이더가 지정하는 스토리지 준비 모드 |

추가 Worker 환경 변수는 프로바이더 YAML의 `env` 또는 Kubernetes `podTemplate`에서 지정할 수 있습니다. `ANKOLE_MAX_CONCURRENT_SLOTS`는 단일 Worker 내 환경 워크스페이스와 Codex 턴의 동시 실행 상한을 제어하며 기본값은 `12`입니다(일반 모델 턴은 이 슬롯을 점유하지 않음). 프로바이더 환경 설정을 바꾸면 Agent가 유휴 상태일 때 Worker가 교체됩니다.

브라우저 실행 경로와 내장 Skill 경로(`ANKOLE_BROWSER_*`, `ANKOLE_BUILTIN_SKILLS_ROOT` 등)는 Worker 이미지 내부에 고정되어 있으며 관리자가 임의로 변경할 수 없습니다.

또한 `PATH`, `HOME`, `DATABASE_URL` 및 `ANKOLE_` 접두사로 시작하는 변수 이름은 Agent 환경 편집기에서 예약어로 보호됩니다. 프로바이더 YAML에서 허용된 항목만 설정할 수 있으며, 사용자 정의 환경 변수 관리 방법은 [환경 변수](../worker-env/)를 참조하세요.

## Deployment 환경 변수 변경

프로세스 시작 변수를 바꾸려면 Docker Compose의 `.env` 또는 Helm `values`를 수정한 뒤 해당 프로세스를 재시작하세요. Worker 프로바이더 설정은 Console에서 편집하며, 이미 한 번 반영된 시드 파일은 저장된 프로바이더 설정을 덮어쓰지 않습니다. 이미지나 인스턴스 사양을 변경하면 각 Agent가 유휴 상태에 들어갔을 때 Worker가 순차 교체됩니다.

## 다음 단계

- Agent 내부 도구와 스크립트에 주입하는 사용자 정의 값은 [Environment variables](../worker-env/)를 참조하세요.
- 무중단으로 조정 가능한 런타임 설정과 전체 AppConfigure 키 목록은 [AppConfigure](../app-configuration/)를 참조하세요.
- 실제 배포 절차 속에서 각 변수가 쓰이는 맥락은 [Quick start의 deployment 섹션](../quickstart/#deployment)을 참조하세요.
