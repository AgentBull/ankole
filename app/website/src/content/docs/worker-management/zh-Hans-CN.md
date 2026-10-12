---
title: 工作节点
description: 在 Console 中查看每个 Agent 的 Worker，了解控制面如何管理它，并处理常见故障。
section: User guide
order: 52
---

每个 Agent 独享一台 Worker，并在 `/workspace` 有自己的持久 Home。运维在 Console 中创建 Worker provider，选择类型、填写 YAML，密钥单独保存。创建 Agent 时选定 provider，之后不能更改；不同实例规格使用不同 provider。

## WorkerPool（工作节点池）

一个 Worker provider 就是一个 WorkerPool：一种平台类型、一份 YAML 配置，以及单独加密保存的凭据。池属于站点。不同租户的 Agent 可以选用同一个池，但每个 Agent 都有独立的 Worker、持久 Home、缓存和 Worker 凭据。

1. 打开 **Console → Settings → Worker providers**，选择 **New Worker provider**。
2. 选择类型，以对应的 YAML 示例配置实例镜像、规格、存储和连接地址。
3. 在独立的凭据字段中填写平台密钥，保存后执行可用性检查。
4. 把一个池设为默认，或在创建 Agent 时明确选择池。两者都没有时，Agent 创建失败。

站点最多有一个默认池。更改默认池只影响之后创建的 Agent，已有 Agent 保留原 provider。不同规格或位置使用不同池，同一种类型也可以创建多个池。创建后不能修改 provider ID、类型、存储位置或 Agent 的 provider 绑定。仍被 Agent Worker 行引用的池不能删除。

池通过所选平台管理实例，不会把一个 Agent 的电脑分配给另一个 Agent。创建步骤见 [Agents](../agents/)，执行与恢复见 [Agent Computer Worker](../agent-computer-worker/)。

## 每个 Agent 一台 Worker

创建 Agent 只保存 provider 绑定和 Worker 行，不立即启动实例。环境工具、Codex Job 或 Automation Job 需要电脑时，控制面才启动 Worker。主对话与 Workflow 的模型调用在控制面执行，可以不依赖 Worker。

同一个 Agent 的 Session 和 Job 使用自己的工作区，共享这台电脑及 Home。打开的环境工作区和运行中的 Codex 回合各占一个 Worker 槽位。`ANKOLE_MAX_CONCURRENT_SLOTS` 设置这台 Worker 的容量。增加池或其他 Agent 不会扩大已有 Agent 的 Worker 槽位，也不会提高它独立的后台 Job 并发上限。

## 查看工作节点

打开 **Console → Workers**。每行显示 Agent、provider、状态、负载、心跳和最近的平台错误。

| 状态 | 含义 |
| --- | --- |
| `absent` | 没有实例，需要时创建 |
| `starting` | 已保存 generation，等待创建或接纳 |
| `ready` | 已连接，可以执行回合 |
| `stale` | 原连接已断开 |
| `paused` | 平台保留进程与内存 |
| `draining` | 等待回收或替换 |
| `deleting` | 等待实例与存储删除 |

创建超时后沿用同一 generation 重试。平台结果不确定时，Agent 可能一直等待；控制面不会因此创建第二个写者。修改配置前先读 **Reason**。

## Provider 与存储

各平台的限制、凭据与网络要求，以及 SQLite 缓存盘配置见 [WorkerProvider 与缓存盘](../worker-providers/)。旧版本部署见 [从 1.0 升级到 2.0](../upgrade-to-2/)。

| 类型 | 持久 Home | 空闲回收 |
| --- | --- | --- |
| Docker | 每个 Agent 的本地卷 | 删除容器 |
| Kubernetes | 独享 PVC 或共享 PVC 的子目录 | 删除 Pod |
| Cloudflare | R2 目录备份 | 备份后删除容器 |
| Vercel | 每个 Agent 的 Drive | 删除沙箱 |
| Lambda MicroVMs | EFS 上的 Agent 目录 | 保留内存暂停 |
| 函数计算 | 每个 Agent 的 AgenticSpace 或 OSS 前缀 | 保留内存暂停 |

Vercel 的 24 小时会话需要 Pro 或 Enterprise。Lambda 的内存配额须同时容纳运行中、暂停中的 Worker 和存储删除辅助实例。部署前按仓库 CONTRIBUTING 的命令检查目标环境。函数计算已按官方协议实现，存储、模板捕获与内存暂停仍须在已开通的阿里云账户实测。ACS 的默认内存保留尚未确认，当前未注册。

删除实例与换镜像都会保留 Home。Codex 线程文件在 `/workspace/.codex`，SQLite 缓存在 `/var/cache/ankole/codex`；重建只删除缓存。Docker 本地卷不能抵御宿主丢失；Cloudflare 被平台强制停止时可能丢失最后一次备份之后的写入。持久 Home 和 [Agent 云盘](../file-management/) 都需要备份。

## 回收、替换与删除

- 在 provider YAML 中设置 `idleReleaseAfter`。6 种 provider 默认均为 `15m`，可设为 `never`。
- 支持内存暂停的类型暂停空闲 Worker，其他类型删除实例，持久存储与配置的缓存卷保留。
- 镜像或实例配置变化时，在空闲后替换；协议变化立即替换。旧的暂停实例会先替换再接工作。
- `agent_computer.worker.ready_timeout` 默认 600 秒，只重建平台上已经观察到的实例，不会结清结果不确定的创建。
- 删除 Agent 先等实例消失，再删除 Home 与缓存，最后删除 Worker 行。Agent UID 由服务端生成，不会复用。

## 排查未就绪的 Worker

检查 provider 凭据、存储、容量和 `endpoints`。Docker 的 `ANKOLE_DOCKER_GID` 必须匹配容器内 socket 的组；Kubernetes 检查控制面的 Role、Pod 事件和 PVC；Cloudflare 检查适配器镜像映射与 token；Lambda 检查镜像构建、构建角色、VPC 连接器和 EFS 连通性。

用 provider 标签确认目标实例，先读日志再停止。Kubernetes 正常删除必须等到完成，不得用宽限 0 绕过失联节点。Docker 先停止，再删除：

```bash
docker stop CONTAINER_NAME
docker rm CONTAINER_NAME
```

需要时控制面会创建替代实例，Home 和缓存卷仍在。停止会中断正在运行的回合，由各自的重试规则处理。已就绪但工作仍等待时，比较负载与回合容量。`ANKOLE_MAX_CONCURRENT_SLOTS` 是 provider YAML 中的实例环境变量，修改后空闲替换。见 [性能调优](../performance-tuning/)。
