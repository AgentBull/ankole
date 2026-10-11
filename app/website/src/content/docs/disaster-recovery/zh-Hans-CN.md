---
title: 灾难恢复
description: 恢复 Ankole 实例，包括可恢复数据、不可恢复数据、跨主机迁移和恢复演练。
section: Guides
order: 320
---

恢复的是同一个部署的 PostgreSQL、文件存储、Agent 持久 Home 与原部署密钥。[备份指南](../backup-and-restore/)说明需要保留的数据和一致备份流程。

## 恢复前

确认旧控制面和 Worker 都不能写恢复后的 Home。连接断开不能证明 Worker 已停止；暂停实例、结果未知的创建请求也要算在内。PostgreSQL 中未结清的 generation 与凭据必须保留，恢复后仍重试同一代，直到平台给出确定结果。

演练使用隔离的平台资源。复制数据库后仍指向生产 provider 位置，会操作生产实例。Ankole 不提供 provider 之间或存储布局之间的自动迁移。

## 恢复流程

1. 准备替代基础设施，保持控制面停止，保留 provider 位置与持久存储布局。Docker Home 卷必须先恢复，不能让控制面先建出空卷。
2. 恢复 PostgreSQL、配套文件存储与全部持久 Home。命令与顺序见[备份与还原](../backup-and-restore/)。保留 Agent UID、卷名、属主与权限。
3. 从密钥管理系统恢复原 `ANKOLE_SECRET_BASE`。它用于解密 provider 密钥及未结清 generation 的凭据。若密钥已丢失，先制定单独的凭据恢复方案；只重新输入 provider 凭据不能恢复 generation 凭据。
4. 配置其他启动密钥与地址后启动控制面，让正常协调流程检查平台真实状态。不要清空 generation 或实例引用来改变显示状态。不确定的平台结果仍停在 `starting` 或 `deleting`，原因记录在 `last_error`。
5. 启用已恢复的 Agent，读取已知 Home 文件与云盘文件，恢复一个 Background Job，执行一次真实回合。切换流量前再次确认旧部署保持停止。

## 恢复边界

PostgreSQL 恢复持久工作状态，Home 恢复工作区与 Codex 线程文件，SQLite 缓存可以重建。备份之后的文件修改不在恢复点内；Home 备份不包含进程内存和正在进行的模型请求。

Docker 本地卷在宿主丢失后需要外部备份。Cloudflare 需要 R2 备份及数据库中的引用；强制停止可能丢失该备份之后的修改。各类型限制见[工作节点](../worker-management/)。

计划迁移主机时，先停止写者并做最后一次一致备份。恢复演练使用隔离资源，按相同流程验证用户路径，并记录实际恢复点和耗时。省略 Home 或加密密钥的演练不能证明完整恢复。
