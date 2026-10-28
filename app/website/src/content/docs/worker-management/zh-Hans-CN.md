---
title: 工作节点
description: 在 Console 中查看并管理每个 Agent 独享的 Worker，了解控制面的调度回收机制与常见故障排查。
section: User guide
order: 52
---

在 Ankole 中，每个 Agent 都独享一台专属的 Worker，并在 `/workspace` 路径下拥有持久化的主目录（Home）。运维人员先在 Console 中添加工作节点提供商（Worker Provider）：选定底层算力平台、编写 YAML 规格配置，并将平台访问密钥填入独立的加密字段保存。新建 Agent 时选定绑定的提供商，创建后即不可更改；如需区分不同机型规格，可建立多个提供商实例分别指派。

## WorkerPool（工作节点池）

一个 Worker Provider 即对应一个工作节点池（WorkerPool），由底层平台类型、一份 YAML 实例配置以及单独加密存储的平台访问凭据组成。节点池属于站点级资源：不同租户下的 Agent 可以共用同一个节点池配置，但落到实际运行时，每个 Agent 依然各自拥有完全隔离的 Worker 实例、持久化主目录、缓存盘与连接凭据。

1. 打开 **Console → Settings → Worker providers**，点击 **New Worker provider**。
2. 选定底层平台类型，对照页面提供的 YAML 模板配置容器镜像、计算规格、存储卷及回连控制面的端点地址。
3. 在独立的凭据栏填入平台访问密钥，保存后触发连通性与可用性检查。
4. 将其中一个节点池设为站点默认池，或者在每次新建 Agent 时显式指定目标节点池（若既未设默认池又未手动指定，新建 Agent 将直接报错失败）。

整个站点最多只能指定一个默认池；切换默认池仅影响此后新建的 Agent，存量 Agent 继续固定使用创建时绑定的原提供商。同一平台类型下也支持创建多个节点池以区分硬件规格或可用区。节点池一旦创建，其 `provider ID`、平台类型、存储位置以及既有 Agent 的绑定关系均不可修改；只要数据库中仍有任何 Agent Worker 记录引用某个节点池，该节点池便不允许删除。

节点池仅负责调用底层算力平台按需启停实例，绝不会把某一个 Agent 的沙箱电脑转配给另一个 Agent 混用。新建 Agent 的完整流程见 [Agents](../agents/)，沙箱执行与断线恢复细节见 [Agent Computer Worker](../agent-computer-worker/)。

## 每个 Agent 一台 Worker

新建 Agent 时，系统仅在数据库中写入提供商绑定关系与初始 Worker 记录，并不会当场拉起底层计算实例；只有当环境工具、Codex 后台任务或自动化任务真正需要沙箱电脑时，控制面才会按需唤醒或创建该 Agent 的 Worker。纯文本主对话与 Workflow 编排的模型调用直接在控制面内完成，无需启动 Worker。

同一个 Agent 名下的多个 Session 与后台任务各自使用独立的工作区子目录，但共享同一台 Worker 实例及 `/workspace` 主目录。每个打开的环境工作区与每个正在运行的 Codex 回合各占用 1 个 Worker 并发槽位，单台 Worker 的槽位上限由 `ANKOLE_MAX_CONCURRENT_SLOTS` 决定。单纯新建更多节点池或添加其他 Agent，并不会扩充既有单个 Agent 的 Worker 槽位容量，也不会放宽其独立的后台任务并发上限。

## 查看工作节点

打开 **Console → Workers** 页面，列表会逐行展示每个 Agent 绑定的提供商、当前生命周期状态、实时槽位负载、最近心跳时间及底层平台上报的最新错误摘要：

| 状态 | 含义 |
| --- | --- |
| `absent` | 当前未运行底层计算实例，有任务需要时再按需创建 |
| `starting` | 已分配并持久化实例代数（generation），正在等待平台拉起实例并回连注册 |
| `ready` | 实例已成功回连控制面，可随时承接执行回合 |
| `stale` | 原有的长连接已断开，等待重连或协调恢复 |
| `paused` | 实例已被底层平台挂起，内存状态原地保留 |
| `draining` | 正在排空在途工作，准备执行空闲回收或版本替换 |
| `deleting` | 正在等待底层平台彻底销毁计算实例与关联存储 |

若拉起实例超时，控制面会沿用同一个代数（generation）幂等重试；一旦底层平台返回状态不明，该 Agent 的待执行任务可能会保持挂起等待——为严守单写者边界，控制面绝不会在旧实例生死未卜时贸然拉起第二个并发写者实例。动手调整配置前，请先仔细阅读列表中的 **Reason** 诊断说明。

## Provider 与存储

六种算力平台各自的配额约束、权限凭据、网络连通要求及 SQLite 缓存盘规范详见 [WorkerProvider 与缓存盘](../worker-providers/)；版本升级迁移步骤见 [从 1.0 升级到 2.0](../upgrade-to-2/)。

