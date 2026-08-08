---
title: 工作节点
description: 在 Console 中查看 Agent Computer Worker 的状态、容量和最近心跳，并处理常见故障。
section: User guide
order: 52
---

Agent Computer Worker 是 Agent 实际工作的电脑。控制面负责管理和分配工作，Worker 负责运行 Agent、工具和文件操作。一个实例可以连接一个或多个 Worker。

## 查看工作节点

打开 **Console → 工作节点**。每行会显示：

- **状态**：节点是否可以接收新工作；
- **槽位**：该节点最多可以同时运行多少个 Agent 回合；
- **活跃轮次**：当前正在执行的回合数；
- **最近心跳**：控制面最后一次收到节点状态的时间；
- **版本**：节点当前运行的 Ankole 版本。

只要至少有一个节点处于“就绪”状态，控制面就可以继续分配工作。节点长期没有心跳，通常表示容器已停止、网络中断，或 Worker 无法通过认证连接控制面。

选择“浏览文件”可以查看该节点上的 Agent 文件。具体操作见 [文件管理](../file-management/)。

## 没有就绪节点

按顺序检查：

1. Worker 容器或 Pod 是否正在运行。
2. Worker 日志是否出现控制面地址、认证密钥或连接失败。
3. 控制面和 Worker 使用的 `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` 是否一致。
4. Worker 是否能访问控制面的 Runtime Fabric 地址。
5. 控制面和 Worker 是否使用兼容的 Ankole 版本。

Docker Compose 可以查看：

```bash
docker compose ps agent-computer-worker
docker compose logs agent-computer-worker
```

Kubernetes 可以查看：

```bash
kubectl -n ankole get pods
kubectl -n ankole logs deployment/ankole-agent-computer-worker
```

实际资源名称取决于安装时使用的 release 名称；若命令找不到对象，请先用 `kubectl -n ankole get deployments` 确认名称。

## 节点已就绪，但工作排队

比较“活跃轮次”和“槽位”。如果全部节点的活跃轮次都达到槽位上限，新工作会等待可用容量。

短时间排队属于正常现象。持续排队时，先确认模型提供商没有变慢，再决定增加 Worker、提高单节点容量，或降低同时运行的任务数。容量调整方法见 [性能调优](../performance-tuning/)。

## 重启工作节点

只有节点无响应、且日志表明它无法自行恢复时，才需要重启。

Docker Compose：

```bash
docker compose restart agent-computer-worker
```

Kubernetes：

```bash
kubectl -n ankole rollout restart deployment/ankole-agent-computer-worker
```

重启会中断该节点正在执行的回合。控制面会按相应任务的重试规则处理这些工作，因此重启后还要在 **Console → 会话**或**后台 Agent 任务**中确认结果。
