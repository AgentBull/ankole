---
title: Signal routing 규칙
description: chat application을 Agent에 연결하고, 그룹 메시지와 memory 처리 방식을 선택하는 방법을 설명합니다.
section: User guide
order: 14
---

signal routing 규칙은 어떤 Agent가 메시지를 받을지 결정합니다. 현재 하나의 규칙은 하나의 chat application을 하나의 Agent에 직접 연결합니다. Agent는 여러 규칙을 사용해 여러 chat application에 연결할 수 있습니다.

“signal”이라는 용어는 chat 외의 범위까지 열어 둡니다. 향후 규칙은 routing expression을 사용해 channel, conversation 또는 기타 조건으로 Agent를 선택할 수 있습니다. Salesforce 같은 시스템의 event를 전달할 수도 있습니다.

Slack, Microsoft Teams, Lark, Feishu 또는 DingTalk application을 아직 준비하지 않았다면, 먼저 [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule)의 Channel Provider 단계를 완료하십시오.

## routing 규칙 만들기

1. Console에서 **Signal Routing**을 열고 **New routing rule**을 선택합니다.
2. 메시지를 받을 Agent와 Channel Provider adapter를 선택합니다.
3. `support-slack`처럼 명확한 규칙 이름을 입력합니다.
4. group-message mode와 memory scope를 선택합니다.
5. chat application의 credential과 connection 세부 정보를 입력하고 규칙을 저장합니다.
6. 해당 chat application에서 bot에게 메시지를 보냅니다. 선택한 Agent가 응답하는지 확인합니다.

각 bot 계정에 고유한 chat application과 routing 규칙을 부여하십시오. 여러 Agent가 서로 다른 bot 계정을 사용해야 한다면, bot별로 별도의 application을 만든 다음 규칙을 각각 만드십시오.

이렇게 하면 Agent identity와 메시지가 분리되고, 각 credential을 개별적으로 교체할 수 있습니다.

## group-message mode 선택

Console에는 선택한 Channel Provider가 지원하는 mode만 표시됩니다.

| 모드 | Agent를 지칭하지 않는 그룹 메시지에 일어나는 일 |
|---|---|
| **Addressed messages only** | Agent는 메시지를 보지 못하고 응답하지 않습니다. |
| **Observe unaddressed messages** | 메시지가 conversation context에 들어가지만 Agent를 깨우지 않습니다. 누군가 Agent를 지칭한 후 Agent는 이를 context로 사용할 수 있습니다. |
| **May intervene** | Agent는 먼저 대화에 참여하는 것이 도움이 될지 결정합니다. 말하기로 결정한 경우에만 응답합니다. |

Slack, Microsoft Teams, Lark, Feishu는 세 가지 mode를 모두 지원합니다. DingTalk와 WeCom은 bot을 명시적으로 지칭하는 그룹 메시지만 받을 수 있으므로, Console은 이들에 대해 첫 번째 mode만 제공합니다. WeCom에는 이 외에도 훨씬 더 많은 제한이 있습니다(메시지 회수 불가, 그룹 내 파일 불가, Agent가 대화를 시작할 수 없음). 따라서 첫 번째 channel로는 권장하지 않습니다. [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule)의 WeCom 탭을 참조하십시오.

**May intervene**는 Agent가 모든 메시지에 응답하게 만들지 않습니다. Agent가 언제 말할지 스스로 결정하게 하며, 각 메시지는 한 번만 판정됩니다. 특정 그룹에서 Agent가 언제 말할지 알려 주려면, 그 그룹에서 바로 channel standing order를 부여하십시오(예: “CI가 빨간불일 때만 말해”). 그래도 너무 자주 말한다면, 먼저 standing order나 역할 지침을 강화하십시오. 판정 동작과 standing order에 대해서는 [Ambient intervention](../ambient-intervention/)을 참조하십시오.

질문과 답변 동작만 필요한 그룹에는 **Addressed messages only**를 사용하십시오.

## 알 수 없는 발신자 처리 선택

Ankole는 발신자를 알려진 계정에 자동으로 매핑합니다. 디렉터리 동기화나 로그인으로 이미 가져온 계정은 플랫폼 ID로 일치하고, 새 플랫폼 계정도 플랫폼이 알려주는 이메일이나 휴대폰 번호가 기존 계정과 같으면 같은 사람으로 합쳐집니다. 이 매핑은 최선의 시도입니다. 디렉터리에 없는 외부 사용자나 채팅 계정을 한 번도 연결하지 않은 로컬 로그인 사용자는 일치하지 않을 수 있습니다.

