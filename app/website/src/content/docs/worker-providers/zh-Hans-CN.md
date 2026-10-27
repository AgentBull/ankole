---
title: WorkerProvider 与缓存盘
description: 横向对比 Docker、Kubernetes、Cloudflare、Vercel、AWS Lambda 与阿里云函数计算的规格边界，正确配置持久化主目录与本地 SQLite 缓存盘。
section: Guides
order: 317
---

`WorkerProvider` 决定了 Agent 的专属沙箱电脑运行在哪类算力底座上，以及其持久化主目录（Home）与运行缓存如何挂载存储。每个 Agent 固定绑定唯一一个提供商并独享一台 Worker；提供商本身属于站点级资源，访问凭据在 Console 的独立加密字段中托管，切勿将明文密钥直接写进 YAML 配置文本中。日常创建与巡检操作见 [工作节点](../worker-management/)。

部分云厂商驱动由可选控制面插件提供：使用 Vercel 需先启用 `vercel-worker-provider` 插件；使用阿里云函数计算则需启用 `china-market-ai-providers` 插件（该插件同时包含国内主流模型适配器）。请在站点管理控制台开启对应插件并重启控制面后再创建节点池。注意，只要任意租户下仍存在引用了某插件算力驱动的 Agent（包括处于挂起暂停态或正在清理删除途中的 Agent），系统都会拦截并禁止关闭该插件。

## 先区分三种存储

| 存储层级 | 存放内容 | 持久性与隔离要求 |
| --- | --- | --- |
| **Agent 主目录（Home）**：`/workspace` | 任务工作区文件、用户态安装的软件包、`/workspace/.codex` 下的持久化线程 | 销毁实例或升级镜像后必须完整保留，需纳入定期备份 |
| **Worker 运行缓存**：`/var/cache/ankole` | `codex/` 子目录下的 SQLite 数据库、WAL 日志及本地进程文件锁 | 允许随时清空重建，但每个 Agent 必须严格独享 |
| **控制面云盘** | 聊天收发附件、对外发布产物、已安装 Skill 与自动化脚本 | 由 PostgreSQL 元数据与 OpenDAL 对象存储共同承载，需纳入定期备份 |

请勿混淆三者的职责：控制面云盘所用的 S3 存储桶不能拿来充当 Worker 的 `/workspace` 主目录或本地 SQLite 缓存盘；同样地，Cloudflare 用于备份主目录的 R2 桶、阿里云函数计算挂载的 OSS 主目录前缀，也与控制面云盘各自独立配置。云盘后端设置见 [云盘存储配置](../drive-storage/)。

## Provider 对照

| `kind` | 持久化主目录（Home） | 本地缓存盘 | 空闲回收动作 | 单实例最长存活时限 |
| --- | --- | --- | --- | --- |
| `docker` | Agent 独享的宿主机本地命名卷 | 独享本地命名卷 | 销毁容器 | 适配器层不设硬性时限 |
| `kubernetes` | 独享 PVC，或共享 PVC 下的专属子目录 | 独享块存储 PVC 或 `emptyDir` | 删除 Pod | 适配器层不设硬性时限 |
| `cloudflare` | 启动时从 R2 拉取恢复，优雅退出前写回备份 | 容器实例本地磁盘 | 完成备份后销毁容器 | 受 Cloudflare 平台策略控制 |
| `vercel` | Agent 独享的持久 Drive | 沙箱实例本地磁盘 | 销毁沙箱实例 | 可配置，默认 24 小时 |
| `lambda` | AWS EFS 上的 Agent 专属子目录 | MicroVM 实例本地磁盘 | 保留内存快照挂起 | 8 小时（含挂起暂停时长） |
| `function_compute` | AgenticSpace 或 OSS 中的 Agent 专属前缀 | 实例本地磁盘 | 保留内存快照挂起 | 24 小时 |

上表所列存活时限为 Ankole 适配器层遵循的边界，并非各云平台所有计费档位的全集；实际投产前仍请核对您名下云账号的并发配额、套餐档位与目标地域可用性。

全部 6 种提供商的空闲回收阈值 `idleReleaseAfter` 默认均为 `15m`（设为 `never` 可关闭空闲回收）——注意，该参数仅控制 Ankole 何时主动释放闲置实例，无法突破云平台自身的单实例最长存活上限。节点池创建后，其所属地域、存储定位键、提供商类型及存量 Agent 的绑定关系均锁定不可更改；而调整机型规格、实例环境变量或回连地址后，系统会在现有 Worker 进入空闲态时平滑替换。初始种子 YAML 文件仅在数据库提供商表为空时导入一次，后续配置变更请统一在 Console 页面操作。

