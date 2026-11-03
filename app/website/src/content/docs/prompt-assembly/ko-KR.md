---
title: 프롬프트 조립
section: Developer guide
order: 118
description: 제어 플레인의 주 Agent 지침과 Codex Job 컨텍스트 구성 경로.
---

주 Agent의 모델 시스템 지침은 제어 플레인에서 조립합니다. `Ankole.Sessions.Context.resolve/2`가 현재 도메인 상태를 조회하고 `Ankole.Sessions.Prompt.system/1`이 이를 프롬프트로 렌더링하면, `Ankole.Sessions.Driver`가 AIGateway로 전달합니다. 반면 Worker는 환경 도구 작업과 Codex Job 실행을 담당합니다. 전체 실행 흐름은 [Agent loop](../agent-loop/)를 참조하세요.

## 현재 컨텍스트

각 실행은 Agent 신원, 활성 기능, 시작 대화와 시간대를 확인합니다. `Ankole.AIAgent.Library.Contracts`는 개별 상속·추가·재정의 설정에 따라 전역 기준을 합칩니다. 컨트롤 플레인은 유효한 `AGENTS.md` 전체를 읽습니다. `DESIGN.md`도 같은 모듈이 관리하며 완전한 런타임 파일로 제공합니다.

`Ankole.Sessions.Prompt.system/1`은 AGENTS 규약 전체, 완료 및 권한 규칙, Job과 Workflow 정책, 기억 지침, 환경과 도구 설명, Skill 카탈로그, 런타임 컨텍스트를 순서대로 조립합니다. 템플릿은 `app/control_plane/priv/sessions/prompts/`에 있습니다.

Skill 카탈로그에는 해당 Agent에서 활성화된 패키지의 설명을 표시합니다. `skill_view`는 선택한 매니페스트를 필요할 때 읽으며 Agent는 참조된 파일을 명시적으로 읽습니다. 마지막에는 Agent, `/workspace`, Session 작업 공간, 시간대, 대화 시작 시각과 채널을 기록합니다. Lark와 Feishu는 하나의 어댑터를 사용하며 설정된 도메인에 따라 상위 API를 선택합니다.

## 설정과 기록

테넌트별 실행 한도는 `AgentConfig`에서 해석합니다. 기본값은 `ai_agent.max_iterations`가 `90`, `ai_agent.max_output_tokens`가 명시적 제한 없음, `ai_agent.inactivity_timeout_ms`가 30분이며, 이 값들로 제어 플레인 턴의 실행 범위를 제한합니다.

대화 기록과 감사용 모델 요청 내역은 AIGateway가 보관합니다. 이번 턴의 입력과 외부 공급자 관측 정보는 시스템 지침에 중복 포함하지 않고 `Prompt.Input`을 거쳐 사용자 메시지로 구성하며, 제어 플레인은 매 실행 시점의 최신 컨텍스트로 시스템 지침을 새로 렌더링합니다.

## Codex Job과 Workflow 작업

Codex Job은 Worker에서 실행합니다. 매 턴 시작과 재개 시 최신 규약을 가져와 `$CODEX_HOME/AGENTS.md`, `~/AGENTS.md`, `~/DESIGN.md`를 원자적으로 갱신합니다. 네이티브 Codex는 전역 Agent 지침과 프로젝트 자체 지침 파일을 결합합니다. 자세한 내용은 [Background Agent Jobs](../background-agent-jobs/)를 참조하세요.

Workflow 작업은 `Prompt.workflow_system/1`을 통해 Agent 신원, 작업 ID, 저장된 결과 스키마, 결과 제출 규칙, 위임 및 `sleep` 규칙을 전달받습니다. Ambient routing 역시 전용 프롬프트를 사용하며, 각 실행 경로는 고유한 실행 계약을 따릅니다.
