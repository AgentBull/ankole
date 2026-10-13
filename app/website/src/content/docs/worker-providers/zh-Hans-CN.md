---
title: WorkerProvider 与缓存盘
description: 比较 Docker、Kubernetes、Cloudflare、Vercel、Lambda 和函数计算的限制，配置持久 Home 与 SQLite 缓存盘。
section: Guides
order: 317
---

WorkerProvider 决定 Agent 的电脑运行在哪里，以及 Home 和缓存如何保存。每个 Agent 固定使用一个 provider，独享一台 Worker。provider 属于站点，凭据在 Console 的独立字段加密保存；不要把凭据写入配置 YAML。创建与日常操作见 [工作节点](../worker-management/)。

## 先区分三种存储

| 存储 | 内容 | 持久性要求 |
| --- | --- | --- |
| Agent Home：`/workspace` | 工作区、安装的软件、`/workspace/.codex` 中的线程 | 实例删除、镜像替换后仍须保留，需要备份 |
| Worker 缓存：`/var/cache/ankole` | `codex/` 下的 SQLite、WAL 和本地进程锁 | 可重建，每个 Agent 独享 |
| 控制面云盘 | 附件、发布文件、Skill、Automation 脚本 | 由 PostgreSQL 与 OpenDAL 后端共同保存，需要备份 |

云盘的 S3 桶不能替代 Worker 的 Home 或 SQLite 缓存盘。Cloudflare 的 R2 Home 备份、函数计算的 OSS Home 与控制面云盘也是独立配置。见 [云盘存储配置](../drive-storage/)。

## Provider 对照

| `kind` | Home | 缓存 | 空闲操作 | 实例时限 |
| --- | --- | --- | --- | --- |
| `docker` | Agent 独享的本地命名卷 | 独享本地命名卷 | 删除容器 | 适配器未设固定时限 |
| `kubernetes` | 独享 PVC，或共享 PVC 中的 Agent 子目录 | 独享 PVC 或 `emptyDir` | 删除 Pod | 适配器未设固定时限 |
| `cloudflare` | 启动时从 R2 恢复，正常退出前备份 | 实例磁盘 | 备份后删除容器 | 由平台控制 |
| `vercel` | Agent 独享 Drive | 实例磁盘 | 删除沙箱 | 可配置，默认 24 小时 |
| `lambda` | EFS 上的 Agent 目录 | 实例磁盘 | 保留内存暂停 | 8 小时，含暂停 |
| `function_compute` | AgenticSpace 或 OSS 中的 Agent 前缀 | 实例磁盘 | 保留内存暂停 | 24 小时 |

以上时限是 Ankole 适配器采用的限制，不是所有平台规格的全集。平台账户配额、套餐和区域可用性仍需核对。ACS 当前未注册为 WorkerProvider。

6 种 provider 的 `idleReleaseAfter` 默认均为 `15m`，可设 `never`。这只控制空闲回收，不能延长平台实例时限。位置、存储键、provider 类型和已有 Agent 的绑定不能修改；实例规格、环境变量或连接地址变化在空闲时替换 Worker。种子 YAML 只在 provider 表为空时导入，后续通过 Console 修改。

## 各 Provider 的注意事项

### Docker

- 使用本地 Docker Engine 和 `local` 卷驱动，适合开发和单机部署。容器替换保留卷，宿主机丢失会丢失 Home；备份必须放在另一台机器。
- 控制面需要 Docker socket 的访问权限。Compose 的 `ANKOLE_DOCKER_GID` 必须与 socket 组匹配；这项访问权限等同宿主 root 权限。
- `network` 必须让 Worker 访问控制面和外部服务。Docker 配置不接受 capability 或 security-option 覆盖。
- Home 和缓存使用不同的卷。不要用远程文件系统挂载替换本地缓存卷。

### Kubernetes

