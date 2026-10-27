---
title: 适配器配置指南
description: 按平台查找 Ankole 身份源和聊天渠道的应用类型、凭证、权限与验证步骤。
section: Getting started
order: 3
---

本页汇总 Ankole 内置的企业身份源与聊天渠道适配器。开始配置前，请先确认目标平台在系统中承担的是**身份源提供商（IdP）**、**聊天渠道**，还是两者兼有，再打开对应的平台指南按步骤完成接入。

首次初始化时，`/setup` 页面会根据所选 IdP 自动展示登录回调地址与完整配置指南入口。初始化完成后，Pod 管理员（`pod_admin`）可在 **Pod 设置**（`/api/v2/pod/admin/identity-providers`）中管理当前租户的企业身份源提供商；站点管理员也可在站点控制台的 **Console → 身份源提供商**中统一维护身份源，并配置站点级免密邮箱验证码（Email OTP）所需的 SMTP 参数（`authn.email.*`）。外部聊天应用则在 **Console → 信号路由**中绑定到目标 Agent。

## 身份源提供商

IdP 负责企业单点登录（SSO），并按各平台开放能力同步员工、部门或用户组；Ankole 自身不保存用户密码。Pod 管理员（`pod_admin`）可在 **Pod 设置**中配置本租户的企业身份源，站点管理员也可在 **Console → 身份源提供商**中维护。免密邮箱验证码（Email OTP）登录依赖站点控制台中配置的站点级 SMTP 参数（`authn.email.*`），配好发信服务后即自动启用。系统初始化期间，必须先实际完成一次邮箱验证码校验或企业 SSO 登录，才能创建首位管理员。下表中的凭证名称与配置表单保持一致，所需的具体权限、回调地址及验证步骤请参见各平台指南。

