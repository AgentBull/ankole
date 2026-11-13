---
title: Agents
description: Console에서 Agent를 만들고 소유자, 지속 동작, 모델, 기능, 환경 변수를 설정하는 방법을 설명합니다.
section: User guide
order: 13
---

Agent는 Ankole Agent Harness 안에서 지속적으로 업무를 수행하는 작업 주체입니다. 각 Agent는 고유한 미션, 소유자, 접근 권한, 도구, 모델 프로필, 영구 파일 공간을 갖추고 있으며, 허용된 지식 공개 범위 안에서 Company Brain을 활용하고 **Pod** 워크스페이스나 신호 라우팅 규칙으로 연결된 외부 채널에서 협업합니다.

## 개인 어시스턴트와 AI 동료

`Ankole.Principals`는 Agent를 두 가지 하위 유형으로 구분합니다.

- **개인 어시스턴트(`personal_assistant`)** — 활성 상태인 각 내부 Human `member`마다 첫 사용 시 1:1로 자동 프로비저닝됩니다(초기 UID는 `<owner_uid>_assistant`). Unified Drive, Pod Docs·Base, `all_humans` 같은 협업 리소스에서는 소유자(사람)의 권한을 투영해 동작하며(`site_console:**` 및 `tenant_console:**` 관리자 범위 제외), group memory 공개 모드는 `strict`로 고정되고 소유자도 변경할 수 없습니다. 규약과 Skill 바인딩은 소유자 본인만 조회·편집할 수 있으며, 소유자 계정이 일시 중지·퇴사 처리되거나 외부 `guest`로 전환되면 어시스턴트도 자동으로 비활성화됩니다.
- **AI 동료(`ai_colleague`)** — 팀 전반의 전문 역할을 위해 운영자가 생성하는 공유 Agent입니다. Drive, Pod, Workflow, 스케줄, Background Agent Job 전반에서 Agent 자신의 Principal 권한으로 동작하며, 사람의 승인이 필요한 작업에서는 `propose_action_card`로 승인 카드를 게시하고 `send_to_agent`를 통해 격리된 `agent_peer` 대화에서 동료 Agent에게 하위 업무를 위임합니다.

## AI 동료 생성

1. **Console → Agents**(또는 Pod 워크스페이스 설정)를 열고 **New Agent**를 선택합니다.
2. 표시 이름을 입력하고 의미가 드러나는 테넌트 범위 소문자 `uid`(`^[a-z0-9][a-z0-9._@+-]{0,95}$`, 예: `research-analyst`)를 지정합니다. Agent는 테넌트 안에서 `(tenant_id, uid)`로 고유하게 식별됩니다.
3. 역할(role), 아바타 URL(선택 사항), `WorkerProvider`를 지정합니다.
4. 이 Agent를 소유할 사용자 Principal과 group memory 공개 모드를 선택합니다.
5. Agent를 저장한 뒤 규약, 모델 프로필 재정의, Agent별 환경 변수를 구성합니다.

역할(role)은 "Research Analyst"나 "Customer Support"처럼 담당 업무를 한눈에 알아볼 수 있게 요약한 설명입니다. 실제 행동 원칙·책임 범위와 시각 디자인 규칙은 **Meta Ankole → Agents**의 두 가지 조합형 규약 문서(`AGENTS.md`, `DESIGN.md`)로 관리합니다.

`WorkerProvider` 설정은 이 Agent가 사용할 [WorkerProvider](../worker-providers/) 대상을 결정합니다. 생성 요청에서 생략하면 사이트 기본 provider가 할당되며, 기본 provider가 지정되어 있지 않으면 생성이 거부됩니다(저장 후에는 변경할 수 없습니다). 여러 Agent가 같은 provider를 공유하더라도 각자 독립된 전용 Worker 인스턴스, `/drive` FUSE 마운트, 영구 `/workspace` Home을 할당받으며, Agent를 저장하면 최초 Worker 기동이 백그라운드 대기열에 들어갑니다. 최초 기동이 완료되고 유휴 Worker가 해제된 뒤에는 컴퓨터 작업이 필요할 때 control plane이 다시 기동합니다.

