---
title: 프롬프트 조립
section: Developer guide
order: 118
description: 제어 플레인의 주 Agent 지침과 Codex Job 컨텍스트 구성 경로.
---

제어 플레인이 주 Agent의 모델 지침을 구성합니다. `Ankole.Sessions.Context.resolve/2`가 현재 도메인 정보를 읽고, `Ankole.Sessions.Prompt.system/1`이 렌더링하며, `Ankole.Sessions.Driver`가 AIGateway로 보냅니다. Worker는 환경 작업과 Codex Job을 받습니다. [Agent loop](../agent-loop/)를 참조하세요.

## 현재 컨텍스트

Agent의 신원과 문서, 유효한 Skill과 플러그인, 대화 시작 채널과 시간대가 포함됩니다. `SOUL.md`는 행동과 판단을, `MISSION.md`는 책임을 제공합니다. 도메인 소유자가 PostgreSQL에 저장합니다. 환경 도구는 workspace 계약으로 실체화된 런타임 파일을 받습니다.

주 프롬프트의 순서는 신원, SOUL, MISSION, 완료와 권한 지침, 사용 가능한 Job과 Workflow 정책, 기억 안내, 환경과 도구 안내, Skill 목록, 런타임 컨텍스트입니다. 템플릿은 `app/control_plane/priv/sessions/prompts/`, 렌더러는 `app/control_plane/lib/ankole/sessions/prompt.ex`에 있습니다.

목록은 `brain-recall-only: true` Skill을 생략합니다. 유효한 집합에는 남으며 Brain으로 발견하고 `skill_view`로 읽을 수 있습니다. 런타임 접미사에는 Agent, `/workspace`, 현재 Session workspace, 시간대, 대화 시작 시간과 채널이 포함됩니다. Lark adapter는 Lark와 Feishu를 나타내고 domain이 상위 API를 선택합니다.

## 설정과 기록

`AgentConfig`는 테넌트 설정을 해석합니다. `ai_agent.max_iterations`의 기본값은 90, `ai_agent.max_output_tokens`는 명시적 제한 없음, `ai_agent.inactivity_timeout_ms`는 30분입니다. 이 값들은 제어 플레인 턴을 제한합니다.

AIGateway가 대화 기록과 감사용 모델 요청을 보관합니다. 현재 입력과 provider 관측은 `Prompt.Input`을 통해 사용자 메시지가 되며 시스템 지침에 중복하지 않습니다. 제어 플레인은 실행마다 현재 컨텍스트로 지침을 렌더링합니다.

## Codex Job과 Workflow 작업

Codex Job은 별도의 Worker 경로를 사용합니다. Runner는 고정된 실행 선택을 해석하고 RPC로 현재 도메인 정보를 얻어 Job 프로젝트와 `AGENTS.md`를 준비합니다. Native Codex가 해당 Job의 모델 루프를 소유합니다. [Background Agent Jobs](../background-agent-jobs/)를 참조하세요.

Workflow 작업은 `Prompt.workflow_system/1`으로 신원, 작업 ID, 저장된 결과 schema, 제출 규칙과 위임 및 sleep 규칙을 받습니다. Ambient routing도 별도 프롬프트를 사용합니다. 각 경로는 자체 실행 계약을 따릅니다.
