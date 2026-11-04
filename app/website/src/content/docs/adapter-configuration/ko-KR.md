---
title: 어댑터 구성 가이드
description: 각 Ankole identity, 채팅, 공유 Connector 어댑터의 앱 유형, 자격 증명, 권한, 검증 단계를 확인합니다.
section: Getting started
order: 3
---

이 페이지는 Ankole에 기본 포함된 엔터프라이즈 identity, 채팅, Connector 어댑터 구성을 안내합니다. 먼저 연동할 플랫폼을 **Identity Provider(IdP)**, **Channel Provider**, **Connector Toolkit** 중 어떤 역할(또는 복합 역할)로 사용할지 확인한 뒤 해당 상세 가이드를 열어 보세요.

최초 실행 설정 단계에서는 `/setup` 화면에서 선택한 IdP의 로그인 콜백 URL과 가이드 링크를 확인할 수 있습니다. 테넌트 애플리케이션 연결은 Pod 관리자(`pod_admin`)가 **Pod → Connections**(`/connectors`, `/api/v2/pod/connectors`)에서 관리하며, 엔터프라이즈 Identity Provider는 **Pod Settings**(`/api/v2/pod/admin/identity-providers`) 또는 Site Console(**Console → Identity Providers**)에서 관리합니다. 사이트 수준의 패스워드리스 Email OTP SMTP 설정(`authn.email.*`)은 Site Console에서 구성하고, 외부 채팅 애플리케이션은 **Console → Signal Routing**에서 Agent에 연결합니다.

`Ankole.Connectors`는 공유 애플리케이션 루트 자격 증명(`authConfigId`)을 중앙에서 관리하므로, Identity Provider·IM Signal 라우팅 규칙·MCP Toolkit·외부 이벤트 트리거가 동일한 암호화 연결 레코드를 함께 참조할 수 있습니다. 예를 들어 **Pod → Connections**(또는 Console의 IdP / Signal Routing 설정 화면)에서 Feishu / Lark 엔터프라이즈 앱 연결 하나만 등록하면 SSO 및 디렉터리 동기화, IM 메시지 라우팅, MCP Toolkit(`lark-im`, `lark-approvals`, `lark-tasks`, `lark-calendar`), Connector 이벤트 트리거를 중복 앱 등록이나 시크릿 재입력 없이 모두 구동할 수 있습니다. Slack과 Microsoft 365(Entra ID 및 Teams) 역시 하나의 `authConfigId` 연결을 공유할 수 있으며, Agent별 봇 프로필·배포 범위·자격 증명 교체 주기를 분리해야 할 때는 별도 연결을 추가하면 됩니다.

## Identity Providers

IdP를 연동하면 조직 SSO 로그인을 제공하고 직원, 부서, 그룹 정보를 동기화할 수 있습니다. 엔터프라이즈 공급자는 Pod 관리자(`pod_admin`)가 **Pod Settings**에서 구성하며, 사이트 관리자도 **Console → Identity Providers**에서 관리할 수 있습니다. 두 화면 모두 `Ankole.Connectors` 연결 선택기(`authConfigId`)를 공유하므로 **Pod → Connections**에 등록된 연결을 선택하거나 현장에서 바로 생성할 수 있습니다. 패스워드리스 Email OTP 로그인은 Site Console의 사이트 SMTP 설정(`authn.email.*`)을 사용하며 발신 메일 서비스가 구성되면 로그인 화면에 활성화됩니다. Ankole은 사용자 비밀번호를 저장하지 않으므로, 초기 설정 시 첫 관리자 계정은 실제 이메일 인증 코드 확인 또는 조직 SSO 로그인을 완료해 생성합니다.

아래 표의 자격 증명 이름은 설정 폼의 필드 이름과 동일하며, 필요한 권한과 콜백 URL 및 검증 절차는 각 상세 가이드를 참조하세요.

