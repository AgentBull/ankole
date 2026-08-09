---
title: Agent Library
description: Agent가 할 수 있는 일 — 파일시스템 번들로서의 Skill, Codex 패키지로서의 Agent Plugin, 그리고 Agent별로 해석되는 기본값-후-재정의 활성화 모델.
section: Developer guide
order: 107
---

Agent Library는 한 가지 질문에 대한 답이다: 이 Agent는 실제로 무엇을 할 수 있는가? Agent Library는 배포 인스턴스가 제공하는 Skill과 Agent Plugin의 카탈로그에, 특정 Agent에서 어떤 것이 켜져 있는지를 결정하는 Agent별 상태를 더한 것입니다. 이 페이지는 그 모델을 `Ankole.AIAgent.Library`의 실제 코드에 대응시킵니다.

핵심 속성을 먼저 명시합니다: Skill과 Plugin 자체는 파일시스템 번들이지 데이터베이스 행이 아닙니다. PostgreSQL은 활성화 상태, 레지스트리 의미론, 파일 관찰을 보관합니다 — 인스턴스 전체 기본값 위의 희소한 Agent별 재정의. 바이트와 버전은 인스턴스 라이브러리에 남고, 데이터베이스는 누가 무엇을 켰는지만 기록합니다.

## 두 종류의 Capability

라이브러리는 서로 관련되지만 구별되는 두 가지를 보관합니다:

- **A Skill**은 `SKILL.md`로 식별되는 파일시스템 번들입니다. Skill 이름은 소문자로 시작하고 문자로 시작하며 문자, 숫자, `_`, `-`만 사용하고 최대 64자다. Skill은 `builtin` (앱 이미지에 포함되어 `app/library/skills`에서 동기화) 이거나 `installed` (워커가 볼 수 있는 스토리지 아래에 Agent가 설치) 중 하나입니다. `agent_skills` 행은 활성화 상태, 소스 종류, 콘텐츠 해시, 동기화 시간을 기록합니다 — 명시적으로 파일 콘텐츠 테이블이 아닙니다.
- **An Agent Plugin**은 표준 Codex Plugin 패키지에 Ankole의 선택적 `workspace-template/` 초기화 디렉터리를 더한 것입니다. 패키지 바이트와 버전은 인스턴스 라이브러리에 살고, PostgreSQL은 희소한 Agent별 활성화 재정의만 저장합니다. Plugin 식별자는 Skill 이름과 같은 형식 규칙을 따릅니다.

둘은 연결되어 있다: Agent Plugin은 Skill을 담을 수 있고, Skill 행은 부모 활성화와 카탈로그 표시를 위해 `agent_plugin_id`를 기록합니다. 하지만 Agent Plugin 소속은 독립적인 메타데이터입니다 — Skill이 로드되는 방식은 바꾸지 않습니다.

## 활성화: 기본값, 그다음 재정의

Agent의 유효 Capability는 두 계층으로 카탈로그를 훑어 해석된다:

1. **인스턴스 전체 기본값** — 각 Skill의 `default_enabled`와 운영자가 설정하는 전역 Plugin 기본값.
2. **Agent별 재정의** — Skill 행의 `enabled_override` 또는 한 Agent에 범위가 한정된 Agent Plugin 재정의.

해석 결과는 Capability 엔드포인트가 반환하는 `effective_enabled` 필드다: 기본값을 취하고, 재정의가 있으면 적용합니다. 재정의가 없는 Capability는 기본값을 상속하고, 재정의가 있는 Capability는 재정의를 따릅니다. 카탈로그는 256개 Plugin으로 한정되므로 해석은 저렴하게 유지되고 표면은 읽기 쉽게 유지됩니다.

이것이 Console의 [Agent Library capabilities](../console-api/) 라우트가 노출하는 모델입니다: 전역 기본값을 설정한 다음 Agent별로 좁히거나 넓힙니다.

## 영구 Agent 문서와 Skill 오버레이

Capability와 함께 라이브러리는 Agent 자신이 쓰는 문서와 Skill 커스터마이제이션도 보관합니다:

