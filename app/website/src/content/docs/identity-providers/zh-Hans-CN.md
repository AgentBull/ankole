---
title: Identity provider
description: 五个受支持平台的 identity provider 如何工作——共享的 OIDC 模型、directory 同步能力、哪个 adapter 服务哪个平台。
section: User guide
order: 44
---

identity provider（IdP）是管理员登录 Ankole Console 的方式，也是 directory group 同步进 AuthZ 的方式。五个平台作为 identity provider 受支持，各自通过其 adapter 的身份面。本页是跨五个平台的综合运维者视角——共享模型、差异、每个平台的分步指南在哪。

先把决定性的性质说清楚：每个 identity provider 用 **OIDC 登录、directory 同步进 AuthZ group**，但限定登录的边界因平台而异。Lark 和钉钉用应用可用范围或 `corpid`；Slack 用 workspace（`teamID`）；Entra ID 用租户；Google Workspace 用 `allowedDomains`。边界始终在，只是表达方式不同。

## 五个受支持的 provider

| Provider | Adapter id | 登录边界 | Directory 同步 | 实时 |
|---|---|---|---|---|
| **Lark / 飞书** | `lark` | 应用可用范围 | IM 群 + 组织结构 | 是（长连接 WebSocket） |
| **钉钉** | `dingtalk` | `corpid`（组织） | 组织结构（部门 + 用户） | 是（Stream WebSocket） |
| **Slack** | `slack` | workspace（`teamID`，可选） | workspace 成员 | 是（Socket Mode） |
| **Entra ID** | `entra-id` | 租户（单租户应用） | directory group + 用户 | 是（Graph 订阅） |
| **Google Workspace** | `google-workspace` | `allowedDomains`（工作空间域） | directory group | 否（仅全量） |

每个 provider 带 `oidc_authorization` 和 `oidc_code_exchange` 用于登录、`directory_full_sync` 用于周期同步。五个中的四个还带 `directory_realtime_sync`；Google Workspace 没有，因为其他几个用的 Google 侧通道在此不适用。

## 共享模型

不论平台，流程一致：

1. **配置 identity provider**——通过 Console 或设置流程，用平台凭证。
2. **管理员登录**——通过 Console 的 OIDC 路径。adapter 跑授权码流程、读用户身份、解析为 Ankole Principal。首个成功用户成 root 管理员；激活码失效。
3. **Directory 同步运行**——全量按节奏，实时（若支持）经平台事件通道。group 和成员作为 Ankole AuthZ group 到达。
4. **运维者向已同步 group 授予**——通过 [Principal 与 AuthZ](../principal-authz/)。

adapter 拥有 OIDC 和 directory 细节；Ankole 拥有 Principal 解析和 AuthZ 授予。两者之间的边界是已同步的 group——adapter 提供成员，AuthZ 决定它意味着什么。

## Directory 同步：全量与实时

两种形态（平台支持两者时）：

- **全量同步**按节奏通过平台 API 读取 directory。它是底——即使实时漏掉变更，也把 Ankole 的视图收敛到平台事实。节奏由 `principals.identity_providers.directory_full_sync_interval_hours`（AppConfigure）控制。
- **实时同步**用平台的事件通道——长连接 WebSocket（Lark）、Stream API（钉钉）、Socket Mode（Slack）、Graph 订阅（Entra ID）。directory 变更几分钟内到达 Ankole，不等下次全量。

Google Workspace 仅全量。其他四个两者都有，实时骑聊天面用的同一连接（或 Entra ID 的、由 `SubscriptionReconciler` 管理的 Graph 订阅）。

## 配置什么

所有 provider 的共同步骤：

1. **在平台开发者后台注册应用**——Lark/钉钉/Slack 与聊天 binding 同一应用；Entra ID 单独应用注册；Google Workspace 一个 OAuth client 加一个 service account。
2. **加 OIDC 回调 URL** 到应用安全设置——Ankole Console 回调。
3. **授予 directory scope**——adapter 读取用户、group、部门所需的权限。
4. **配置 identity provider**——通过 `PUT /identity-providers/<provider_id>`，带平台的 `adapter_id` 和凭证。

每个平台的分步指南见下表。

## 出问题的时候

所有 provider 的常见失败：

- **登录在重定向处失败**——回调 URL 不匹配或凭证错。先修应用的 redirect 配置。
- **对有效用户登录失败**——用户在边界之外（错的 workspace/租户/域/应用范围）。边界是平台特定的栅栏；在平台侧放宽，不在 Ankole 里。
- **Directory 同步返回空**——directory scope 未授予或应用版本未发布。scope 和发布是常见元凶。
- **实时同步陈旧**——事件通道未连接。确认连接类型（长连接/Stream/Socket Mode/Graph 订阅）健康。

## 各平台指南

| 平台 | 指南 |
|---|---|
| Lark / 飞书 | [用 Lark 作管理员登录](../lark-admin-login/) |
| 钉钉 | [用钉钉作管理员登录](../dingtalk-admin-login/) |
| Slack | [用 Slack 作管理员登录](../slack-admin-login/) |
| Entra ID | [用 Entra ID 作管理员登录](../entra-id-admin-login/) |
| Google Workspace | [用 Google Workspace 作管理员登录](../google-workspace-admin-login/) |

## 本指南不是什么

它不是各平台配置教程——每个平台有自己的指南见上表。它不是安全加固指南——边界与轮换纪律见[安全加固](../security-hardening/)。它也不是 AuthZ 页的替代——identity provider 提供 group；AuthZ 决定它们能做什么。

## 下一步

- 已同步 group 所喂给的权限模型，读 [Principal 与 AuthZ](../principal-authz/)。
- Console 路由，读 [Console API 参考](../console-api/)。
- 你的平台的分步指南，按上表。
