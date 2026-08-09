---
title: kit CLI 레퍼런스
description: devkit 명령 표면 — 운영자나 contributor가 실행하는 모든 `bun run kit` 명령, 각 명령의 역할, 그리고 이를 감싸는 script에 대해 설명합니다.
section: Reference
order: 200
---

`kit`은 Ankole의 devkit 명령줄입니다. 저장소 루트에서 `bun run kit <command>`로 호출하며, 환경 설정, 로컬 service, 개발 환경, database lifecycle, activation code, log, code generation, 저장소 분석을 다룹니다. 이 페이지는 모든 명령에 대한 레퍼런스입니다.

핵심 속성을 먼저 밝히면, `kit`은 `tools/devkit/`에 있는 Bun + TypeScript 프로그램이며, 저장소의 `package.json` script가 일반적인 명령(`services:start`, `services:stop`, `dev`, `analyze` 등)을 감싸므로 전체 `bun run kit` 형식을 입력하지 않아도 됩니다. 두 형식 모두 동작하며, script는 별칭(alias)입니다.

## 환경과 감지

| 명령 | 역할 |
|---|---|
| `kit env-setup` | Ankole 개발에 필요한 호스트 toolchain을 설치합니다 — 시스템 빌드 패키지, Docker, Rust, Elixir/Erlang toolchain, 고정된(pinned) Bun. `--print`를 추가하면 설치 명령을 실행하지 않고 출력합니다. |
| `kit is-ci` | CI 환경에서 실행 중이면 `0`으로 종료하고, 그렇지 않으면 `1`로 종료합니다. CI 여부로 분기하는 script에서 사용합니다. |
| `kit is-dev` | 개발 환경에서 실행 중이면 `0`으로 종료하고, 그렇지 않으면 `1`로 종료합니다. |

새 머신에서 `env-setup`을 한 번 실행하십시오. 나머지는 다른 명령이 내부적으로 호출하는 감지 헬퍼입니다.

## 로컬 service와 개발 환경

| 명령 | 역할 |
|---|---|
| `kit external-services start` | devkit Docker Compose service(PostgreSQL 등)를 시작합니다. `bun run services:start`로 래핑되어 있습니다. |
| `kit external-services stop` | devkit Compose service를 중지합니다. `bun run services:stop`으로 래핑되어 있습니다. |
| `kit external-services status` | devkit service 상태를 보고합니다. `bun run services:status`로 래핑되어 있습니다. |
| `kit dev` | 완전한 개발 환경(Phoenix, 프런트엔드 자산, 관리형 Docker worker 하나)을 시작합니다. `bun run dev`로 래핑되어 있습니다. 이 터미널을 열어 둡니다. |

`kit dev`는 전체 스택을 실행하는 유일한 명령입니다. PostgreSQL을 시작하거나 확인하고, 로컬 database를 생성 및 migrate하며, 없거나 오래된 worker image를 빌드하고 관리형 worker를 시작합니다. 두 번째 `kit dev`를 시작하지 마십시오. 해당 터미널에서 `Ctrl+C`로 중지하십시오.

## 데이터베이스 라이프사이클

`kit app-db`는 로컬 control-plane database를 관리합니다.

| 명령 | 역할 |
|---|---|
| `kit app-db create` | app database가 아직 없으면 생성합니다. |
| `kit app-db drop` | app database를 삭제합니다. 파괴적 작업을 확인하려면 `--yes`가 필요합니다. |
| `kit app-db rebuild` | app database를 삭제하고 생성한 다음 migrate합니다. `--yes`가 필요하며, 재생성 후 Ecto migration을 실행합니다. |
| `kit app-db migrate` | 구성된 로컬 database에 control-plane Ecto migration을 실행합니다. |

다음 옵션이 이 명령들에 공통으로 적용됩니다. `--start-services`는 작업 전에 Compose를 시작하고, `--pull-images`는 먼저 최신 service image를 가져오며, health-check 대기 시간은 service 준비 상태를 기다리는 시간을 제어합니다. 특히 `app-db rebuild` 명령은 로컬 `ankole_dev` database를 삭제하므로, 데이터를 실제로 버려도 되는 경우에만 실행하십시오.

## 설정과 조회

| 명령 | 역할 |
|---|---|
| `kit show bootstrap-activation-code` | 현재 setup activation code를 출력합니다. 첫 방문 페이지에서 code가 필요하고 `kit dev` 터미널이 보이지 않을 때 사용합니다. |
| `kit logs pretty` | stdin의 Ankole 구조화 JSON log 줄을 보기 좋게 출력합니다. 읽기 쉬운 로컬 출력을 위해 log 스트림을 파이프로 연결하십시오. |

## code generation과 분석

| 명령 | 역할 |
|---|---|
| `kit generate [collection-name:]<schematic-name> [options]` | schematic에서 파일을 생성하거나 수정합니다. `bun run kit g code-workspace`(`bun run workspace:update`로 래핑됨)는 VS Code workspace를 재생성합니다. |
| `kit analyze all` | 모든 저장소 분석을 실행합니다. `bun run analyze`로 래핑되어 있습니다. |
| `kit analyze smells` | code smell을 보고합니다. `bun run analyze:smells`로 래핑되어 있습니다. |
| `kit analyze unused` | 사용되지 않는 코드를 보고합니다. `bun run analyze:unused`로 래핑되어 있습니다. |
| `kit analyze structure` | 저장소 구조를 보고합니다. `bun run analyze:structure`로 래핑되어 있습니다. |
| `kit analyze cycles` | dependency cycle을 보고합니다. `bun run analyze:cycles`로 래핑되어 있습니다. |

## Worker 테스트 실행기

`kit agent-computer-test`는 Agent Computer Worker 패키지 테스트를 표준 worker container runtime에서 실행하므로, 실제 turn이 사용하는 것과 동일한 환경에서 테스트가 실행됩니다. `--suite`로 `unit` 또는 `integration`을 받고, `--prebuilt-image`로 이미지를 빌드하는 대신 특정 Agent Computer Worker Docker image를 대상으로 실행할 수 있습니다.

## 더 알아보기

```bash
bun run kit --help
```

`kit`은 `@crustjs` 명령 트리이므로 모든 레벨에 `--help`가 있습니다. 위의 명령은 운영자나 contributor가 실제로 실행하는 것들이며, 특정 명령의 전체 하위 명령 표면(예: `kit app-db --help`)은 CLI에 직접 물어보십시오.

## 다음 단계

- 이 명령들을 사용하는 로컬 환경 안내는 [Quick start](../quickstart/)를 읽으십시오.
- `kit dev`가 시작하는 항목은 [architecture overview](../architecture/)를 읽으십시오.