- **Durable Agent 문서**는 `mission`, `soul`, `design`이며, 컨테이너 테이블이 받아들이는 세 가지 `source_kind` 값입니다. 처음 두 개는 책임과 행동을 정의합니다. `design`은 시각 작업용 디자인 시스템을 저장합니다. 이 문서들은 `agent_library_container_entries`에 살며 콘텐츠 해시를 사용합니다.
- **Skill 오버레이**는 `(agent, skill)`당 하나씩 `agent_skill_overlays`의 의미적 행입니다. 운영자가 Skill 번들을 포크하지 않고 한 Agent에 대해 Skill이 동작하는 방식을 커스터마이즈할 수 있게 해줍니다. 오버레이는 비교-후-교체(compare-and-swap) 교체를 지원하므로 동시 편집이 결정적으로 해결됩니다.

Skill 뷰는 Skill의 파일과 Agent가 가진 오버레이를 함께 읽으므로 Agent는 번들과 별도 패치가 아니라 하나의 일관된 Skill을 본다.

## 동기화: 레지스트리 정직성 유지

Skill은 파일시스템 번들이므로 데이터베이스 레지스트리는 파일시스템을 추적해야 한다. 두 동기화 경로가 그 일을 한다:

- **`sync_builtin_skills`**는 `app/library/skills` 트리를 builtin Skill 행과 조정하고, 무엇이 바뀌었는지, 콘텐츠 해시, Skill과 파일 수를 반환합니다. 앱 이미지에서 실행되므로 새 이미지는 다음 동기화에서 builtin Skill을 추가하거나 갱신할 수 있다.
- **`sync_agent_skills`**는 한 Agent의 설치된 Skill을 워커가 볼 수 있는 스토리지가 실제로 보여주는 것과 조정하고, `replace_installed_skill_observations`가 관찰된 파일 집합을 기록합니다. 스토리지에서 사라진 Skill은 레지스트리에 반영되고, 나타난 Skill은 포착됩니다.

동기화는 읽고 조정하는 것이지 밀어 넣고 기도하는 것이 아닙니다. `content_hash`가 동기화를 멱등으로 만든다: 같은 트리는 같은 해시를 만들고 실제 변경만 행을 쓴다.

## 운영자 표면

[Console](../console-api/) 페이지에서 이미 다룬 Console 라우트가 이 모델을 구동합니다. 특히 Capability 라우트:

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/agent-library/capabilities` | 기본값이 있는 전역 카탈로그 |
| `PUT` | `/agent-library/agent-plugins/:id` | Plugin의 전역 기본값 설정 |
| `PUT` | `/agent-library/skills/:id` | Skill의 전역 기본값 설정 |
| `GET` | `/agents/:agent_uid/library-capabilities` | 한 Agent의 유효 Capability |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 한 Agent에 대한 Plugin 재정의 |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | 한 Agent에 대한 Skill 재정의 |
| `GET` | `/agents/:agent_uid/library-documents` | Agent의 mission/soul/design 나열 |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | 문서 하나 설정 |
| `GET` | `/agents/:agent_uid/library-skill-overlays` | Skill 오버레이 나열 |
| `PUT` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | Skill 오버레이 설정 |
| `DELETE` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | Skill 오버레이 제거 |

`/agents/:agent_uid/library-capabilities`를 읽으면 Agent Skill 동기화가 트리거되므로 운영자가 보는 것은 현재 스토리지와 조정된 레지스트리이지 오래된 스냅샷이 아닙니다.

## Agent Library가 아닌 것

마켓플레이스가 아니고 핫 로드 시스템도 아닙니다. Skill과 Plugin은 배포 인스턴스와 함께 제공되거나 워커가 볼 수 있는 스토리지에 설치되는 신뢰된 퍼스트 파티 번들입니다. 서드 파티 발견은 없고, 워커가 이미 제공하는 것 이상의 격리 장치는 없다. 데이터베이스는 Skill 바이트의 원천이 아닙니다 — 그 바이트는 파일시스템에 있고 레지스트리는 보이는 것만 추적합니다. 그리고 라이브러리는 모델의 tool이 정의되는 곳이 아닙니다. 운영자가 Agent가 turn에 가져올 수 있는 Capability를 결정하는 곳입니다. “enabled”에서 “실제로 호출됨”으로 넘어가는 일은 turn 시점에 Agent Computer Worker의 몫입니다.

## 다음 단계

- 라이브러리를 구성하는 라우트는 [Console](../console-api/) 페이지를 읽으세요.
- turn 중에 활성화된 Skill을 실행하는 Worker는 [Actor Runtime](../actor-runtime/) 페이지를 읽으세요.
- 라이브러리가 범위로 삼는 Agent Principal은 [Principal과 AuthZ](../principal-authz/)를 읽으세요.
