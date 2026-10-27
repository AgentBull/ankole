---
title: kit CLI 레퍼런스
description: devkit 명령 표면 — 운영자나 contributor가 실행하는 모든 `bun run kit` 명령, 각 명령의 역할, 그리고 이를 감싸는 script에 대해 설명합니다.
section: Reference
order: 200
---

`kit`은 Ankole의 devkit 명령줄 도구입니다. 저장소 루트에서 `bun run kit <command>` 형식으로 실행하며, 호스트 환경 설정, 로컬 서비스 관리, 개발 환경 구동, 데이터베이스 수명 주기, 활성화 코드 조회, 로그 출력, 코드 생성, 저장소 정적 분석을 담당합니다. 이 문서는 주요 `kit` 명령어를 정리한 레퍼런스입니다.

`kit`은 `tools/devkit/` 아래에 구현된 Bun + TypeScript 프로그램입니다. 자주 쓰는 명령(`services:start`, `services:stop`, `dev`, `analyze` 등)은 저장소 루트의 `package.json` 스크립트에 별칭(alias)으로 등록되어 있으므로, 매번 `bun run kit` 전체를 입력하지 않아도 동일하게 실행할 수 있습니다.

## 환경과 감지

| 명령 | 역할 |
|---|---|
| `kit env-setup` | 시스템 빌드 패키지, Docker, Rust, Elixir/Erlang 툴체인, 버전이 고정된(pinned) Bun 등 Ankole 개발에 필요한 호스트 툴체인을 설치합니다. `--print` 옵션을 붙이면 실제 설치를 수행하지 않고 실행할 명령만 출력합니다. |
| `kit is-ci` | CI 환경에서 실행 중이면 종료 코드 `0`, 아니면 `1`을 반환합니다. CI 여부에 따라 분기하는 스크립트에서 사용합니다. |
| `kit is-dev` | 개발 환경에서 실행 중이면 종료 코드 `0`, 아니면 `1`을 반환합니다. |

새 개발 머신을 준비할 때 `env-setup`을 한 번 실행하십시오. 나머지 두 명령은 다른 스크립트나 명령이 내부적으로 호출하는 환경 감지 헬퍼입니다.

## 로컬 service와 개발 환경

| 명령 | 역할 |
|---|---|
| `kit external-services start` | devkit용 Docker Compose 서비스(PostgreSQL 18 및 `ankole-function-runtime`)를 시작합니다. `bun run services:start`로도 실행할 수 있습니다. |
| `kit external-services stop` | devkit용 Compose 서비스를 중지합니다. `bun run services:stop`으로도 실행할 수 있습니다. |
| `kit external-services status` | devkit 서비스의 현재 상태를 출력합니다. `bun run services:status`로도 실행할 수 있습니다. |
| `kit dev` | PostgreSQL 18, `ankole-function-runtime`, Phoenix 및 프런트엔드 자산, Agent별 Worker 컨테이너를 생성하는 Docker Worker 백엔드까지 전체 개발 환경을 시작합니다. `bun run dev`로도 실행할 수 있으며, 개발 중에는 해당 터미널을 열어 둡니다. |

로컬 스택 전체를 한 번에 띄울 때는 `kit dev`를 사용합니다. 이 명령을 실행하면 PostgreSQL 18과 `ankole-function-runtime`을 기동(또는 상태 확인)한 뒤 로컬 control-plane 데이터베이스(`ankole_dev`)를 생성해 마이그레이션하고, 누락되었거나 오래된 Worker 이미지를 빌드한 다음 Docker Worker 백엔드를 연결해 control plane을 시작합니다. `BASE_DB_URLS`가 설정되어 있지 않으면 개발 부트스트랩 과정에서 로컬 Base 샤드 데이터베이스 네 개(`ankole_base_00`~`ankole_base_03`)도 자동으로 생성해 초기화합니다.

이후 Agent를 생성하면 control plane이 해당 Agent 전용 Worker 컨테이너를 만들고, 컨테이너 내부에서는 로컬 Agent Computer 소스를 `bun --watch`로 실행합니다. 생성된 컨테이너 목록은 `docker ps -a --filter label=ankole.installation=dev`로 확인할 수 있습니다. 이미 실행 중인 상태에서 두 번째 `kit dev`를 중복 실행하지 마십시오. 종료할 때는 해당 터미널에서 `Ctrl+C`를 누르면 되며, 이때 `dev` 설치에 속한 Worker 컨테이너도 함께 정리됩니다. 나중에 다시 시작하면 기존 Agent가 Worker를 필요로 하는 시점에 control plane이 컨테이너를 새로 생성합니다.

