---
title: 환경 변수
description: 명령줄 도구, MCP 서버, Background Agent Job에 필요한 환경 변수를 Console에서 구성하는 방법.
section: User guide
order: 10
---

Agent는 명령을 실행하거나, MCP 서버를 호출하거나, Agent Computer Worker에서 Background Agent Job을 시작할 때 환경 변수가 필요할 수 있습니다. API 키, 토큰, 서비스 URL 등과 같은 값에는 Console의 **Environment variables**를 사용하세요.

자격 증명을 Skill, Agent 문서, 채팅 메시지에 넣지 마세요.

Agent와 Agent가 시작한 프로그램은 이 변수들을 읽을 수 있습니다. Agent가 실행하는 각 명령은 이 값들을 담은 새 환경에서 시작하며, Worker 프로세스의 환경을 상속하지 않습니다. Agent가 사용해야 하는 자격 증명만 저장하세요. LLM Provider, identity provider, 채팅 채널의 자격 증명은 각각의 Console 페이지에서 구성하세요.

## 먼저 스코프를 선택하세요

| 변수가 필요한 대상 | 설정 위치 | 스코프 |
|---|---|---|
| 사이트 전체 Agent | **Console → Environment variables → New site variable** | 사이트 기본값 |
| 한 테넌트의 Agent | **Console → 테넌트 선택 → Environment variables → New tenant variable** | 해당 테넌트에서 사이트 값 재정의 |
| 하나의 Agent | **Console → Agents → Agent 선택 → Environment variables** | 해당 Agent에서 테넌트와 사이트 값 재정의 |

Agent 재정의, 테넌트 값, 사이트 기본값 순으로 해석합니다. 재정의를 지우면 다음 사용 가능한 값으로 돌아갑니다. 어느 범위에도 값이 없으면 변수를 전달하지 않습니다.

## 사이트 또는 테넌트 변수 추가

1. **Console → Environment variables**를 열고 테넌트를 선택합니다. 필요한 범위에 맞춰 **New site variable** 또는 **New tenant variable**을 선택합니다.
2. 이름을 입력합니다. 문자, 숫자, 밑줄을 포함할 수 있지만 숫자로 시작할 수 없습니다. 예를 들어 `MY_API_KEY`처럼 사용하세요.
3. 값을 입력합니다. API 키, 토큰, 비밀번호 등 민감한 값에는 **Store as secret**을 켠 상태로 유지하세요.
4. 해당 변수를 사용하는 도구나 서비스를 식별할 수 있는 메모를 선택적으로 추가합니다. 이 메모는 Agent에게 전달되지 않습니다.
5. 변수를 저장합니다.

런타임은 `PATH`, `HOME`, `SHELL`, `TERM`, `LANG`, `BASH_ENV`, `ENV`, `WORKER_ID`, `DATABASE_URL`, `CODEX_UNSAFE_ALLOW_NO_SANDBOX`, 그리고 `ANKOLE_`로 시작하는 이름을 예약합니다. 이 이름들은 여기서 설정할 수 없습니다.

## 하나의 Agent용 변수 설정

1. **Console → Agents**를 열고 Agent를 선택합니다.
2. **Environment variables**를 찾습니다.
3. 변수를 추가하거나 기존 변수에서 **Override**를 선택합니다.
4. 값을 입력하고 저장합니다.

이 섹션은 사이트, 테넌트, Agent 값을 표시합니다. **Source** 열은 적용된 값의 출처를 보여 줍니다. **Clear**는 Agent 재정의만 제거하며 이후 테넌트 또는 사이트 값이 적용될 수 있습니다.

## 변수 유형 이해

WorkerEnv 항목은 모두 운영자가 추가한 사용자 지정 값입니다. Ankole과 Plugin은 WorkerEnv를 통해 AppConfigure 키를 내보내지 않습니다. 런타임 예약 변수와 binding 자격 증명은 각 도메인이 관리합니다.

## 값 암호화, 표시, 순환

**Store as secret**은 새 변수에서 기본적으로 켜져 있습니다. Console은 목록에서 암호화된 값을 마스킹하지만, Agent는 실행 시 원래 값을 받습니다.

암호화된 변수를 편집할 때 마스크를 그대로 두면 저장된 값이 유지됩니다. 자격 증명을 순환하려면 새 값을 입력하고 저장하세요. 먼저 이전 값을 표시할 필요는 없습니다.

**Reveal**은 현재 값을 확인해야 할 때만 선택하세요. **Store as secret**을 끄면 Console이 평문 저장 확인을 요청합니다. API 키, 토큰, 비밀번호에서는 암호화를 끄지 마세요.

## 변경 사항이 적용되는 시점

변경은 이후 Worker 작업에 적용됩니다. 이미 환경을 가져온 실행이나 작업공간은 이전 값을 유지합니다. 주 모델 추론은 컨트롤 플레인에서 실행하며 WorkerEnv를 해당 프로세스 환경으로 받지 않습니다.

Agent가 기대한 값을 받지 못하면 다음 항목을 순서대로 확인하세요.

1. 이름이 Skill, 스크립트 또는 `bearer_token_env_var` 선언과 정확히 일치하는지 확인합니다. 대소문자를 구분합니다.
2. 사이트 기본값보다 먼저 Agent와 테넌트 재정의를 확인합니다.
3. 적어도 한 범위에 값이 존재하는지 확인합니다.
4. 변경 후 새 Worker 작업을 시작합니다. 기존 작업공간은 가져온 환경을 유지합니다.

MCP 기반 Skill에서는 `bearer_token_env_var`에 환경 변수 이름만 넣으세요. 토큰은 여기에 저장합니다. 선언 계약은 [MCP](../mcp/)를 참조하세요.
