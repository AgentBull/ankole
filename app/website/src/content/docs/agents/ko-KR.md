---
title: Agents
description: Console에서 Agent를 생성한 다음 역할, durable 동작, 모델, 기능, environment variable을 구성하는 방법을 설명합니다.
section: User guide
order: 13
---

Agent는 시간을 두고 작업하는 디지털 동료입니다. 각 Agent는 고유한 identity, 작업 지침, 모델, 기능, file space를 가집니다. signal routing 규칙이 Agent를 chat channel의 메시지에 연결합니다.

## Agent 생성

1. **Console → Agents**를 열고 **New Agent**를 선택합니다.
2. 필수 display name을 입력합니다. Console은 영어 또는 중국어 텍스트에서 UID를 생성합니다. 예를 들어 `Research Analyst`는 `research-analyst`, `研究分析师`는 `yan-jiu-fen-xi-shi`가 됩니다. 혼합 언어 이름도 동작합니다.
3. UID를 검토하거나 변경한 다음 역할과 선택적 avatar URL을 입력합니다. UID는 이 deployment 인스턴스 안에서 고유한 안정적인 식별자이며, Agent를 저장한 후에는 변경할 수 없습니다. display name은 나중에 변경해도 기존 configuration이 깨지지 않습니다.
4. Agent를 저장합니다. 그러면 페이지에 해당 Agent의 durable 지침, model profile, Agent별 environment variable이 표시됩니다.

이전 Ankole 버전의 Agent는 display name 없이도 로드하고 실행할 수 있습니다. 다음에 기본 정보를 저장하기 전에 display name을 추가해야 합니다.

역할(role)은 “Research Analyst”나 “Customer Support”처럼 작업에 대한 짧은 요약을 제공합니다. 아래의 세 가지 durable 문서가 책임, 동작, 시각적 디자인을 관리합니다.

## durable 문서 설정

Agent 페이지에서 **MISSION / SOUL / DESIGN**을 엽니다.

| 문서 | 작성 내용 |
|---|---|
| `MISSION.md` | Agent가 왜 존재하는지, 어떤 작업을 소유하는지, 완전한 결과가 무엇을 의미하는지 |
| `SOUL.md` | 어떻게 커뮤니케이션하는지, 어떻게 결정을 내리는지, 불확실성을 어떻게 처리하는지 |
| `DESIGN.md` | 웹 페이지, 슬라이드, 문서, 차트 및 기타 시각적 산출물을 위한 디자인 시스템 |

`DESIGN.md`는 <a href="https://www.designmd.co/about" target="_blank" rel="noreferrer">DESIGN.md format</a>을 사용합니다. YAML frontmatter에 색상, 타이포, 간격, 모서리, component 같은 design token을 저장합니다. Markdown 본문은 시각적 원칙과 적용 방법을 설명합니다. Ankole에는 바로 사용할 수 있는 기본 디자인 시스템이 포함되어 있습니다. **Console → Agents → DESIGN**에서 회사 브랜드로 교체할 수 있습니다.

워크플로, 권한 경계 또는 동작 규칙을 `DESIGN.md`에 넣지 마십시오. 그것들은 `MISSION.md`, `SOUL.md` 또는 특정 Skill에 넣으십시오. 명확한 문서 소수의 집합으로 시작한 다음, 실제 작업이 필요하다는 것을 보여줄 때만 규칙을 추가하십시오.

저장된 변경 사항은 이후의 conversation에 적용됩니다. 이미 실행 중인 작업은 시작할 때 읽은 버전으로 계속됩니다.

## 모델 구성

같은 페이지에서 최소한 `primary`, `light`, `heavy` model profile을 구성하십시오. 이들은 일반 conversation, 가벼운 작업, 복잡한 추론을 담당합니다.

최초 설정에서는 세 가지 모두 이미 검증한 동일한 모델을 사용할 수 있습니다.

선택적 profile은 Agent가 필요할 때만 구성하십시오.

- Agent가 이미지를 읽어야 할 때 `vision_fallback`을 구성하십시오.
- Agent가 공개 웹 페이지를 검색하거나 읽어야 할 때 `web_search`와 `web_fetch`를 구성하십시오.
- Agent가 이미지를 만들어야 할 때 `image_generate`를 구성하십시오.
- Job이 별도의 provider 또는 모델을 필요로 할 때 **Background Agent Jobs**를 구성하십시오. ChatGPT 구독은 [ChatGPT subscription provider](../chatgpt-subscription-provider/)를 통해 동일한 provider 선택을 사용합니다.

모델을 선택하거나 입력하기 전에 Provider를 선택하세요. context length 필드도 Provider를 선택한 후 사용할 수 있습니다. 비워 두면 Provider와 모델의 기본값을 사용합니다.

고급 설정에는 선택한 Provider가 선언한 옵션만 표시됩니다. **Reasoning summary**는 Responses API에만 적용됩니다. **Answer detail**은 기본 응답 상세 수준을 설정합니다. **Service tier**는 이 model profile의 request tier를 재정의합니다. 사용 가능한 값은 Provider, 계정, 모델에 따라 다릅니다. 비워 두면 Provider 기본값을 사용합니다.

첫 LLM Provider와 모델 설정은 [Quick start](../quickstart/#3-add-an-llm-provider-and-create-an-agent)를 참조하십시오.

## 기능과 environment variable 구성

Agent는 Agent Plugins와 Skills의 deployment 인스턴스 기본값을 상속합니다. 이를 변경하려면 **Console → Agent Library**를 열고 기본값을 편집하거나 이 Agent에 대한 override를 설정하십시오.

전체 절차는 [Agent Library](../skills/)를 참조하십시오.

Skill, 명령줄 tool 또는 MCP service에 API key가 필요하면 Agent 페이지의 **Environment variables**에 추가하십시오. Agent별 값은 이 Agent에서만 사용할 수 있습니다.

같은 이름의 전역 값을 override합니다. [Environment variables](../worker-env/)를 참조하십시오.

## chat channel 연결

새 Agent가 Slack, Microsoft Teams, Lark, Feishu 또는 DingTalk에서 메시지를 받으려면 먼저 signal routing 규칙이 필요합니다.

**Console → Signal routing**을 열고 chat application과 대상 Agent를 선택하십시오. 하나의 chat application에는 여러 규칙을 둘 수 있으며, 서로 다른 Agent를 위해 별도의 bot application을 만들 수 있습니다.

[Signal routing rules](../signal-bindings/)를 참조하십시오.

## Agent 변경 또는 비활성화

display name, 역할, durable 지침, 모델, 기능은 언제든 변경할 수 있습니다. UID는 다른 configuration이 Agent를 식별하는 데 사용하므로 변경할 수 없습니다.

비활성화된 Agent는 새 작업을 받지 않습니다. 하나의 chat entry point만 중지하려면 Agent 전체를 비활성화하는 대신 관련 signal routing 규칙을 비활성화하십시오.

## Agent가 응답하지 않는 경우

다음 항목을 순서대로 확인하십시오.

1. Agent가 활성화되어 있는지.
2. `primary`, `light`, `heavy` profile이 구성되어 있고 LLM Provider를 사용할 수 있는지.
3. signal routing 규칙이 이 Agent를 가리키는지.
4. worker가 하나 이상 준비되었는지.
5. **Console → Conversations**에 메시지가 있고 유용한 오류가 표시되는지.

channel별 확인 사항은 [Quick start troubleshooting](../quickstart/#if-the-agent-does-not-reply)을 참조하십시오.
