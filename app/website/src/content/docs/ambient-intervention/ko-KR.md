---
title: Ambient intervention(주변 개입)
description: “May intervene” 그룹에서 Agent가 말할지 여부를 어떻게 결정하는지, 응답이 질문한 사람에게 어떻게 연결되는지, channel standing order가 언제 말할지 어떻게 알려 주는지 설명합니다.
section: User guide
order: 17
---

[signal binding](../signal-bindings/)이 그룹 메시지 mode를 **May intervene**으로 설정하면, Agent는 자신을 지칭하지 않는 그룹 메시지도 보고, 새 메시지 배치마다 먼저 값싼 판정 하나를 내립니다. 지금 말하는 것이 도움이 되는가? 기본값은 침묵입니다 — 대부분의 그룹 잡담에는 응답이 필요 없습니다. 판정이 응답할 가치가 있다고 말할 때만 실제 응답 turn이 시작됩니다.

이 페이지는 그 판정이 어떻게 동작하는지와, 이를 제어하는 두 가지 수단(channel standing order와 binding 자체)을 설명합니다.

## 각 메시지는 한 번만 판정됩니다

Agent는 channel별 판정 커서를 유지합니다. 각 검사는 마지막 검사 이후에 도착한 메시지만 판정하며, 이전 메시지는 배경으로만 나타나고 다시 평가되지 않습니다. Agent가 내버려 두기로 결정한 메시지가 몇 라운드 뒤에 갑자기 답변되지는 않습니다.

모든 판정은 이유와 함께 기록됩니다. Agent가 너무 조용하거나 너무 적극적으로 보일 때 운영자는 추측 대신 매번 말하거나 침묵하기로 결정한 이유를 읽을 수 있습니다.

## 응답은 질문한 사람에게 연결됩니다

Agent가 말하기로 결정하면 두 가지 경우를 구분합니다.

- **누군가 묻고 있는 경우** — @ 언급 없이도 새 메시지 중 하나가 실제로 Agent에게 묻거나 지칭합니다. 그러면 응답이 그 메시지에 앵커됩니다. 이를 지원하는 channel에서는 인용 응답 또는 스레드 응답으로 렌더링되므로, 방에 누구에게 답하는지 보입니다.
- **자발적 발언(Volunteering)** — 아무도 지칭하지 않았지만 Agent는 지금 정보를 추가하는 것이 도움이 된다고 판정합니다(또는 standing order가 매치되었습니다). 응답은 일반 그룹 메시지로 나갑니다.

귀속(attribution)은 검증됩니다. 식별된 질문은 판정된 배치에 존재해야 하고, 사람에게서 와야 하며, 작성자가 여전히 최신 발화자여야 합니다. Agent는 대화가 지나간 뒤 오래된 질문을 꺼내지 않습니다. 그런 경우는 일반적인 선제적 응답으로 격하됩니다.

## Channel standing order

standing order는 channel에 붙은 하나의 durable 정책 텍스트입니다. 그 방에서 언제 선제적으로 말할지 Agent에게 알려 줍니다. 예:

- “CI가 빨간불이거나 배포가 실패할 때만 말해.”
- “18:00 이후 누군가 일일 보고서를 올리면 요약해 줘. 그 외에는 조용히 있어.”
- “이것은 고객 그룹이야. 누군가 기술 질문을 직접 하지 않는 한 참여하지 마.”

**channel에서 Agent에게 직접 말해서 설정합니다.** 아무 channel 구성원이나 “지금부터 여기서는 CI가 빨간불일 때만 말해”라고 말할 수 있으며, Agent는 이를 이 channel의 standing order로 저장하고 누가 요청했는지 기록합니다. 변경은 완전한 교체입니다. order를 수정해 달라고 요청하면 Agent는 완전한 새 텍스트를 저장합니다. 제거하려면 “이 channel의 standing order를 지워 줘”라고 말하십시오.

standing order는 두 곳에 전달됩니다. 말할지 침묵할지 판정은 이를 해당 방의 운영자 정책으로 취급하고(매치는 말할 이유가 되며, 키워드가 아니라 의미로 판정합니다), 실제 응답 turn도 context에서 이를 볼 수 있습니다.

두 가지 경계:

- **May intervene mode에서만 활성화됩니다.** 다른 binding mode에서는 텍스트가 저장되지만 완전히 비활성 상태이며, Agent는 저장 후 비활성 상태라고 알려 줍니다. binding을 May intervene으로 전환하면 추가 단계 없이 활성화됩니다.
- 하나의 order 텍스트는 최대 4000자까지 저장할 수 있습니다.

Console에서도 standing order를 읽고 쓸 수 있습니다. [Console API reference](../console-api/)의 `/signal-channels/:channel_id/standing-orders` endpoint를 참조하십시오.

## 여전히 너무 많이 또는 너무 적게 말하는 경우

- **너무 많이 말함:** 먼저 standing order를 강화하거나 지운 다음 Agent의 역할 지침을 강화하십시오. 질문과 답변 동작만 필요한 그룹이라면 binding을 **Addressed messages only**로 되돌리십시오.
- **너무 적게 말함:** binding mode가 May intervene인지 확인하고 channel에 명시적 standing order 하나를 부여하십시오 — 판정은 기본적으로 보수적이며, order가 없으면 Agent는 누군가 실제로 필요로 할 때만 말합니다.
- **Order를 저장했지만 변화가 없음:** Agent가 order를 저장한 후의 응답을 읽으십시오 — 활성 여부를 알려 줍니다. 비활성 상태는 거의 항상 channel의 binding mode가 May intervene이 아님을 의미합니다.

## 다음 단계

- 그룹 메시지 mode와 binding 구성: [Signal bindings](../signal-bindings/)를 읽으십시오.
- 메시지가 Agent work item이 되는 방법: [SignalsGateway](../signals-gateway/)를 읽으십시오.
