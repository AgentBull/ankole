---
title: Agent Library
description: Agent가 할 수 있는 일 — 파일 번들로서의 Skill, Codex 패키지로서의 Agent Plugin, 그리고 Agent별로 해석되는 기본값-후-재정의 활성화 모델.
section: Developer guide
order: 107
---

Agent Library는 "이 Agent가 실제로 어떤 작업을 수행할 수 있는가?"라는 질문에 답하는 계층입니다. 배포 인스턴스에서 제공하는 Skill 및 Agent Plugin 카탈로그와, 개별 Agent마다 어떤 항목을 켤지 결정하는 활성화 상태를 함께 관리합니다. 이 문서에서는 해당 모델이 `Ankole.AIAgent.Library` 코드에 어떻게 구현되어 있는지 설명합니다.

기본 배포되는 Skill과 Agent Plugin은 앱 이미지 안에 포함된 파일 번들이며, 운영 중 추가로 설치한 Skill은 Control Plane이 관리하는 Agent Files 드라이브의 `skills/` 경로 아래에 저장됩니다. PostgreSQL은 카탈로그 메타데이터, 활성화 상태, 정본 파일 참조만 보관하고 실제 설치 파일 바이트는 객체 스토리지에 저장합니다. 이후 Worker는 필요한 파일을 로컬 실행 캐시로 내려받아 사용합니다.

## 두 종류의 Capability

라이브러리는 서로 밀접하지만 역할이 구분되는 두 가지 단위를 관리합니다.

- **Skill**은 `SKILL.md` 매니페스트로 식별되는 파일 번들입니다. Skill 이름은 영문 소문자로 시작해야 하며 영문자, 숫자, `_`, `-`만 사용해 최대 64자까지 지정할 수 있습니다. 소스에 따라 앱 이미지에 포함되어 `app/library/skills`에서 동기화되는 `builtin` Skill과, Agent Files 드라이브의 `skills/` 아래에 저장되는 `installed` Skill로 나뉩니다. `agent_skills` 테이블 행에는 활성화 상태, 소스 종류, 콘텐츠 해시, 동기화 시각만 기록되며 파일 본문 자체는 저장되지 않습니다.
- **Agent Plugin**은 표준 Codex Plugin 패키지에 Ankole 전용 선택 디렉터리인 `workspace-template/` 초기화 템플릿을 결합한 단위입니다. 패키지 바이트와 버전은 인스턴스 라이브러리에 보관되며, PostgreSQL에는 변경된 Agent별 활성화 재정의(override)만 최소한으로 저장됩니다. Plugin 식별자도 Skill 이름과 동일한 명명 규칙을 따릅니다.

두 단위는 계층으로 연결될 수 있습니다. 하나의 Agent Plugin 안에 여러 Skill이 포함될 수 있으며, 이 경우 각 Skill 행은 상위 플러그인의 활성화 상태를 따르고 카탈로그에 소속을 표시하기 위해 `agent_plugin_id`를 기록합니다. 다만 플러그인 소속 여부는 관리용 메타데이터일 뿐, 런타임에 Skill을 로드하는 방식 자체는 달라지지 않습니다.

## 활성화: tenant 기본값과 Agent 재정의

Agent Plugin과 Skill의 기본 활성화 상태는 tenant 설정에서 결정됩니다. tenant 수준의 재정의가 없으면 site 설정을 상속하고, 운영자가 별도로 지정한 site 설정도 없으면 배포된 카탈로그 자체의 기본값을 따릅니다. 개별 Agent에는 그 기본값을 덮어쓰는 재정의만 저장합니다.

최종 상태인 `effective_enabled`는 Agent별 재정의가 있으면 그 값을, 없으면 상속된 tenant 기본값을 반영합니다. 단, Plugin에 속한 member Skill은 상위 Plugin도 함께 활성화되어 있어야 실제로 켜집니다. 상위 Plugin을 비활성화하더라도 하위 Skill의 개별 재정의 설정은 지워지지 않으며, 나중에 상위 Plugin을 다시 켜면 그대로 적용됩니다.

Console의 [Agent Library capabilities](../console-api/) 화면에서는 현재 선택한 tenant의 기본값을 조회·수정한 뒤 개별 Agent 단위로 재정의를 설정할 수 있습니다. 이때 API의 `global_default_enabled` 필드는 site 상속까지 반영된 해당 tenant의 유효 기본값을 반환합니다.

