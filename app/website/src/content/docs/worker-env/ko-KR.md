---
title: 환경 변수
description: 명령줄 도구, MCP 서버, Background Agent Job에 필요한 환경 변수를 Console에서 구성하는 방법.
section: User guide
order: 10
---

Agent는 명령을 실행하거나, MCP 서버를 호출하거나, Agent Computer Worker에서 Background Agent Job을 시작할 때 환경 변수가 필요할 수 있습니다. API 키, 토큰, 서비스 URL 등과 같은 값에는 Console의 **Environment variables**를 사용하세요.

자격 증명을 Skill, Agent 문서, 채팅 메시지에 넣지 마세요.

Agent와 Agent가 시작한 프로그램은 이 변수들을 읽을 수 있습니다. Agent가 사용해야 하는 자격 증명만 저장하세요. LLM Provider, identity provider, 채팅 채널의 자격 증명은 각각의 Console 페이지에서 구성하세요.

## 먼저 스코프를 선택하세요

| 변수가 필요한 대상 | 설정 위치 | 스코프 |
|---|---|---|
| 모든 Agent | **Console → Environment variables** | 기본적으로 모든 Agent가 사용 가능 |
| 하나의 Agent | **Console → Agents → Agent 선택 → Environment variables** | 해당 Agent만 사용 가능; 같은 이름의 값은 전역 값을 덮어씀 |

Agent 값을 지우면 같은 이름의 전역 값이 다시 활성화됩니다. 전역 값이 없으면 Agent는 더 이상 변수를 받지 않습니다.

## 모든 Agent용 변수 추가

1. **Console → Environment variables**를 열고 **New variable**을 선택합니다.
2. 이름을 입력합니다. 문자, 숫자, 밑줄을 포함할 수 있지만 숫자로 시작할 수 없습니다. 예를 들어 `MY_API_KEY`처럼 사용하세요.
3. 값을 입력합니다. API 키, 토큰, 비밀번호 등 민감한 값에는 **Store as secret**을 켠 상태로 유지하세요.
4. 해당 변수를 사용하는 도구나 서비스를 식별할 수 있는 메모를 선택적으로 추가합니다. 이 메모는 Agent에게 전달되지 않습니다.
5. 변수를 저장합니다. Agent의 다음 턴부터 사용할 수 있습니다.

런타임은 `PATH`, `HOME`, `SHELL`, `TERM`, `LANG`, `BASH_ENV`, `ENV`, `WORKER_ID`, `DATABASE_URL`, `CODEX_UNSAFE_ALLOW_NO_SANDBOX`, 그리고 `ANKOLE_`로 시작하는 이름을 예약합니다. 이 이름들은 여기서 설정할 수 없습니다.

## 하나의 Agent용 변수 설정

1. **Console → Agents**를 열고 Agent를 선택합니다.
2. **Environment variables**를 찾습니다.
3. 변수를 추가하거나 기존 변수에서 **Override**를 선택합니다.
4. 값을 입력하고 저장합니다.

이 섹션에는 기본값, 전역 값, 이 Agent의 값이 표시됩니다. **Source** 열은 어떤 값이 활성 상태인지 보여 줍니다. **Clear**를 선택하면 Agent 값을 제거하고 전역 값이나 기본값을 복원합니다.

## 변수 유형 이해

| 유형 | 의미 | 가능한 작업 |
|---|---|---|
| Custom | 관리자가 Console에서 추가한 변수 | 편집 또는 삭제 |
| Declared | Ankole 또는 활성화된 플러그인이 제공하는 변수 | 값 편집 또는 기본값으로 재설정 |

declared 변수는 이름과 데이터 형식이 고정되어 있습니다. 값도 기본값도 없는 변수는 **Unset**으로 표시됩니다.

## 값 암호화, 표시, 순환

**Store as secret**은 새 변수에서 기본적으로 켜져 있습니다. Console은 목록에서 암호화된 값을 마스킹하지만, Agent는 실행 시 원래 값을 받습니다.

암호화된 변수를 편집할 때 마스크를 그대로 두면 저장된 값이 유지됩니다. 자격 증명을 순환하려면 새 값을 입력하고 저장하세요. 먼저 이전 값을 표시할 필요는 없습니다.

**Reveal**은 현재 값을 확인해야 할 때만 선택하세요. **Store as secret**을 끄면 Console이 평문 저장 확인을 요청합니다. API 키, 토큰, 비밀번호에서는 암호화를 끄지 마세요.

## 변경 사항이 적용되는 시점

변경은 이미 시작된 실행에는 영향을 주지 않습니다. 새 값은 Agent의 다음 턴, 이후의 Background Agent Job 실행, 이후의 Automation Job 시도에서 사용할 수 있습니다.

Agent가 기대한 값을 받지 못하면 다음 항목을 순서대로 확인하세요.

1. 이름이 Skill, 스크립트 또는 `bearer_token_env_var` 선언의 이름과 정확히 일치하는지. 이름은 대소문자를 구분합니다.
2. Agent가 같은 이름의 값을 가지고 있는지. Agent 값은 전역 값을 덮어씁니다.
3. 변수가 **Unset**으로 표시되지 않는지.
4. 변경 후 새 Agent 턴이 시작되었는지.

MCP 기반 Skill에서는 `bearer_token_env_var`에 환경 변수 이름만 넣으세요. 토큰은 여기에 저장합니다. 선언 계약은 [MCP](../mcp/)를 참조하세요.