| 平台类型 | 持久化主目录（Home）存储方式 | 空闲回收动作 |
| --- | --- | --- |
| Docker | 每个 Agent 独享的宿主机本地命名卷 | 销毁容器 |
| Kubernetes | 独享 PVC，或共享 PVC 下的专属子目录 | 删除 Pod |
| Cloudflare | R2 对象存储目录快照备份 | 完成备份后销毁容器 |
| Vercel | 每个 Agent 独享的持久 Drive | 销毁沙箱实例 |
| Lambda MicroVMs | AWS EFS 上的 Agent 专属目录 | 保留内存快照挂起暂停 |
| 函数计算 | 每个 Agent 独享的 AgenticSpace 或 OSS 前缀目录 | 保留内存快照挂起暂停 |

配置跨云平台时需留意特定约束：Vercel 的 `sessionTimeoutSeconds` 必须小于或等于当前账号套餐允许的实际上限（默认为 `86400` 秒；若账号上限为 45 分钟则须设为 `2700` 秒）；AWS Lambda 的并发内存配额必须足以同时容纳运行中实例、挂起暂停中实例以及辅助清理存储的临时实例；阿里云函数计算从挂起态唤醒恢复时，依赖内置在 Worker 镜像里的 OSS 重连辅助程序，部署时务必保持控制面与 Worker 镜像版本严格匹配。

正常销毁计算实例或升级更换容器镜像，都会完整保留 `/workspace` 主目录数据。其中，Codex 持久化线程保存在 `/workspace/.codex` 下，可重建的 SQLite 运行缓存则位于 `/var/cache/ankole/codex` 下，触发环境重建时仅清空缓存盘。注意，Docker 本地命名卷无法防范宿主机硬盘损坏，而 Cloudflare 容器若遭平台侧强制驱逐杀停，可能会丢失自上一次成功备份以来的增量写入——因此请务必同时为持久化主目录与 [Agent 云盘](../file-management/) 建立定期备份。

## 回收、替换与删除

- **配置空闲回收时长**：在提供商 YAML 中设置 `idleReleaseAfter`（全部 6 种提供商默认均为 `15m`，设为 `never` 可禁用空闲自动回收）。
- **按平台特性回收算力**：支持内存快照挂起的平台（如 Lambda、函数计算）会将空闲 Worker 置为暂停态，其余平台则直接销毁计算实例，同时完整保留持久化主目录与已配置的独立缓存卷。
- **平滑滚动替换**：更新容器镜像或实例规格参数后，存量 Worker 会在进入空闲态后再行替换；若遇到底层通信协议版本升级则立即强制替换；处于挂起态的旧配置实例在承接新任务前也会先完成替换。
- **就绪超时重建保护**：`agent_workers.ready_timeout_seconds` 默认为 `600` 秒，仅针对底层平台已明确可观测到的卡死实例触发重建，绝不会擅自强行结清平台侧结果仍不确定的创建请求。
- **有序清理已删 Agent**：删除某个 Agent 时，控制面会先等待其底层计算实例彻底销毁退出，随后清理持久化主目录与缓存存储，最后才删除数据库中的 Worker 行记录。Agent UID 由服务端全局唯一生成，删除后永不复用。

## 排查未就绪的 Worker

遇到 Worker 长时间卡在未就绪状态时，请依次核查提供商访问凭据、存储卷挂载、账户容量配额及回连 `endpoints` 地址：Docker 环境重点核对 `ANKOLE_DOCKER_GID` 是否与宿主机 Docker Socket 的属组 GID 一致；Kubernetes 环境检查控制面 ServiceAccount 的 Role 权限、`kubectl describe pod` 事件及 PVC 绑定状态；Cloudflare 环境核查适配器侧的镜像映射表与鉴权令牌；AWS Lambda 环境则逐一排查镜像构建状态、构建 IAM Role、VPC 连接器及 EFS 挂载连通性。

如需手动干预问题实例，请先通过平台资源标签定位准确的目标容器或 Pod，提取保存现场日志后再执行停止操作。在 Kubernetes 中删除异常 Pod 时必须等待 API Server 正常确认终态，严禁附加零宽限期（`--grace-period=0`）强行绕过失联节点；在 Docker 环境中请按顺序优雅停止并移除容器：

```bash
docker stop CONTAINER_NAME
docker rm CONTAINER_NAME
```

旧实例移除后，只要该 Agent 后续仍有待处理任务，控制面便会自动拉起全新替代实例，原有的主目录与缓存卷数据依然完好。手动停止实例会打断当时正在运行的回合，后续将由各任务自身的重试契约接管恢复。若发现 Worker 明明已处于 `ready` 状态但新任务仍在排队等待，请比对当前活跃负载与单实例槽位上限——`ANKOLE_MAX_CONCURRENT_SLOTS` 作为提供商 YAML 中的实例环境变量，修改保存后会在下次空闲替换时生效。调优方法详见 [性能调优](../performance-tuning/)。
