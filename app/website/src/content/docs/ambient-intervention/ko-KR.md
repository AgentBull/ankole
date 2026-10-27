---
title: Ambient intervention(주변 개입)
description: “May intervene” 그룹에서 Agent가 말할지 여부를 어떻게 결정하는지, 응답이 질문한 사람에게 어떻게 연결되는지, channel standing order가 언제 말할지 어떻게 알려 주는지 설명합니다.
section: User guide
order: 17
---

외부 채널의 [signal binding](../signal-bindings/)에서 그룹 메시지 모드를 **May intervene**으로 설정하거나 네이티브 **Pod Chat** 그룹 스레드에서 참여 Agent의 `may_intervene` 정책을 켜 두면, Agent는 자신을 직접 호출하지 않은 그룹 메시지도 읽고 사람들이 보낸 새 메시지 묶음(배치)마다 적절한 처리 경로를 판단합니다. 기본 동작은 침묵이며, 개입이 필요하다고 판단될 때만 짧은 답변을 남기거나 새 업무를 시작하거나 현재 실행 중인 background job에 후속 정보를 전달합니다.

이 모드에서 Agent의 그룹 대화 동작은 Conversation에 저장된 `standing_orders`와 그룹 개입 설정(외부 채널은 Signal Binding 구성, Signal Binding 없이 동작하는 Pod Chat 그룹 스레드는 참여 Agent별 `may_intervene` 정책)이라는 두 가지 기준에 따라 제어됩니다.

## 각 메시지는 한 번만 판정됩니다

같은 그룹 Conversation에 여러 Agent가 참여하더라도 메시지와 standing order만 공유할 뿐, 어디까지 판정했는지를 나타내는 진행 위치는 각 Agent가 독립적으로 유지합니다. 주변 개입 판정은 **사람**이 보낸 메시지가 들어왔을 때만 실행되며, Agent가 보낸 메시지는 다른 Agent를 깨우지 않습니다. 또한 매 검사 시점에는 직전 검사 이후에 새로 도착한 메시지만 평가하고 이전 메시지는 맥락 파악용 배경으로만 참고합니다. 따라서 한 번 침묵하기로 판정한 메시지에 몇 라운드 뒤 갑자기 뒤늦은 답변을 달지 않습니다.

모든 판정 결과에는 선택한 처리 경로(action), 승인 근거(authorization source), 판단 사유가 기록되며, 백그라운드 작업으로 전달(`HANDOFF`)한 경우에는 정확한 대상 Job 정보까지 함께 남습니다. 운영자는 Agent가 지나치게 조용하거나 반대로 너무 자주 끼어들 때 이 기록을 조회해 왜 해당 경로가 선택되었는지 바로 확인할 수 있습니다.

## 네 가지 처리 경로

- **처리 안 함(`NOOP`)**: Agent가 발언하지 않고 침묵을 유지합니다. 일상적인 잡담, 단순 확인 응답, 이미 답변된 질문, 또는 다른 구성원이 이미 맡기로 한 일에는 대개 이 경로가 선택됩니다.
- **foreground 응답(`FOREGROUND_REPLY`)**: 간단한 답변이나 질문 구체화, 일정·의견 조율, 진행 상태 안내, 가벼운 단발성 조회를 위해 짧은 공개 turn 하나를 실행합니다. 이 경로에서는 새로운 background job을 생성하거나 재개할 수 없습니다.
- **새 작업(`NEW_WORK`)**: 독립적으로 수행해야 할 실질적인 업무가 감지되었을 때 선택됩니다. 사람이 직접 작업을 요청했거나 채널의 standing order 조건과 일치할 때만 정규 owner turn으로 진입합니다. 이때 사람이 유발한 turn은 **`Human ∩ Agent` 권한 교집합**(`interactive_principal = waking_human`) 아래에서 실행되므로, 접근하려는 모든 리소스에 대해 발화한 사용자와 Agent 양쪽 모두 권한을 가지고 있어야 합니다. 두 가지 승인 근거 중 어느 것도 없다면 Agent는 도구나 background job 실행 권한이 없는 확인 전용 turn만 열어 작업을 맡을지 먼저 물어봅니다.
- **전달(`HANDOFF`)**: 동일한 Agent, owner Session, Conversation(외부 채널인 경우 동일한 binding 포함)에 속해 현재 실행 중인 background job 가운데 맥락이 명확히 일치하는 대상 하나를 골라 새 메시지를 조용히 전달합니다. 대상 후보가 불분명하거나 여러 개여서 모호한 경우에는 전달하지 않습니다.

판정기(recognizer) 자체는 background job을 직접 생성하지 않습니다. 처리 경로와 승인 근거만 결정해 넘기면, 이어서 실행되는 일반 owner turn이 기존의 권한 검증과 백그라운드 작업 규칙을 그대로 적용합니다.

## 응답은 질문한 사람에게 연결됩니다

Agent가 발언하기로 결정했을 때는 발화 상황에 따라 응답 방식이 두 가지로 나뉩니다.

- **누군가 질문한 경우** — `@` 멘션이 없더라도 새 메시지 중 하나가 실질적으로 Agent에게 묻거나 말을 건넨 상황입니다. 이때는 해당 메시지에 응답을 연결(앵커)합니다. 인용 답장이나 스레드 답장을 지원하는 채널에서는 누구의 말에 답하는지가 화면에 명확히 표시됩니다.
- **자발적 발언(Volunteering)** — 특정인이 Agent를 지칭하지는 않았지만 지금 정보를 보태는 편이 유익하다고 판단했거나 standing order 조건이 충족된 상황입니다. 이때는 특정 메시지에 묶이지 않는 일반 그룹 메시지로 발언합니다.

