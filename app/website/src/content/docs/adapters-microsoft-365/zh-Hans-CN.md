---
title: Microsoft 365 adapter
description: 把一个 agent 接到 Microsoft 365——通过 Bot Framework 的 Teams 聊天、Graph/Bot Framework webhook、Entra ID identity provider，以及一个独立的 directory webhook handler。
section: User guide
order: 18
---

Microsoft 365 adapter 是聊天 adapter 里覆盖最广的。一个 plugin（`microsoft365-adapter`）一次贡献四个契约：一个 Teams 聊天面、一个 Graph/Bot Framework webhook handler、一个 Entra ID identity provider，再加一个专门处理 directory 事件的 webhook handler。本页是运维者的设置路径。

## adapter 声明了什么

`Ankole.Plugins.Microsoft365Adapter`（`plugin_id: "microsoft365-adapter"`）声明四个 adapter 契约：

- **`signals_gateway.adapter`**（`id: "teams"`）——Teams 聊天面。一个 signal binding 把 Teams 消息和事件路由给 agent。
- **`signals_gateway.webhook_handler`**（`id: "teams"`，`module: TeamsWebhook`，`kinds: ["messages"]`）——Graph/Bot Framework webhook 面。通过 `/webhooks/v1/...` 正门处理 Bot Framework 消息投递。
- **`principals.identity_provider`**（`id: "entra-id"`）——Entra ID 面。让管理员用 Microsoft 工作账号登录 Console。能力：`oidc_authorization`、`oidc_code_exchange`、`directory_full_sync`、`directory_realtime_sync`。
- **`signals_gateway.webhook_handler`**（`id: "entra-id"`，`module: DirectoryWebhook`，`kinds: ["directory"]`）——第二个 webhook handler，专门用于 realtime 同步期间的 directory 变更投递。

plugin 监管两个子进程：`TeamsChannels.StartupSync`（启动时投影 Teams 频道成员）和 `SubscriptionReconciler`（让 Graph 订阅保持存活）。启用 plugin 后，Teams 聊天、两个 webhook handler 和 Entra ID 登录一起可用。

## 前置条件

在 Entra ID（Azure AD）里注册一个应用，并给它配一个 Bot registration。聊天配置（由 `Config.validate_chat_config/1` 校验）需要：

| 字段 | 含义 |
|---|---|
| `appID` | Microsoft App ID（client id）；必填，必须是 GUID。 |
| `appPassword` | Microsoft App client secret；必填，由控制面加密存储。 |
| `botTenancy` | `single_tenant`（默认）或 `multi_tenant`。 |
| `tenantID` | Entra tenant GUID；单租户应用必填。 |

Bot Connector token 的租户跟随 `botTenancy`。单租户应用用你的 `tenantID`。多租户应用的 bot token 租户是固定的 `botframework.com` 段，`tenantID` 此时可选。为应用订阅它所需的 Teams channel 和 Graph 订阅范围，并为这些范围授予管理员同意。

## 创建 Teams 聊天 binding

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/teams/<binding_name> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "...", "filters": { ... }, "unaddressed_group_message_policy": "..." }'
```

binding 的 `config_ref` 指向存在 `signals_gateway.teams.bindings.<id>` 这个 AppConfigure 键下的 Teams 应用配置。filter 和群消息策略字段见 [Signal binding](../signal-bindings/)，所有 adapter 共用。

## Bot Framework 鉴权

入境的 Teams 消息以携带 Bot Framework JWT 的请求到达。adapter（`BotFrameworkAuth`）在任何处理之前先校验每个请求：用 Bot Framework JWKS 校验 RS256 签名、签发方 `https://api.botframework.com`、受众等于你的 `appID`、`serviceUrl` 声明与 activity 的 service URL 匹配，并留五分钟时钟余量。签名本身由 native kernel 校验；只有通过校验的请求才变成 actor 事件。

这就是为什么 `appID` 和 `appPassword` 必须与应用注册一致。adapter 把 App ID 当作期望的 JWT 受众，用 App password 换取 Bot Connector token 发出站调用。受众对不上、签名失败、或 `serviceUrl` 不匹配的 token，在到达 agent 之前就被拒绝。Emulator 路径（`sts.windows.net` 签发方）不被接受——只放行生产 connector 流量。

## Graph 订阅与调和器

Graph 变更通知订阅由 adapter 拥有，不是由你拥有。订阅状态存在机器管理的 `principals.entra_id.graph_subscriptions.<id>` AppConfigure 键下。每个订阅带一个 `clientState`；adapter 设这个值，没有匹配 `clientState` 的 Graph 投递会被拒绝。

`SubscriptionReconciler` 让订阅保持存活。它在每个订阅的过期窗口前续订，并重建掉线的订阅。续订间隔远远落在 Graph 的续订窗口内，所以错过几轮运行也不会丢数据。你不需要手工续订订阅。

## 两个 webhook handler

plugin 声明两个 `signals_gateway.webhook_handler` 契约，因为两种流量不同，走不同的路径：

- **`teams`**（`TeamsWebhook`，kinds `["messages"]`）——Teams 机器人的 Bot Framework 消息投递。
- **`entra-id`**（`DirectoryWebhook`，kinds `["directory"]`）——realtime 目录同步期间的 directory 变更通知。

两者都从 `/webhooks/v1/...` 正门进来；kind 和 handler 模块决定每次投递要做什么。

## Teams 频道成员

adapter 投影 Teams 频道成员，让频道里的 agent 知道频道里都有谁。`TeamsChannels` 在启动时跑一次 startup sync，之后 `sync_channels` 和 `refresh_channel` 任务维持成员信息。成员从 Graph 读取并作为投影镜像；Teams 始终是事实来源。你不在 Ankole 里管理成员——变动在同步运行时流入。

## Entra ID 作为管理员 identity provider

身份面让管理员通过 Entra ID 用自己的 Microsoft 工作账号登录 Console。声明携带 `oidc_authorization`、`oidc_code_exchange`、`directory_full_sync`、`directory_realtime_sync`。通过 identity-provider 界面配置：

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/entra-id-main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "adapter_id": "entra-id", "tenantID": "...", "clientID": "...", "clientSecret": "...", "oidc": { "enabled": true }, "sync": { "contacts": true, "realtime": true } }'
```

配置键模式为 `principals.identity_providers.entra-id.<id>`。登录后，一次 directory 同步（全量和/或 realtime）把 Entra ID group 拉进 AuthZ group，于是 Console AuthZ 能映射到你现有的 Entra ID group 结构。

## 出问题的时候

- **Bot Framework 校验失败**——确认 `appID` 与注册一致、JWT 受众是你的 App ID。受众或 `serviceUrl` 错误的 token 在到达 agent 之前就被拒绝。
- **`appID`/`tenantID` 不匹配**——单租户应用 `tenantID` 必填；多租户的 bot token 租户是 `botframework.com`，所以单租户 tenant 留在多租户配置里（或反过来）都换不出对的 token。
- **webhook 不再触发**——Graph 订阅会过期；`SubscriptionReconciler` 续订它们，但订阅掉线了调和器会重建。查调和器诊断；`clientState` 轮换表现为投递被拒。
- **directory realtime 同步没开**——realtime 同步需要在 identity provider 上设 `publicBaseURL`；没设的话 adapter 只回退到全量同步。

## 下一步

- binding 模型，读 [Signal binding](../signal-bindings/)。
- webhook 正门，读 [SignalsGateway](../signals-gateway/) 开发者页。
- identity-provider 路由，读 [Console API 参考](../console-api/)。
