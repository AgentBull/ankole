---
title: 查看日志
description: 从 Docker Compose、Kubernetes 或 Cloudflare 获取 Ankole 日志，并用事件名和上下文字段定位问题。
section: User guide
order: 57
---

当 Console 只显示“请求失败”或 Agent 没有回复时，日志可以告诉你故障发生在控制面、工作节点、聊天渠道还是模型提供商。

Ankole 默认输出结构化 JSON 日志。每条记录都包含严重级别、事件名、说明和相关上下文。排障时先找事件名，再用 Agent UID、Provider ID 或错误原因缩小范围。

## 获取日志

Docker Compose：

```bash
docker compose logs --since 30m control-plane
docker ps -a --filter label=ankole.installation=ankole
docker logs --since 30m CONTAINER_NAME
```

控制面为每个 Agent 创建一个 Worker 容器。第二条命令列出这些容器；标签 `ankole.agent-uid` 标明每个容器所属的 Agent。

Kubernetes：

```bash
kubectl -n ankole logs deployment/ankole-control-plane --since=30m
kubectl -n ankole get pods -l ankole.io/installation=ankole
kubectl -n ankole logs POD_NAME -c worker --since=30m
```

资源名称可能随 release 名称变化。找不到对象时，先运行 `kubectl -n ankole get deployments`。Worker Pod 标签 `ankole.io/installation` 的值是 release 名称，除非 `worker.installation` 设置了其他值；Pod 注解 `ankole.io/agent-uid` 标明该 Pod 所属的 Agent。

Cloudflare（在 `tools/deploy/cloudflare/agent-workers` 目录中）：

```bash
bunx wrangler tail ankole-agent-workers
```

适配器为 Worker 的每次启动、停止和快照写一行 JSON。

若某个 Agent 的 Worker 没有启动，**Console → 工作节点**会显示它的状态，以及它的后端给出的最新原因。见 [工作节点](../worker-management/)。

复现问题前记下大致时间、Agent、聊天渠道和用户动作。这样可以只查看相关时间段，不必从启动日志开始翻找。

## 看懂一条日志

```json
{
  "severity": "warning",
  "event": "signals.webhook.dispatch_failed",
  "message": "provider webhook dispatch failed",
  "handler_id": "lark",
  "reason": "..."
}
```

- `severity` 表示严重程度；
- `event` 是最适合搜索和聚合的事件名；
- `message` 是便于阅读的说明；
- 其余字段用于定位具体 Agent、聊天渠道、任务或请求。

一条错误前后的警告和信息通常能还原完整过程。不要只复制最后一行；排障时保留相同请求前后的相关记录。

## 常见查找顺序

1. 先按问题发生时间缩小范围。
2. 搜索 `error`、`warning` 或 Console 中显示的错误码。
3. 找到相关事件后，再按 Agent UID（也是该 Agent 的 Worker 的 ID）、Provider ID 或聊天适配器过滤。
4. 对照 **Console → 会话**或**后台 Agent 任务**中的状态，确认失败发生在哪一步。

日志不会包含解密后的模型凭据、聊天渠道密钥或 Worker 凭据。提交日志用于排障前，仍应检查其中是否含有用户消息、网址或其他业务数据。

## 临时增加日志

`ANKOLE_LOG_LEVEL` 控制日志级别，默认是 `info`。需要复现难以定位的问题时，可以暂时改为 `debug` 并重启对应服务；复现结束后恢复原值，避免持续产生大量日志。

完整变量说明见 [部署环境变量参考](../environment-variables/)。

更多按现象分类的检查见 [FAQ](../faq/)。