**계정 자동 매핑에 실패한 경우**에서 이런 발신자의 처리를 선택합니다:

| 옵션 | 동작 |
|---|---|
| **수동 검토**(기본값) | 발신자가 콘솔의 **아이덴티티 → 대기 중인 매핑** 목록에 나타납니다. 관리자가 계정을 연결할 때까지 Agent를 향한 메시지에는 관리자에게 연결을 요청하라는 고정 답장 하나만 돌아가며, 그 외에는 아무 처리도 하지 않습니다. 메시지는 컨텍스트나 메모리에 들어가지 않습니다. |
| **독립 계정 자동 생성** | Ankole가 발신자를 위한 독립 계정을 만들고 즉시 응답합니다. 누구나 Agent와 대화할 수 있는 열린 채널에 적합합니다. |

매핑되지 않은 발신자가 그룹에서 Agent를 지목하지 않고 나눈 잡담은 항상 무시됩니다.

Lark와 Feishu에서는 외부 그룹도 여기에 해당합니다. 외부 테넌트 구성원에게는 직원 ID가 없으므로 수동 연결이나 자동 생성이 필요합니다. 같은 콘솔 페이지에서 본인이 메시지를 보내기 전에 미리 매핑을 등록할 수도 있습니다. 예를 들어 로컬 로그인 사용자를 채팅 계정과 연결할 때 사용합니다.

## memory scope 선택

**Shared**는 그룹 메시지가 이 인스턴스의 shared memory scope에 들어가도록 합니다. Agent가 여러 conversation에 걸쳐 지식을 유지해야 하는 작업 그룹에 사용하십시오.

**Channel only**는 그룹 메시지를 이 channel만 읽을 수 있는 memory에 보관합니다. 고객 데이터, 기밀 프로젝트 또는 분리되어야 하는 팀에 사용하십시오.

## 규칙 편집, 비활성화 또는 활성화

목록에는 기본적으로 활성화된 규칙만 표시됩니다. 이전 규칙을 확인하거나 복원해야 하면 **비활성 규칙 표시**를 켜세요.

**편집**을 선택하면 현재의 비밀 정보가 아닌 설정을 볼 수 있습니다. 대상 Agent, group-message mode, memory scope 또는 chat credential을 변경할 수 있습니다. 다른 Agent를 선택하면 새 메시지가 그 Agent로 전달됩니다. 기존 conversation과 memory는 자동으로 이동하지 않습니다.

server는 저장된 token이나 secret을 브라우저로 반환하지 않습니다. credential 필드를 비워 두면 암호화된 기존 값을 유지합니다. 값을 바꾸려는 경우에만 새 값을 입력하세요.

**비활성화**를 선택하면 규칙, chat application 연결, 기록을 유지하면서 새 메시지 전달을 중지합니다. 복원하려면 **비활성 규칙 표시**에서 해당 규칙을 찾고 **활성화**를 선택하세요. 규칙을 다시 만들 필요가 없습니다.

## Agent가 응답하지 않는 경우

- **Channel Provider가 없음:** **Agent Library → Control Plane Plugins**를 열고 plugin을 활성화한 다음, 페이지가 안내할 때 control plane을 다시 시작하십시오.
- **bot이 그룹 메시지를 받지 못함:** provider의 event subscription, 권한, application release 상태를 확인하십시오. DingTalk와 WeCom 그룹 메시지는 bot을 명시적으로 @-언급해야 합니다.
- **WeCom이 예상과 다르게 동작함:** 먼저 [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule)의 WeCom 탭과 동작을 비교하십시오. 일반적인 원인은 슈퍼 관리자가 만들지 않은 bot, 누락된 trusted-IP 항목, 또는 사용자가 아직 활성화하지 않은 conversation입니다.
- **규칙은 저장됐지만 응답이 없음:** 대상 Agent가 활성화되어 있고, 해당 모델 configuration이 정상이며, 규칙이 규칙 목록에 있는지 확인하십시오.
- **DM은 동작하는데 그룹 메시지가 동작하지 않음:** group-message mode를 확인하고 bot이 대상 그룹에 속해 있는지 확인하십시오.

[Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule)의 provider별 권한, event, credential을 사용하십시오.

DingTalk 규칙의 경우, streaming card 응답에는 DingTalk card platform의 AI card template 하나가 필요합니다. [Quick start](../quickstart/#4-connect-a-chat-channel-and-create-its-signal-routing-rule)의 DingTalk 탭 고급 섹션에서 만드는 방법을 보여 줍니다.
