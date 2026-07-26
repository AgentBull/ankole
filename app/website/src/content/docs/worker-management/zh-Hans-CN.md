---
title: Worker 管理
description: 如何观察和管理 Agent Computer worker——列出、检查、理解 worker 池、并发回合容量、worker 不健康时怎么办。
section: User guide
order: 52
---

worker 是运行 agent 回合的 Agent Computer 进程。控制面管理其生命周期——启动、指派回合、隔离其回复——运维者观察其状态和容量。本页是 worker 面的运维者视角：如何列出和检查 worker、容量数字意味着什么、worker 不健康时怎么办。

先把决定性的性质说清楚：worker 是**可替换的执行底座**。控制面拥有回合和提交；worker 拥有执行。崩溃的 worker 被其监督器重启；它跑的回合被控制面重试。你不"修"worker——你让监督器重启它，你修导致失败的配置。

## 列出 worker

```bash
curl https://ankole.example.com/api/v1/agent-computer-workers \
  -H "Authorization: Bearer $CONSOLE_TOKEN"
```

`GET /agent-computer-workers` 列出控制面知道的每个 worker——其 id、状态、指派状态。健康的 worker 就绪且有可用的回合槽；繁忙的 worker 有活跃回合占用其容量。

## 容量数字意味着什么

每个 worker 有一个 `maxConcurrentTurns` 设置（由 `ANKOLE_MAX_CONCURRENT_TURNS` 控制，默认 9）。worker 通过准入提示报告其可用回合槽——还能接受多少回合。控制面用此提示避免把工作发给已满的 worker。

Compose（单主机）上有一个 worker；扩展意味着抬其回合上限。Helm（Kubernetes）上 worker 是一个可水平扩展的 Deployment——更多 pod，各有自己的上限。容量链（回合 × 连接池 × Postgres）见[性能调优](../performance-tuning/)。

## worker 不健康时

- **worker 启不起来**——检查镜像（`ANKOLE_AGENT_COMPUTER_IMAGE`）、`SYS_ADMIN`/seccomp/`/proc` 要求（见[平台支持](../platform-support/)）、worker 认证 key（`ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`）。
- **worker 启动但回合失败**——检查控制面日志看回合错误；worker 报告它，`handle_turn_error` 分类它。重试边界见 [Agent 循环](../agent-loop/)。
- **worker 慢**——检查 `/ai-gateway/conversations` 看回合的模型调用；慢的 worker 通常在等 provider，不是 worker 自身。
- **worker pod 被内存杀（Helm）**——抬 pod 内存上限，或降 `ANKOLE_MAX_CONCURRENT_TURNS` 让更少并发回合装入同样内存。

不要试图"修"worker 进程。监督器重启它；控制面重试回合。你的工作是修导致失败的配置或容量，不是干预进程。

## 重启 worker

Compose 上：

```bash
docker compose restart agent-computer-worker
```

Helm 上删 pod 让 Deployment 重建它：

```bash
kubectl -n ankole delete pod -l app.kubernetes.io/component=worker
```

重启在 worker 楔住时是对的——卡在一种不接受回合但监督器还没重启它的状态。控制面的回合级隔离栏确保进行中的回合在新 worker 上重试；不丢数据。

## 本指南不是什么

它不是 Agent Computer 概念页——循环、工具、归属边界见 [Agent Computer](../agent-computer/)。它不是 Kubernetes 运维指南——pod 生命周期、资源限制、节点亲和是你的集群的事。它不是性能调优指南——容量链见[性能调优](../performance-tuning/)。

## 下一步

- worker 概念页，读 [Agent Computer](../agent-computer/)。
- 容量链，读[性能调优](../performance-tuning/)。
- 回合生命周期与重试，读 [Agent 循环](../agent-loop/)和 [Actor Runtime](../actor-runtime/)。
- 平台要求，读[平台支持](../platform-support/)。
