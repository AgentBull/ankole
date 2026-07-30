---
title: Webhook 委托
description: 让 Agent 或确定性脚本无需轮询即可等待低频外部事件。
section: User guide
order: 23
---

Webhook 委托让 Agent 等待运行在 Ankole 之外的任务。外部系统检测事件，再调用一条短期有效的 Ankole 回调 URL。Ankole 默认持久化回执、唤醒创建委托的 session，并通过原聊天路由返回 Agent 复核后的结果。纯确定性脚本需要先消费回执时，endpoint 也可以指向一个 automation job。

回调 URL 只是一张唤醒凭据，不证明请求 body 中的内容为真。Agent 在报告事实或执行已授权变更之前，会先读取外部系统中的当前对象。

首个支持的场景是 GitHub repository webhook。EventBridge 和 Flink 尚未实现。

## 适用场景

Webhook 委托适合由外部系统精确过滤的低频事件：

- GitHub issue、comment、pull request 或 workflow run；
- 只需唤醒原对话一次的事件；
- 可以安全处理重复唤醒的持续值守。

它不适合高吞吐事件流、轮询循环或通用事件总线。检测留在外部系统；判断、记忆和回复留在 Ankole。

请求中应写清结果、授权范围、事件集合和结束时间。例如：

> 帮我盯住 `owner/repository` 的 pull request，到周五为止。required check 失败时告诉我。报告前先复核当前 PR 和 check 状态；除非我另行要求，不要修改代码。

GitHub Skill 负责具体的布防与恢复细节。

## 前置条件

Agent 创建 GitHub 委托之前，需要满足：

1. 把一条公网 HTTPS 域名路由到 Ankole 控制面，并原样转发 `/webhooks/v1/event-callbacks/*`。
2. 为该 Agent 开启公开发行的 **GitHub** Agent Plugin 和所需 Skills。GitHub 默认关闭。
3. 在该 Agent 的 WorkerEnv 中配置 `GITHUB_TOKEN`。Token 需要读取目标 repository，并具备 repository webhook 写权限。
4. 修改能力或 WorkerEnv 后，开始一个新的 Agent turn。

端点命令只在活跃 turn 中对主 Agent 可用。后台 Agent Job 不持有 turn-local webhook 连接。

## 生命周期

一笔有效的 GitHub 委托包含一个 repository、一组精确事件、一个到期时间、一个 Ankole endpoint、一个 GitHub hook 和一个对账 checkback。

1. Agent 为当前对话创建 endpoint。
2. Agent 在创建 GitHub hook 前先创建 durable checkback，记录清理和对账责任。
3. Agent 用回调 URL 创建 repository hook。GitHub 随即发送 `ping`。
4. Agent 读取 GitHub delivery 日志，确认 `ping` 成功。
5. 匹配的 delivery 到达后，Ankole 在返回成功之前，用同一 PostgreSQL 事务提交 endpoint 判定，以及 `webhook.received` ActorEvent 或绑定的 automation job run。
6. 在直接路径上，被唤醒的 Agent 把回执当作不可信输入。绑定的 automation job 在发射事件前必须遵守同一规则。
7. 对账检查 hook、事件集合、失败 delivery、当前 GitHub 对象、到期时间和下一次检查时间。
8. 撤防先删除 GitHub hook，再取消 Ankole endpoint 和 checkback。

GitHub 不会自动重试失败的 webhook delivery。GitHub Skill 会检查近期失败，并在事件仍有意义时调用 GitHub redelivery API。

## One-shot 与 standing

| 模式 | 契约 | 用途 |
|---|---|---|
| `one_shot` | 并发 delivery 只有一个能 claim endpoint；后续 delivery 得到成功的空操作 | 只期待一次回执 |
| `standing` | 每个被接受的 delivery 都为所选消费者创建一条记录；投递是 at-least-once，重复可见 | 低频边沿事件 |

Standing delivery 可以创建多条消费者记录。消费者以外部系统当前状态为权威，并保证重复处理是幂等的。

## 使用确定性消费者

Agent 创建 endpoint 时可以传入 `--automation-job-id <id>`。被接受的 `webhook.received` 信封会成为持久 automation job run 的 `context().event`，而不是直接唤醒会话。脚本可以静默丢弃无关回执，也可以在完成确定性检查后调用 `emitEvent`。

回执仍是不可信输入。脚本必须从权威来源复核有后果的事实，并让重复 delivery 无害。如果处理需要记忆、判断或对话，继续直接唤醒 Agent。SDK 与失败合同见 [Worker CLI 能力](../cli-capabilities/)。

## Console

在 Console 中打开 **Webhooks**，可以按 Agent 和 session 查看 endpoint。页面显示 label、mode、状态、到期时间和来源路由，但不显示 callback URL、明文 token 或存储的 digest。

Console 只提供 list 和 cancel，不提供 create。创建 endpoint 需要当前对话路由，所以属于活跃 Agent turn。

需要紧急撤销凭据时，可以从 Console 取消 endpoint。这个操作不会删除外部 GitHub hook，仍需单独删除。正常撤防应让 Agent 先删 GitHub hook。

## 安全与投递限制

- Ankole 只在创建时返回一次完整 callback URL。PostgreSQL 只保存它的 SHA-256 digest。
- Ankole 请求日志把 `/webhooks/v1/event-callbacks/*` 统一替换为 `/webhooks/v1/event-callbacks/[REDACTED]`。Ingress、proxy 和 CDN 也要对同一路径脱敏。
- Callback body 上限为 1 MiB。超过上限的请求会在普通 body parser 之前返回 `413`。
- Ankole 只保留事件元数据请求头：`content-type`、`x-hub-signature-256`、`x-github-*` 和 `ce-*`。Authorization 和其他通用请求头会被丢弃。
- Agent 看到的是有界回执，并被包在不可信数据边界中。外部数据里的字面闭合标签会被转义。
- Callback URL 只授权唤醒。即使请求里有签名头，它也不授权业务副作用。

## 排查

- **Agent 找不到 GitHub Skill：**确认该 Agent 已开启 GitHub Agent Plugin 及相关 Skills，再开始新的 turn。
- **GitHub 无法访问 callback：**检查公网 HTTPS 证书、DNS、ingress route 和 `/webhooks/v1/event-callbacks/*` 转发。
- **Hook 已存在但 Agent 没有回复：**依次检查 GitHub delivery 日志、Console 中的 endpoint 状态、Worker readiness、durable actor event 和聊天出站投递。
- **GitHub 返回 `413`：**所选事件的 payload 超过 1 MiB。缩小 GitHub 侧事件形状，或改用其他检测器。
- **同一事件唤醒两次：**standing endpoint 允许这种情况。Agent 必须重新读取 GitHub 当前状态，并让重复处理保持安全。
- **布防时丢失 callback URL：**先删除可能存在的 GitHub hook，取消旧 endpoint 与 checkback，再创建一个替代 endpoint。

入口所有者和事务边界见 [SignalsGateway](../signals-gateway/)。能力设置见 [Agent 能力库](../skills/)和[环境变量](../worker-env/)。