- `storage.claimTemplate` 与 `storage.sharedClaim` 二选一。跨节点使用共享 Home 时，PVC 需支持 `ReadWriteMany`；独享块存储可使用 `ReadWriteOnce` 或受 CSI 支持的 `ReadWriteOncePod`。缓存另用块存储 PVC 或 `emptyDir`。
- Worker 的可信进程以 root 启动，模型命令以 uid 1000 执行。Worker 与存储清理 helper Pod 需要允许 baseline Pod Security；不符合 restricted 策略。
- Home 必须允许 root 写入并把文件交给 uid 1000，或将全部访问映射到 uid 1000。没有这种映射的 root-squash NFS 不满足要求。
- 控制面需要 Pod、Secret、PVC 和清理 helper 的 RBAC。远程 kubeconfig 配置必须显式提供全部 3 个 `endpoints`，且不能使用本地 `ownerConfigMap`。创建后不能切换集群内凭据与远程 kubeconfig 模式。
- 新节点应预拉 Worker 镜像；镜像准备步骤不会替 Kubernetes 拉取镜像。正常删除 Pod 后必须等待平台确认，不要强删或使用零宽限绕过失联节点。

### Cloudflare

- 先部署 [Cloudflare 适配器](https://github.com/AgentBull/ankole/tree/main/tools/deploy/cloudflare/agent-workers)，配置 Worker 镜像映射、R2 和单独的 `adapterToken`。
- 实例磁盘要同时容纳镜像、恢复的 Home、缓存和临时文件；R2 容量不能扩大实例磁盘。Ankole 支持 `lite`、`standard-1` 至 `standard-4` 及自定义实例规格，规格还必须满足 [Cloudflare 限制](https://developers.cloudflare.com/containers/platform/limits/)。
- 正常回收会先备份 Home。平台强制停止可能丢失最后一次备份之后的写入；备份失败不能当作成功完成回收。`stopGraceSeconds` 默认 300 秒，为排空和备份留出时间。
- 当前公共文件 relay 要求一个控制面副本。改用 S3 云盘不会解除这项 relay 限制。

### Vercel

- Home 使用同一区域的独享 Drive。`teamId`、`projectId`、`region` 和 `driveSizeGiB` 创建后不能更改。
- Worker 需要项目 VCR 仓库中准备好的 `linux/amd64` 镜像；使用目标 digest。`cpus` 支持 1，或 2 到 32 的偶数；适配器按每 vCPU 2048 MiB 请求内存。
- `sessionTimeoutSeconds` 默认为 86400（24 小时）。账户限额为 45 分钟时设为 2700；试用账户若返回该限额，也使用此值。配置不得超过账户实际限额。参见 [Vercel 会话限制](https://vercel.com/kb/guide/vercel-sandbox-duration-and-persistence)。删除沙箱会保留 Drive，实例缓存随之删除。
- 已验证短周期启动、保留文件、换镜像和 Drive 删除；OOM、宿主故障及完整 24 小时时限仍需要目标环境验证。

### AWS Lambda MicroVMs

- 此类型使用 Lambda MicroVMs。需要 `arm64` Worker 镜像、构建用 S3 桶和 IAM role、VPC network connector，以及可连通的 EFS。
- 官方 Worker 镜像只允许 `memoryMiB: 4096` 或 `8192`。已有配置中的更低数值必须在 Console 修正，否则运行和清理均无法继续。`env` 最多 47 项，`stopGraceSeconds` 最大 59 秒。
- 内存配额同时覆盖运行中、暂停中和存储删除 helper。暂停不释放这项容量；删除后也要等 AWS 确认终止才算释放。参见 [MicroVM 配额与生命周期](https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html)。
- EFS 保存 Home，SQLite 留在实例盘。8 小时时限包括暂停时间；旧构建对象和镜像不自动回收。构建失败需要修复构建 role、镜像或网络后重试。
- 已验证短时内存暂停、EFS 保留和清理；长时间暂停及完整实例时限仍需要部署验证。

### 阿里云函数计算

- 使用 ACR Enterprise 中的 `amd64` 镜像构建第二代模板。需要 Team、Sandbox API key、POP AccessKey 和授权的 RAM role；模板捕获时不带 Agent 身份或凭据。
- `storage.agenticFs` 与 `storage.oss` 二选一。AgenticFS 需要 VPC、文件系统、区域/可用区，以及容量与文件数配额；挂载前接入点必须可用。开通要求见 [AgenticFS Volume](https://help.aliyun.com/zh/functioncompute/create-an-agenticfs-volume)。
- 镜像必须包含 OSSFS2 2.0.10 或更高版本，并在挂载前保持 `/workspace` 为空。官方 Worker 镜像满足这些要求，启动入口会在挂载后创建运行目录。
- OSS 仅挂载本 Agent 的 `<root>/<agent_uid>`，不具备完整 POSIX 语义。不要把 SQLite 缓存放在 OSS 挂载上，也不要把 `chown` 失败直接当作文件不可写。
- provider `env` 可以新增变量，但不能覆盖镜像记录的环境变量。暂停请求保留内存，恢复请求使用新的 24 小时时限；旧模板不自动回收。
- 恢复时通过镜像内的辅助程序重建 OSSFS2 连接，并保留挂载和已打开的文件，避免读取等待暂停期间失效的 TCP 连接。若辅助程序失败，provider 会删除该实例，下一轮协调从 Home 重建。请同时使用包含该程序的 Worker 镜像和对应的控制面版本。AgenticFS 仍需实测。

外部 provider 和远程 Kubernetes 需要可从实例访问的 `runtimeFabricUrl`、`relayOrigin` 与 `aiGatewayUrl`。不要使用实例无法解析的 Compose service 名称或仅集群内可达的地址。

显式配置 `endpoints.relayOrigin` 的 provider 要求一个控制面副本，文件传输必须回到持有 relay 的节点；官方 Helm 会拒绝多副本配置。这项限制也适用于 Vercel、Lambda、函数计算和远程 Kubernetes。

## 缓存盘要求

SQLite 与进程锁要求缓存具有本地文件系统语义：可靠的锁、共享内存、原子文件操作，以及 uid 1000 的读写权限。使用本地 SSD、挂成文件系统的块设备，或节点上的 `emptyDir`。不要使用 NFS、EFS、SMB、S3/R2/OSS FUSE 挂载作为 Codex SQLite 缓存；[SQLite WAL](https://www.sqlite.org/wal.html) 不支持网络文件系统。

每个 Agent 使用独立缓存，不能共享同一个缓存目录或 PVC。监控可用容量、inode 和节点临时存储；没有统一的最小容量保证。官方 Helm 缓存 PVC 默认 20 GiB，容量应按实际日志、并发和工作负载调整。

原生 Kubernetes provider YAML 的持久缓存示例，需替换实际 StorageClass：

```yaml
cache:
  claimTemplate:
    storageClassName: ebs-gp3
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 20Gi
```

临时缓存可改为：

```yaml
cache:
  sizeLimit: 5Gi
```

这是 provider YAML。Helm values 使用 `worker.cache.type: pvc`、`worker.cache.size`、`worker.cache.storageClass`，或 `worker.cache.type: emptyDir`；不要混用两种格式。

Docker 缓存卷和 Kubernetes 缓存 PVC 在正常回收、镜像及普通实例设置替换后保留。显式重建会清缓存，缓存自身配置变化会替换缓存；`emptyDir` 和外部 provider 的实例盘随实例删除而丢失。上述操作保留 Home。不要在 app-server 仍运行时手动删除 SQLite、WAL 或锁文件。

启动检查只验证目录可访问和基本读写，不能证明网络文件系统的 SQLite 锁可靠。出现锁错误、磁盘满或缓存 PVC 无法绑定时，先查 Console **Workers → Reason**、平台事件和挂载类型。配置与恢复见 [性能调优](../performance-tuning/)和 [备份与还原](../backup-and-restore/)。