## 데이터베이스 라이프사이클

`kit app-db`는 로컬 control-plane 데이터베이스를 관리합니다.

| 명령 | 역할 |
|---|---|
| `kit app-db create` | 애플리케이션 데이터베이스가 아직 없으면 새로 생성합니다. |
| `kit app-db drop` | 애플리케이션 데이터베이스를 삭제합니다. 데이터가 삭제되므로 확인용 `--yes` 플래그가 필요합니다. |
| `kit app-db rebuild` | 애플리케이션 데이터베이스를 삭제하고 다시 생성한 뒤 Ecto 마이그레이션까지 실행합니다. `--yes` 플래그가 필요합니다. |
| `kit app-db migrate` | 구성된 로컬 데이터베이스에 대해 control-plane Ecto 마이그레이션을 실행합니다. |

`create`, `drop`, `rebuild` 명령에는 공통 옵션을 함께 지정할 수 있습니다. `--start-services`를 붙이면 작업 전에 Compose 서비스를 먼저 시작하고, `--pull`을 붙이면 최신 서비스 이미지를 먼저 받아 오며, `--wait-timeout`으로 서비스 헬스체크 대기 시간(초 단위, 기본값 `60`)을 조정할 수 있습니다. 특히 `app-db rebuild`를 실행하면 로컬 `ankole_dev` 데이터베이스가 통째로 삭제되므로, 기존 데이터를 버려도 확실히 괜찮을 때만 사용하십시오.

## 설정과 조회

| 명령 | 역할 |
|---|---|
| `kit show bootstrap-activation-code` | 현재 초기 설정용 활성화 코드(activation code)를 출력합니다. 첫 방문 화면에서 코드를 입력해야 하는데 `kit dev`를 띄운 터미널을 바로 볼 수 없을 때 유용합니다. |
| `kit logs pretty` | 표준 입력(stdin)으로 들어오는 Ankole의 구조화된 JSON 로그를 읽기 편한 형식으로 정리해 출력합니다. 로컬에서 로그 스트림을 파이프로 연결해 확인하십시오. |

## code generation과 분석

| 명령 | 역할 |
|---|---|
| `kit generate [collection-name:]<schematic-name> [options]` | 지정한 schematic으로 파일을 생성하거나 수정합니다. 예를 들어 `bun run kit g code-workspace`(`bun run workspace:update`와 동일)를 실행하면 VS Code 워크스페이스 파일이 재생성됩니다. |
| `kit analyze all` | 저장소의 모든 정적 분석 검사를 실행합니다. `bun run analyze`로도 실행할 수 있습니다. |
| `kit analyze smells` | 코드 스멜(code smell)을 검사해 보고합니다. `bun run analyze:smells`로도 실행할 수 있습니다. |
| `kit analyze unused` | 사용되지 않는 코드를 찾아 보고합니다. `bun run analyze:unused`로도 실행할 수 있습니다. |
| `kit analyze structure` | 저장소 구조 규칙을 검사해 보고합니다. `bun run analyze:structure`로도 실행할 수 있습니다. |
| `kit analyze cycles` | 순환 의존성(dependency cycle)을 찾아 보고합니다. `bun run analyze:cycles`로도 실행할 수 있습니다. |

## Worker 테스트 실행기

`kit agent-computer-test`는 표준 Worker 컨테이너 런타임 안에서 Agent Computer Worker 패키지 테스트를 실행하므로, 실제 Agent 턴이 동작하는 환경과 동일한 조건에서 검증할 수 있습니다. `--suite` 옵션에는 `unit` 또는 `integration`을 지정할 수 있으며, 이미지를 새로 빌드하는 대신 특정 Docker 이미지를 지정하려면 `--image`를 사용합니다.

## 더 알아보기

```bash
bun run kit --help
```

`kit`은 `@crustjs` 기반의 계층형 명령 트리로 구성되어 있어 모든 단계에서 `--help`를 지원합니다. 위 표에는 운영자와 기여자가 자주 쓰는 명령을 추려 담았으며, 세부 하위 명령(예: `kit app-db --help`)은 CLI 도움말로 직접 확인하십시오.

## 다음 단계

- 위 명령어를 활용해 로컬 환경을 구축하는 절차는 [Quick start](../quickstart/)를 참조하십시오.
- `kit dev`로 기동되는 전체 구성 요소는 [architecture overview](../architecture/)를 참조하십시오.