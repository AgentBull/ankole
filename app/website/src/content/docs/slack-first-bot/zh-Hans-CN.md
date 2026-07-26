---
title: 你的第一个 Slack 机器人
description: 一份完整 walkthrough——部署 Ankole、配置 provider、创建 agent、通过 Socket Mode 绑到 Slack 应用，并验证机器人在频道里回复。
section: Guides
order: 303
---

本指南把一个 agent 一路带到可用的 Slack 机器人：在频道里 @、收到真实的模型回复、并验证端到端路径。读完你会得到一个能在 Slack workspace 里 @ 的 agent，并对沿途每一个边界都心中有数。

一句话讲完流程：**部署 Ankole → 激活并登录 → 配置 provider → 创建 agent → 绑到 Slack → @ 机器人 → 验证回复。**

本指南与[你的第一个 Lark 机器人](../lark-first-bot/)镜像——想要共享步骤的更多深度，先读那一篇。差异是 Slack 专属的：Slack 应用形态、Socket Mode（无需公共入口）、以及 adapter 强制的 token 前缀校验。

## 前置条件

- 一台满足[平台支持](../platform-support/)的 Linux 主机或 Kubernetes 集群。
- 一个能在 [Slack API dashboard](https://api.slack.com/apps) 创建应用的 Slack workspace。
- 一个用于真实模型回合的 LLM provider API key。

## 第 1 步：部署 Ankole

按[安装部署](../installation/)——单机用 Docker Compose，集群用 Helm。栈健康后，打开 HTTPS `/setup` 页面，从控制面日志读取激活码。输入 code。在 plugin 这一步，保持 **Slack adapter 启用**。

## 第 2 步：创建 Slack 应用

在 Slack API dashboard 从零创建一个新应用（或复用已有的）。adapter 要求两个 token，并严格校验它们的前缀：

| 字段 | token 类型 | 前缀规则 |
|---|---|---|
| `botToken` | bot user token (xoxb) | 必须以 `xoxb-` 开头 |
| `appToken` | app-level token (xapp) | 必须以 `xapp-` 开头 |

前缀错的 `botToken`（`xapp-…`）会以 `invalid_token_prefix` 失败，不以 `xapp-` 开头的 `appToken` 也是。两者都必需——缺一个以 `missing` 失败。在 *Basic Information → App-Level Tokens* 下生成 `appToken`；它就是 Socket Mode 的动力。

为应用订阅 agent 应当看到的事件——至少 `app_mention`（让 agent 被 @ 时醒来）和 `message.im`（让私信到达）。在应用设置里启用 **Socket Mode**；这是 Slack 把事件投递给 Ankole 的方式，无需公共入口端点。

授予这些事件所需的 scope：至少 `app_mentions:read`、`chat:write`，以及 `channels:history`（私有频道和私信用 `groups:history` / `im:history`）。把应用安装到 workspace 以生成 `botToken`。

## 第 3 步：通过 Slack 登录（可选）并启用 directory 同步

Slack 也能作为管理员 identity provider，带与其他 adapter 相同的 OIDC + directory 同步能力（`oidc_authorization`、`directory_full_sync`、`directory_realtime_sync`）。若想让管理员用 Slack 账号登录 Console，通过设置流程或 `PUT /identity-providers/<provider_id>`（`adapter_id: "slack"`）配置 identity provider。

Directory 同步把 Slack workspace 成员拉进 AuthZ group。adapter 拥有 Slack directory 成员投影——Slack 是事实来源，变动随 adapter 同步传播。实时同步使用 Socket Mode 连接（同一个 `appToken`），所以不需要为它开第二个入口。

若只想要聊天机器人、不要 Slack 作 IdP，跳过这一步——聊天 binding 不依赖它。

## 第 4 步：配置 provider 并绑定 model profile

按 [Provider 与模型](../providers-and-models/)：新增 provider 行，再把 agent 必需的 model profile 槽——`primary`、`light`、`heavy`——以及 agent 需要的可选槽绑上。

## 第 5 步：创建 agent

按 [Agent](../agents/)。用 `POST /agents` 创建，记下它的 `uid`，并至少撰写一份 `mission` 文档。一个 Slack 机器人的 mission，值得点名它所在的频道和它提供的帮助类型。

## 第 6 步：把 agent 绑到 Slack

创建 signal binding，把这个 agent 接到你的 Slack 应用：

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/slack/main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "<slack-config-key>", "unaddressed_group_message_policy": "addressed_only" }'
```

`config_ref` 指向带着 `botToken` 和 `appToken` 的 Slack 配置。`addressed_only` 是最安全的首发策略——agent 只在 `app_mention` 时醒来，而非每条频道消息都醒。policy 字段见 [Signal binding](../signal-bindings/)，binding 承载的内容见 [Slack adapter](../adapters-slack/) 专页。

## 第 7 步：验证机器人回复

把机器人邀请进测试频道（或开一个与它的私信）。@ 它一个简单问题：

> @Ankole 你能做什么？

收到回复，意味着整条路径都通了：Socket Mode 通过 app-level 连接投递了事件、signal binding 接受了它、actor 醒来、model profile 解析成功、回复通过 bot token 发回。如果机器人不回复，按顺序排查：

1. Socket Mode 已启用，且应用已安装到 workspace（`botToken` 存在）。
2. `appToken` 以 `xapp-` 开头，`botToken` 以 `xoxb-` 开头——adapter 在任何事件流动之前就拒绝错误前缀。
3. 机器人在频道里（Slack 不会为不是成员的机器人投递事件）。
4. 事件订阅包含 `app_mention`（私信还有 `message.im`），且 scope（`app_mentions:read`、`chat:write`、history scope）已授予。
5. signal binding 已启用，并指向这个 agent。
6. agent 有可用的 model profile，provider 凭证有效。

查看 worker 最近的输出，但不要打印它的环境：

```bash
docker logs --tail 200 ankole-dev-agent-computer   # 本地
kubectl -n ankole logs -l app.kubernetes.io/component=worker --tail=200  # Helm
```

## 与 Lark 机器人有什么不同

walkthrough 的形态一致；Slack 专属的部分是：

- **Socket Mode，而非 webhook 入口。** Slack 通过以 `appToken` 打开的 app-level WebSocket 投递事件。你不必为 Slack 暴露公共 HTTPS 端点，也不必像 Lark 的长连接 + OIDC 那样配置回调 URL。
- **两个 token，严格前缀规则。** `botToken`（`xoxb-`）和 `appToken`（`xapp-`）；adapter 两者都校验，拒绝错误前缀。
- **directory 成员归属。** Slack adapter 拥有成员投影，Lark 投影 IM 群；两者都是聊天平台作事实来源。

## 下一步去哪里

你现在有一个 agent 在一个 Slack 频道里活着。从这里出发：

- **让它观察频道对话**——把 binding 的 `unaddressed_group_message_policy` 改开，并订阅 `message.channels`，让 agent 看到非 @ 的消息。
- **给它节奏**——加一条[调度](../schedules/)，每天发一份帖子。
- **交接长工作**——让 agent 委派给[后台任务](../background-jobs-ops/)，见[后台研究任务](../background-research-job/)指南。
- **联合管理员登录**——若跳过了第 3 步，把 Slack 配置为 identity provider。

运维界面读 [Console 运维操作](../console-operations/)。adapter 内部读 [Slack adapter](../adapters-slack/) 专页。