## 소유자와 group memory 공개 설정

모든 Agent에는 반드시 소유자(사람 Principal)를 지정해야 합니다. 소유자는 해당 Agent가 작성하거나 보유한 지식과 그 Agent를 공개 대상(audience)으로 지정한 지식을 검토할 수 있습니다. 다만 소유자가 특정 Group의 구성원이 아니라면, Agent 소유권만으로 그 Group에 속한 지식까지 열람할 수는 없습니다.

group memory 공개 모드는 여러 사람이 함께 보는 대화방에서 Agent가 어디까지 지식을 인용해 답변할 수 있는지를 결정합니다.

- **Strict** 모드에서는 그룹 대화의 모든 참여자가 해당 기억 항목의 공개 범위(audience scope) 조건을 충족해야만 인용할 수 있습니다.
- **Relaxed** 모드에서는 질문한 발신자의 권한만 확인하며, 대화방에 있는 다른 참여자 때문에 조회 결과가 제한되지 않습니다.

1:1 대화(direct message)에서는 두 모드가 동일하게 동작합니다. 해당 그룹에서 완화된 공개 기준을 명시적으로 허용한 경우가 아니라면 **Strict**를 유지하세요. 전체 지식 구조와 공개 범위 모델은 [Brain](../brain/)을 참조하세요.

## Agent 규약 설정

**Meta Ankole → Agents**에서 전역 기준 또는 개별 Agent의 `AGENTS.md`와 `DESIGN.md`를 편집합니다. `AGENTS.md`는 행동과 책임을, `DESIGN.md`는 웹 페이지·슬라이드·문서·차트의 시각 규칙을 정의합니다.

각 Agent 규약은 전역 기준을 상속하거나 내용을 추가하거나 완전히 대체할 수 있습니다. DESIGN 메타데이터에는 디자인 토큰을, 본문에는 사용법을 기록합니다. 개인 어시스턴트의 설정은 소유자 본인만 보고 편집할 수 있습니다. [Agent Library](../agent-library/)를 참조하세요.

저장한 변경은 Codex Job 재개를 포함한 다음 턴부터 적용됩니다. 현재 턴에서는 시작할 때 전체를 읽은 규약을 사용합니다.

## 모델 구성

Agent의 모델 프로필은 **Console → Model Profiles**에서 구성하는 3계층 희소 상속 체인(`Agent -> Pod -> Site`)을 따라 해석되며, `coding -> heavy -> primary` 및 `light -> primary` 슬롯 간 폴백이 적용됩니다. Site나 Pod에 `primary` 프로필이 이미 구성되어 있으면 새 Agent는 슬롯별 개별 설정 없이도 즉시 동작하므로, 이 Agent의 역할에 Pod 기본값과 다른 provider·모델 등급·사용자 지정 언어 모델 별칭이 필요할 때만 슬롯을 재정의하세요.

- Pod 기본값보다 상위 등급이나 특화된 모델이 필요하면 `primary`, `light`, 또는 `heavy`를 재정의합니다.
- `primary`가 네이티브 이미지 입력을 지원하지 않는데 이미지를 읽어야 한다면 `vision_fallback`을 구성합니다.
- Pod 기본값과 다른 웹 검색·열람 설정이 필요하면 `web_search`와 `web_fetch`를 구성합니다.
- 전용 이미지 생성 provider를 사용하려면 `image_generate`를 구성합니다.
- 백그라운드 작업(`coding`)에 별도의 provider나 모델을 쓰려면 **Background Agent Jobs** 프로필을 구성합니다(비워 두면 `heavy -> primary`로 폴백합니다). ChatGPT 구독 연결도 [ChatGPT subscription provider](../chatgpt-subscription-provider/)를 통해 동일한 방식으로 선택할 수 있습니다.

별도 `web_search` 또는 `image_generate` 프로필을 쓰려면 해당 provider-hosted 스위치도 꺼야 합니다. 프로필을 연결하는 것만으로 스위치가 바뀌지는 않습니다. 두 스위치는 기본적으로 켜져 있으며 Site → Pod → Agent 순서로 설정을 상속합니다.

