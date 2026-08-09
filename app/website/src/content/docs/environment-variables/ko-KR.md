---
title: Deployment 환경 변수
description: control plane과 Agent Computer Worker가 프로세스 시작 시 읽는 deployment 설정을 설명합니다.
section: Reference
order: 202
---

이 페이지는 Ankole이 프로세스 시작 시 읽는 deployment 환경 변수만 나열합니다. 이 변수들은 PostgreSQL 연결, 인스턴스 secret 설정, RuntimeFabric 시작, control-plane 및 Worker 프로세스 튜닝에 사용됩니다.

[AppConfigure](../app-configuration/) 가이드가 이제 인스턴스 실행 중에 관리자가 변경할 수 있는 runtime 설정을 담당합니다. 그런 설정을 `.env`나 Kubernetes Secret에 넣지 마십시오.

## Bootstrap과 secret(프로세스 시작)

이 변수들은 control plane이 시작되기 전에 존재해야 합니다. Docker Compose의 경우 `.env`에, Helm chart가 읽는 경우에는 Secret에 설정하십시오.

| 변수 | 필수 | 의미 |
|---|---|---|
| `DATABASE_URL` | 예 | control plane용 PostgreSQL connection string |
| `ANKOLE_SECRET_BASE` | 예 | 인스턴스 전체 secret base; 다른 key를 파생하는 데 사용 |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | 예 | worker가 RuntimeFabric에 제시하는 auth key |
| `POSTGRES_PASSWORD` | 번들 PostgreSQL만 | PostgreSQL 비밀번호(번들 PostgreSQL이 활성화된 경우 필수, 그 외에는 외부 Secret이 제공) |
| `ANKOLE_HOST` | Compose | deployment가 서비스되는 DNS 이름 |
| `ACME_EMAIL` | Compose | Caddy가 Let's Encrypt에 사용하는 이메일 |

이 값들은 `.env`나 Secret에 보관하십시오. 버전 관리에 커밋하지 마십시오. Docker Compose의 `.env.example`이 시작 configuration입니다.

Helm chart의 `values.yaml`은 관련 Kubernetes 값을 나열합니다. `ankoleSecretBase`, `workerAuthKey`, `postgresqlPassword`입니다.

## Runtime 튜닝(프로세스 환경)

이 변수들은 시작 시 읽혀 실행 중인 프로세스를 튜닝합니다. secret이 아닙니다.

| 변수 | 기본값 | 의미 |
|---|---|---|
| `ANKOLE_ENV` | — | deployment 환경 라벨(예: `prod`, `dev`) |
| `ANKOLE_LOG_LEVEL` | `info` | log 레벨(`debug`, `info`, `warning`, `error`) |
| `ANKOLE_LOG_FORMAT` | `json` | log 줄 형식(`json`은 수집용, `pretty`는 로컬 읽기용) |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | control-plane database connection pool 크기 |
| `ANKOLE_POSTGRES_MAX_CONNECTIONS` | `300` | 번들 서버용 PostgreSQL `max_connections` 설정 |
| `ANKOLE_MAX_CONCURRENT_TURNS` | `9` | 동시 actor turn 수 상한 |
| `ANKOLE_LIBRARY_ROOT` | chart 기본값 | 번들 Agent Library(`app/library`) 경로 |
| `ANKOLE_INTERNAL_SKILLS_ROOT` | — | 내부 skill bundle 경로 |
| `ANKOLE_AI_GATEWAY_BASE_URL` | — | AIGateway base URL override(거의 필요하지 않음) |
| `ANKOLE_RUNTIME_FABRIC_BIND_ENDPOINT` | — | RuntimeFabric 바인드 엔드포인트 |

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

worker는 작고 고정된 환경 변수 집합을 읽습니다. actor identity는 여기에 **없습니다** — 환경이 아니라 `turn_start`로 전달됩니다. 이 변수들은 운영자가 아니라 관리형 worker bootstrap이 설정합니다.

| 변수 | 의미 |
|---|---|
| `WORKER_ID` | worker identity(예: `worker-local-1`) |
| `ANKOLE_RUNTIME_FABRIC_ENDPOINT` | RuntimeFabric TCP 엔드포인트 |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | RuntimeFabric worker auth key; endpoint와 별개입니다 |
| `ANKOLE_AGENTS_ROOT` | 공유 `/agents` workspace 마운트의 루트 |
| `ANKOLE_AGENT_COMPUTER_IMAGE` | worker가 실행하는 Agent Computer Worker image |
| `ANKOLE_VERSION` | Ankole 버전 라벨 |

Worker image는 browser, Bubblewrap, Codex, Skill 경로를 설정합니다. 여기에는 `ANKOLE_BROWSER_*`, `ANKOLE_BWRAP_PATH`, `ANKOLE_CODEX_BINARY`, `ANKOLE_BUILTIN_SKILLS_ROOT`가 포함됩니다. 관리자는 이 경로들을 변경할 수 없습니다.

`PATH`, `HOME`, `DATABASE_URL` 및 `ANKOLE_`로 시작하는 이름은 예약되어 있으며 Console에서 변경할 수 없습니다. Agent별 사용자 정의 값은 [Environment variables](../worker-env/)를 참조하십시오.

## Deployment 환경 변수 변경

- Docker Compose를 사용하는 경우 `.env`를 변경하고 영향을 받는 container를 다시 시작하십시오.
- Kubernetes를 사용하는 경우 Helm values 또는 관련 Secret을 변경하고 영향을 받는 workload를 다시 시작하십시오.

프로세스는 시작할 때만 이 변수들을 읽습니다. 프로세스를 다시 시작하지 않고 파일이나 Secret만 변경하면 현재 runtime은 변하지 않습니다.

## 다음 단계

- Agent가 사용하는 사용자 정의 값은 [Environment variables](../worker-env/)를 읽으십시오.
- runtime 설정과 전체 AppConfigure key 목록은 [AppConfigure](../app-configuration/)를 읽으십시오.
- 맥락 속의 deployment 변수는 [Quick start의 deployment 섹션](../quickstart/#deployment)을 읽으십시오.