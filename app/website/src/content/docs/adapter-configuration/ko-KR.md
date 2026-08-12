---
title: 어댑터 구성 가이드
description: 각 Ankole identity 및 채팅 어댑터의 앱 유형, 자격 증명, 권한, 검증 단계를 확인하는 방법.
section: Getting started
order: 3
---

이 페이지는 Ankole에 포함된 엔터프라이즈 identity 및 채팅 어댑터를 안내합니다. 먼저 플랫폼이 **Identity Provider(IdP)**, **Channel Provider**, 또는 둘 다를 제공하는지 결정하세요. 그런 다음 해당하는 상세 가이드를 여세요.

최초 실행 설정 중 `/setup`은 선택한 IdP의 로그인 콜백 URL과 가이드 링크를 보여 줍니다. 설정 후에는 **Console → Identity Providers**에서 identity 설정을 관리하고, **Console → Signal Routing**에서 채팅 애플리케이션을 Agent에 바인딩하세요.

## Identity Providers

IdP는 Console 로그인을 제공합니다. 플랫폼이 지원하면 직원, 부서, 그룹도 동기화할 수 있습니다. 아래의 자격 증명 이름은 Ankole 폼의 이름과 일치합니다. 정확한 권한, provider 콘솔 경로, 검증 단계는 링크된 가이드를 사용하세요.

| 플랫폼 | 외부 애플리케이션 | 주요 구성 | 상세 가이드 |
|---|---|---|---|
| Slack | 처음부터 생성한 Slack 앱 | Client ID 및 Client Secret; 디렉터리 동기화에는 Bot Token과 App Token도 필요 | [Slack IdP 가이드](../quickstart/?idp=slack#identity-providers) |
| Microsoft Entra ID | 단일 테넌트 앱 등록 | Tenant ID, Client ID, Client Secret, Microsoft Graph 권한 | [Entra ID 가이드](../quickstart/?idp=entra-id#identity-providers) |
| Google Workspace | OAuth 웹 클라이언트와 도메인 전체 위임 service account | OAuth 클라이언트, 허용 도메인, service account JSON, 위임된 관리자 이메일 | [Google Workspace 가이드](../quickstart/?idp=google-workspace#identity-providers) |
| Feishu / Lark | 엔터프라이즈 자체 구축 앱 또는 Custom App | App ID, App Secret, 서비스 지역, 애플리케이션 사용 가능 범위 | [Feishu / Lark IdP 가이드](../quickstart/?idp=lark#identity-providers) |
| DingTalk | 내부 엔터프라이즈 애플리케이션 | Client ID, Client Secret, Corp ID, 디렉터리 권한 | [DingTalk IdP 가이드](../quickstart/?idp=dingtalk#identity-providers) |
| WeCom | 선택적 연락처 동기화가 포함된 자체 구축 앱 | CorpID, AgentId, 애플리케이션 Secret, 연락처 동기화 Secret, 신뢰된 IP 주소 | [WeCom IdP 가이드](../quickstart/?idp=wecom#identity-providers) |

Provider를 구성한 후 콜백 URL을 `/setup`에 표시된 그대로 등록하세요. 직접 입력하지 마세요. 브라우저가 접근하는 HTTPS origin을 내부 컨테이너 주소로 바꾸지 마세요. 로그인 성공 후 전체 디렉터리 동기화를 한 번 실행하고 **Principals and permission groups**에서 사용자, 부서, 그룹을 확인하세요.

## Channel Providers

채팅 어댑터는 메시지를 수신하고 Agent의 답변을 보냅니다. 프로덕션에서는 한 플랫폼이 둘 다 제공하더라도 identity용과 채팅용 애플리케이션을 별도로 생성하세요. 이렇게 분리하면 로그인 권한, 봇 권한, 릴리스 범위, 자격 증명 순환이 서로 독립적으로 유지됩니다.

| 플랫폼 | 외부 애플리케이션 | 연결 방식과 주요 구성 | 상세 가이드 |
|---|---|---|---|
| Slack | Bot User가 있는 Slack 앱 | Socket Mode; Bot Token, App Token, 이벤트, Bot 스코프 | [Slack 채널 가이드](../quickstart/?channel=slack#chat-channels) |
| Microsoft Teams | Entra 애플리케이션이 있는 Azure Bot | Bot Framework; App ID, Client Secret, 테넌트, 메시징 endpoint | [Teams 채널 가이드](../quickstart/?channel=teams#chat-channels) |
| Feishu / Lark | 별도의 엔터프라이즈 자체 구축 앱 또는 Custom App | 장기 연결; App ID, App Secret, 이벤트, 봇 권한 | [Feishu / Lark 채널 가이드](../quickstart/?channel=lark#chat-channels) |
| DingTalk | 봇이 있는 내부 엔터프라이즈 애플리케이션 | Stream 모드; Client ID 및 Client Secret, AI 카드는 선택 사항 | [DingTalk 채널 가이드](../quickstart/?channel=dingtalk#chat-channels) |
| WeCom | 슈퍼 관리자가 생성한 API 모드 AI 봇 | 장기 연결; Bot ID와 봇 Secret | [WeCom 채널 가이드](../quickstart/?channel=wecom#chat-channels) |

외부 애플리케이션을 준비한 후 **Console → Signal Routing → New routing rule**을 여세요. Agent와 어댑터를 선택하고 자격 증명을 입력하세요. IdP와 채팅 애플리케이션이 같은 엔터프라이즈 조직에 속할 때만 두 곳에 같은 `platformSubjectNamespace`를 사용하세요. 네임스페이스를 조직 간에 공유하지 마세요.

## 저장된 자격 증명 업데이트

Identity Provider 또는 signal routing 규칙을 편집할 때 Console은 암호화된 자격 증명이 저장되어 있다는 사실만 표시합니다. token이나 secret을 브라우저로 반환하거나 페이지에 넣지 않습니다. 저장된 값을 유지하려면 자격 증명 필드를 비워 두세요. 값을 바꾸려는 경우에만 새 값을 입력하고 저장하세요. 이전 자격 증명의 순환 또는 취소는 외부 provider에서 수행합니다. Console에서는 현재 값을 볼 수 없습니다.

## 검증 순서

1. IdP 로그인을 검증하고 첫 번째 관리자가 Console을 열 수 있는지 확인합니다.
2. 전체 디렉터리 동기화를 실행하고 Principals and permission groups를 확인합니다.
3. 채팅 라우팅 규칙을 생성합니다. 먼저 직접 메시지나 명시적 멘션으로 테스트합니다.
4. Agent가 메시지를 수신하고 답변을 보내는지 확인합니다. 그런 다음 그룹 관찰, 실시간 디렉터리 동기화, 카드 같은 고급 기능을 활성화합니다.

Provider 스코프, 애플리케이션 권한, 릴리스 범위를 변경하면 provider가 요구할 때 애플리케이션을 재설치하거나 다시 게시하세요. 순환한 각 자격 증명으로 Ankole을 업데이트하세요.
