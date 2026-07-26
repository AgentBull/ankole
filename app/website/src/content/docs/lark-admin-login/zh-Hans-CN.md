---
title: 用 Lark 或飞书作管理员登录
description: 把 Lark 或飞书配置为管理员 identity provider——自建应用的 OIDC、经长连接的 IM 群 directory 同步、设置所依赖的回调 URL 精确匹配。
section: Guides
order: 322
---

本指南把 Console 管理员登录联合到 Lark 或飞书。读完，管理员用 Lark 账号登录 Ankole、directory group（IM 群与组织结构）同步进 AuthZ、且设置用的是你的聊天机器人用的同一个自建应用。它是 [Lark adapter](../adapters-lark/) 的身份面；本页是仅针对该面的运维 walkthrough。

先把决定性的性质说清楚：Lark 的身份面承载与 Entra ID 面相同的四项能力——`oidc_authorization`、`oidc_code_exchange`、`directory_full_sync`、`directory_realtime_sync`。实时同步跑在 Lark 长连接 WebSocket 上，不是 Graph 订阅，所以无需公共入口——聊天面用的同一条出站连接也承载 directory 变更。这就是 Lark 作 IdP 是三个实时同步 adapter 里运行最简单的那个的原因。

## 在 Lark 里需要什么

一个企业自建应用同时做聊天 binding 和身份面——与你在[你的第一个 Lark 机器人](../lark-first-bot/)里用的同一个 `appID`/`appSecret`。身份面在其上还需要：

- **OIDC 回调 URL**，加到应用的安全设置里。本地开发用 `http://localhost:4000/sessions/oidc/lark-main/callback`。生产主机用真实 HTTPS origin。Lark 要求请求的 `redirect_uri` 与白名单精确匹配——而 `localhost` 和 `127.0.0.1` 是不同的 redirect URI，除非你也更新白名单条目，否则用文档约定的形态。
- **Directory 与登录 scope**，通过飞书的批量导入或权限页授予：`auth:user_access_token:read`、`contact:contact.base:readonly`、`contact:department.base:readonly`、`contact:department.organize:readonly`、`contact:user.base:readonly`、`contact:user.department:readonly`、`contact:user.email:readonly`。这些让 adapter 读用户是谁、属于哪些群和部门。
- **已发布的应用版本。** 未发布的设置对测试用户不生效；在登录前发布一个包含回调 URL、scope 和测试用户可用范围的版本。

## 配置 identity provider

通过设置流程（首次设置）或 Console 创建 identity provider：

| 字段 | 值 |
|---|---|
| Provider ID | `lark-main` |
| Domain | Feishu（国际域名用 Lark） |
| App ID | 自建应用的 App ID |
| App Secret | 自建应用的 App Secret |
| OIDC | 启用 |
| Directory sync | 启用 |
| WebSocket 增量同步 | 启用 |

在浏览器里输入 App Secret——coding agent 永远不应请求、读取、重复或存储它。选择保存 provider 并用 OIDC 登录的动作。人完成飞书授权后，第一个成功用户成为本部署的 root 管理员，激活码随之失效。

保存 provider 还会从控制面建立出站 WebSocket 长连接——需要互联网访问，但不需要公网 IP、反向代理或隧道。这是聊天面用的同一条连接；每个应用一个 owner。

## 登录流程

标准 Lark OIDC：重定向到飞书授权端点、用返回的 code 换取 user access token、读取用户身份。adapter 把用户解析为 Ankole Principal。没有 `allowedDomains` 边界要配——边界是应用的可用范围（应用发布给哪些用户），设在飞书开发者后台，不在 Ankole 里。不在应用范围内的用户无法鉴权。

## Directory 同步（全量 + 实时）

启用 directory 同步后，adapter 把飞书的 directory——IM 群、部门、用户——拉进 AuthZ group。两种同步形态：

- **全量同步**（`directory_full_sync`）按节奏通过飞书 API 读取 directory，把 Ankole 的视图收敛到飞书的事实。
- **实时同步**（`directory_realtime_sync`）骑在长连接 WebSocket 上。飞书里某个群或部门变化时，事件经聊天面用的同一条连接到达——没有公共 webhook、没有 Graph 订阅、没有第二个入口。`sync_im_groups` 和 `refresh_im_group` 任务让镜像保持当前。

首次同步后，飞书 IM 群作为 Ankole AuthZ group 存在。通过 [Principal 与 AuthZ](../principal-authz/) 向它们授予——"这个飞书 IM 群里的每个人可以管理这些 agent"是一条真实的 grant，飞书为事实来源。

## 验证登录与同步

通过 Console 的 Lark 路径，用应用可用范围内的用户登录。成功登录解析为 Ankole Principal。

然后验证同步：

- **全量同步**——首次运行后，检查 `/principal-groups` 看飞书 IM 群和部门。
- **实时同步**——在飞书里给一个 IM 群加减用户，观察 `/principal-groups` 更新。若不更新，长连接可能尚未建立——飞书有时在检测到客户端之前拒绝长连接事件。保持控制面运行并重试；连接会自行建立。

## 出问题的时候

- **登录失败、回调不匹配**——确认浏览器 origin、provider id 和飞书白名单合起来恰好得到文档约定的回调 URL（本地 `http://localhost:4000/sessions/oidc/lark-main/callback`）。飞书精确匹配。
- **对有效用户登录失败**——用户在应用可用范围之外。在飞书开发者后台加他们并发布新版本。
- **Directory 同步返回空**——directory scope（`contact:*`、`auth:user_access_token:read`）未授予，或应用版本未发布。scope 和发布是常见元凶。
- **实时同步陈旧**——长连接尚未建立。确认控制面有出站互联网；保持运行，让连接起来。

## 与其它 IdP 指南的差异

- **vs Entra ID**——相同四能力，但 Lark 实时同步骑长连接 WebSocket，不是 Graph 订阅。无公共入口、无 `SubscriptionReconciler`、无 `clientState`——运行更简单。
- **vs Google Workspace**——Google Workspace 仅全量、无实时。Lark 两者都有，经长连接。
- **vs 聊天 binding**——同一个自建应用做两者，用同一个 `appID`/`appSecret`。身份面加回调 URL 和 directory scope；聊天面加消息 scope。一个应用，两个面。

## 本指南不是什么

它不是飞书开发者后台教程——后台会变，确切 scope 名由飞书文档。它不是把应用范围外的用户纳入的途径；范围是边界，放宽它飞书侧决定。它也不与聊天面分离；一个应用服务两者，应用配置共享。

## 下一步

- adapter 参考（两个面），读 [Lark adapter](../adapters-lark/) 专页。
- 同一应用的聊天面，读[你的第一个 Lark 机器人](../lark-first-bot/)。
- 已同步 group 所喂给的权限模型，读 [Principal 与 AuthZ](../principal-authz/)。
