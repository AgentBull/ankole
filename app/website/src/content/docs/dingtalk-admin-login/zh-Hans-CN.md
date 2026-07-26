---
title: 用钉钉作管理员登录
description: 把钉钉配置为管理员 identity provider——同一个机器人的凭证、带 corpid scope 的 OIDC、经 Stream WebSocket 的组织结构 directory 同步、本 adapter 独有的 credential-check 能力。
section: Guides
order: 324
---

本指南把 Console 管理员登录联合到钉钉。读完，管理员用钉钉工作账号登录 Ankole、组织结构（部门与用户）同步进 AuthZ、且设置复用你的聊天机器人用的同一个 `clientId`/`clientSecret`。它是[钉钉 adapter](../adapters-dingtalk/) 的身份面；本页是仅针对该面的运维 walkthrough，镜像 [Lark](../lark-admin-login/) 和 [Slack](../slack-admin-login/) 管理员登录。

先把决定性的性质说清楚：钉钉身份面承载五项能力——与其它聊天平台 IdP 相同的四项（`oidc_authorization`、`oidc_code_exchange`、`directory_full_sync`、`directory_realtime_sync`），加上本 adapter 独有的 `credential_check`。实时同步骑 Stream WebSocket（聊天面用的同一个 `clientId`/`clientSecret`），无需公共入口。而且一对凭证做所有事——聊天、OIDC、directory——这就是钉钉是聊天平台里配置最简单的 IdP 的原因。

## 在钉钉里需要什么

一个企业内部机器人同时做聊天 binding 和身份面——与[你的第一个钉钉机器人](../dingtalk-first-bot/)里同一个 `clientId`/`clientSecret`。身份面在钉钉侧增加：

- **OIDC 回调 URL**，在机器人的开发者后台配置，指向 Ankole Console 回调。钉钉精确匹配。
- **登录与 directory scope**，授予机器人——OIDC scope（默认 `openid corpid`）和 directory 同步所需的 contact/department 读取权限。
- **已发布的机器人版本**，包含回调 URL、scope、测试用户可用范围。未发布的设置不生效。

没有第二个 OAuth client、没有 service account、没有单独 bot token——同一对凭证兼任 Stream 凭证、也鉴权 OIDC 和读取 directory。这是钉钉区别于 Lark（单独 `appID`/`appSecret`）和 Slack（单独 `clientID`/`clientSecret`）的单一凭证设计。

## 配置 identity provider

通过设置流程或 Console 创建 identity provider：

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/dingtalk-main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "adapter_id": "dingtalk",
    "clientId": "<app-key>",
    "clientSecret": "<app-secret>",
    "oidc": { "enabled": true, "scope": "openid corpid" },
    "sync": { "contacts": true, "websocket": true, "pageSize": 50 }
  }'
