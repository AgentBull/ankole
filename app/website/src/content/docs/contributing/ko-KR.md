---
title: 기여하기
description: 병합되는 Ankole 기여로 가는 길 — 규칙이 어디 있는지, 설정 방법, 올바른 검사를 실행하는 방법, 그리고 프로젝트가 요구하는 changelog와 PR 규율.
section: Guides
order: 321
---

Ankole에 기여한다는 것은 첫 편집 전에 두 문서를 읽고, 그 문서들이 정의하는 경로를 따르는 것을 의미합니다. 이 페이지는 지도입니다: 권위 있는 소스를 가리키고, 그 소스를 통과하는 경로를 명명하며, 어느 쪽도 복제하지 않습니다. 이 페이지와 소스 문서가 충돌하면 소스 문서가 옳습니다.

결정적인 속성을 먼저 밝힙니다: Ankole의 기여 규칙은 선택적 관례가 아니라 프로젝트의 검토 프로세스와 모든 커밋을 관문으로 막는 changelog 규칙에 의해 강제됩니다. [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md) 또는 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)를 건너뛴 기여는 돌아가서 읽으라는 요청을 받을 것입니다. 먼저 읽으세요.

## 규칙을 소유하는 두 문서

- **[`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md)** — 프로젝트 전역 규칙: 범위와 권한, changelog를 버전 단위로 삼는 규칙, 핵심 규율(가장 작은 올바른 변경, worse-is-better), 설계 우선순위(단순성 > 정확성 > 일관성 > 완전성), 목표 충실성(objective fidelity), 서브시스템 경계. 변경을 *어떻게* 만드는지를 결정하는 문서입니다.
- **[`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)** — 기여 경로: 6단계 로컬 설정, Feishu 엔드투엔드 수락, 문제 해결 순서, 저장소 지도, 품질 관문, changelog와 PR 단계. 변경을 착수하기 위해 *무엇을* 해야 하는지를 결정하는 문서입니다.

둘 다 각자의 영역에서 진실의 원천(source of truth)입니다. 이 가이드와 나머지 문서들은 둘에 링크합니다. 여기의 어떤 것도 둘을 덮어쓰지 않습니다.

## 설정 경로(6단계)

`CONTRIBUTING.md`는 설정을 여섯 단계로 안내하며 그것이 권위 있는 버전입니다. 모양은 다음과 같으니, 어떤 과정인지 알 수 있습니다:

1. **저장소를 얻고 환경을 선택하세요** — 클론하고 macOS/Linux/WSL2 또는 GitHub Codespaces를 선택합니다.
2. **시스템 도구를 설치하고 검증하세요** — `bash tools/devkit/scripts/env-setup.sh`를 실행한 다음 `bun`, `elixir`, `rustc`, `cargo clippy`, `docker`가 모두 작동하는지 확인합니다. 각 `kit` 명령이 무엇을 하는지는 [kit CLI reference](../kit-cli/)를 참조하세요.
3. **의존성을 설치하고 PostgreSQL을 초기화하세요** — `bun install`, `bun run services:start`, `bun run control-plane:setup`.
4. **완전한 개발 환경을 시작하세요** — `bun dev`.
5. **최초 제품 설정을 완료하세요** — 활성화, Feishu 테스트 앱 생성, OIDC 구성, Console에서 런타임 구성.
6. **엔드투엔드 경로를 증명하세요** — 실제 Feishu 메시지가 agent에 도달하고 예상된 답변을 반환합니다.

설정은 페이지가 열렸을 때 끝나는 것이 아닙니다. 실제 메시지가 왕복했을 때 끝납니다. 짧은 경로는 [Quick start](../quickstart/)를, 전체 수락은 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)를 참조하세요.

## 변경하는 방법

첫 편집 전에 `AGENTS.md`를 읽으세요. 가장 자주 등장하는 규칙:

- **범위와 권한.** 답변 또는 계획 요청은 읽기 전용 검사를 승인하고, 구현 요청은 편집을 승인합니다. 승인 없이 범위를 확장하지 마세요.
- **changelog가 버전 단위입니다.** 모든 커밋은 정확히 하나의 `CHANGELOG.md` 버전을 추가하고, 그 버전은 커밋의 모든 유지된 변경을 설명합니다. 하나의 버전이 여러 커밋에 걸치지 않고, 하나의 커밋이 여러 버전을 담지 않습니다. 아래 섹션을 참조하세요.
- **가장 작은 올바른 변경.** 선택된 방향을 따르고 시스템이 유지할 수 있는 계약을 보존하며 이해 가능한 가장 작은 변경을 선호하세요. 약간의 중복은 복잡성을 키우는 추상화보다 낫습니다.
- **Worse is better.** 단순성이 인터페이스 균일성이나 이론적 완전성을 이깁니다. 단순성이 이길 때는, 조용히 잘못된 결과를 만들기보다 계약을 좁히거나 지원하지 않는 경우를 명시적으로 거부하세요.
- **목표 충실성(objective fidelity).** 요청된 작업을 하지, 더 저렴한 대리물을 하지 마세요. 초록 테스트가 목표가 아니라, 소유 추상화를 통과하는 실제 경로가 목표입니다.
- **서브시스템 경계.** PostgreSQL은 지속적 사실을 소유하고, Elixir control plane은 지속적 상태와 감독을 소유하고, Rust kernel은 공유 네이티브 프리미티브를 소유하고, Bun Agent Computer Worker는 실행을 소유합니다. 경계를 가로지르는 변경은 그 경계를 존중해야지, 덮어서는 안 됩니다.

