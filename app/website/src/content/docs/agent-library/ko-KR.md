---
title: Agent Library
description: Agent가 할 수 있는 일 — 파일 번들로서의 Skill, Codex 패키지로서의 Agent Plugin, 그리고 Agent별로 해석되는 기본값-후-재정의 활성화 모델.
section: Developer guide
order: 107
---

Agent Library는 한 가지 질문에 대한 답이다: 이 Agent는 실제로 무엇을 할 수 있는가? Agent Library는 배포 인스턴스가 제공하는 Skill과 Agent Plugin의 카탈로그에, 특정 Agent에서 어떤 것이 켜져 있는지를 결정하는 Agent별 상태를 더한 것입니다. 이 페이지는 그 모델을 `Ankole.AIAgent.Library`의 실제 코드에 대응시킵니다.

배포되는 Skill과 Agent Plugin은 앱 이미지 안의 파일 번들입니다. 설치된 Skill은 Control Plane이 관리하는 Agent Files 드라이브의 `skills/` 아래에 저장됩니다. PostgreSQL은 카탈로그, 활성화 상태, 권위 있는 파일 참조를 보관하고 객체 스토리지는 설치된 파일 내용을 보관합니다. Worker는 이 파일을 로컬 실행 캐시에 다운로드합니다.

## 두 종류의 Capability

라이브러리는 서로 관련되지만 구별되는 두 가지를 보관합니다:

- **A Skill**은 `SKILL.md`로 식별되는 파일 번들입니다. Skill 이름은 소문자로 시작하고 문자로 시작하며 문자, 숫자, `_`, `-`만 사용하고 최대 64자다. Skill은 `builtin` (앱 이미지에 포함되어 `app/library/skills`에서 동기화) 이거나 `installed` (Agent Files 드라이브의 `skills/` 아래에 저장) 중 하나입니다. `agent_skills` 행은 활성화 상태, 소스 종류, 콘텐츠 해시, 동기화 시간을 기록합니다 — 명시적으로 파일 콘텐츠 테이블이 아닙니다.
- **An Agent Plugin**은 표준 Codex Plugin 패키지에 Ankole의 선택적 `workspace-template/` 초기화 디렉터리를 더한 것입니다. 패키지 바이트와 버전은 인스턴스 라이브러리에 살고, PostgreSQL은 희소한 Agent별 활성화 재정의만 저장합니다. Plugin 식별자는 Skill 이름과 같은 형식 규칙을 따릅니다.

둘은 연결되어 있다: Agent Plugin은 Skill을 담을 수 있고, Skill 행은 부모 활성화와 카탈로그 표시를 위해 `agent_plugin_id`를 기록합니다. 하지만 Agent Plugin 소속은 독립적인 메타데이터입니다 — Skill이 로드되는 방식은 바꾸지 않습니다.

## 활성화: tenant 기본값과 Agent 재정의

tenant 설정은 Agent Plugin과 Skill의 유효 기본값을 제공합니다. tenant 재정의가 없으면 site 설정을 상속하며 운영자 설정도 없으면 배포된 카탈로그 기본값을 사용합니다. Agent는 자신의 재정의만 저장합니다.

`effective_enabled`는 Agent 재정의 또는 상속한 tenant 기본값을 반영합니다. Plugin member Skill은 부모 Plugin도 활성화되어 있어야 합니다. 부모를 비활성화해도 member 설정은 유지하며 부모를 다시 활성화하면 적용합니다.

Console의 [Agent Library capabilities](../console-api/)는 선택한 tenant의 기본값을 읽고 수정한 뒤 Agent별 재정의를 허용합니다. API 필드 `global_default_enabled`는 site 상속을 포함한 선택된 tenant의 유효 기본값을 반환합니다.

## Brain에서만 검색하는 Skill 발견

배포되는 standalone Skill이나 Agent Plugin member는 `brain-recall-only: true`를 선언할 수 있습니다. 배포되는 Skill은 하나의 전역 이름 공간을 공유하므로 Plugin 소속이 Skill 이름을 바꾸지 않습니다. Agent가 설치한 Skill은 이 모드에 참여하지 않습니다.

Agent Library는 전체 유효 Skill 집합을 Worker에 전달합니다. 일반 Skill은 모델에 표시되는 Skill 카탈로그에 들어갑니다. Brain에서만 검색하는 Skill은 `skill_view`로 로드할 수 있는 집합에 남지만 카탈로그에서는 제외됩니다. Library sweep은 이름, 설명, 태그만 `lazyload-agent-skills/<skill-name>`의 가벼운 Brain 레코드로 projection합니다. Skill 본문, 리소스, Agent별 교훈은 각각을 소유하는 파일 및 데이터베이스 경로에 남습니다.

projection은 같은 테넌트 내의 Agent가 공유하며 한 Agent가 Skill을 비활성화해도 삭제되지 않습니다. Brain query와 `skill_view`는 모두 해당 Agent의 현재 Plugin 및 Skill 유효 상태를 적용합니다. 따라서 비활성화된 레코드는 검색 슬롯을 차지하지 않고 로드할 수도 없습니다. 기능을 다시 활성화하면 기존 projection을 그대로 사용할 수 있습니다.

## 영구 Agent 문서와 Skill 교훈