| 平台 | 需要创建的第三方应用 | 需要准备的主要配置 | 完整步骤 |
|---|---|---|---|
| Slack | From scratch Slack app | Client ID、Client Secret；同步通讯录时还需要 Bot Token 和 App Token | [Slack IdP 指南](../quickstart/?idp=slack#identity-providers) |
| Microsoft Entra ID | 单租户应用注册 | Tenant ID、Client ID、Client Secret、Microsoft Graph 权限 | [Entra ID 指南](../quickstart/?idp=entra-id#identity-providers) |
| Google Workspace | OAuth Web Client 和启用全网域授权的服务账号 | OAuth Client、允许登录的域名、服务账号 JSON、委派管理员邮箱 | [Google Workspace 指南](../quickstart/?idp=google-workspace#identity-providers) |
| 飞书 / Lark | 企业自建应用或 Custom App | App ID、App Secret、服务区域和应用可用范围 | [飞书 / Lark IdP 指南](../quickstart/?idp=lark#identity-providers) |
| 钉钉 | 企业内部应用 | Client ID、Client Secret、Corp ID 和通讯录权限 | [钉钉 IdP 指南](../quickstart/?idp=dingtalk#identity-providers) |
| 企业微信 | 自建应用，并按需启用通讯录同步 | CorpID、AgentId、应用 Secret、通讯录同步 Secret 和可信 IP | [企业微信 IdP 指南](../quickstart/?idp=wecom#identity-providers) |

在第三方管理后台填写回调地址时，请直接复制 `/setup` 页面显示的完整地址，切勿手写拼接，也不要用容器内部地址替代浏览器实际访问的 HTTPS 地址。首次登录成功后，先执行一次全量同步，再前往**主体和权限组**页面核对同步进来的人员、部门或用户组。

## 聊天渠道

聊天适配器负责接收外部渠道消息并回传 Agent 回复。生产环境中，建议将 IdP 登录应用与聊天机器人应用分开创建，避免单点登录权限、机器人权限、可见范围与密钥轮换互相牵连。

| 平台 | 需要创建的第三方应用 | 连接方式与主要配置 | 完整步骤 |
|---|---|---|---|
| Slack | Slack app 和 Bot User | Socket Mode；Bot Token、App Token、事件与 Bot scopes | [Slack 聊天指南](../quickstart/?channel=slack#chat-channels) |
| Microsoft Teams | Azure Bot 和对应的 Entra 应用 | Bot Framework；App ID、Client Secret、Tenant 与消息端点 | [Teams 聊天指南](../quickstart/?channel=teams#chat-channels) |
| 飞书 / Lark | 独立的企业自建应用或 Custom App | 长连接；App ID、App Secret、事件与机器人权限 | [飞书 / Lark 聊天指南](../quickstart/?channel=lark#chat-channels) |
| 钉钉 | 企业内部应用和机器人 | Stream 模式；Client ID、Client Secret，AI 卡片可选 | [钉钉聊天指南](../quickstart/?channel=dingtalk#chat-channels) |
| 企业微信 | 由超级管理员创建的 API 模式智能机器人 | 长连接；Bot ID 和机器人 Secret | [企业微信聊天指南](../quickstart/?channel=wecom#chat-channels) |
| Telegram | 用 @BotFather 创建的机器人 | 长轮询；Bot token，并关闭群组隐私模式 | [Telegram 聊天指南](../quickstart/?channel=telegram#chat-channels) |
| Discord | Developer Portal 中带机器人的应用 | Gateway WebSocket；Bot token、消息内容 intent 和机器人权限 | [Discord 聊天指南](../quickstart/?channel=discord#chat-channels) |
| LINE | Official Account 的 Messaging API channel | Webhook；Channel ID、Channel secret、channel access token 和 webhook URL | [LINE 聊天指南](../quickstart/?channel=line#chat-channels) |
| WhatsApp | 添加了 WhatsApp 产品的 Meta App 和一个 Business 手机号 | Cloud API webhook；App ID、App secret、verify token、Phone number ID 和 System User token | [WhatsApp 聊天指南](../quickstart/?channel=whatsapp#chat-channels) |
| Email | 一个支持 IMAP 和 SMTP 的专用邮箱 | IMAP 和 SMTP 的主机与端口、登录名、密码和发信人认证 | [Email 聊天指南](../quickstart/?channel=email#chat-channels) |

Telegram、Discord、LINE 和 WhatsApp 属于消费级即时通讯平台，发信人本身没有企业员工档案。陌生用户首次发来消息后，管理员需先在**身份 → 待绑定账号**中将其关联到系统账号，Agent 才会为其提供服务；不过在 WhatsApp 渠道中，若某个已知账号已登记相同手机号，系统会自动完成账号关联。邮件渠道则完全通过显式的邮箱身份绑定来识别发信人：企业员工邮箱由通讯录同步自动建立绑定，外部人员邮箱需由管理员手动添加绑定。详见 [信号路由规则](../signal-bindings/)。

第三方应用准备就绪后，打开 **Console → 信号路由 → 新增路由规则**，选择目标 Agent 与渠道适配器并填入凭证。表单中的**身份源提供商**字段用于关联同一平台的 IdP：当前若只有一个同平台 IdP 会默认选中，若有多个则需手动指定；若选择「不关联」，该路由规则将使用独立的身份命名空间。关联 IdP 后，系统才能将聊天发信人与通讯录同步进来的员工识别为同一个账号，因此所选 IdP 必须与该聊天应用归属同一个企业组织。

## 更新已保存的凭证

重新编辑身份源或信号路由配置时，Console 仅提示某项加密凭证已保存，绝不会将明文 Token 或 Secret 回传给浏览器或渲染到页面中。保存表单时，凭证输入框留空代表沿用现有密钥；只有输入新值并提交，才会覆盖服务端加密存储的旧值。如需核对或作废旧凭证，请直接前往第三方平台轮换或吊销，无法通过 Console 查看原值。

## 验证顺序

1. 验证企业 IdP SSO 登录或免密 SMTP 邮箱验证码（Email OTP）登录，确认首位管理员成功获得 `siteadmin` 与 `pod_admin` 权限进入 Pod 工作区，且能正常打开 `/site-admin-console` 站点管理控制台。
2. 若已接入企业 IdP，执行一次通讯录全量同步，检查人员主体与权限组是否正确生成。
3. 创建聊天渠道的信号路由规则，先通过单人私聊或在群内明确 `@Agent` 发送测试消息。
4. 确认 Agent 能收到消息并正常回复后，再逐步开启群消息旁路观察、实时通讯录同步或交互卡片等进阶功能。

后续如果在第三方平台调整了权限范围（scope）、应用权限或可用范围，请按平台要求重新发布或安装应用；若同时轮换了密钥凭证，请及时同步更新到 Ankole。
