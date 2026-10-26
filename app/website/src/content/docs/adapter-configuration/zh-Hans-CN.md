---
title: 适配器配置指南
description: 按平台查找 Ankole 身份源和聊天渠道的应用类型、凭证、权限与验证步骤。
section: Getting started
order: 3
---

本页汇总 Ankole 当前内置的企业身份和聊天适配器。先确定平台承担的是**身份源提供商（IdP）**、**聊天渠道**，还是两者，然后打开对应的完整步骤。

首次初始化时，`/setup` 会根据当前选择的 IdP 显示登录回调地址和完整配置指南入口。Pod 管理员（`pod_admin`）在 **Pod 设置**（`/api/v2/pod/admin/identity-providers`）中管理当前租户的企业身份源提供商；站点管理员也可在站点控制台的 **Console → 身份源提供商**中管理身份源，并在站点控制台中配置站点级免密邮箱验证码（Email OTP）的 SMTP 参数（`authn.email.*`）。外部聊天应用在 **Console → 信号路由**中绑定到 Agent。

## 身份源提供商

IdP 提供企业登录，并按平台能力同步员工、部门或用户组。Pod 管理员（`pod_admin`）在 **Pod 设置**中配置本租户的企业身份源，站点管理员也可在 **Console → 身份源提供商**中维护。免密邮箱验证码（Email OTP）登录使用站点控制台中配置的站点级 SMTP 参数（`authn.email.*`），配置发信服务后即启用。初始化时，实际验证一次邮箱验证码或完成企业 SSO 后，才能创建首位管理员。Ankole 不保存用户密码。表中的凭证名称与表单一致；具体权限、回调地址与验证步骤见链接中的指南。

