---
title: Adapter configuration guide
description: Find the app type, credentials, permissions, and verification steps for each Ankole identity and chat adapter.
section: Getting started
order: 3
---

This page lists the enterprise identity and chat adapters that Ankole includes. First decide whether a platform supplies an **Identity Provider (IdP)**, a **Channel Provider**, or both. Then open the applicable detailed guide.

During first-run setup, `/setup` shows the login callback URL and a guide link for the selected IdP. After setup, manage identity settings under **Console → Identity Providers**. Bind chat applications to Agents under **Console → Signal Routing**.

## Identity Providers

An IdP supplies Console sign-in. It can also synchronize employees, departments, or groups when the platform supports this function. The credential names below match the Ankole form. Use the linked guide for the exact permissions, provider-console paths, and verification steps.

| Platform | External application | Main configuration | Detailed guide |
|---|---|---|---|
| Slack | Slack app created from scratch | Client ID and Client Secret; directory sync also needs a Bot Token and App Token | [Slack IdP guide](../quickstart/?idp=slack#identity-providers) |
| Microsoft Entra ID | Single-tenant app registration | Tenant ID, Client ID, Client Secret, and Microsoft Graph permissions | [Entra ID guide](../quickstart/?idp=entra-id#identity-providers) |
| Google Workspace | OAuth web client and a service account with domain-wide delegation | OAuth client, allowed domains, service-account JSON, and delegated administrator email | [Google Workspace guide](../quickstart/?idp=google-workspace#identity-providers) |
| Feishu / Lark | Enterprise self-built app or Custom App | App ID, App Secret, service region, and application availability | [Feishu / Lark IdP guide](../quickstart/?idp=lark#identity-providers) |
| DingTalk | Internal enterprise application | Client ID, Client Secret, Corp ID, and directory permissions | [DingTalk IdP guide](../quickstart/?idp=dingtalk#identity-providers) |
| WeCom | Self-built app with optional contacts synchronization | CorpID, AgentId, application Secret, contacts-sync Secret, and trusted IP addresses | [WeCom IdP guide](../quickstart/?idp=wecom#identity-providers) |

After you configure the provider, register the callback URL exactly as `/setup` shows it. Do not type it manually. Do not replace the browser-facing HTTPS origin with an internal container address. After sign-in succeeds, run one full directory sync and check the users, departments, or groups under **Principals and permission groups**.

## Channel Providers

A chat adapter receives messages and sends Agent replies. For production use, create separate applications for identity and chat, even when one platform supplies both. This separation keeps sign-in permissions, bot permissions, release scope, and credential rotation independent.

| Platform | External application | Connection and main configuration | Detailed guide |
|---|---|---|---|
| Slack | Slack app with a Bot User | Socket Mode; Bot Token, App Token, events, and Bot scopes | [Slack channel guide](../quickstart/?channel=slack#chat-channels) |
| Microsoft Teams | Azure Bot with its Entra application | Bot Framework; App ID, Client Secret, tenant, and messaging endpoint | [Teams channel guide](../quickstart/?channel=teams#chat-channels) |
| Feishu / Lark | Separate enterprise self-built app or Custom App | Long connection; App ID, App Secret, events, and bot permissions | [Feishu / Lark channel guide](../quickstart/?channel=lark#chat-channels) |
| DingTalk | Internal enterprise application with a bot | Stream mode; Client ID and Client Secret, with optional AI cards | [DingTalk channel guide](../quickstart/?channel=dingtalk#chat-channels) |
| WeCom | API-mode AI bot created by a super administrator | Long connection; Bot ID and bot Secret | [WeCom channel guide](../quickstart/?channel=wecom#chat-channels) |

After you prepare the external application, open **Console → Signal Routing → New routing rule**. Select the Agent and adapter, and enter the credentials. Use the same `platformSubjectNamespace` for the IdP and chat application only when both applications belong to the same enterprise organization. Do not share a namespace across organizations.

## Verification order

1. Verify IdP sign-in and confirm that the first administrator can open the Console.
2. Run a full directory sync and check the Principals and permission groups.
3. Create the chat routing rule. Test it first with a direct message or an explicit mention.
4. Confirm that the Agent receives the message and sends a reply. Then enable advanced functions such as group observation, real-time directory sync, or cards.

If you change provider scopes, application permissions, or release scope, reinstall or republish the application when the provider requires this action. Update Ankole with each rotated credential.