## Brain에서만 검색하는 Skill 발견

기본 배포되는 standalone Skill이나 Agent Plugin 하위 Skill은 매니페스트에 `brain-recall-only: true`를 선언할 수 있습니다. 배포 Skill들은 단일 전역 이름 공간을 공유하므로 Plugin에 속해 있더라도 Skill 이름은 바뀌지 않습니다. 한편 운영 중 설치한(`installed`) Skill에는 이 모드를 사용할 수 없습니다.

Agent Library는 활성화된 전체 Skill 목록을 Worker에 전달합니다. 그중 일반 Skill은 모델 프롬프트의 Skill 카탈로그에 바로 노출되지만, `brain-recall-only`로 지정된 Skill은 카탈로그에서 제외된 채 `skill_view`로 로드 가능한 대상에만 남습니다. 대신 Library sweep 작업이 해당 Skill의 이름, 설명, 태그만 추출하여 `lazyload-agent-skills/<skill-name>` 경로의 가벼운 Brain 레코드로 투영(projection)합니다. Skill 본문과 부속 리소스, Agent별 교훈은 각각 원래의 파일 스토리지와 데이터베이스 테이블에 그대로 유지됩니다.

이 투영 레코드는 같은 tenant 안의 모든 Agent가 공유하므로, 특정 Agent 하나에서 해당 Skill을 비활성화하더라도 레코드 자체는 삭제되지 않습니다. 대신 Brain 검색과 `skill_view` 양쪽에서 호출한 Agent의 현재 Plugin 및 Skill 유효 활성화 상태를 실시간으로 검사합니다. 따라서 비활성화된 Skill은 검색 결과 슬롯을 차지하지 않고 로드할 수도 없으며, 나중에 다시 활성화하면 기존 투영 레코드를 즉시 재사용합니다.

## 영구 Agent 문서와 Skill 교훈

라이브러리는 Capability 카탈로그 외에도 Agent의 정체성을 정의하는 영구 문서와 실행 경험을 축적하는 Agent별 Skill 교훈을 함께 보관합니다.

- **영구(Durable) Agent 문서**는 컨테이너 테이블의 `source_kind`로 허용되는 네 가지 문서인 `mission`, `soul`, `design`, `confidentiality_policy`입니다. `mission`과 `soul`은 Agent의 책임 범위와 행동 방식을 정의하고, `design`은 시각 산출물용 디자인 시스템을 담으며, `confidentiality_policy`는 Agent가 Brain에 지식을 기록할 때 공개 대상(audience)을 판단하는 기준을 안내합니다. 네 문서는 모두 `agent_library_container_entries` 테이블에 콘텐츠 해시와 함께 저장됩니다.
- **Skill 교훈**은 `agent_skill_lessons` 테이블에 저장되며 본문을 직접 덮어쓰지 않는 불변 의미 단위의 레코드입니다. 각 행은 특정 Agent와 특정 Skill의 조합에 귀속되며 작성 주체, 근거 증거, 리스(lease) 상태, 폐기 이력을 기록합니다. Dreaming 작업은 실제 근거에 기반한 기한부(리스) 교훈을 생성하고, 운영자는 만료 기한이 없는 수동 교훈을 직접 추가하거나 기존 교훈을 폐기할 수 있습니다.

런타임에 `skill_view`로 Skill 파일을 읽으면 전달 조건을 충족한 유효 교훈들이 `Agent-specific additions` 섹션 아래에 덧붙여 표시되며, 원본 `SKILL.md` 파일은 수정되지 않습니다. 교훈의 근거 기록과 재검증 및 노출 규칙은 [Skill 교훈](../skill-lessons/)을 참조하세요.

## 동기화: 레지스트리 정직성 유지

Control Plane의 `sync_agent_skills` 함수는 다음 두 소스를 읽어 개별 Agent의 카탈로그를 최신 상태로 맞춥니다.

