---
title: Agents
description: Console에서 Agent를 만들고 소유자, 지속 동작, 모델, 기능, 환경 변수를 설정하는 방법을 설명합니다.
section: User guide
order: 13
---

Agent는 Ankole Agent Harness 안에서 지속적으로 업무를 수행하는 작업 주체입니다. 각 Agent는 고유한 미션, 소유자, 접근 권한, 도구, 모델 프로필, 전용 파일 공간을 갖추고 있으며, 지정된 지식 공개 범위에 따라 Company Brain을 활용합니다. 외부 메시지나 이벤트는 신호 라우팅 규칙을 통해 담당 Agent로 전달됩니다.

## Agent 생성

1. **Console → Agents**를 열고 **New Agent**를 선택합니다.
2. 표시 이름을 입력하고 자동 생성된 handle을 확인합니다. handle은 나중에도 변경할 수 있으며, 저장 시점에 Ankole이 전역에서 고유한 불투명(opaque) UID를 발급합니다.
3. 역할(role), 아바타 URL(선택 사항), Worker provider를 지정합니다.
4. 이 Agent를 소유할 사용자 Principal과 group memory 공개 모드를 선택합니다.
5. Agent를 저장하면 상세 페이지에서 durable 지침 문서, model profile, Agent별 environment variable을 이어서 구성할 수 있습니다.

역할(role)은 "Research Analyst"나 "Customer Support"처럼 담당 업무를 한눈에 알아볼 수 있게 요약한 설명입니다. 실제 책임 범위와 행동 원칙, 시각 디자인, 기밀 유지 기준은 아래에서 설명하는 네 가지 durable 문서로 제어합니다.

Worker provider 설정은 이 Agent가 사용할 [Worker pool](../worker-management/)을 결정합니다. 생성 요청에서 생략하면 사이트 기본 pool이 할당되며, 기본 pool이 지정되어 있지 않으면 생성이 거부됩니다. 한 번 저장한 Worker provider는 나중에 바꿀 수 없습니다. 여러 Agent가 같은 pool을 쓰더라도 각자 독립된 전용 Worker와 영구 Home을 할당받으며, Agent를 저장한 직후에는 인스턴스를 띄우지 않고 실제로 컴퓨터 작업이 필요해질 때 control plane이 시작합니다.

## 소유자와 group memory 공개 설정

모든 Agent에는 반드시 소유자(사람 Principal)를 지정해야 합니다. 소유자는 해당 Agent가 작성하거나 보유한 지식과 그 Agent를 공개 대상(audience)으로 지정한 지식을 검토할 수 있습니다. 다만 소유자가 특정 Group의 구성원이 아니라면, Agent 소유권만으로 그 Group에 속한 지식까지 열람할 수는 없습니다.

group memory 공개 모드는 여러 사람이 함께 보는 대화방에서 Agent가 어디까지 지식을 인용해 답변할 수 있는지를 결정합니다.

- **Strict** 모드에서는 그룹 대화의 모든 참여자가 해당 기억 항목의 공개 범위(audience scope) 조건을 충족해야만 인용할 수 있습니다.
- **Relaxed** 모드에서는 질문한 발신자의 권한만 확인하며, 대화방에 있는 다른 참여자 때문에 조회 결과가 제한되지 않습니다.

1:1 대화(direct message)에서는 두 모드가 동일하게 동작합니다. 해당 그룹에서 완화된 공개 기준을 명시적으로 허용한 경우가 아니라면 **Strict**를 유지하세요. 전체 지식 구조와 공개 범위 모델은 [Brain](../brain/)을 참조하세요.

## durable 문서 설정

Agent 상세 페이지에서 **MISSION / SOUL / DESIGN / CONFIDENTIALITY POLICY** 탭을 열어 네 문서를 작성합니다.

| 문서 | 작성 내용 |
|---|---|
| `MISSION.md` | Agent의 존재 목적, 담당 업무 범위, 완료로 인정되는 결과물의 기준 |
| `SOUL.md` | 소통 어조, 의사결정 방식, 불확실한 상황을 다루는 태도 |
| `DESIGN.md` | 웹 페이지, 슬라이드, 문서, 차트 등 시각 산출물에 적용할 디자인 시스템 |
| `ConfidentialityPolicy.md` | Agent가 Brain에 직접 지식을 기록할 때 공개 범위(audience scope)를 고르는 기준 |

