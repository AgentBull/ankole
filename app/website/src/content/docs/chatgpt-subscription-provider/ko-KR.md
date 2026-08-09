---
title: ChatGPT 구독 provider
description: 디바이스 로그인과 공유 자격 증명 풀로 ChatGPT 구독을 AIGateway에 연결하는 방법.
section: User guide
order: 41
---

ChatGPT 구독은 평범한 AIGateway provider입니다. 일반 대화와 Background Agent Job을 포함해 어떤 모델 프로필이든 이를 가리킬 수 있습니다. 프로필은 provider 행과 모델을 선택합니다. 행 안의 한 계정을 선택하지는 않습니다.

provider 행은 자격 증명 풀(credential pool)을 소유합니다. control plane은 각 계정 토큰을 암호화하고, OAuth 토큰을 갱신하며, 각 요청에 사용 가능한 풀 멤버를 선택합니다. Agent Computer는 자신의 AIGateway endpoint와 AIGateway 키만 받습니다. ChatGPT refresh token은 절대 받지 않습니다.

## provider 생성

1. **Console → LLM Providers**를 엽니다.
2. provider를 추가하고 provider 종류로 **ChatGPT Subscription**을 선택합니다.
3. `chatgpt-main` 같은 안정적인 provider ID를 입력합니다.
4. provider를 저장합니다.

기본 endpoint와 identity 헤더는 Codex 프로토콜과 일치합니다. 배포에 특정 요구 사항이 있을 때만 고급 endpoint나 헤더를 변경하세요.

## 디바이스 로그인으로 계정 추가

1. ChatGPT 구독 provider를 엽니다.
2. **Add ChatGPT account**를 선택합니다.
3. 검증 링크를 열고 Console이 표시하는 일회용 코드를 입력합니다.
4. Console이 로그인을 완료하고 풀 멤버를 추가할 때까지 기다립니다.
5. 같은 provider에 계정을 더 추가하려면 과정을 반복합니다.

Console은 공식 디바이스 로그인을 사용할 수 있을 때 사용합니다. 그 경로를 사용할 수 없으면 Console이 브라우저 로그인 URL을 표시하고 완전한 콜백 URL을 붙여 넣도록 요청합니다. 엔터프라이즈 운영자는 대신 신뢰된 액세스 토큰과 해당 ChatGPT 계정 ID를 추가할 수 있습니다.

## 자격 증명 풀 구성

각 멤버는 라벨, 우선순위, 소스, health 상태, 요청 수, rate-limit 데이터, 모델 또는 이미지 사용량을 가집니다. 비밀 토큰은 절대 표시되지 않습니다.

선택 전략을 하나 선택하세요. Console은 표시 이름을 변환하지만, API 값과 저장 값은 안정적으로 유지됩니다:

| Console 라벨 | API 값 | 동작 |
| --- | --- | --- |
| Fill first | `fill_first` | 사용할 수 없게 될 때까지 첫 번째 healthy 멤버를 사용합니다. |
| Round robin | `round_robin` | 각 선택 후 순환합니다. |
| Least used | `least_used` | 요청 수가 가장 적은 멤버를 선택합니다. |
| Random | `random` | 임의의 healthy 멤버를 선택합니다. |

`exhausted` 멤버는 cooldown 후 자동으로 돌아옵니다. `dead` 멤버는 새 로그인 또는 대체 자격 증명이 필요합니다. 멤버를 비활성화하거나 삭제할 수도 있습니다. 라벨만 바꾸는 것은 `dead` 상태를 해제하지 않습니다.

## provider를 Agent에 할당

1. **Console → Agents**를 열고 Agent를 선택합니다.
2. 필요한 모델 프로필을 엽니다. 지속적인 Job에는 **Background Agent Jobs**, 일반 모델 턴에는 다른 프로필을 사용하세요.
3. ChatGPT 구독 provider와 자격이 있는 모델을 선택합니다.
4. 필요에 따라 reasoning effort와 Fast Mode를 설정합니다.
5. 프로필을 저장합니다.

모든 호출은 AIGateway를 통해 계속됩니다. gateway는 가능하면 같은 계정에 상태ful 스레드를 유지하고, 재시도 가능한 provider 실패 시 순환하며, 다른 provider로 fallback하지 않습니다. 모든 멤버를 사용할 수 없으면 대화형 호출은 다음 복구 시간과 함께 rate-limit 오류를 반환합니다. Background Agent Job은 가장 이른 풀 멤버가 복구될 때까지 `queued`로 돌아갑니다.

Job 생성, 제어, 문제 해결은 [Background Agent Jobs](../background-jobs/)를 참조하세요.