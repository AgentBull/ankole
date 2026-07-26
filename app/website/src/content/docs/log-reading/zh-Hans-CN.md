---
title: 日志阅读
description: 如何阅读 Ankole 的结构化控制面和 worker 日志——事件名搜索模式、严重级别、本地 pretty 打印器。
section: User guide
order: 57
---

Ankole 的日志是结构化 JSON——事件名、人类消息、结构化字段，严重级别从 `debug` 到 `error`。本页是运维者阅读日志的实用指南：搜索模式、旋钮、本地 pretty 打印器。它以实际机制补充[可观测性](../observability/)页。

先把决定性的性质说清楚：**事件名是连接键**。每行日志带一个稳定的事件名，如 `signals_gateway.webhook.dispatch_failed` 或 `ai_gateway.response_failed`。先按事件名搜、再按结构化字段收窄。线性读日志慢；按事件名读快。

## 日志形态

每行日志有：

```json
{
  "severity": "warning",
  "event": "signals_gateway.webhook.dispatch_failed",
  "message": "provider webhook dispatch failed",
  "handler_id": "lark",
  "kind": "message",
  "reason": "..."
}
```

`event` 字段是稳定标识符——同一运维事实在版本间不变。`message` 人可读但可能变；搜 `event`、读 `message`。其余字段是结构化上下文——`handler_id`、`reason`、`agent_uid`、`turn_ref`——是你找到事件后用来收窄的。

## 两个旋钮

| 变量 | 默认 | 效果 |
|---|---|---|
| `ANKOLE_LOG_LEVEL` | `info` | `debug`/`info`/`warning`/`error`——控制输出什么。非法值启动时拒绝。 |
| `ANKOLE_LOG_FORMAT` | `json` | `json` 供摄入，`pretty` 供本地阅读（但仅在开发中设 `pretty`；生产保持 `json`）。 |

为某次复现降到 `debug`，然后调回去。留在 `debug` 的部署又吵又慢。

## 本地用 pretty 打印器阅读

```bash
bun run kit logs pretty < /path/to/log-stream
```

pretty 打印器从 stdin 读 JSON 行并格式化为终端可读——严重级别、事件、消息、字段一目了然。生产里格式留 `json`，让日志摄入器处理格式。

## 搜索模式

出问题时从事件名出发：

1. **确定事件。** webhook 失败搜 `webhook.dispatch_failed`；provider 调用失败搜 `ai_gateway.response_failed` 或 `ai_gateway.request_failed`；回合出错搜回合错误事件。
2. **按字段收窄。** 找到事件后，按 `agent_uid`、`handler_id`、`reason` 或 `turn_ref` 过滤找具体实例。
3. **读上下文。** 事件周围的字段告诉你哪个子系统、哪个 agent、哪个边界产出了它。问题到界面的映射见[可观测性](../observability/)。

## 不在日志里的东西

- **Secret。** 日志模块从不记录解密的 secret 值、worker 认证 key 或 provider 凭证。携带敏感数据的字段在日志前被遮蔽。
- **完整会话转写。** 那些在 AIGateway 的 PostgreSQL 里，不在日志中。通过 `/ai-gateway/conversations/:id/messages` 读。
- **每次工具调用的完整参数。** 日志记录工具跑了及其结果，不是完整参数载荷。工具调用细节读会话消息。

## 本指南不是什么

它不是可观测性概念页——问题到界面的映射见[可观测性](../observability/)。它不是日志摄入器设置指南——你的摄入器（Loki、Elasticsearch、Datadog、CloudWatch）是你的选择。它不是故障排查 runbook——具体失败模式见 [FAQ](../faq/)或[调度故障排查](../cron-troubleshooting/)。

## 下一步

- 可观测性界面，读[可观测性](../observability/)。
- 作为环境变量的日志旋钮，读[环境变量](../environment-variables/)。
- kit pretty 打印器，读 [kit CLI 参考](../kit-cli/)。
- 故障排查模式，读 [FAQ](../faq/)。