- **배포되는 Skill**은 앱 이미지에서 읽어오며 standalone Skill과 Agent Plugin 하위 Skill을 모두 포함합니다. 새 앱 이미지를 배포하면 다음 동기화 시점에 새로운 Skill이 추가되거나 기존 항목이 갱신됩니다.
- **설치된 Skill**은 Agent Files 드라이브의 `skills/<name>/SKILL.md`에서 직접 읽어옵니다. Library는 드라이브 목록의 모든 페이지와 각 매니페스트 파일을 끝까지 읽은 뒤에야 카탈로그 테이블을 갱신합니다. 매니페스트가 새로 추가되거나 수정되면 카탈로그 행을 갱신하고, 매니페스트가 삭제되면 해당 행을 제거합니다. 중간에 파일 읽기나 파싱이 실패하면 카탈로그를 변경하지 않고 기존 상태를 보존하며, 행을 갱신하더라도 운영자가 지정해 둔 `enabled_override` 값은 그대로 유지합니다.

Worker는 설치된 Skill을 로컬 실행 캐시로 내려받기만 할 뿐, 로컬 캐시를 역으로 스캔해 카탈로그를 보고하거나 덮어쓰지 않습니다. 또한 콘텐츠 해시를 비교하므로 내용이 바뀌지 않은 행은 불필요하게 다시 쓰지 않습니다.

## 운영자 표면

[Console](../console-api/) 문서에서 다루는 Console API 라우트들이 이 라이브러리 모델을 제어합니다. 주요 Capability 및 문서 관리 라우트는 다음과 같습니다.

| 메서드 | 경로 | 용도 |
|---|---|---|
| `GET` | `/agent-library/capabilities` | 선택한 tenant의 카탈로그와 기본값 조회 |
| `PUT` | `/agent-library/agent-plugins/:id` | Plugin의 tenant 기본값 설정 |
| `PUT` | `/agent-library/skills/:id` | Skill의 tenant 기본값 설정 |
| `GET` | `/agents/:agent_uid/library-capabilities` | 특정 Agent의 유효 Capability 조회 |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 특정 Agent의 Plugin 활성화 재정의 |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | 특정 Agent의 Skill 활성화 재정의 |
| `GET` | `/agents/:agent_uid/library-documents` | Agent의 mission/soul/design/confidentiality policy 목록 조회 |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | 특정 영구 문서 저장 |
| `GET` | `/agents/:agent_uid/skill-lessons` | 활성 및 폐기된 Skill 교훈 목록 조회 |
| `POST` | `/agents/:agent_uid/skill-lessons` | 운영자 수동 Skill 교훈 추가 |
| `POST` | `/agents/:agent_uid/skill-lessons/:lesson_id/retire` | Skill 교훈 폐기 |

`GET /agents/:agent_uid/library-capabilities`를 호출하면 앱 이미지와 Agent Files 드라이브에서 최신 Skill 목록을 즉시 동기화하며, 이때 Worker가 실행 중일 필요는 없습니다.

## Agent Library가 아닌 것

Agent Library는 외부 마켓플레이스나 런타임 핫로드 시스템이 아닙니다. 모든 Skill과 Plugin은 신뢰할 수 있는 퍼스트 파티 번들로 취급됩니다. 기본 번들은 배포 이미지에 포함되어 제공되고 설치형 Skill은 Agent Files 드라이브에 보관될 뿐, 서드 파티 패키지 탐색 기능이나 Worker 컨테이너 기본 격리 이상의 별도 샌드박스는 두지 않습니다. 또한 모델의 기본 도구(tool) 스키마를 정의하는 곳도 아니며, 운영자가 각 Agent의 실행 turn에 어떤 역량을 허용할지 결정하는 제어 계층입니다. 실제 실행 시점에는 control plane이 주 Agent 루프용 Skill 지침을 읽고, Worker가 환경 도구와 Codex Job에서 사용할 Skill 파일을 준비합니다.

## 다음 단계

- 라이브러리를 제어하는 API 상세 사양은 [Console](../console-api/) 문서를 참조하세요.
- Agent별 작업 지침 축적 방식은 [Skill 교훈](../skill-lessons/)을 참조하세요.
- 실행 turn 중 활성화된 Skill이 동작하는 과정은 [Sessions](../sessions/) 문서를 참조하세요.
- 라이브러리 권한과 소유 범위의 기준이 되는 Agent Principal은 [Principal과 AuthZ](../principal-authz/)를 참조하세요.