```

adapter 校验的字段：

| 字段 | 必需 | 含义 |
|---|---|---|
| `clientId` | 是 | 机器人的 AppKey——与聊天面相同 |
| `clientSecret` | 是 | 机器人的 AppSecret（静态加密） |
| `oidc.enabled` | 默认真 | OIDC 登录是否激活 |
| `oidc.scope` | 默认 `openid corpid` | 要请求的 OIDC scope |
| `sync.contacts` | 默认真 | directory 同步是否运行 |
| `sync.websocket` | 默认真 | 实时同步是否用 Stream WebSocket |
| `sync.pageSize` | 默认 50 | directory 页大小（1–100） |

每个 pattern 加密；`clientSecret` 是 secret 材料。这里的 `clientId`/`clientSecret` 与聊天 binding 用的是同一个值——一个机器人、一对凭证、两个面。

## 登录流程

钉钉 OIDC：重定向到钉钉授权端点、换码、读用户身份。`openid corpid` 的 `oidc.scope` 带着用户的 open id 和它的 corporation id——`corpid` 把用户系到你的钉钉组织，这也是该 scope 存在的原因。adapter 把用户解析为 Ankole Principal；第一个成功用户成为本部署的 root 管理员，激活码随之失效。

边界是钉钉组织（`corpid`）。来自另一个钉钉组织用户不共享你的 `corpid`，无法鉴权。这是钉钉等价于 Lark 的应用可用范围和 Slack 的 `teamID`。

## `credential_check` 能力

钉钉身份面在标准四能力之外声明 `credential_check`。这是 adapter 在依赖 `clientId`/`clientSecret` 之前先向钉钉验证这对凭证的能力——一次预检，在配置时而非首次登录尝试时捕获错误凭证对。它为本 adapter 独有；其它 IdP 在登录或同步失败时才发现坏凭证。

## Directory 同步（全量 + 实时）

`sync.contacts` 开启时，adapter 把钉钉组织结构——部门与用户——拉进 AuthZ group。两种形态：

- **全量同步**（`directory_full_sync`）按节奏通过钉钉 API 读取 directory，每次按 `sync.pageSize`（1–100，默认 50）分页。
- **实时同步**（`directory_realtime_sync`）骑聊天面用的 Stream WebSocket。钉钉里部门或用户变化时，事件经同一连接到达——没有公共 webhook、没有 Graph 订阅、没有第二个入口。

首次同步后，钉钉部门和用户成员作为 Ankole AuthZ group 存在。通过 [Principal 与 AuthZ](../principal-authz/) 向它们授予——"这个钉钉部门里的每个人可以管理这些 agent"是一条真实的 grant，钉钉为事实来源。

## 验证登录与同步

通过 Console 的钉钉路径，用组织里的用户登录。成功登录解析为 Ankole Principal。

然后验证同步：

- **全量同步**——首次运行后，检查 `/principal-groups` 看钉钉部门和成员。
- **实时同步**——在钉钉组织结构里加或移动一个用户，观察 `/principal-groups` 更新。若不更新，Stream 连接可能未建立——确认机器人已启用、`clientId`/`clientSecret` 有效。

## 出问题的时候

- **登录在重定向处失败**——机器人的回调 URL 与 Ankole Console 回调不匹配。钉钉精确匹配。
- **对有效用户登录失败**——用户在另一个钉钉组织（不同 `corpid`），或机器人版本未发布。
- **配置时 `credential_check` 失败**——`clientId`/`clientSecret` 对错。这是预检早捕获；继续之前改正凭证。
- **Directory 同步返回空**——contact/department 读取 scope 未授予，或 `clientId` 缺它们。钉钉按凭证集合缓存 app token；刚轮换的 `clientSecret` 可能需要一个刷新周期。
- **实时同步陈旧**——Stream 连接未建立。确认机器人已启用、控制面有出站互联网。

## 与其它 IdP 指南的差异

- **vs Lark**——相同长连接实时模型。Lark 用飞书 WebSocket；钉钉用 Stream API。钉钉加 `credential_check` 和单一凭证设计；Lark 用单独 `appID`/`appSecret`。
- **vs Slack**——相同 Socket-Mode 风格实时。Slack 身份面加单独 OAuth client；钉钉复用机器人的 `clientId`/`clientSecret`。
- **vs Entra ID**——Entra ID 实时用带 reconciler 的 Graph 订阅；钉钉用 Stream WebSocket，更简单。
- **vs Google Workspace**——Google Workspace 仅全量；钉钉两者都有。
- **vs 聊天 binding**——一个机器人服务两者，一对凭证。身份面加回调 URL 和 directory scope；聊天面加事件订阅和卡片模板。

## 本指南不是什么

它不是钉钉开发者后台教程——后台会变，确切 scope 名由钉钉文档。它不是把其他钉钉组织的用户纳入的途径；`corpid` 是边界。它也不与聊天面分离；一个机器人、一对凭证、两个面。

## 下一步

- adapter 参考（两个面），读[钉钉 adapter](../adapters-dingtalk/) 专页。
- 同一机器人的聊天面，读[你的第一个钉钉机器人](../dingtalk-first-bot/)。
- 已同步 group 所喂给的权限模型，读 [Principal 与 AuthZ](../principal-authz/)。
