---
title: 灾难恢复
description: 恢复 Ankole 部署实例——覆盖控制面 PostgreSQL、Base 分片数据库、文件存储、Agent Home、Function Runtime、部署密钥与恢复演练。
section: Guides
order: 320
---

灾难恢复时，必须将控制面 PostgreSQL 主库、独立 Pod Base 分片数据库（配置了 `BASE_DB_URLS` 时）、文件存储、Agent 持久 Home、无状态 `ankole-function-runtime` 服务以及原部署密钥作为一个整体协同还原。需要保留的数据范围与一致性备份流程见[备份指南](../backup-and-restore/)。

## 恢复前

开始恢复前，先确认旧控制面与旧 Worker 均无法再向恢复后的 Home 和数据库写入数据。仅凭连接断开并不能说明 Worker 已经停止，处于暂停状态的实例以及结果未明的创建请求都必须一并排查。PostgreSQL 中尚未结清的实例代次（generation）记录及对应凭据必须原样保留；控制面恢复后会继续核对同一代实例，直到基础设施平台返回明确状态。

恢复演练必须在隔离的平台资源上进行。若复制出的数据库仍指向生产环境的 WorkerProvider 位置，演练过程就会直接操作生产实例。此外，Ankole 不支持跨提供商或跨存储布局的自动迁移。

## 恢复流程

1. 准备替代基础设施并保持控制面处于停止状态，沿用原部署的 WorkerProvider 位置、`BASE_DB_URLS` 分片标识（`ankole_sharding`）与持久存储布局。预先部署同版本的无状态 `ankole-function-runtime` 服务；若使用 Docker 本地卷存放 Home，必须在控制面启动前先行恢复卷数据，避免控制面启动时自动创建出空卷。
2. 按照[备份与还原](../backup-and-restore/)中的顺序，依次恢复控制面 PostgreSQL 主库、`BASE_DB_URLS` 中的全部独立 Base 分片库（若已配置）、配套文件存储与全部持久 Home。对独立 Base 分片库执行时间点恢复（PITR）时，**每个 Base 分片库的恢复时间点都必须 `>=` 控制面主库的恢复时间点**，防止控制面已记录为物理表的 Base 表在分片库中缺失；同时保持分片库与主库一致的排序规则（locale/collation）及 `public._ankole_shard` 分片身份，并保留 Agent UID、卷名、文件属主与权限。
3. 从密钥管理系统中恢复原 `ANKOLE_SECRET_BASE`。该密钥用于解密各类 Provider 密钥及未结清实例代次的凭据。一旦该密钥丢失，请先暂停恢复并制定专门的凭据重建方案——仅重新录入 Provider 凭据，无法解开未结清实例代次的凭据。
4. 配置其余启动密钥与服务地址（包括 `DATABASE_URL`、独立分片场景下的 `BASE_DB_URLS`、`ANKOLE_FUNCTION_RUNTIME_URL` 以及共享的 `ANKOLE_FUNCTION_RUNTIME_TOKEN`），先启动 `ankole-function-runtime`，再启动控制面，由控制面的常规协调流程去核查平台侧的真实实例状态。切勿为了表面状态正常而手动清空实例代次或实例引用；状态未明的实例应继续停留在 `starting` 或 `deleting`，并在 `last_error` 中保留原因。
5. 启用已恢复的 Agent，逐项验证读取已知的 Home 文件、云盘或 Pod 文件以及 Pod Base 数据表，再恢复一个 Background Job 并跑通一次真实回合。正式切换生产流量前，再次确认旧部署实例处于停止状态。

## 恢复边界

恢复完成后，持久业务数据与多维表状态由控制面 PostgreSQL 主库和 Base 分片库还原，工作区与 Codex 线程文件由持久 Home 还原；SQLite 缓存可在运行中自动重建，`ankole-function-runtime` 本身则不保存任何持久状态。备份时间点之后的文件改动、进程内存数据，以及中断前仍在执行中的模型或函数调用，均不在恢复范围内。

宿主机损毁后，Docker 本地卷必须依靠外部备份才能还原；Cloudflare Worker 则同时依赖 R2 备份与数据库中的引用记录，若实例被强制终止，最后一次备份之后的改动可能会丢失。各类运行环境的详细限制见[工作节点](../worker-management/)。

执行计划内跨主机迁移时，应先停止所有写入进程，再对主库、Base 分片库、文件存储与 Agent Home 执行最后一次一致性备份。恢复演练应在隔离资源上完整复现上述步骤并验证端到端用户路径，同时记录实际恢复点目标（RPO）与恢复时间目标（RTO）。任何跳过 Base 分片库、持久 Home 或加密密钥的演练，都无法证明系统具备完整恢复能力。
