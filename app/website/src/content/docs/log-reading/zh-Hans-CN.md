---
title: 查看日志
description: 从 Docker Compose、Kubernetes 或 Cloudflare 获取 Ankole 日志，并利用事件名与上下文字段定位故障。
section: User guide
order: 57
---

当 Console 仅提示“请求失败”或 Agent 迟迟没有回复时，可通过日志定位故障究竟发生在控制面、工作节点、聊天渠道还是模型提供商。

Ankole 默认输出结构化 JSON 日志，每条记录均包含严重级别、事件名、文字说明与相关上下文字段。排查问题时，建议先按事件名锁定环节，再结合 Agent UID、提供商 ID 或报错原因缩小范围。

## 获取日志

Docker Compose 部署：

```bash
docker compose logs --since 30m control-plane
docker ps -a --filter label=ankole.installation=ankole
docker logs --since 30m CONTAINER_NAME
```

控制面会为每个 Agent 创建一个独立的 Worker 容器。第二条命令用于列出所有 Worker 容器，其中 `ankole.agent-uid` 标签标明了各容器归属的 Agent。

Kubernetes 部署：

```bash
kubectl -n ankole logs deployment/ankole-control-plane --since=30m
kubectl -n ankole get pods -l ankole.io/installation=ankole
kubectl -n ankole logs POD_NAME -c worker --since=30m
```

实际资源名称可能随 Helm Release 名称而变化；若提示找不到对象，可先运行 `kubectl -n ankole get deployments` 确认部署名。若未显式覆盖 `worker.installation`，Worker Pod 上的 `ankole.io/installation` 标签值即为 Release 名称，而 Pod 注解 `ankole.io/agent-uid` 则标明了该 Pod 归属的 Agent。

Cloudflare 部署（在 `tools/deploy/cloudflare/agent-workers` 目录下执行）：

```bash
bunx wrangler tail ankole-agent-workers
```

每当 Worker 启动、停止或生成快照时，适配器都会输出一行对应的 JSON 日志。

如果某个 Agent 的 Worker 根本未能启动，可直接打开 **Console → 工作节点** 查看当前状态及底层后端返回的最新原因，详见 [工作节点](../worker-management/)。

动手复现问题前，建议先记下操作时间、目标 Agent、所在聊天渠道与触发动作，这样只需截取对应时间窗口的日志，无需从头翻阅启动日志。

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

- `severity`：日志严重级别；
- `event`：机器可读的事件名，最适合用来检索与聚合统计；
- `message`：便于人工阅读的简短说明；
- 其余字段：用于定位具体的 Agent、聊天渠道、后台任务或请求上下文。

一条错误日志前后的警告与普通信息往往能还原完整的调用链。排障时请勿只截取最后一行报错，应一并保留同一次请求前后的上下文记录。

## 常见查找顺序

1. 先按故障发生的时间段截取日志。
2. 搜索 `error`、`warning` 或 Console 页面显示的错误码。
3. 找到可疑事件后，再按 Agent UID（同时也是对应 Worker 的 ID）、提供商 ID 或聊天渠道适配器进一步过滤。
4. 对照 **Console → 会话** 或 **后台 Agent 任务** 页面中的执行状态，确认卡在或失败于哪一步。

Ankole 在输出日志前会自动隐去解密后的模型凭据、聊天渠道密钥与 Worker 凭据；不过在将日志对外提交排障前，仍请先检查其中是否包含用户聊天原文、内部网址或其他敏感业务数据。

## 临时增加日志

日志输出级别由环境变量 `ANKOLE_LOG_LEVEL` 控制，默认为 `info`。遇到难以复现或定位的疑难问题时，可将其临时调为 `debug` 并重启对应服务；排查完毕后请及时改回原值，以免持续刷出海量调试日志。

完整的环境变量说明见 [部署环境变量参考](../environment-variables/)，更多按故障现象分类的排查步骤见 [FAQ](../faq/)。
