---
title: 프롬프트 조립
section: Developer guide
order: 118
description: 제어 플레인의 주 Agent 지침과 Codex Job 컨텍스트 구성 경로.
---

주 Agent의 모델 시스템 지침은 제어 플레인에서 조립합니다. `Ankole.Sessions.Context.resolve/2`가 현재 도메인 상태를 조회하고 `Ankole.Sessions.Prompt.system/1`이 이를 프롬프트로 렌더링하면, `Ankole.Sessions.Driver`가 AIGateway로 전달합니다. 반면 Worker는 환경 도구 작업과 Codex Job 실행을 담당합니다. 전체 실행 흐름은 [Agent loop](../agent-loop/)를 참조하세요.

## 현재 컨텍스트

프롬프트 컨텍스트에는 Agent의 신원과 문서, 현재 유효한 Skill 및 플러그인, 대화 시작 채널, 시간대가 포함됩니다. 행동 원칙과 판단 기준은 `SOUL.md`에서, 담당 업무와 책임 범위는 `MISSION.md`에서 정의합니다. 이 문서들은 도메인 소유 모듈이 PostgreSQL에 영속 저장하며, 환경 도구가 실행될 때는 workspace 계약에 따라 런타임 파일로 실체화되어 전달됩니다.

주 시스템 프롬프트는 신원, `SOUL.md`, `MISSION.md`, 완료 및 권한 지침, 사용 가능한 Job·Workflow 정책, 기억 안내, 환경 및 도구 안내, Skill 목록, 런타임 컨텍스트 순서로 조립됩니다. 프롬프트 템플릿은 `app/control_plane/priv/sessions/prompts/`에 있고, 렌더링 로직은 `app/control_plane/lib/ankole/sessions/prompt.ex`에 구현되어 있습니다.

프롬프트 내 Skill 목록에서는 `brain-recall-only: true`로 선언된 Skill이 생략되지만, 활성 Skill 집합에는 그대로 남으므로 Brain 검색으로 발견해 `skill_view`로 본문을 읽을 수 있습니다. 런타임 접미사에는 Agent 식별자, `/workspace`, 현재 Session workspace 경로, 시간대, 대화 시작 시각 및 채널 정보가 들어갑니다. Lark 어댑터는 Lark와 Feishu를 모두 지원하며, 설정된 domain 값에 따라 상위 API 엔드포인트가 결정됩니다.

## 설정과 기록

테넌트별 실행 한도는 `AgentConfig`에서 해석합니다. 기본값은 `ai_agent.max_iterations`가 `90`, `ai_agent.max_output_tokens`가 명시적 제한 없음, `ai_agent.inactivity_timeout_ms`가 30분이며, 이 값들로 제어 플레인 턴의 실행 범위를 제한합니다.

대화 기록과 감사용 모델 요청 내역은 AIGateway가 보관합니다. 이번 턴의 입력과 외부 공급자 관측 정보는 시스템 지침에 중복 포함하지 않고 `Prompt.Input`을 거쳐 사용자 메시지로 구성하며, 제어 플레인은 매 실행 시점의 최신 컨텍스트로 시스템 지침을 새로 렌더링합니다.

## Codex Job과 Workflow 작업

Codex Job은 이와 별도의 Worker 실행 경로를 따릅니다. Runner가 고정된 실행 선택지를 해석하고 RPC로 현재 도메인 정보를 받아 Job 프로젝트 디렉터리와 `AGENTS.md`를 준비하면, 해당 Job의 모델 루프는 Native Codex가 직접 구동합니다. 자세한 내용은 [Background Agent Jobs](../background-agent-jobs/)를 참조하세요.

Workflow 작업은 `Prompt.workflow_system/1`을 통해 Agent 신원, 작업 ID, 저장된 결과 스키마, 결과 제출 규칙, 위임 및 `sleep` 규칙을 전달받습니다. Ambient routing 역시 전용 프롬프트를 사용하며, 각 실행 경로는 고유한 실행 계약을 따릅니다.
