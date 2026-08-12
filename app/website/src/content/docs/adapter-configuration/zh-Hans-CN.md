---
title: 适配器配置指南
description: 按平台查找 Ankole 身份源和聊天渠道的应用类型、凭证、权限与验证步骤。
section: Getting started
order: 3
---

本页汇总 Ankole 当前内置的企业身份和聊天适配器。先确定平台承担的是**身份源提供商（IdP）**、**聊天渠道**，还是两者，然后打开对应的完整步骤。

首次初始化时，`/setup` 会根据当前选择的 IdP 显示登录回调地址和完整配置指南入口。初始化完成后，身份配置在 **Console → 身份源提供商**中维护，聊天应用在 **Console → 信号路由**中绑定到 Agent。

## 身份源提供商

IdP 负责 Console 登录，并按平台能力同步员工、部门或用户组。表中的凭证名称与 Ankole 表单一致；具体权限、第三方后台路径和验证步骤以链接中的指南为准。

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

第三方应用准备好后，在 **Console → 信号路由 → 新增路由规则**中选择目标 Agent 和适配器，并填写凭证。同一平台的 IdP 与聊天应用属于同一个企业组织时，两处使用相同的 `platformSubjectNamespace`；不同组织不能共用命名空间。

## 更新已保存的凭证

编辑身份源或信号路由时，Console 只会说明某个加密凭证已经保存，不会把真实 Token 或 Secret 返回浏览器或写入页面。凭证字段留空表示继续使用现有值；只有输入新值并保存，才会替换服务器中的加密值。需要确认或撤销旧凭证时，请在第三方平台轮换或撤销它，不能通过 Console 查看原值。

## 验证顺序

1. 先验证 IdP 登录，并确认首位管理员可以进入 Console。
2. 运行通讯录全量同步，检查人员和权限组。
3. 创建聊天路由规则，先用私聊或明确 @ Agent 的消息测试。
4. 确认 Agent 收到消息并成功回复，再启用群消息观察、实时目录同步或卡片等高级能力。

如果第三方平台修改了 scope、应用权限或发布范围，请按该平台要求重新安装或发布应用，并把轮换后的凭证同步更新到 Ankole。