| 平台 | 需要创建的第三方应用 | 需要准备的主要配置 | 完整步骤 |
|---|---|---|---|
| Slack | From scratch Slack app | Client ID、Client Secret；同步通讯录时还需要 Bot Token 和 App Token | [Slack IdP 指南](../quickstart/?idp=slack#identity-providers) |
| Microsoft Entra ID | 单租户应用注册 | Tenant ID、Client ID、Client Secret、Microsoft Graph 权限 | [Entra ID 指南](../quickstart/?idp=entra-id#identity-providers) |
| Google Workspace | OAuth Web Client 和启用全网域授权的服务账号 | OAuth Client、允许登录的域名、服务账号 JSON、委派管理员邮箱 | [Google Workspace 指南](../quickstart/?idp=google-workspace#identity-providers) |
| 飞书 / Lark | 企业自建应用或 Custom App | App ID、App Secret、服务区域和应用可用范围 | [飞书 / Lark IdP 指南](../quickstart/?idp=lark#identity-providers) |
| 钉钉 | 企业内部应用 | Client ID、Client Secret、Corp ID 和通讯录权限 | [钉钉 IdP 指南](../quickstart/?idp=dingtalk#identity-providers) |
| 企业微信 | 自建应用，并按需启用通讯录同步 | CorpID、AgentId、应用 Secret、通讯录同步 Secret 和可信 IP | [企业微信 IdP 指南](../quickstart/?idp=wecom#identity-providers) |

完成第三方后台配置后，把 `/setup` 显示的回调地址原样登记。不要手写地址，也不要用容器内地址替代浏览器实际访问的 HTTPS origin。登录成功后运行一次全量同步，并在**主体和权限组**中检查人员、部门或用户组。

## 聊天渠道

聊天适配器负责接收消息并发送 Agent 回复。正式使用时，建议把 IdP 应用和聊天应用分开创建，这样登录权限、机器人权限、发布范围和凭证轮换不会互相影响。

| 平台 | 需要创建的第三方应用 | 连接方式与主要配置 | 完整步骤 |
|---|---|---|---|
| Slack | Slack app 和 Bot User | Socket Mode；Bot Token、App Token、事件与 Bot scopes | [Slack 聊天指南](../quickstart/?channel=slack#chat-channels) |
| Microsoft Teams | Azure Bot 和对应的 Entra 应用 | Bot Framework；App ID、Client Secret、Tenant 与消息 endpoint | [Teams 聊天指南](../quickstart/?channel=teams#chat-channels) |
| 飞书 / Lark | 独立的企业自建应用或 Custom App | 长连接；App ID、App Secret、事件与机器人权限 | [飞书 / Lark 聊天指南](../quickstart/?channel=lark#chat-channels) |
| 钉钉 | 企业内部应用和机器人 | Stream 模式；Client ID、Client Secret，AI 卡片可选 | [钉钉聊天指南](../quickstart/?channel=dingtalk#chat-channels) |
| 企业微信 | 由超级管理员创建的 API 模式智能机器人 | 长连接；Bot ID 和机器人 Secret | [企业微信聊天指南](../quickstart/?channel=wecom#chat-channels) |
| Telegram | 用 @BotFather 创建的机器人 | 长轮询；Bot token，并关闭群组隐私模式 | [Telegram 聊天指南](../quickstart/?channel=telegram#chat-channels) |
| Discord | Developer Portal 中带机器人的应用 | Gateway WebSocket；Bot token、消息内容 intent 和机器人权限 | [Discord 聊天指南](../quickstart/?channel=discord#chat-channels) |
| LINE | Official Account 的 Messaging API channel | Webhook；Channel ID、Channel secret、channel access token 和 webhook URL | [LINE 聊天指南](../quickstart/?channel=line#chat-channels) |
| WhatsApp | 添加了 WhatsApp 产品的 Meta App 和一个 Business 手机号 | Cloud API webhook；App ID、App secret、verify token、Phone number ID 和 System User token | [WhatsApp 聊天指南](../quickstart/?channel=whatsapp#chat-channels) |
| Email | 一个支持 IMAP 和 SMTP 的专用邮箱 | IMAP 和 SMTP 的主机与端口、登录名、密码和发信人认证 | [Email 聊天指南](../quickstart/?channel=email#chat-channels) |

Telegram、Discord、LINE 和 WhatsApp 是消费级 IM。它们的用户没有员工记录，新发信人需要先在**身份 → 待绑定账号**中映射到账号，Agent 才会为其服务；如果某个已知账号已拥有该手机号，WhatsApp 会自行完成映射。邮件发信人只能通过显式的邮箱身份绑定被识别：员工的绑定由通讯录同步创建，其他人的绑定由管理员创建。见 [信号路由规则](../signal-bindings/)。

第三方应用准备好后，在 **Console → 信号路由 → 新增路由规则**中选择目标 Agent 和适配器，并填写凭证。**身份源提供商**字段引用同一平台的 IdP：只有一个 IdP 时默认采用，有多个时必须选择，「不关联」选项让绑定保留自己的命名空间。该引用让聊天发信人和通讯录同步的用户成为同一个账号，所以只能选择与聊天应用属于同一个企业组织的 IdP。

## 更新已保存的凭证

编辑身份源或信号路由时，Console 只会说明某个加密凭证已经保存，不会把真实 Token 或 Secret 返回浏览器或写入页面。凭证字段留空表示继续使用现有值；只有输入新值并保存，才会替换服务器中的加密值。需要确认或撤销旧凭证时，请在第三方平台轮换或撤销它，不能通过 Console 查看原值。

## 验证顺序

1. 验证企业 IdP SSO 登录或免密 SMTP 邮箱验证码（Email OTP）登录，确认首位管理员以 `siteadmin` 和 `pod_admin` 身份进入 Pod 工作区，并可打开 `/site-admin-console` 站点管理控制台。
2. 配置了企业 IdP 时，运行通讯录全量同步，检查主体和权限组。
3. 创建聊天路由规则，先用私聊或明确 @ Agent 的消息测试。
4. 确认 Agent 收到消息并成功回复，再启用群消息观察、实时目录同步或卡片等高级能力。

如果第三方平台修改了 scope、应用权限或发布范围，请按该平台要求重新安装或发布应用，并把轮换后的凭证同步更新到 Ankole。
