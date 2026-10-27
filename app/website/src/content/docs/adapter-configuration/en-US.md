---
title: Adapter configuration guide
description: Find the app type, credentials, permissions, and verification steps for each Ankole identity and chat adapter.
section: Getting started
order: 3
---

This page lists the enterprise identity and chat adapters included with Ankole. First, check whether your platform acts as an **Identity Provider (IdP)**, a **Channel Provider**, or both, and then open the matching guide below.

During first-run setup, the `/setup` page displays the exact login callback URL and a setup guide link for your chosen IdP. Pod administrators (`pod_admin`) manage enterprise identity providers for a tenant in **Pod Settings** (`/api/v2/pod/admin/identity-providers`), while site administrators manage identity providers in **Console → Identity Providers** alongside the site-level SMTP settings for passwordless Email OTP sign-in (`authn.email.*`). External chat applications connect to Agents under **Console → Signal Routing**.

## Identity Providers

An IdP authenticates members of your organization and can synchronize employees, departments, and groups. Pod administrators (`pod_admin`) configure enterprise identity providers in **Pod Settings**, and site administrators can also manage them in **Console → Identity Providers**. When site SMTP delivery (`authn.email.*`) is configured in the Site Console, Ankole also offers passwordless Email OTP sign-in. Because Ankole never stores user passwords, you create the first administrator during setup either by verifying a live email code or by completing enterprise SSO.

In the table below, the credential names match the fields in the Ankole configuration form. Follow the linked guides for required provider permissions, callback URLs, and verification steps.

| Platform | External application | Main configuration | Detailed guide |
|---|---|---|---|
| Slack | Slack app created from scratch | Client ID and Client Secret; directory sync also needs a Bot Token and App Token | [Slack IdP guide](../quickstart/?idp=slack#identity-providers) |
| Microsoft Entra ID | Single-tenant app registration | Tenant ID, Client ID, Client Secret, and Microsoft Graph permissions | [Entra ID guide](../quickstart/?idp=entra-id#identity-providers) |
| Google Workspace | OAuth web client and a service account with domain-wide delegation | OAuth client, allowed domains, service-account JSON, and delegated administrator email | [Google Workspace guide](../quickstart/?idp=google-workspace#identity-providers) |
| Feishu / Lark | Enterprise self-built app or Custom App | App ID, App Secret, service region, and application availability | [Feishu / Lark IdP guide](../quickstart/?idp=lark#identity-providers) |
| DingTalk | Internal enterprise application | Client ID, Client Secret, Corp ID, and directory permissions | [DingTalk IdP guide](../quickstart/?idp=dingtalk#identity-providers) |
| WeCom | Self-built app with optional contacts synchronization | CorpID, AgentId, application Secret, contacts-sync Secret, and trusted IP addresses | [WeCom IdP guide](../quickstart/?idp=wecom#identity-providers) |

After you configure the provider, copy and register the callback URL exactly as shown on `/setup`—do not type it by hand or replace the browser-facing HTTPS origin with an internal container address. Once sign-in succeeds, run a full directory sync and verify the imported users, departments, and groups under **Principals and permission groups**.

## Channel Providers

A chat adapter receives incoming messages and delivers Agent replies. In production, register separate external applications for identity and chat—even when one platform supports both—so that sign-in permissions, bot permissions, release scope, and credential rotation remain independent.

| Platform | External application | Connection and main configuration | Detailed guide |
|---|---|---|---|
| Slack | Slack app with a Bot User | Socket Mode; Bot Token, App Token, events, and Bot scopes | [Slack channel guide](../quickstart/?channel=slack#chat-channels) |
| Microsoft Teams | Azure Bot with its Entra application | Bot Framework; App ID, Client Secret, tenant, and messaging endpoint | [Teams channel guide](../quickstart/?channel=teams#chat-channels) |
| Feishu / Lark | Separate enterprise self-built app or Custom App | Long connection; App ID, App Secret, events, and bot permissions | [Feishu / Lark channel guide](../quickstart/?channel=lark#chat-channels) |
| DingTalk | Internal enterprise application with a bot | Stream mode; Client ID and Client Secret, with optional AI cards | [DingTalk channel guide](../quickstart/?channel=dingtalk#chat-channels) |
| WeCom | API-mode AI bot created by a super administrator | Long connection; Bot ID and bot Secret | [WeCom channel guide](../quickstart/?channel=wecom#chat-channels) |
| Telegram | Bot created with @BotFather | Long polling; Bot token, with group privacy mode off | [Telegram channel guide](../quickstart/?channel=telegram#chat-channels) |
| Discord | Application with a bot in the Developer Portal | Gateway WebSocket; Bot token, message content intent, and bot permissions | [Discord channel guide](../quickstart/?channel=discord#chat-channels) |
| LINE | Messaging API channel of an Official Account | Webhook; Channel ID, Channel secret, channel access token, and webhook URL | [LINE channel guide](../quickstart/?channel=line#chat-channels) |
| WhatsApp | Meta App with the WhatsApp product and a Business phone number | Cloud API webhook; App ID, App secret, verify token, Phone number ID, and System User token | [WhatsApp channel guide](../quickstart/?channel=whatsapp#chat-channels) |
| Email | A dedicated mailbox with IMAP and SMTP | IMAP and SMTP hosts and ports, login, password, and sender authentication | [Email channel guide](../quickstart/?channel=email#chat-channels) |

Because Telegram, Discord, LINE, and WhatsApp are consumer messaging platforms without an employee directory, an administrator maps each new sender to an account under **Identity → Pending mappings** before the Agent serves them. On WhatsApp, however, Ankole resolves the sender automatically when an existing account already owns that phone number. Email senders are recognized only through an explicit email identity binding, which directory sync creates automatically for employees and an administrator creates for everyone else. See [Signal routing rules](../signal-bindings/#choose-what-happens-to-unknown-senders).

Once the external application is ready, open **Console → Signal Routing → New routing rule**, select the target Agent and adapter, and enter the credentials. Use the **Identity provider** field to link the rule to an IdP on the same platform: if only one matching IdP exists, Ankole selects it by default; if multiple exist, choose the appropriate one; or choose the standalone option to keep sender identities in a dedicated namespace for this binding. Linking an IdP unifies chat senders and synced directory users under a single account, so only select an IdP that belongs to the same enterprise organization as the chat application.

## Update a stored credential

When you edit an Identity Provider or a signal routing rule, the Console shows whether an encrypted credential is stored without ever returning raw tokens or secrets to the browser. Leave a credential field blank to keep the stored value, or enter and save a new value when replacing it. Because stored secrets cannot be retrieved from the Console, rotate or revoke old credentials directly in the external provider.

## Verification order

1. Verify sign-in via enterprise IdP SSO or passwordless Email OTP over SMTP, and confirm that the first administrator opens the Pod workspace with `siteadmin` and `pod_admin` access and can access the Site Admin Console at `/site-admin-console`.
2. If you configured an enterprise IdP, run a full directory sync and inspect the resulting Principals and permission groups.
3. Create the chat routing rule and test it first with a direct message or an explicit mention.
4. Once you confirm that the Agent receives the message and replies, enable optional features such as group observation, real-time directory sync, or interactive cards.

Whenever you change provider scopes, application permissions, or release scope, reinstall or republish the application if the platform requires it, and update Ankole with each rotated credential.
