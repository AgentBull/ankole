---
title: 프롬프트 조립
description: 에이전트가 매 턴마다 보는 시스템 프롬프트가 어떻게 만들어지는지 설명합니다 — 제어 플레인의 데이터 제공자, 프롬프트를 Worker로 전달하는 두 채널, 그리고 최종 프롬프트를 생성하는 Worker 측 조립 과정.
section: Developer guide
order: 118
---

매 턴마다 Worker는 모델이 보는 시스템 프롬프트를 구성합니다. 이 프롬프트는 PostgreSQL에 저장된 에이전트 컨텍스트에서 턴 시점에 해석되어 Worker에서 렌더링됩니다. 이 페이지는 각 구성 요소가 제어 플레인에서 Worker로 전달되는 경로, 각 구성 요소가 무엇인지, 그리고 조립이 어디에서 일어나는지를 설명합니다. [Agent Computer Worker](../agent-computer-worker/) 및 [AIGateway](../ai-gateway/) 문서를 기반으로 합니다.

시스템 프롬프트는 제어 플레인이 아니라 **Worker에서 조립**됩니다. 제어 플레인은 영구 Agent 문서, Skills, Brain 스냅샷, Agent 설정, 채팅 컨텍스트를 두 경로로 공급합니다. Worker는 이 사실들을 최종 프롬프트로 렌더링합니다.

## 두 데이터 채널

Worker는 제어 플레인으로부터 두 경로로 컨텍스트를 받으며, 각 경로는 서로 다른 부류의 데이터를 전달합니다:

| 채널 | 전달 내용 | 시점 |
|---|---|---|
| `turn_start.request_context` | agent-loop 설정(`ai_agent.max_iterations`, `max_output_tokens`, `inactivity_timeout_ms`)과 턴 로컬 사실(시그널과 턴 종류) | 루프가 시작되기 전에 TurnStart 봉투에 포함 |
| `AgentConversationContextBroker` RPC | 영구 Agent 문서(`SOUL`/`MISSION`/`DESIGN`), 활성화된 skills, Brain 스냅샷(고정 메모 + 채널 항목), 대화 원본 채널, 인스턴스 타임존, agent 프로필 | 루프 시작 시 RuntimeFabric을 통한 RPC로 Worker가 가져옴 |

이 분리는 의도적입니다. 턴 로컬 사실은 매 턴마다 바뀌므로 `turn_start`를 통해 전달되고, 대화 범위 컨텍스트는 한 대화 안에서 턴 사이에 안정적이고 broker가 캐시하므로 Worker가 broker를 통해 가져옵니다. broker의 moduledoc은 명확히 밝힙니다: “이 RPC는 의도적으로 전사 메시지나 턴 로컬 요청 컨텍스트를 반환하지 않습니다. 전사 히스토리는 AIGateway가 소유하며, 턴 로컬 사실은 `turn_start`로 전달됩니다.”

## 제어 플레인이 제공하는 것

### 영구 Agent 문서

`AgentConversationContextBroker`는 `Library.list_agent_documents/1`을 통해 Agent의 영구 문서를 읽습니다. 문서는 `soul`, `mission`, `design`으로 반환됩니다. `SOUL.md`는 커뮤니케이션과 판단을 정의하고, `MISSION.md`는 책임을 정의하며, `DESIGN.md`는 시각 작업을 위한 디자인 시스템을 제공합니다.

### 활성화된 Skills

`Library.skills_for_system_prompt/1`은 에이전트의 실질 스킬 집합, 즉 기본값-후-덮어쓰기 방식으로 활성화된 스킬과 그 설명 및 메타데이터를 반환합니다. Worker는 이를 사용하여 시스템 프롬프트의 스킬 블록을 구성하고, 모델에게 어떤 스킬이 있고 각각 무엇을 위한 것인지 알려줍니다.

### Brain 스냅샷

`Brain.Snapshot.get_or_create/1`은 대화의 Brain 범위를 해석하고 스냅샷, 즉 에이전트의 고정 메모(`agent_context`)와 채널의 영구 컨텍스트(`group_context`)를 반환합니다. 이들은 저장된 컨텍스트 항목, 즉 에이전트가 기억하라고 지시받은 영구 사실이며 전체 Brain 지식 베이스가 아닙니다. 스냅샷은 투영(projection)이지 쿼리가 아닙니다. 회상(전체 검색)은 이 스냅샷이 아니라 루프 중 Brain 도구를 통해 이루어집니다.

### 대화 원본 채널

