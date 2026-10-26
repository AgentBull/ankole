---
title: 灾难恢复
description: 恢复 Ankole 部署实例——覆盖控制面 PostgreSQL、Base 分片数据库、文件存储、Agent Home、Function Runtime、部署密钥与恢复演练。
section: Guides
order: 320
---

恢复时须将控制面 PostgreSQL 主库、独立 Pod Base 分片数据库（配置了 `BASE_DB_URLS` 时）、文件存储、Agent 持久 Home、无状态 `ankole-function-runtime` 服务以及原部署密钥作为一个整体协同恢复。[备份指南](../backup-and-restore/)说明了需要保留的数据和一致备份流程。

## 恢复前

确认旧控制面和 Worker 均无法再写入恢复后的 Home 与数据库。连接断开不能证明 Worker 已停止；暂停实例、结果未知的创建请求也必须计入。PostgreSQL 中未结清的 generation 与凭据必须保留，恢复后仍核对同一代，直到平台返回确定结果。

演练必须使用隔离的平台资源。若复制出的数据库仍指向生产环境的 provider 位置，将会操作生产实例。Ankole 不提供跨 provider 或跨存储布局的自动迁移。

## 恢复流程

1. 准备替代基础设施并保持控制面停止，保留原有的 provider 位置、`BASE_DB_URLS` 分片标识（`ankole_sharding`）与持久存储布局。预先部署同版本的无状态 `ankole-function-runtime` 服务；Docker Home 卷必须在控制面启动前恢复，避免控制面先创建出空卷。
2. 按照[备份与还原](../backup-and-restore/)的顺序，恢复控制面 PostgreSQL 主库、`BASE_DB_URLS` 中的全部独立 Base 分片库（若已配置）、配套文件存储与全部持久 Home。对独立 Base 分片库执行时间点恢复（PITR）时，**每个 Base 分片库的恢复时间点都必须 `>=` 控制面主库的恢复时间点**，以防止控制面已标记为物理表的 Base 表在分片库中缺失；同时保持分片库与主库一致的排序规则（locale/collation）及 `public._ankole_shard` 分片身份。保留 Agent UID、卷名、文件属主与权限。
3. 从密钥管理系统恢复原 `ANKOLE_SECRET_BASE`。它用于解密 provider 密钥及未结清 generation 的凭据。若该密钥已丢失，请先停下制定单独的凭据恢复方案；仅重新输入 provider 凭据无法恢复未结清 generation 的凭据。
4. 配置其余启动密钥与服务地址（包括 `DATABASE_URL`、独立分片场景下的 `BASE_DB_URLS`、`ANKOLE_FUNCTION_RUNTIME_URL` 以及共享的 `ANKOLE_FUNCTION_RUNTIME_TOKEN`），先启动 `ankole-function-runtime` 再启动控制面，让正常协调流程检查平台真实状态。不要为了表面健康而手动清空 generation 或实例引用；结果未明的实例应保持在 `starting` 或 `deleting` 状态，并在 `last_error` 中保留原因。
5. 启用已恢复的 Agent，验证读取已知的 Home 文件、云盘或 Pod 文件以及 Pod Base 数据表，恢复一个 Background Job 并执行一次真实回合。切换生产流量前再次确认旧部署保持停止。

## 恢复边界

控制面 PostgreSQL 与 Base 分片库恢复持久业务与多维表状态，Home 恢复工作区与 Codex 线程文件；SQLite 缓存可以重建，`ankole-function-runtime` 本身无持久状态。备份点之后的文件修改、进程内存及在途的模型或函数调用均不在恢复范围内。

Docker 本地卷在宿主机损毁后依赖外部备份才能恢复。Cloudflare 同时需要 R2 备份与数据库中的引用记录；强制终止可能丢失最后一次备份之后的修改。各类型限制详见[工作节点](../worker-management/)。

计划内跨主机迁移时，先停止所有写者并完成最后一次覆盖主库、Base 分片库、文件存储与 Agent Home 的一致备份。恢复演练应在隔离资源上完整复现上述步骤并验证端到端用户路径，同时记录实际恢复点（RPO）与耗时（RTO）。省略 Base 分片库、Home 或加密密钥的演练不能证明具备完整恢复能力。
