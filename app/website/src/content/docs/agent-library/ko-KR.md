---
title: Agent Library
description: Agent가 할 수 있는 일 — 파일 번들로서의 Skill, Codex 패키지로서의 Agent Plugin, 그리고 Agent별로 해석되는 기본값-후-재정의 활성화 모델.
section: Developer guide
order: 107
---

Agent Library는 Agent가 활성화한 Skill과 Agent Plugin을 결정합니다. 공유 Skill은 Pod의 `/AnkoleBrain/skills/<name>`에 저장합니다. 홈페이지는 지식 페이지이며 스크립트와 템플릿은 그 아래의 파일입니다. Agent 전용 Skill은 개인 Files 공간의 `skills/`에 설치할 수 있습니다. PostgreSQL이 콘텐츠, 권한, 활성화 상태를 보관하고 Worker에는 실행용 사본을 만듭니다.

## 기능과 활성화

Skill은 `SKILL.md`와 전역에서 고유한 소문자 이름을 가집니다. Agent Plugin은 관련 Skill과 선택적인 `workspace-template/`을 묶습니다. 활성화 여부는 배포 기본값, 사이트 및 테넌트 설정, Agent별 설정 순서로 결정합니다. Plugin에 속한 Skill은 상위 Plugin도 활성화되어 있어야 합니다.

활성화 여부와 읽기 권한은 별개입니다. 카탈로그에는 현재 대화에서 읽을 수 있는 활성 Skill을 표시합니다. 사람이 시작한 턴에서는 Agent, 요청자, 해당 방 참여자의 권한 교집합을 적용하고, 무인 자동화에서는 Agent 자신의 권한을 적용합니다. 카탈로그는 이름과 설명을 제공하며 `skill_view`가 필요한 내용을 읽습니다.

## 콘텐츠 편집과 업데이트

공유 Skill은 Pod에서 편집합니다. 읽을 수 있는 지식 하위 페이지를 Skill 지침에 추가하되, `metadata.role = "reference"`인 장은 필요할 때 하위 경로로 읽습니다. Agent별로 검토된 지침을 적용하는 방법은 [Skill lessons](../skill-lessons/)를 참조하세요.

시작 및 카탈로그 동기화 시 Ankole은 공식 패키지를 저장된 기준과 비교합니다. 홈페이지 메타데이터와 본문, 관리 대상 파일의 경로·콘텐츠 해시·모드를 확인합니다. 로컬 수정이 없으면 파일 추가와 삭제를 포함해 원자적으로 업데이트합니다. 수정이 있으면 패키지 전체를 보존하고 검토할 상위 버전의 해시를 기록합니다. 테넌트가 만든 보충 페이지와 사용자 파일은 관리 기준에서 제외합니다.

## Agent 규약

`/AnkoleBrain/AGENTS.md`는 조직의 행동 원칙과 책임을, `/AnkoleBrain/DESIGN.md`는 시각 규약을 정의합니다. `/AnkoleBrain/agents/<uid>/AGENTS.md`는 개별 책임을 추가하고 `AGENTS.override.md`는 전역 규약 전체를 대체합니다. DESIGN도 본문 추가와 메타데이터 병합 또는 전체 대체를 선택할 수 있습니다. 빈 override는 상속된 내용을 의도적으로 비웁니다.

개인 비서 페이지는 소유자와 비서만 읽을 수 있으며 소유자가 관리합니다. 조직의 Agent는 기본적으로 공통 규약을 상속하고 맞춤 설정이 필요할 때만 개별 규약 페이지를 만듭니다.

Console에서 유효한 기능을 확인하고 Pod 링크로 규약을 편집합니다. `GET /agents/:agent_uid/library-documents`는 유효한 AGENTS와 DESIGN 및 원본 페이지를 반환합니다. Worker는 매 턴 `~/AGENTS.md`, `~/DESIGN.md`, `$CODEX_HOME/AGENTS.md`를 갱신하며 프로젝트 지침 파일은 프로젝트에서 관리합니다.

설치는 [Skills](../skills/), 실행 경로는 [Prompt assembly](../prompt-assembly/), API는 [Console](../console-api/)를 참조하세요.