`DESIGN.md`는 <a href="https://www.designmd.co/about" target="_blank" rel="noreferrer">DESIGN.md format</a>을 따릅니다. YAML frontmatter에는 색상, 타이포그래피, 간격, 모서리 반경, 컴포넌트 같은 디자인 토큰을 정의하고, Markdown 본문에는 시각 원칙과 적용 가이드를 기술합니다. Ankole에는 즉시 활용할 수 있는 기본 디자인 시스템이 내장되어 있으며, **Console → Agents → DESIGN**에서 조직 브랜드에 맞게 교체할 수 있습니다.

업무 워크플로나 권한 경계, 일반 행동 규칙은 `DESIGN.md`에 넣지 말고 `MISSION.md`, `SOUL.md`, `ConfidentialityPolicy.md` 또는 개별 Skill에 작성하세요. 참고로 `ConfidentialityPolicy.md`는 Agent가 도구를 통해 직접 Brain에 지식을 기록할 때 참고하는 지침이며, 대화 내용을 바탕으로 자동 학습할 때는 해당 대화의 참여자 구성을 기준으로 공개 범위가 결정됩니다. 처음에는 꼭 필요한 핵심 원칙만 간결하게 적어 두고, 실제 업무를 운영하면서 필요한 규칙만 점진적으로 추가하는 편이 효과적입니다.

문서를 수정해 저장하면 그 이후에 시작되는 대화부터 반영되며, 이미 실행 중인 작업은 시작 시점에 읽어들인 문서 버전으로 끝까지 진행됩니다.

## 모델 구성

같은 페이지에서 최소한 일반 대화용 `primary`, 가벼운 보조 작업용 `light`, 복합 추론용 `heavy` 세 가지 model profile을 구성하세요.

초기 설정 단계에서는 이미 검증을 마친 동일한 모델 하나를 세 프로필에 모두 지정해도 무방합니다.

나머지 선택적 프로필은 해당 기능이 실제로 필요한 Agent에만 구성하세요.

- 이미지를 읽고 해석해야 한다면 `vision_fallback`을 구성합니다.
- 공개 웹 페이지를 검색하거나 본문을 가져와야 한다면 `web_search`와 `web_fetch`를 구성합니다.
- 이미지를 직접 생성해야 한다면 `image_generate`를 구성합니다.
- 백그라운드 작업에 별도의 provider나 모델을 쓰려면 **Background Agent Jobs** 프로필을 구성합니다. ChatGPT 구독 연결도 [ChatGPT subscription provider](../chatgpt-subscription-provider/)를 통해 동일한 방식으로 선택할 수 있습니다.

모델을 고르거나 직접 입력하려면 먼저 Provider부터 선택해야 하며, context length 입력란 역시 Provider를 선택한 뒤에 활성화됩니다. context length를 비워 두면 해당 Provider와 모델의 기본값을 따릅니다.

고급 설정 영역에는 선택한 Provider에서 선언한 옵션만 나타납니다. **Reasoning summary**는 Responses API 기반 모델에만 적용되며, **Answer detail**은 응답의 기본 상세 수준을 지정하고, **Service tier**는 해당 model profile의 요청 등급을 재정의합니다. 선택 가능한 값은 Provider, 계정 등급, 모델에 따라 다르며 비워 두면 Provider 기본값이 적용됩니다.

