---
title: ChatGPT 구독 provider
description: 디바이스 로그인과 공유 자격 증명 풀로 ChatGPT 구독을 AIGateway에 연결하는 방법.
section: User guide
order: 41
---

ChatGPT 구독 연결은 다른 업스트림과 동일한 방식으로 동작하는 일반 AIGateway provider입니다. 일반 대화용 프로필과 Background Agent Job용 프로필을 포함해 어떤 모델 프로필에서든 이 provider 행과 사용할 모델을 지정할 수 있습니다.

각 provider 행은 자체 자격 증명 풀(credential pool)을 보유합니다. control plane이 개별 계정 토큰을 암호화해 보관하고 OAuth 토큰을 자동 갱신하며, 매 요청마다 사용 가능한 풀 멤버를 선택해 호출합니다. Agent Computer에는 전용 AIGateway 엔드포인트와 AIGateway 접근 키만 전달될 뿐 ChatGPT 원본 refresh token은 절대 전달되지 않습니다.

## provider 생성

1. **Console → LLM Providers**를 엽니다.
2. 새 provider를 추가하고 종류(kind)로 **ChatGPT Subscription**을 선택합니다.
3. `chatgpt-main`처럼 식별하기 쉬운 고유 provider ID를 입력합니다.
4. 설정을 저장합니다.

기본 엔드포인트와 인증 헤더는 Codex 프로토콜 규격에 맞춰 사전 설정되어 있습니다. 별도의 프록시나 사내 네트워크 요건이 있는 경우에만 고급 엔드포인트나 커스텀 헤더를 수정하세요.

## 디바이스 로그인으로 계정 추가

1. 방금 생성한 ChatGPT 구독 provider 상세 화면을 엽니다.
2. **Add ChatGPT account**를 선택합니다.
3. 안내된 인증 링크를 브라우저에서 열고 Console 화면에 표시된 일회용 코드를 입력합니다.
4. Console에서 로그인이 완료되고 자격 증명 풀에 계정이 추가될 때까지 잠시 기다립니다.
5. 동일한 provider 풀에 여러 구독 계정을 묶어 쓰려면 위 과정을 반복해 추가합니다.

공식 디바이스 코드 로그인을 사용할 수 있는 환경에서는 Console이 해당 방식을 기본으로 진행합니다. 만약 디바이스 로그인을 사용할 수 없으면 브라우저 로그인 URL을 대신 안내하며, 로그인 완료 후 리다이렉트된 전체 콜백 URL을 복사해 붙여 넣으면 연결됩니다. 엔터프라이즈 운영 환경에서는 신뢰된 액세스 토큰과 해당 ChatGPT 계정 ID를 직접 등록할 수도 있습니다.

## 자격 증명 풀 구성

풀에 등록된 각 멤버에는 식별용 라벨, 우선순위, 등록 경로, 상태(health), 누적 요청 수, 속도 제한(rate-limit) 정보, 모델 및 이미지 사용량이 표시되며 비밀 토큰 원문은 화면에 절대 노출되지 않습니다.

운용 목적에 맞는 풀 선택 전략을 하나 지정하세요. Console 화면에서는 UI 언어에 맞춰 번역된 이름을 보여 주며, API와 데이터베이스는 정규 영문 키를 사용합니다.

| Console 라벨 | API 값 | 동작 |
| --- | --- | --- |
| Fill first | `fill_first` | 첫 번째 정상(healthy) 멤버를 한도에 도달할 때까지 우선 사용합니다. |
| Round robin | `round_robin` | 요청마다 정상 멤버를 순서대로 돌아가며 선택합니다. |
| Least used | `least_used` | 누적 요청 수가 가장 적은 정상 멤버를 선택합니다. |
| Random | `random` | 정상 멤버 가운데 무작위로 하나를 선택합니다. |

일시적으로 한도를 소진한 `exhausted` 멤버는 쿨다운 시간이 지나면 자동으로 풀에 복귀합니다. 반면 토큰이 만료·폐기된 `dead` 멤버는 다시 로그인하거나 새 자격 증명으로 교체해야 복구되며, 단순히 라벨 이름만 바꾼다고 해서 `dead` 상태가 풀리지는 않습니다. 특정 멤버를 일시 비활성화하거나 풀에서 완전히 삭제할 수도 있습니다.

## provider를 Agent에 할당

1. **Console → Agents**를 열고 설정할 Agent를 선택합니다.
2. 연결할 모델 프로필을 엽니다. 장기 백그라운드 작업에는 **Background Agent Jobs** 프로필을, 일반 대화 턴에는 `primary` 등 해당 프로필을 선택하세요.
3. 등록해 둔 ChatGPT 구독 provider와 지원 모델을 선택합니다.
4. 필요에 따라 reasoning effort와 Fast Mode 옵션을 지정합니다.
5. 프로필을 저장합니다.

이후 모든 모델 호출은 AIGateway를 거쳐 실행됩니다. AIGateway는 상태 보존형(stateful) 대화 스레드를 가능한 한 동일한 계정에 고정해 이어 가고, 재시도 가능한 오류가 발생하면 풀 안의 다른 정상 계정으로 자동 전환하되 다른 provider로 임의 우회(fallback)하지는 않습니다. 만약 풀의 모든 계정이 사용 불가능한 상태라면 일반 대화 호출에는 가장 빠른 복구 예정 시각과 함께 속도 제한 오류가 반환되며, Background Agent Job은 가장 먼저 복구되는 풀 멤버의 쿨다운 해제 시각까지 `queued` 상태로 대기합니다.

백그라운드 작업의 생성, 진행 제어, 문제 해결 방법은 [Background Agent Jobs](../background-jobs/)를 참조하세요.