## 各 Provider 的注意事项

### Docker

- **单机本地卷特性**：直接调用宿主机本地 Docker Engine 与 `local` 卷驱动，适合本地开发及单机中小规模部署。更换容器可无缝保留数据卷，但一旦宿主机物理磁盘损毁就会丢失主目录数据，因此务必将备份存往异机或远端对象存储。
- **高权限 Socket 保护**：控制面需挂载访问宿主机 Docker Socket，Docker Compose 中的 `ANKOLE_DOCKER_GID` 必须与宿主机上该 Socket 文件的属组 GID 一致；在安全边界上，持有该权限等同于拥有宿主机 `root` 权限。
- **网络与安全限制**：所配置的 `network` 必须允许 Worker 同时访问控制面与所需外部服务；Docker 提供商配置不支持自定义覆盖容器 Linux Capabilities 或 `security-opt` 选项。
- **主目录与缓存分卷**：主目录与运行缓存使用两个彼此独立的本地命名卷，切勿将本地缓存卷替换为 NFS 等远程网络文件系统挂载。

### Kubernetes

- **主目录存储二选一**：在 `storage.claimTemplate`（每 Agent 独享 PVC）与 `storage.sharedClaim`（多 Agent 共用同一 PVC 下的独立子目录）之间二选一。跨宿主机节点挂载共享主目录 PVC 时，底层存储必须支持 `ReadWriteMany`；每 Agent 独享块存储则可选用 `ReadWriteOnce` 或底层 CSI 支持的 `ReadWriteOncePod`。运行缓存须另外单独配置块存储 PVC 或节点 `emptyDir`。
- **Pod 安全基线要求**：Worker 容器内的受信任引导进程以 `root` 身份启动，随后降权以 `uid 1000` 执行模型命令；因此 Worker Pod 与存储清理辅助（helper）Pod 所在的命名空间需放行 `baseline` Pod Security 级别（无法在强制 `restricted` 策略下运行）。
- **文件系统属主映射**：主目录存储必须允许容器内 `root` 写入并将文件属主移交给 `uid 1000`，或者在存储服务端直接将全部读写访问统一映射为 `uid 1000`——默认开启 `root_squash` 且未做 UID 映射的传统 NFS 无法满足此要求。
- **RBAC 与集群连接模式**：控制面需具备管理目标命名空间下 Pod、Secret、PVC 及清理辅助 Pod 的 RBAC 权限。若采用远程 `kubeconfig` 连接外部集群，必须在配置中显式填全全部 3 个回连 `endpoints`，且不得启用本地集群专用的 `ownerConfigMap`；节点池创建后不支持在“集群内 ServiceAccount 模式”与“远程 kubeconfig 模式”之间切换。
- **镜像预拉取与优雅删除**：建议在新扩容的 Kubernetes 节点上预先拉取好 Worker 镜像（控制面的镜像准备阶段不会代为向集群节点分发拉取镜像）。删除异常 Pod 后必须等待 API Server 确认终态，切勿使用零宽限期强制删除来绕过失联节点。

### Cloudflare