첫 LLM Provider 등록과 모델 구성 절차는 [Quick start](../quickstart/#llm-providers)를 참조하세요.

## 토큰 할당량 설정

model profile 옆에 있는 **토큰 할당량** 섹션에서는 이 Agent가 반복 주기마다 소비할 수 있는 최대 토큰 수를 제한합니다. 주기 길이(일 단위), 주기 시작 시각, 토큰 한도를 입력해 설정하며, 할당량을 지정하지 않은 Agent는 사용량 제한 없이 동작합니다.

할당량을 설정하면 현재 주기의 시작·종료 시각과 함께 한도 대비 누적 사용량이 비율 막대로 표시됩니다. Ankole은 일반 대화뿐 아니라 예약된 turn, Workflow, Background Agent Job, 그리고 해당 호출에서 파생된 컨텍스트 압축(compaction)까지 포함하여 이 Agent가 수행한 모든 모델 호출에 대해 provider가 보고한 input/output 토큰을 합산합니다. 반면 Brain 내부 모델 호출, 임베딩, 웹 도구, 이미지 생성, 또는 사용자가 개인 토큰으로 직접 보낸 요청은 이 할당량에 합산되지 않습니다.

Agent가 한도에 도달하면 채팅으로 새 메시지를 보냈을 때 일반 답변 대신 현재 사용량, 설정된 한도, 주기 종료 시각을 안내하는 메시지가 반환되며, 해당 Agent의 Background Agent Job은 다음 주기를 기다리지 않고 즉시 실패 처리됩니다. 한도 검사는 각 모델 호출 직전에 수행되므로, 마지막으로 허용된 호출 하나가 실행되면서 소비한 토큰만큼은 설정 한도를 초과해 기록될 수 있습니다. 한도 초과로 차단된 메시지는 자동으로 재전송되지 않으므로 주기가 갱신된 뒤 사용자가 다시 보내야 합니다.

**주기 재설정**을 누르면 그 시점을 기준으로 새 주기가 즉시 시작되어 기존 주기가 끝나기 전이라도 작업을 재개할 수 있으며, **한도 해제**를 누르면 토큰 제한 자체가 제거됩니다. 어느 쪽을 실행하든 기존의 토큰 사용 이력은 감사(audit) 목적으로 보존됩니다. 그 밖의 비용 제어 수단은 [Cost management](../cost-management/)를 참조하세요.

## 기능과 environment variable 구성

새로 만든 Agent는 Agent Plugins와 Skills에 대한 테넌트 기본값을 그대로 상속합니다. 구성을 변경하려면 **Console → Agent Library**에서 테넌트 전체 기본값을 수정하거나 해당 Agent 전용 override를 지정하세요.

자세한 설정 방법은 [Agent Library](../skills/)를 참조하세요.

Skill이나 명령줄 도구, MCP 서비스에서 외부 API 키가 필요한 경우에는 Agent 상세 페이지의 **Environment variables** 섹션에 등록하세요. 여기에 등록한 값은 해당 Agent 전용으로 격리되어 전달됩니다.

동일한 이름의 변수가 있을 때 Agent별 값은 테넌트 값을 덮어쓰며, 테넌트 값이 없으면 사이트 값을 덮어씁니다. 자세한 우선순위 규칙은 [Environment variables](../worker-env/)를 참조하세요.

## chat channel 연결

**Pod Chat**에서는 별도의 Signal Binding 없이도 워크스페이스 구성원이 활성 상태인 Agent에게 바로 1:1 메시지(`dm`)를 보내거나 그룹 대화(`group`)에 초대할 수 있습니다.

외부 IM 채널과 전용 메일함 연동은 Signal Binding으로 관리합니다. Slack, Microsoft Teams, Lark, Feishu, DingTalk, WeCom, Telegram, Discord, LINE, WhatsApp 또는 이메일로 들어오는 메시지를 처리하려면 signal routing 규칙을 등록하세요.

**Console → Signal routing**을 열고 연동할 채팅 애플리케이션과 담당 Agent를 연결하면 됩니다. 하나의 채팅 앱에 여러 라우팅 규칙을 둘 수도 있고, Agent마다 별도의 봇 애플리케이션을 만들어 연결할 수도 있습니다.

자세한 규칙 작성법은 [Signal routing rules](../signal-bindings/)를 참조하세요.

## Agent 변경 또는 비활성화

표시 이름, 역할, durable 지침 문서, 모델 프로필, 활성 기능은 운영 중 언제든지 변경할 수 있습니다. 다만 UID는 다른 설정에서 이 Agent를 참조하는 고유 식별자이므로 변경할 수 없습니다.

Agent를 비활성화하면 새 작업을 수락하지 않고 목록에 "비활성" 상태로 남습니다. 비활성 상태인 Agent는 언제든 다시 활성화하거나 영구 삭제할 수 있습니다. 영구 삭제는 비활성화된 Agent에 대해서만 허용되며, 실행 시 해당 Agent의 세션, 작업, 관련 기록이 함께 삭제됩니다. Agent 전체를 멈추지 않고 특정 채팅 채널 유입만 막으려면 관련 signal routing 규칙만 비활성화하세요.

## Agent가 응답하지 않는 경우

다음 항목을 순서대로 점검해 보세요.

1. Agent가 활성(Active) 상태인지 확인합니다.
2. `primary`, `light`, `heavy` 모델 프로필이 모두 지정되어 있고 연결된 LLM Provider가 정상 작동하는지 확인합니다.
3. 외부 채널을 사용 중이라면 시그널 라우팅 규칙이 이 Agent를 가리키고 있는지 확인합니다.
4. **Console → Workers**에서 해당 Agent의 Worker가 `ready` 상태이거나 오류 없이 시작 중인지 확인합니다.
5. **Console → Conversations**에서 메시지가 실제로 유입되었는지, 실행 로그에 구체적인 오류 원인이 기록되어 있는지 확인합니다.

채널별 상세 점검 항목은 [Quick start troubleshooting](../quickstart/#agent-not-replying)을 참조하세요.