`SignalsGateway.ConversationChannel`은 AIGateway 대화가 선언한 제공자 채널을 투영합니다. 현재 채널 미러에서 그룹 라벨을 읽고 피어 Principal에서 DM 라벨을 읽습니다. `lark` 어댑터를 하나의 Lark/Feishu 표면으로 보고하며, 어댑터 도메인은 API 서버만 선택합니다. broker는 이 투영을 `ConversationInfo.origin_channel`로 보내므로, 내부 웨이크업의 ActorEvent 페이로드에 채널 객체가 없어도 대화 원본이 유실되지 않습니다.

### Agent 설정(AppConfigure에서)

`AgentConfig`는 AppConfigure에서 루프 수준 설정을 해석하고 이를 `turn_start.request_context.ai_agent`에 스냅샷합니다:

- `ai_agent.max_iterations`(기본값 90) — agent 루프의 반복 예산
- `ai_agent.max_output_tokens`(기본값 nil = 명시적 상한 없음) — 응답당 토큰 상한
- `ai_agent.inactivity_timeout_ms`(기본값 30분) — 턴이 비활성 상태로 허용되는 시간

이 설정은 개별 모델 응답이 아니라 actor 턴에 속하므로 `turn_start`에 실려 이동합니다.

## Worker 측 조립

Worker의 `system_prompt.ts`가 최종 프롬프트를 구성합니다. 여기의 moduledoc은 설계를 명시합니다: “느리게 변하는 지침이 앞에 오고, 대화 범위 런타임, skill, Brain 스냅샷이 접미사를 이룹니다.” 블록은 순서대로 다음과 같습니다:

1. **핵심 지침** — 턴의 컨텍스트에서 조립된 에이전트의 기본 동작 계약.
2. **영구 Agent 문서** — broker 응답에서 렌더링된 `SOUL`, `MISSION`, `DESIGN`.
3. **영구 컨텍스트** — Brain 스냅샷의 고정 메모와 채널 항목을 지침과 함께 렌더링(“항목이 여전히 유효할 때만 사용하고, 그렇지 않으면 무시하세요”).
4. **Skills** — 활성화된 스킬 설명으로, 모델이 무엇을 사용할 수 있는지 알려줍니다.
5. **채널 및 런타임 컨텍스트** — 대화 원본 채널, 워크스페이스 경로, 사용 가능한 도구 이름.

Worker는 매 턴마다 현재의 PostgreSQL 기반 컨텍스트에서 전체 프롬프트를 다시 렌더링하며, 캐시된 버전을 신뢰하지 않습니다. AIGateway는 감사용으로 이전 요청 지침을 보관하지만, 턴은 현재 상태를 렌더링합니다.

## 시스템 프롬프트에 포함되지 않는 것

- **전사 히스토리** — AIGateway의 상태 저장 Responses가 소유하며, 시스템 프롬프트는 이를 반복하지 않습니다.
- **턴 로컬 관찰** — 시그널, 수신 메시지, 사용자의 현재 입력. 이들은 시스템 프롬프트가 아니라 현재 사용자 메시지에 남습니다.
- **Brain 회상 결과** — 회상(전체 검색)은 시스템 프롬프트 블록이 아니라 루프 중 Brain 도구를 통해 이루어집니다. 스냅샷이 바닥이고 회상이 천장입니다.

이 분리는 시스템 프롬프트를 안정적으로 유지하고(대화가 커질 때가 아니라 페르소나, 스킬, 메모리가 바뀔 때 변경), 턴당 페이로드를 작게 유지합니다.

## 이 가이드가 아닌 것

이 가이드는 프롬프트 엔지니어링 튜토리얼이 아닙니다 — `system_prompt.ts`의 리터럴 문자열은 모델과의 계약이며, 이를 바꾸는 것은 문서 변경이 아니라 동작 변경입니다. 제어 플레인 측의 프롬프트 조립 설명도 아닙니다 — 조립은 Worker에서 일어나며 제어 플레인의 역할은 데이터를 제공하는 것입니다. 그리고 `system_prompt.ts`를 읽는 것을 대신하는 것도 아닙니다. 이 가이드는 그 파일로 가는 지도입니다.

## 다음 단계

- 이 프롬프트를 사용하는 agent 루프에 대해서는 [에이전트 루프](../agent-loop/)를 읽으세요.
- 조립을 실행하는 Agent Computer Worker에 대해서는 [Agent Computer Worker](../agent-computer-worker/)를 읽으세요.
- 영구 컨텍스트 블록에 공급되는 Brain 스냅샷에 대해서는 [Brain](../brain/)을 읽으세요.
- 스킬 블록에 대해서는 [Agent Library](../agent-library/)를 읽으세요.