모델을 고르거나 직접 입력하려면 먼저 Provider부터 선택해야 하며, context length 입력란 역시 Provider를 선택한 뒤에 활성화됩니다. context length를 비워 두면 해당 Provider와 모델의 기본값을 따릅니다. Agent 슬롯 재정의를 삭제하면 다시 Pod 및 Site 기본값을 상속합니다. 각 슬롯 머리글에는 그 값이 Agent 자체 재정의인지, 어느 계층에서 상속한 값인지가 표시되며, **모두 상속 복원**을 누르면 이 Agent의 재정의를 한 번에 모두 삭제합니다.

고급 설정 영역에는 선택한 Provider에서 선언한 옵션만 나타납니다. **Reasoning summary**는 Responses API 기반 모델에만 적용되며, **Answer detail**은 응답의 기본 상세 수준을 지정하고, **Service tier**는 해당 model profile의 요청 등급을 재정의합니다. 선택 가능한 값은 Provider, 계정 등급, 모델에 따라 다르며 비워 두면 Provider 기본값이 적용됩니다.

첫 LLM Provider 등록과 모델 구성 절차는 [Quick start](../quickstart/#llm-providers)를 참조하세요.

## 토큰 할당량 설정

model profile 옆에 있는 **토큰 할당량** 섹션에서는 이 Agent가 반복 주기마다 소비할 수 있는 최대 토큰 수를 제한합니다. 주기 길이(일 단위), 주기 시작 시각, 토큰 한도를 입력해 설정하며, 할당량을 지정하지 않은 Agent는 사용량 제한 없이 동작합니다.

할당량을 설정하면 현재 주기의 시작·종료 시각과 함께 한도 대비 누적 사용량이 비율 막대로 표시됩니다. Ankole은 일반 대화뿐 아니라 예약된 turn, Workflow, Background Agent Job, 그리고 해당 호출에서 파생된 컨텍스트 압축(compaction)까지 포함하여 이 Agent가 수행한 모든 모델 호출에 대해 provider가 보고한 input/output 토큰을 합산합니다. 반면 Brain 내부 모델 호출, 임베딩, 웹 도구, 이미지 생성, 또는 사용자가 개인 토큰으로 직접 보낸 요청은 이 할당량에 합산되지 않습니다.

Agent가 한도에 도달하면 채팅으로 새 메시지를 보냈을 때 일반 답변 대신 현재 사용량, 설정된 한도, 주기 종료 시각을 안내하는 메시지가 반환되며, 해당 Agent의 Background Agent Job은 다음 주기를 기다리지 않고 즉시 실패 처리됩니다. 한도 검사는 각 모델 호출 직전에 수행되므로, 마지막으로 허용된 호출 하나가 실행되면서 소비한 토큰만큼은 설정 한도를 초과해 기록될 수 있습니다. 한도 초과로 차단된 메시지는 자동으로 재전송되지 않으므로 주기가 갱신된 뒤 사용자가 다시 보내야 합니다.

**주기 재설정**을 누르면 그 시점을 기준으로 새 주기가 즉시 시작되어 기존 주기가 끝나기 전이라도 작업을 재개할 수 있으며, **한도 해제**를 누르면 토큰 제한 자체가 제거됩니다. 어느 쪽을 실행하든 기존의 토큰 사용 이력은 감사(audit) 목적으로 보존됩니다. 그 밖의 비용 제어 수단은 [Cost management](../cost-management/)를 참조하세요.

## 기능, 연결 및 environment variable 구성

새로 만든 Agent는 Agent Plugins와 Skills에 대한 테넌트 기본값을 그대로 상속합니다. 구성을 변경하려면 Pod의 **Meta Ankole → Skills**(또는 **Console → Agent Library**)에서 테넌트 전체 기본값을 수정하거나 해당 Agent 전용 override를 지정하세요. 자세한 설정 방법은 [Skills](../skills/)와 [Agent Library](../agent-library/)를 참조하세요.

Lark/Feishu, GitHub, Linear 같은 외부 SaaS 플랫폼, 개인 OAuth 계정, Skill이 선언한 원격 MCP 서비스 자격 증명은 **Pod → Connections**(`/connectors`)에서 `Ankole.Connectors`로 통합 구성하여 시크릿을 컨트롤 플레인 내부에 보관합니다([MCP 사용](../using-mcp/) 참조). Agent 상세 페이지의 **Environment variables** 섹션은 Agent Computer 내부의 사용자 지정 CLI 도구나 스크립트에서 읽는 환경 변수에 사용하며, 동일한 이름의 변수가 있을 때 Agent별 값은 테넌트 및 사이트 값을 덮어씁니다([Environment variables](../worker-env/) 참조).

## chat channel 연결

**Pod Chat**에서는 별도의 Signal Binding 없이도 워크스페이스 구성원이 자신의 개인 어시스턴트나 활성 AI 동료에게 바로 1:1 메시지(`dm`)를 보내거나 AI 동료를 그룹 대화(`group`)에 초대할 수 있습니다. Agent끼리도 `send_to_agent`를 통해 격리된 `agent_peer` 대화에서 직접 협업할 수 있습니다.

외부 IM 채널과 전용 메일함 연동은 Signal Binding으로 관리합니다. Slack, Microsoft Teams, Lark, Feishu, DingTalk, WeCom, Telegram, Discord, LINE, WhatsApp 또는 이메일로 들어오는 메시지를 처리하려면 **Console → Signal routing**을 열고 연동할 채팅 애플리케이션과 담당 Agent를 연결하세요(지원 플랫폼에서는 `Ankole.Connectors`에 등록된 공유 연결을 그대로 재사용할 수 있습니다). 하나의 채팅 앱에 여러 라우팅 규칙을 둘 수도 있고, Agent마다 별도의 봇 애플리케이션을 만들어 연결할 수도 있습니다. 자세한 규칙 작성법은 [Signal routing rules](../signal-bindings/)를 참조하세요.

## Agent 변경, 이름 변경 또는 비활성화

표시 이름, 역할, `AGENTS.md` 및 `DESIGN.md` 규약, 모델 프로필 재정의, 활성 기능은 운영 중 언제든지 변경할 수 있습니다. AI 동료의 테넌트 범위 `uid`를 변경하려면 먼저 Agent를 비활성화하고 실행 중이거나 일시 중지된 Worker 인스턴스를 제거한 뒤, 감사 기록이 남는 이름 변경 작업(`POST /api/v2/agents/:uid/rename` 또는 워크스페이스 관리 화면)을 실행하세요. 테넌트 내 권한 grant, 그룹 멤버십, Brain 경로 및 멘션, Base 참조가 단일 트랜잭션으로 일괄 갱신됩니다.

Agent를 비활성화하면 새 작업을 수락하지 않고 목록에 "비활성" 상태로 남습니다. 비활성 상태인 Agent는 언제든 다시 활성화하거나 영구 삭제할 수 있습니다. 영구 삭제는 비활성화된 Agent에 대해서만 허용되며, 실행 시 해당 Agent의 세션, 작업, 관련 기록이 함께 삭제됩니다. Agent 전체를 멈추지 않고 특정 채팅 채널 유입만 막으려면 관련 signal routing 규칙만 비활성화하세요.

## Agent가 응답하지 않는 경우

다음 항목을 순서대로 점검해 보세요.

1. Agent가 활성(Active) 상태인지 확인합니다.
2. Agent에 유효한 `primary` 모델 프로필이 해석되고 있는지(Site/Pod 기본값 또는 Agent 재정의), 그리고 연결된 LLM Provider가 정상 작동하는지 확인합니다.
3. 외부 채널을 사용 중이라면 시그널 라우팅 규칙이 이 Agent를 가리키고 있는지 확인합니다.
4. 컴퓨터 작업이 필요한 턴이라면 **Console → Workers**에서 Worker가 `ready` 상태이거나 오류 없이 시작 중인지 확인합니다. 단순 질문에는 실행 중인 Worker가 필요하지 않습니다.
5. **Console → Conversations**에서 메시지가 실제로 유입되었는지, 실행 로그에 구체적인 오류 원인이 기록되어 있는지 확인합니다.

채널별 상세 점검 항목은 [Quick start troubleshooting](../quickstart/#agent-not-replying)을 참조하세요.