질문자 귀속(attribution)은 엄격하게 검증됩니다. 지목된 질문 메시지가 이번 판정 배치 안에 실제로 존재해야 하고, 작성자가 사람이어야 하며, 대화 흐름상 여전히 가장 최근 발화자여야 합니다. 이미 대화가 다른 주제로 넘어간 뒤에 이전 질문을 뒤늦게 끌어오지 않으며, 조건을 충족하지 못하면 일반 자발적 발언으로 전환됩니다. 만약 외부 플랫폼에서 원래 질문 메시지가 나중에 삭제되면 저장된 귀속 상태는 `degraded`로 표시되어 메시지 연결만 해제되고, 판정 이력과 진행 위치는 그대로 유지됩니다.

## Channel standing order

standing order는 각 Conversation에 하나씩 저장되어 참여 중인 모든 Agent가 함께 참조하는 상시 운영 지침입니다. 이 채널에서 어떤 상황일 때 먼저 입을 열어야 하는지를 자연어로 지정할 수 있습니다. 예를 들면 다음과 같습니다.

- “CI가 빨간불이거나 배포가 실패할 때만 말해.”
- “18:00 이후 누군가 일일 보고서를 올리면 요약해 줘. 그 외에는 조용히 있어.”
- “이것은 고객 그룹이야. 누군가 기술 질문을 직접 하지 않는 한 참여하지 마.”

**채널 안에서 Agent에게 직접 말하여 설정할 수 있습니다.** 채널 구성원 누구나 “지금부터 여기서는 CI가 빨간불일 때만 말해”처럼 지시하면, Agent가 이를 해당 채널의 standing order로 저장하고 요청한 사용자를 함께 기록합니다. 지침 변경은 전체 덮어쓰기 방식으로 동작하므로, 수정을 요청하면 Agent가 변경 사항을 반영한 새 전체 문구를 저장합니다. 지침을 비우려면 “이 channel의 standing order를 지워 줘”라고 요청하면 됩니다.

저장된 standing order는 두 단계에 모두 반영됩니다. 우선 경로 판정 단계에서 해당 채널의 운영 정책으로 전달되어, 새 메시지가 지침과 명확히 부합할 때 `NEW_WORK` 진입을 승인하는 근거가 됩니다. 이어지는 공개 owner turn에서도 컨텍스트에 포함되어 응답 내용과 어조에 반영됩니다.

운영 시 알아 두어야 할 두 가지 경계 조건은 다음과 같습니다.

- **May intervene 모드에서만 효력을 발휘합니다.** 외부 채널의 바인딩 모드가 다른 값이거나 Pod Chat 그룹 스레드에서 해당 Agent의 `may_intervene`이 꺼져 있더라도 지침 텍스트 자체는 Conversation의 `standing_orders`에 저장되지만, 비활성 상태로 유지되며 Agent도 저장 직후 현재 비활성 상태임을 안내합니다. 이후 May intervene을 켜면 별도 재설정 없이 즉시 적용됩니다.
- 하나의 standing order 텍스트는 최대 4000자까지 저장할 수 있습니다.

Console API를 통해서도 standing order를 조회하고 수정할 수 있습니다. 자세한 명세는 [Console API reference](../console-api/)의 `/api/v2/conversations/:conversation_id/standing-orders` 엔드포인트를 참조하세요.

## 여전히 너무 많이 또는 너무 적게 말하는 경우

- **너무 자주 끼어드는 경우:** 먼저 채널의 standing order를 더 구체적으로 좁히거나 초기화한 뒤 Agent의 역할 지침(`MISSION.md`, `SOUL.md`)을 다듬어 보세요. 명시적으로 호출했을 때만 답하면 되는 대화방이라면 외부 채널 바인딩을 **Addressed messages only**로 바꾸거나 Pod Chat 그룹 스레드에서 해당 Agent의 `may_intervene`을 끄면 됩니다.
- **거의 말하지 않는 경우:** 먼저 May intervene이 켜져 있는지 확인한 뒤(외부 채널의 Signal Binding 또는 Pod Chat 그룹 스레드의 참여 Agent `may_intervene` 설정), 해당 Conversation에 구체적인 standing order를 등록해 보세요. 기본 판정 기준은 보수적으로 설계되어 있어 별도 지침이 없으면 꼭 필요한 순간에만 개입합니다.
- **standing order를 등록했는데도 동작이 달라지지 않는 경우:** 지침을 저장했을 때 Agent가 남긴 안내 메시지를 확인해 보세요. 현재 비활성 상태라고 안내했다면 외부 채널의 바인딩 모드가 May intervene이 아니거나 Pod Chat 그룹 스레드에서 해당 Agent의 `may_intervene`이 꺼져 있는 상태입니다.

## 다음 단계

- 그룹 메시지 모드와 라우팅 규칙 설정은 [Signal bindings](../signal-bindings/)를 참조하세요.
- 유입된 메시지가 Agent의 작업 단위로 변환되는 과정은 [Signals](../signals/)를 참조하세요.
