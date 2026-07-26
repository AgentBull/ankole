---
title: 用 Slack 作管理员登录
description: 把 Slack 配置为管理员 identity provider——OAuth client、团队边界、workspace directory 同步、身份面可复用的可选 bot token。
section: Guides
order: 323
---

本指南把 Console 管理员登录联合到一个 Slack workspace。读完，管理员用 Slack 账号登录 Ankole、workspace 成员同步进 AuthZ、且设置用的是聊天面用的同一个 Socket Mode 连接上的 Slack OIDC。它是 [Slack adapter](../adapters-slack/) 的身份面；本页是仅针对该面的运维 walkthrough，镜像 [Lark 管理员登录](../lark-admin-login/)。

先把决定性的性质说清楚：Slack 身份面承载与 Lark 和 Entra ID 相同的四能力——`oidc_authorization`、`oidc_code_exchange`、`directory_full_sync`、`directory_realtime_sync`。实时同步骑 Socket Mode 连接（聊天面用的同一个 `appToken`），无需公共入口。adapter 也拥有 Slack workspace 成员作为投影——Slack 是事实来源，成员变化随连接承载它们而传播。

## 在 Slack 里需要什么

一个 Slack 应用同时做聊天 binding 和身份面——与[你的第一个 Slack 机器人](../slack-first-bot/)里同一个应用。身份面增加：

- **一个 OAuth client**——应用的 `clientID` 和 `clientSecret`，来自 Slack API dashboard 的 *Basic Information*。它们与聊天面的 `botToken`/`appToken` 分开，尽管四者住在同一应用里。
- **OIDC 回调 URL**，加到应用的 *OAuth & Permissions* redirect URL 里。本地开发用 Ankole Console 回调；生产主机用真实 HTTPS origin。
- **OIDC scope**——`openid`、`email`、`profile`，以及 Slack 要求的身份 scope。adapter 的默认 scope 集覆盖标准登录；仅当需要额外 claim 时才扩展。
- **Directory 读取 scope**——workspace 成员读取权限（`users:read`、`users:read.email`、`team:read`），让 adapter 能投影 workspace 里都有谁。
- **Socket Mode 已启用**——实时同步用聊天面用的同一条 app-level WebSocket。没有 Socket Mode，就没有实时 directory 同步。

身份面可选地复用聊天面的 `botToken` 和 `appToken`——adapter 的身份配置接受它们，带同样的 `xoxb-`/`xapp-` 前缀规则。如果你的聊天 binding 已有它们，让身份面指向同一 token 意味着一条 Socket Mode 连接服务两者。

## 配置 identity provider

通过设置流程或 Console 创建 identity provider：

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/slack-main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "adapter_id": "slack",
    "clientID": "<oauth-client-id>",
    "clientSecret": "<oauth-client-secret>",
    "teamID": "<team-id>",
    "botToken": "<xoxb-bot-token>",
    "appToken": "<xapp-app-token>",
    "oidc": { "enabled": true },
    "sync": { "contacts": true }
  }'
```

adapter 校验的字段：

| 字段 | 必需 | 含义 |
|---|---|---|
| `clientID` | 是 | OAuth client id |
| `clientSecret` | 是 | OAuth client secret（静态加密） |
| `teamID` | 可选 | workspace team id；把登录限定到该 workspace |
| `botToken` | 可选 | 一个 `xoxb-` token，用于 directory 读取；若相同则复用聊天面的 |
| `appToken` | 可选 | 一个 `xapp-` token，用于 Socket Mode 实时同步 |
| `oidc.enabled` | 默认真 | OIDC 登录是否激活 |
| `oidc.scopes` | 默认集 | 要请求的 OIDC scope |
| `sync.contacts` | 默认真 | directory 同步是否运行 |

身份面上的 `botToken` 和 `appToken` 必须遵守与聊天面相同的前缀规则（`xoxb-` 和 `xapp-`），否则 adapter 以 `invalid_token_prefix` 拒绝。每个 pattern 加密。

## 登录流程

标准 Slack OIDC：重定向到 Slack 授权端点、换码、从 token 读用户身份。adapter 把用户解析为 Ankole Principal；第一个成功用户成为本部署的 root 管理员，激活码随之失效。

边界是 workspace。`teamID` 设了，就把登录限定到该 workspace——来自另一个 workspace 的 token 的用户无法鉴权。这是 Slack 等价于 Lark 的应用可用范围边界和 Google Workspace 的 `allowedDomains`。

## Directory 同步（全量 + 实时）

`sync.contacts` 开启时，adapter 把 Slack workspace 成员拉进 AuthZ group。两种形态：

- **全量同步**（`directory_full_sync`）按节奏通过 Slack API 读取 workspace 名册。
- **实时同步**（`directory_realtime_sync`）骑聊天面用的 Socket Mode 连接。Slack 里成员变化时，事件经同一条 `appToken` 打开的 WebSocket 到达——没有公共 webhook、没有 Graph 订阅。

adapter 拥有 Slack directory 成员投影：Slack 是事实来源，Ankole 的视图收敛到它。首次同步后，workspace group 和用户成员作为 Ankole AuthZ group 存在，你通过 [Principal 与 AuthZ](../principal-authz/) 向它们授予。

## 验证登录与同步

通过 Console 的 Slack 路径，用 workspace 成员登录。成功登录解析为 Ankole Principal。

然后验证同步：

- **全量同步**——首次运行后，检查 `/principal-groups` 看 workspace 的 group 和成员。
- **实时同步**——在 Slack 里邀请或移除一名成员，观察 `/principal-groups` 更新。若不更新，Socket Mode 可能未连接——确认应用的 Socket Mode 已启用、`appToken` 以 `xapp-` 开头。

## 出问题的时候

- **登录在重定向处失败**——应用的 redirect URL 不含 Ankole Console 回调，或 `clientID` 不匹配。
- **对有效 workspace 成员登录失败**——`teamID` 已设而用户在另一个 workspace，或 OIDC scope 未授予。
- **Directory 同步返回空**——directory 读取 scope（`users:read`、`team:read`）未授予，或 `botToken` 缺它们。
- **实时同步陈旧**——Socket Mode 未连接。确认应用 Socket Mode 已启用、`appToken` 存在且以 `xapp-` 开头、控制面有出站互联网。

## 与其它 IdP 指南的差异

- **vs Lark**——相同四能力和相同长连接实时模型。Lark 用飞书长连接 WebSocket；Slack 用 Socket Mode。两者都无需公共入口。
- **vs Entra ID**——Entra ID 实时用带 reconciler 和 `clientState` 的 Graph 订阅；Slack 用 Socket Mode，运行更简单。
- **vs Google Workspace**——Google Workspace 仅全量；Slack 两者都有。
- **vs 聊天 binding**——一个应用服务两者。身份面加 OAuth client 和 directory scope；聊天面加事件订阅和消息 scope。两个面用同一 token 时，可选的 `botToken`/`appToken` 共享。

## 本指南不是什么

它不是 Slack 应用配置教程——dashboard 会变，确切 scope 名由 Slack 文档。它不是把其他 workspace 的用户纳入的途径；workspace（可选地由 `teamID` 钉住）是边界。它也不与聊天面分离；一个应用服务两者，Socket Mode 连接共享。

## 下一步

- adapter 参考（两个面），读 [Slack adapter](../adapters-slack/) 专页。
- 同一应用的聊天面，读[你的第一个 Slack 机器人](../slack-first-bot/)。
- 已同步 group 所喂给的权限模型，读 [Principal 与 AuthZ](../principal-authz/)。