| 플랫폼 | 외부 애플리케이션 | 주요 구성 | 상세 가이드 |
|---|---|---|---|
| Slack | 처음부터 생성한 Slack 앱 | Client ID 및 Client Secret; 디렉터리 동기화에는 Bot Token과 App Token도 필요 | [Slack IdP 가이드](../quickstart/?idp=slack#identity-providers) |
| Microsoft Entra ID | 단일 테넌트 앱 등록 | Tenant ID, Client ID, Client Secret, Microsoft Graph 권한 | [Entra ID 가이드](../quickstart/?idp=entra-id#identity-providers) |
| Google Workspace | OAuth 웹 클라이언트와 도메인 전체 위임 service account | OAuth 클라이언트, 허용 도메인, service account JSON, 위임된 관리자 이메일 | [Google Workspace 가이드](../quickstart/?idp=google-workspace#identity-providers) |
| Feishu / Lark | 엔터프라이즈 자체 구축 앱 또는 Custom App(`authConfigId`로 SSO·IM·MCP Toolkit·트리거 공유 가능) | App ID, App Secret, 서비스 지역, 애플리케이션 사용 가능 범위 | [Feishu / Lark IdP 가이드](../quickstart/?idp=lark#identity-providers) |
| DingTalk | 내부 엔터프라이즈 애플리케이션 | Client ID, Client Secret, Corp ID, 디렉터리 권한 | [DingTalk IdP 가이드](../quickstart/?idp=dingtalk#identity-providers) |
| WeCom | 선택적 연락처 동기화가 포함된 자체 구축 앱 | CorpID, AgentId, 애플리케이션 Secret, 연락처 동기화 Secret, 신뢰된 IP 주소 | [WeCom IdP 가이드](../quickstart/?idp=wecom#identity-providers) |

Provider를 구성한 뒤에는 콜백 URL을 직접 입력하지 말고 `/setup`에 표시된 값 그대로 복사해 등록하세요. 브라우저가 접속하는 HTTPS origin을 내부 컨테이너 주소로 바꾸면 로그인이 실패합니다. 로그인에 성공하면 전체 디렉터리 동기화를 한 번 실행하고 **Principals and permission groups**에서 사용자, 부서, 그룹이 정상적으로 반영되었는지 확인하세요.

## Channel Providers

채팅 어댑터는 사용자 메시지를 수신하고 Agent의 응답을 전송합니다. `Ankole.Connectors`를 지원하는 플랫폼(Feishu / Lark, Slack, Microsoft Teams 등)에서는 Signal Routing 규칙이 **Pod → Connections** / Console의 공유 애플리케이션 연결(`authConfigId`)을 그대로 재사용할 수도 있고, Agent마다 다른 봇 이름·배포 범위·교체 주기가 필요할 때 전용 연결을 사용할 수도 있습니다. Feishu / Lark 연결을 재사용하면 단일 자체 구축 앱으로 SSO, IM 라우팅, `lark-im` / `lark-approvals` / `lark-tasks` / `lark-calendar` MCP Toolkit, Connector 이벤트 구독까지 App ID와 App Secret 재입력 없이 함께 운영할 수 있습니다.

| 플랫폼 | 외부 애플리케이션 | 연결 방식과 주요 구성 | 상세 가이드 |
|---|---|---|---|
| Slack | Bot User가 있는 Slack 앱 | Socket Mode; 공유 연결(`authConfigId`) 또는 Bot Token, App Token, 이벤트, Bot 스코프 | [Slack 채널 가이드](../quickstart/?channel=slack#chat-channels) |
| Microsoft Teams | Entra 애플리케이션이 있는 Azure Bot | Bot Framework; 공유 연결(`authConfigId`) 또는 App ID, Client Secret, 테넌트, 메시징 endpoint | [Teams 채널 가이드](../quickstart/?channel=teams#chat-channels) |
| Feishu / Lark | 공유 또는 별도의 엔터프라이즈 자체 구축 앱 / Custom App | 장기 연결; 공유 연결(`authConfigId`) 또는 App ID, App Secret, 이벤트, 봇 권한 | [Feishu / Lark 채널 가이드](../quickstart/?channel=lark#chat-channels) |
| DingTalk | 봇이 있는 내부 엔터프라이즈 애플리케이션 | Stream 모드; Client ID 및 Client Secret, AI 카드는 선택 사항 | [DingTalk 채널 가이드](../quickstart/?channel=dingtalk#chat-channels) |
| WeCom | 슈퍼 관리자가 생성한 API 모드 AI 봇 | 장기 연결; Bot ID와 봇 Secret | [WeCom 채널 가이드](../quickstart/?channel=wecom#chat-channels) |
| Telegram | @BotFather로 생성한 봇 | Long polling; Bot token, 그룹 privacy mode 끄기 | [Telegram 채널 가이드](../quickstart/?channel=telegram#chat-channels) |
| Discord | Developer Portal에서 봇이 있는 애플리케이션 | Gateway WebSocket; Bot token, message content intent, 봇 권한 | [Discord 채널 가이드](../quickstart/?channel=discord#chat-channels) |
| LINE | Official Account의 Messaging API channel | Webhook; Channel ID, Channel secret, channel access token, webhook URL | [LINE 채널 가이드](../quickstart/?channel=line#chat-channels) |
| WhatsApp | WhatsApp 제품이 추가된 Meta App과 Business 전화번호 | Cloud API webhook; App ID, App secret, verify token, Phone number ID, System User token | [WhatsApp 채널 가이드](../quickstart/?channel=whatsapp#chat-channels) |
| Email | IMAP과 SMTP를 사용하는 전용 메일함 | IMAP과 SMTP 호스트와 포트, 로그인, 비밀번호, 발신자 인증 | [Email 채널 가이드](../quickstart/?channel=email#chat-channels) |

Telegram, Discord, LINE, WhatsApp은 일반 소비자용 메신저이므로 사용자에게 사내 직원 레코드가 없습니다. 따라서 새로운 발신자에게 Agent가 응답하려면 먼저 **아이덴티티 → 대기 중인 매핑**에서 해당 발신자를 계정에 연결해야 합니다. 다만 WhatsApp에서는 기존 계정에 해당 전화번호가 이미 등록되어 있으면 발신자가 자동으로 연결됩니다. 이메일 발신자는 명시적인 이메일 identity 바인딩이 등록되어 있어야만 식별되며, 직원 바인딩은 디렉터리 동기화 과정에서 생성되고 외부 발신자 바인딩은 관리자가 직접 생성합니다. 자세한 내용은 [Signal routing rules](../signal-bindings/)를 참조하세요.

외부 애플리케이션을 준비한 뒤 **Console → Signal Routing → New routing rule**을 열어 대상 Agent와 어댑터를 선택하고, 기존 연결(`authConfigId`)을 고르거나 새 자격 증명을 입력하세요. **Identity provider** 항목에서는 같은 플랫폼의 IdP를 연결합니다. 해당 플랫폼의 IdP가 하나뿐이면 기본으로 선택되고, 여러 개라면 직접 지정해야 하며, 독립(standalone) 옵션을 선택하면 바인딩 자체의 네임스페이스를 별도로 유지합니다. 이 설정을 통해 채팅 발신자와 디렉터리에서 동기화된 사용자가 동일한 계정으로 묶이므로, 반드시 채팅 애플리케이션과 같은 엔터프라이즈 조직에 속한 IdP만 선택하세요.

## 저장된 자격 증명 업데이트

**Pod → Connections**의 공유 연결이든 Console의 Identity Provider 및 Signal routing 규칙이든, 화면에는 암호화된 자격 증명의 저장 여부만 표시되며 원본 토큰이나 시크릿은 브라우저로 반환되지 않습니다. 기존 값을 그대로 유지하려면 자격 증명 입력란을 비워 두고, 교체할 때만 새 값을 입력해 저장하세요. 공유 연결(`authConfigId`)의 자격 증명을 갱신하면 시크릿 버전이 올라가면서 해당 연결을 참조하는 모든 Identity Provider, IM 채널, Connector Toolkit이 함께 재구성됩니다. 저장된 원문은 Ankole에서 조회할 수 없으므로 이전 자격 증명의 순환이나 폐기는 외부 플랫폼에서 직접 수행하세요.

## 검증 순서

1. 엔터프라이즈 IdP SSO 로그인 또는 패스워드리스 SMTP Email OTP 로그인을 테스트하고, 첫 번째 관리자가 `siteadmin` 및 `pod_admin` 권한으로 Pod 워크스페이스를 열고 `/site-admin-console`에서 Site Admin Console에 접근할 수 있는지 확인합니다.
2. 엔터프라이즈 IdP를 구성했다면 전체 디렉터리 동기화를 실행한 뒤 Principals and permission groups 목록을 확인합니다.
3. 채팅 라우팅 규칙을 생성하고(지원 플랫폼에서는 공유 연결 `authConfigId` 재사용 가능), 먼저 1:1 메시지(DM)나 명시적 멘션으로 동작을 테스트합니다.
4. Agent가 메시지를 정상 수신하고 답변을 보내는지 확인한 뒤, 그룹 대화 관찰·실시간 디렉터리 동기화·대화형 카드 또는 **Pod → Connections**의 Connector Toolkit 및 개인 OAuth 연동을 활성화합니다.

Provider 스코프, 애플리케이션 권한, 배포 범위를 변경한 경우 외부 플랫폼에서 요구하면 앱을 재설치하거나 다시 배포하세요. 자격 증명을 교체했다면 Ankole에 저장된 자격 증명도 함께 갱신해야 합니다.