Capability와 함께 라이브러리는 Agent 자신이 쓰는 문서와 Agent별 Skill 지침도 보관합니다.

- **Durable Agent 문서**는 `mission`, `soul`, `design`, `confidentiality_policy`이며, 컨테이너 테이블이 받아들이는 네 가지 `source_kind` 값입니다. 처음 두 개는 책임과 행동을 정의합니다. `design`은 시각 작업용 디자인 시스템을 저장합니다. `confidentiality_policy`는 Agent가 Brain에 지식을 쓸 때 audience를 선택하는 방법을 안내합니다. 이 문서들은 `agent_library_container_entries`에 살며 콘텐츠 해시를 사용합니다.
- **Skill 교훈**은 `agent_skill_lessons`의 본문을 직접 변경할 수 없는 의미적 행입니다. 각 행은 Agent 하나와 Skill 하나에 속하며 작성자, 증거, 리스 상태, 폐기 이력을 기록합니다. Dreaming은 증거에 기반한 리스 교훈을 작성합니다. 운영자는 리스가 없는 사람의 교훈을 추가하고 모든 교훈을 폐기할 수 있습니다.

Skill view는 Skill 파일을 읽고 전달 조건을 충족하는 교훈을 `Agent-specific additions` 아래에 표시합니다. 기본 `SKILL.md`는 바뀌지 않습니다. 증거, 재검토, 전달 규칙은 [Skill 교훈](../skill-lessons/)을 참고하십시오.

## 동기화: 레지스트리 정직성 유지

Control Plane의 `sync_agent_skills`는 두 소스를 한 Agent의 카탈로그로 통합합니다.

- **배포되는 Skill**은 앱 이미지에서 읽으며 standalone Skill과 Agent Plugin member를 포함합니다. 새 이미지는 다음 동기화에서 이 Skill을 추가하거나 갱신할 수 있습니다.
- **설치된 Skill**은 Agent Files 드라이브의 `skills/<name>/SKILL.md`에서 직접 읽습니다. Library는 목록의 모든 페이지와 각 manifest를 읽은 후 카탈로그를 변경합니다. 추가되거나 변경된 manifest는 카탈로그 행을 갱신하고, 삭제된 manifest는 해당 행을 제거합니다. 읽기나 파싱에 실패하면 카탈로그는 변경되지 않습니다. 갱신할 때 운영자가 설정한 기존 `enabled_override`를 유지합니다.

Worker는 설치된 Skill을 실행 캐시에 다운로드합니다. 캐시를 스캔해서 카탈로그를 보고하거나 교체하지 않습니다. 콘텐츠 해시를 사용하므로 변경되지 않은 행은 다시 쓰지 않습니다.

## 운영자 표면

[Console](../console-api/) 페이지에서 이미 다룬 Console 라우트가 이 모델을 구동합니다. 특히 Capability 라우트:

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/agent-library/capabilities` | 선택한 tenant의 카탈로그와 기본값 |
| `PUT` | `/agent-library/agent-plugins/:id` | Plugin의 tenant 기본값 설정 |
| `PUT` | `/agent-library/skills/:id` | Skill의 tenant 기본값 설정 |
| `GET` | `/agents/:agent_uid/library-capabilities` | 한 Agent의 유효 Capability |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 한 Agent에 대한 Plugin 재정의 |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | 한 Agent에 대한 Skill 재정의 |
| `GET` | `/agents/:agent_uid/library-documents` | Agent의 mission/soul/design/confidentiality policy 나열 |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | 문서 하나 설정 |
| `GET` | `/agents/:agent_uid/skill-lessons` | 활성 및 폐기된 Skill 교훈 목록 |
| `POST` | `/agents/:agent_uid/skill-lessons` | 사람의 Skill 교훈 추가 |
| `POST` | `/agents/:agent_uid/skill-lessons/:lesson_id/retire` | Skill 교훈 폐기 |

`/agents/:agent_uid/library-capabilities`를 읽으면 앱 이미지와 Agent Files 드라이브에서 Skill을 동기화합니다. 실행 중인 Worker는 필요하지 않습니다.

## Agent Library가 아닌 것

마켓플레이스가 아니고 핫 로드 시스템도 아닙니다. Skill과 Plugin은 신뢰된 퍼스트 파티 번들입니다. 기본 번들은 배포 인스턴스와 함께 제공되고, 설치된 Skill은 Agent Files 드라이브에 저장됩니다. 서드 파티 발견은 없고, 워커가 이미 제공하는 것 이상의 격리 장치는 없다. 라이브러리는 모델의 tool이 정의되는 곳이 아닙니다. 운영자가 Agent가 turn에 가져올 수 있는 Capability를 결정하는 곳입니다. 실행 시 control plane이 주 Agent의 Skill 지침을 읽고 Worker가 컴퓨터 도구와 Codex Job의 Skill을 준비합니다.

## 다음 단계

- 라이브러리를 구성하는 라우트는 [Console](../console-api/) 페이지를 읽으세요.
- Agent별 작업 지침은 [Skill 교훈](../skill-lessons/)을 참고하세요.
- turn 중에 활성화된 Skill을 실행하는 Worker는 [Sessions](../sessions/) 페이지를 읽으세요.
- 라이브러리가 범위로 삼는 Agent Principal은 [Principal과 AuthZ](../principal-authz/)를 읽으세요.
