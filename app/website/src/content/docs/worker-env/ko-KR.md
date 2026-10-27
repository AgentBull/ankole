---
title: 환경 변수
description: 명령줄 도구, MCP 서버, Background Agent Job에 필요한 환경 변수를 Console에서 구성하는 방법.
section: User guide
order: 10
---

Agent가 Agent Computer Worker에서 명령을 실행하거나 MCP 서버를 호출할 때, 또는 Background Agent Job을 시작할 때 환경 변수가 필요할 수 있습니다. API 키, 토큰, 외부 서비스 URL 같은 값은 Console의 **Environment variables**에 등록하세요.

자격 증명을 Skill 본문이나 Agent 문서, 일반 채팅 메시지에 직접 적어 넣어서는 안 됩니다.

여기에 등록한 변수는 Agent와 Agent가 띄운 하위 프로그램에서 읽을 수 있습니다. 각 명령은 등록된 값만 담긴 깨끗한 환경에서 새로 시작되며, Worker 데몬 프로세스 자체의 환경 변수는 상속하지 않습니다. 따라서 Agent 도구가 실제로 사용해야 하는 자격 증명만 여기에 저장하고, LLM Provider나 Identity Provider, 채팅 채널용 자격 증명은 각각의 전용 Console 페이지에서 설정하세요.

## 먼저 스코프를 선택하세요

| 변수가 필요한 대상 | 설정 위치 | 적용 범위 |
|---|---|---|
| 사이트 전체의 모든 Agent | **Console → Environment variables → New site variable** | 사이트 기본값 |
| 특정 테넌트의 Agent | **Console → 테넌트 선택 → Environment variables → New tenant variable** | 해당 테넌트 안에서 사이트 기본값 재정의 |
| 단일 Agent 하나 | **Console → Agents → Agent 선택 → Environment variables** | 해당 Agent에서 테넌트 및 사이트 기본값 재정의 |

변수 값은 Agent 재정의 → 테넌트 값 → 사이트 기본값 순서로 우선 적용됩니다. 상위 재정의를 지우면 그다음 범위의 값이 적용되며, 세 범위 어디에도 값이 없으면 해당 변수는 전달되지 않습니다.

## 사이트 또는 테넌트 변수 추가

1. **Console → Environment variables**를 열고 대상 테넌트를 선택한 뒤, 필요한 범위에 맞춰 **New site variable** 또는 **New tenant variable**을 선택합니다.
2. 변수 이름을 입력합니다. 영문자, 숫자, 밑줄(`_`)을 쓸 수 있으나 숫자로 시작할 수는 없습니다(예: `MY_API_KEY`).
3. 변수 값을 입력합니다. API 키, 토큰, 비밀번호 등 민감한 정보에는 **Store as secret** 옵션을 켠 상태로 유지하세요.
4. 필요한 경우 어느 도구나 서비스에서 쓰는 변수인지 알아볼 수 있도록 메모를 덧붙입니다(이 메모는 Agent에 전달되지 않습니다).
5. 변수를 저장합니다.

런타임 내부에서 쓰는 `PATH`, `HOME`, `SHELL`, `TERM`, `LANG`, `BASH_ENV`, `ENV`, `WORKER_ID`, `DATABASE_URL`, `CODEX_UNSAFE_ALLOW_NO_SANDBOX` 및 `ANKOLE_`로 시작하는 이름은 시스템 예약어이므로 여기서 설정할 수 없습니다.

## 하나의 Agent용 변수 설정

1. **Console → Agents**를 열고 대상 Agent를 선택합니다.
2. **Environment variables** 섹션을 찾습니다.
3. 새 변수를 추가하거나 기존 변수 행에서 **Override**를 선택합니다.
4. 값을 입력하고 저장합니다.

이 섹션에는 사이트, 테넌트, 개별 Agent 범위의 변수가 한꺼번에 표시되며 **Source** 열에서 현재 적용 중인 값의 출처를 확인할 수 있습니다. **Clear**를 누르면 해당 Agent의 개별 재정의만 삭제되고, 테넌트 값이나 사이트 기본값이 있으면 그 값으로 되돌아갑니다.

## 변수 유형 이해

WorkerEnv에 등록되는 항목은 모두 운영자가 직접 추가한 사용자 정의 변수입니다. Ankole 코어나 플러그인의 AppConfigure 설정 키가 WorkerEnv로 자동 내보내지지는 않으며, 런타임 예약 변수와 외부 바인딩 자격 증명은 각 소유 도메인이 별도로 관리합니다.

## 값 암호화, 표시, 순환

새 변수를 만들 때 **Store as secret** 옵션은 기본적으로 켜져 있습니다. 암호화된 값은 Console 목록에서 마스킹되어 표시되지만, Agent가 실행될 때는 복호화된 원래 값이 전달됩니다.

암호화된 변수를 수정할 때 마스킹 표시를 그대로 둔 채 저장하면 기존 저장 값이 유지됩니다. 자격 증명을 교체(순환)할 때는 굳이 이전 값을 먼저 조회할 필요 없이 새 값을 바로 입력해 저장하면 됩니다.

**Reveal**은 문제 진단을 위해 현재 저장된 원문을 직접 대조해야 할 때만 선택하세요. 또한 **Store as secret** 체크를 해제하면 평문 저장 여부를 다시 확인하는 창이 나타나며, API 키·토큰·비밀번호 같은 민감 정보에서는 암호화를 끄지 마세요.

## 변경 사항이 적용되는 시점

변수 변경 사항은 저장 이후 새로 시작되는 Worker 작업부터 반영됩니다. 이미 환경을 주입받아 실행 중인 작업이나 열려 있는 기존 워크스페이스는 이전 값을 그대로 유지합니다. 또한 주 모델 추론 루프는 제어 플레인에서 돌아가므로 해당 프로세스 환경에는 WorkerEnv가 주입되지 않습니다.

만약 Agent가 예상한 환경 변수 값을 읽지 못한다면 다음 순서로 점검하세요.

1. 변수 이름이 Skill이나 스크립트, 또는 `bearer_token_env_var`에 선언된 이름과 대소문자까지 정확히 일치하는지 확인합니다.
2. 사이트 기본값만 보지 말고 개별 Agent 재정의나 테넌트 재정의가 다른 값으로 덮어쓰고 있지 않은지 먼저 확인합니다.
3. 세 범위 중 최소 한 곳에 실제 값이 저장되어 있는지 확인합니다.
4. 설정을 바꾼 뒤 새로운 Worker 작업을 시작했는지 확인합니다(기존 워크스페이스는 처음 가져온 환경을 그대로 유지합니다).

MCP 기반 Skill을 연동할 때는 `bearer_token_env_var` 필드에 변수 이름만 적고 실제 토큰은 이 화면에 저장하세요. 자세한 선언 규격은 [MCP](../mcp/)를 참조하세요.