- **前置部署适配器**：需先部署配套的 [Cloudflare 适配器](https://github.com/AgentBull/ankole/tree/main/tools/deploy/cloudflare/agent-workers)，配妥 Worker 镜像映射、R2 存储桶及独立的通信密钥 `adapterToken`。
- **本地磁盘容量规划**：容器实例自带的本地磁盘需要同时装下容器镜像层、从 R2 拉取解压的主目录文件、SQLite 缓存及运行时临时文件——扩大 R2 存储桶容量并不能撑大容器本地磁盘。Ankole 支持 `lite`、`standard-1` 至 `standard-4` 以及自定义实例规格，所选规格须符合 [Cloudflare Containers 平台限制](https://developers.cloudflare.com/containers/platform/limits/)。
- **退出备份窗口**：正常空闲回收前会先将主目录同步备份至 R2；但若实例遭底层平台强制终止，则可能丢失距上次备份以来的新写入（备份失败时系统不会将其视作正常回收完成）。`stopGraceSeconds` 默认为 `300` 秒，专门用于预留排空在途命令与上传备份的时间窗口。
- **单控制面副本约束**：当前公共文件传输中继（Relay）要求控制面保持单副本运行，即便将控制面云盘切换至 S3 后端也仍受此单副本中继限制约束。

### Vercel

- **同地域持久 Drive**：每个 Agent 的主目录挂载同地域的独享持久 Drive；节点池创建后，`teamId`、`projectId`、`region` 与 `driveSizeGiB` 四个字段即锁定不可更改。
- **镜像与 CPU/内存配比**：需提前将 `linux/amd64` 架构的 Worker 镜像推送至项目关联的 VCR 镜像仓库并引用准确的镜像 Digest。`cpus` 支持填写 `1` 或 `2` 至 `32` 之间的偶数，适配器会按每 vCPU 搭配 `2048 MiB` 的固定比例申请内存。
- **对齐账号会话时长上限**：`sessionTimeoutSeconds` 默认为 `86400` 秒（24 小时）；若您名下的 Vercel 账号或试用套餐将会话上限限制为 45 分钟，请务必将该值调低为 `2700`，严禁填入超出账号实际配额的数值，详见 [Vercel 沙箱时长与持久化说明](https://vercel.com/kb/guide/vercel-sandbox-duration-and-persistence)。销毁沙箱会清空实例本地缓存，但持久 Drive 中的主目录数据完好保留。

### AWS Lambda MicroVMs

- **基础架构依赖**：基于 AWS Lambda MicroVMs 运行，需准备 `arm64` 架构的 Worker 镜像、用于镜像转换构建的 S3 存储桶与 IAM Role、VPC 网络连接器以及网络可达的 Amazon EFS 文件系统。
- **严格的规格与参数上限**：官方 Worker 镜像仅支持将 `memoryMiB` 设为 `4096` 或 `8192`——若存量配置中填有更小数值，必须前往 Console 修正，否则实例拉起与存储清理均会受阻。此外，自定义 `env` 最多支持 `47` 个变量，`stopGraceSeconds` 最大不超过 `59` 秒。
- **并发内存配额核算**：AWS 账户的 MicroVM 内存配额池会同时计入运行中实例、挂起暂停态实例以及执行目录清理的临时辅助实例——将实例挂起暂停**不会**释放其占用的内存配额，删除实例后也须等 AWS 彻底确认终止后配额才会归还。详见 [AWS MicroVM 配额与生命周期文档](https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html)。
- **存储与构建清理**：主目录存放在 EFS 上，SQLite 缓存则留在 MicroVM 本地磁盘中；单实例最长 8 小时寿命包含挂起暂停期间经过的时间。历史构建产物与旧版镜像不会自动清理；若镜像构建失败，请排查修复构建 IAM Role、源镜像或 VPC 网络后重试。

### 阿里云函数计算

- **构建二代沙箱模板**：使用托管在阿里云企业版容器镜像服务（ACR Enterprise）中的 `amd64` 镜像构建第二代沙箱模板，需配齐 Team 标识、Sandbox API Key、POP AccessKey 及获授权的 RAM Role（构建基础模板时不会固化写入单个 Agent 的身份或凭据）。
- **主目录存储二选一**：支持选用 `storage.agenticFs` 或 `storage.oss`。其中 AgenticFS 需预先备妥专有网络 VPC、文件系统实例、地域/可用区及容量与文件数配额，并确认挂载点处于可用状态，开通指引见 [创建 AgenticFS 文件系统](https://help.aliyun.com/zh/functioncompute/create-an-agenticfs-volume)。
- **镜像内 OSSFS2 要求**：Worker 镜像内必须预装 `2.0.10` 或更高版本的 `OSSFS2`，且在执行挂载前保持容器内 `/workspace` 目录为空——官方 Worker 镜像已原生满足此要求，容器入口脚本会在挂载就绪后再初始化运行子目录。
- **注意 OSS 挂载的 POSIX 边界**：OSS 模式下仅挂载对应单个 Agent 的 `<root>/<agent_uid>` 子前缀，不具备完整的本地 POSIX 文件系统语义——**严禁将 SQLite 缓存目录改指到 OSS 挂载路径下**，同时也不要将挂载目录上 `chown` 返回失败误判为文件不可写。
- **环境变量与挂起续期**：提供商 YAML 中的 `env` 可新增环境变量，但无法覆盖固化在基础镜像内的同名变量。发起暂停请求会原地冻结保留内存，后续唤醒恢复则会重新起算一个新的 24 小时存活窗口；淘汰的历史沙箱模板需定期手动清理。
- **唤醒后平滑重连 OSSFS2**：实例从挂起态恢复唤醒时，会调用内置在官方 Worker 镜像中的专用辅助程序原地重建 OSSFS2 底层连接，同时保住现有挂载点与已打开的文件句柄，从而避免文件读取操作一直卡死在暂停期间已断开的旧 TCP 连接上。倘若该重连辅助程序执行失败，提供商适配器会果断销毁该异常实例，交由下一轮调度从持久化主目录全新拉起恢复。生产部署时请务必同步配套包含该辅助程序的同版本 Worker 镜像与控制面。

此外，所有外部云提供商及远程 Kubernetes 集群都要求实例能够通过网络直接访问 `runtimeFabricUrl`、`relayOrigin` 与 `aiGatewayUrl` 三个地址——切勿填入外部实例根本无法解析的内部 Docker Compose 服务名或仅限本集群内部可达的 ClusterIP 域名。

凡显式配置了 `endpoints.relayOrigin` 的提供商均要求控制面以**单副本**模式运行，以确保跨网文件流传输始终回到持有内存中继通道的同一个控制面节点（官方 Helm Chart 会在校验阶段直接拒绝多副本与外部中继组合）。这一约束同样适用于 Vercel、AWS Lambda、阿里云函数计算以及远程 Kubernetes 模式。

## 缓存盘要求

Codex 所依赖的 SQLite 数据库与进程级文件锁要求 `/var/cache/ankole` 必须具备纯正的本地文件系统语义：支持可靠的字节范围文件锁、共享内存映射（mmap）、原子重命名以及 `uid 1000` 用户的完整读写权限。因此，请务必为其配置宿主机本地 SSD、格式化为标准文件系统的块存储卷（如云盘 PVC）或节点内存/本地盘支撑的 `emptyDir`。**严禁将 NFS、Amazon EFS、SMB 或基于 S3 / R2 / OSS 的 FUSE 挂载盘用作 Codex SQLite 缓存盘**——正如 [SQLite WAL 官方文档](https://www.sqlite.org/wal.html)明确指出的，网络文件系统无法安全支撑 WAL 并发锁语义。

每个 Agent 必须独享各自的缓存目录或缓存 PVC，严禁多个 Agent 共用同一个缓存卷。运维期间请持续监控缓存盘剩余空间、Inode 耗用率及宿主机节点临时存储水位（系统不设硬性的统一最小容量下限；官方 Helm Chart 默认分配 `20 GiB` 缓存 PVC，实际生产中请结合日志吞吐、并发槽位数与任务体量按需扩容）。

在原生 Kubernetes 提供商 YAML 中配置持久化块存储缓存盘的示例如下（请将 `ebs-gp3` 替换为集群内实际的块存储 `StorageClass`）：

```yaml
cache:
  claimTemplate:
    storageClassName: ebs-gp3
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 20Gi
```

若改用受大小限制的节点临时缓存（`emptyDir`），可简写为：

```yaml
cache:
  sizeLimit: 5Gi
```

注意区分配置文件层级：上方片段属于写入 Console 的提供商 YAML 配置；而在 Helm `values.yaml` 中则对应 `worker.cache.type: pvc`、`worker.cache.size`、`worker.cache.storageClass`（或 `worker.cache.type: emptyDir`），切勿将两套语法混写在一起。

在生命周期上，Docker 本地缓存卷与 Kubernetes 独立缓存 PVC 在经历常规空闲回收、容器镜像升级或普通实例参数调整替换后都会继续保留；仅在管理员手动触发显式重建时才会清空缓存，或在修改缓存自身存储规格时替换缓存卷；而基于 `emptyDir` 及外部云沙箱本地实例盘的缓存则会随计算实例销毁一并释放。上述所有缓存变动均不会触碰 `/workspace` 持久化主目录。切记，只要 `app-server` 仍在运行，严禁手工进容器删除 SQLite 库文件、`-wal`/`-shm` 日志或进程锁文件。

Worker 启动自检仅能核实缓存目录存在且可正常创建读写普通文件，并不能替你检测出底层误挂网络文件系统所潜藏的 SQLite 并发锁损坏风险。一旦线上报出数据库锁冲突、磁盘空间耗尽或缓存 PVC 长时间处于 Pending 无法绑定，请优先对照 Console 的 **Workers → Reason** 诊断栏、底层平台事件与实际存储挂载类型排查。相关容量规划与容灾还原步骤分别见 [性能调优](../performance-tuning/) 与 [备份与还原](../backup-and-restore/)。