## changelog 규칙

이것은 모든 커밋을 관문으로 막는 규칙이며, 대부분의 기여가 처음에 틀리는 규칙입니다. `AGENTS.md`에서:

- 모든 커밋은 정확히 하나의 루트 `CHANGELOG.md` 버전을 추가합니다.
- 그 버전은 그 커밋의 모든 유지된 소스, 테스트, 문서, 설정, 스키마, 마이그레이션, 매니페스트, 락파일, 요구되는 생성 파일 변경을 설명합니다.
- 하나의 버전은 여러 커밋에 걸치면 안 되고, 하나의 커밋은 여러 버전을 담으면 안 됩니다.
- 버전은 앞에 0이 없는 `MAJOR.MINOR.PATCH`를 사용합니다. 기본은 `PATCH` 증가입니다. 그 커밋으로 사용자나 운영자가 이전에는 할 수 없던 일을 할 수 있게 되거나, 기존 동작이 깨져서 사람이 설정·저장된 데이터·외부 호출자를 바꿔야 할 때만 `MINOR`를 올리고 `PATCH`를 `0`으로 재설정합니다. 그 밖의 변경은 사용자가 곧바로 차이를 느끼더라도 `PATCH`를 올립니다. 아무리 눈에 띄는 버그 수정이라도, 기존 기능 안에서의 속도나 안정성 개선, 내부 재작성, 의존성 업그레이드, 도구, 문서 모두 같습니다. 하나의 커밋에 두 유형이 모두 포함되면 minor 증가분을 사용하되, 어느 한 변경이 그 자체로 `MINOR`에 해당할 때만 그렇게 합니다. `MAJOR`는 명시적인 유지보수자 결정 후에만 변경합니다.
- 커밋 직전에 정확한 staged diff에서 항목을 준비하세요.

changelog는 유일한 changelog이자 버전 단위입니다 — 별도의 릴리스 노트 파일은 없습니다. `main` 런타임 이미지 빌드가 이미지 쌍 검증을 통과한 후, 워크플로는 control-plane 및 Worker 이미지 태그에 최신 버전을 사용하고 정확히 그 섹션에서 불변 GitHub Release를 만듭니다. changelog를 변경의 일부로 취급하고, 사후 서류 작업으로 취급하지 마세요.

## 올바른 검사 실행

`CONTRIBUTING.md`가 검사를 명명하고, [kit CLI reference](../kit-cli/)가 명령을 문서화합니다. 모양:

- **변경한 패키지의 대상 테스트와 일반 정적 검사** — 전체 스위트가 아니라 영향받는 패키지의 테스트를 실행합니다.
- **영향받는 통합 또는 엔드투엔드 스위트** — 변경이 프로세스, provider, 지속성 재시작, 또는 사용자 흐름 경계를 가로지를 때, 그리고 건너뛰지 마세요.
- **`bun run analyze`** (`kit analyze all`) — 저장소 전반의 악취, 사용되지 않는 코드, 구조, 순환을 검사합니다.
- **`bun run lint`** 및 **`bun run fmt:check`** — 커밋 전에.

필요한 명령을 환경에서 실행할 수 없으면 정확한 명령과 차단 요인을 보고하세요 — 해당 보증을 검증된 것으로 주장하지 마세요.

## pull request 제출

`CONTRIBUTING.md`가 PR 단계를 다룹니다. 간단한 모양: PR의 커밋은 changelog 규칙(커밋당 하나의 버전)을 따르고, 변경은 `AGENTS.md`의 경계를 존중하며, PR 설명은 문서들이 사용하는 용어로 무엇이 왜 바뀌었는지 말합니다. 리뷰도 같은 것들을 확인할 것입니다.

## 이 가이드가 아닌 것

이 가이드는 두 문서의 대체물이 아닙니다 — 두 문서로 가는 문입니다. 읽지 않고 편집할 수 있는 면허도 아닙니다. `AGENTS.md`는 의도적으로 짧으며, 읽는 것은 기여가 할 수 있는 가장 저렴한 일입니다. 그리고 규칙을 논쟁할 자리도 아닙니다. 규칙은 정착된 트레이드오프이며, 로컬 선호는 발견(finding)이 아닙니다 — 대신 구현이 선택된 방향 안에서 일관적인지 평가하세요.

## 다음 단계

- 첫 편집 전에 [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md)를 읽으세요.
- 설정과 수락은 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)를 따르세요.
- devkit 명령은 [kit CLI reference](../kit-cli/)를 사용하세요.
- 변경이 가로지르는 서브시스템 경계를 이해하려면 [architecture overview](../architecture/)를 읽으세요.