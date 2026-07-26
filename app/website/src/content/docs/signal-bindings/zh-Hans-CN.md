---
title: Signal binding
description: 如何把一个 agent 接到聊天平台——创建 binding、指向 adapter、用 filter 收窄范围，并选择它在群聊里的行为。
section: User guide
order: 14
---

signal binding 是让 agent 可达的东西。它把一个 provider adapter——Lark、钉钉、Slack、Microsoft 365、Google Workspace——绑到一个 agent 上，让来自该 provider 的消息、webhook 和事件变成 agent 会被唤醒的 actor 事件。本页是运维者走过一个 binding 的路径：选 adapter、给 binding 命名、用 filter 收窄范围、选择群聊行为。

先把决定性的性质说清楚：一个 binding 以 `(agent, binding_name)` 为键，禁用它会停止新信号唤醒 agent，而不删除 binding 的配置。你可以让 agent 安静下来，又不弄丢它的设置。

## 一个 binding 带着什么

一个 binding 形态小而固定：

| 字段 | 含义 |
|---|---|
| `adapter` | provider adapter id——`lark`、`dingtalk`、`slack`、`microsoft365`、`google_workspace`，或本部署 plugin 所声明的其它 |
| `name` | 你选的 binding 名字；每个 agent 唯一 |
| `config_ref` | 对 adapter 所需的 adapter 专属配置（app id、token、webhook 端点）的引用 |
| `filters` | 决定哪些入境事实在范围内的规则 |
| `unaddressed_group_message_policy` | agent 如何对待那些没有直接 @ 到它的群消息 |
| `enabled` | 新信号是否可以通过这个 binding 唤醒 agent |
| `confidential_memory` | agent 是否把通过这个 binding 看到的内容排除在共享记忆之外 |

`config_ref` 背后的 adapter 专属字段因 provider 而异——各 provider 的前置条件（app id、token、事件订阅、webhook URL）见各 adapter 专页。

## 列出可用 adapter

```bash
curl https://ankole.example.com/api/v1/signal-adapters \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

响应是本部署的 Control Plane Plugin 在 `signals_gateway.adapter` 契约下注册的 adapter 声明集合。如果你期待的 adapter 不见了，是声明它的 plugin 没启用——见 [Control Plane Plugins](../control-plane-plugins/)。

## 创建或替换 binding

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/<adapter_id>/<binding_name> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "...", "filters": { ... }, "unaddressed_group_message_policy": "..." }'
```

路径里的 `(adapter_id, binding_name)` 给 binding 命名；对同一对的第二次 `PUT` 替换它。用 `GET /agents/:agent_uid/signal-bindings` 列出 agent 的 binding。

## 用 filter 收窄范围

filter 决定 binding 接受哪些入境事实。不匹配的事实返回一次成功的空操作（`status: :filtered`）——agent 不会被唤醒，也不会有 actor 事件入队。用 filter 把 binding 收窄到特定的 channel、发送者或消息种类，让 agent 只在真正给它的工作上醒来。filter 的形态与 adapter 无关；各 adapter 专页会指出该 provider 上值得过滤的字段。

## 选择群聊行为

`unaddressed_group_message_policy` 控制当一条消息到达群聊、而 agent 没有被直接 @ 时该怎么办。这个策略决定该消息是产生 `may_intervene` 事件（允许 agent 插话），还是 `addressed` 事件（agent 被点名）。按 agent 的角色来设：共享支持频道里的客户成功 agent 可能想观察并插话；发布说明机器人大概率应该在被点名之前保持安静。

## 禁用而不删除

`DELETE /agents/:agent_uid/signal-bindings/:binding_name` 尽管 HTTP 动词是 DELETE，实际上是一次*禁用*操作：它停止新信号唤醒 agent，但让 binding 的配置可恢复。用 `PATCH /agents/:agent_uid/signal-bindings/:binding_name` 重新配置或迁移一个 binding，包括把 `enabled` 重新打开。一个不可用的 binding 会记下 `unavailable_reason`，让你看到它为什么停了——通常是 adapter 配置缺失或被撤销。

## 一个 binding 是一个 adapter 对一个 agent

一个 binding 恰好把一个 adapter 接到一个 agent。想让两个 agent 共享一个 channel，给各自一个 binding；想让一个 agent 在两个 provider 里回答，给它两个 binding。没有“多对多”的 binding 对象——一对一的形态正是让每个 agent 的身份、记忆和权限范围保持清晰的那件事。

## 下一步

- 各 provider 的前置条件和 Console 字段，读用户指南下各 adapter 专页。
- binding 模型以及 binding 如何变成 actor 事件，读 [SignalsGateway](../signals-gateway/) 开发者页。
- 路由，读 [Console API 参考](../console-api/)。
