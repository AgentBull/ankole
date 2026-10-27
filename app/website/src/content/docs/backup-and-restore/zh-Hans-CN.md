---
title: 备份与还原
description: 完整备份并验证 PostgreSQL、文件对象存储、Agent 持久 Home 与部署主密钥。
section: Guides
order: 315
---

一次完整有效的备份必须同时涵盖以下四部分：PostgreSQL（包含控制面数据库以及 `BASE_DB_URLS` 配置的全部物理 Base 分片数据库）、对象存储（控制面文件存储）、每个 Agent 的持久 Home 目录，以及单独保存在密钥管理系统中的部署配置与主密钥。其中，Worker 容器实例、`ankole-function-runtime` 服务和 `/var/cache/ankole` 本地缓存均可随时重建，而数据库、对象存储与持久 Home 则必须通过备份还原。

## 备份内容

| 数据类别 | 包含内容 | 备份方式与来源 |
|---|---|---|
| 控制面 PostgreSQL | 主体身份、Session、后台 Job、Pod 元数据与文档、Provider 配置、加密凭据、generation 标识与存储引用 | 执行 `pg_dump -Fc` 或启用时间点恢复（PITR） |
| 物理 Base 分片库（`BASE_DB_URLS`） | 各租户物理 Base 表的行数据（未配置 `BASE_DB_URLS` 的单库部署中，Base 表直接位于控制面库内，单次 `pg_dump` 即可一并原子导出） | 对每个分片数据库分别执行 `pg_dump -Fc` 或启用 PITR |
| 对象存储（文件存储） | Pod `file` 页面、Pod 与会话附件、编译后的 Applet 产物包、Agent 发布的文件、已安装 Skill 及 Automation 脚本 | Docker Compose 的 `files_data` 卷、Kubernetes 文件存储 PVC 或 S3 兼容存储桶 |
| Agent Home | 工作区文件、用户自行安装的软件、`/workspace/.codex` 下的线程文件 | 各 Worker Provider 对应的独享数据卷、共享目录、云盘、EFS 或 Cloudflare R2 备份 |
| 部署配置与密钥 | `ANKOLE_SECRET_BASE`、`ANKOLE_FUNCTION_RUNTIME_TOKEN`、`BASE_DB_URLS` 及其他启动凭据 | 独立的企业密钥管理系统 |

请注意，容器镜像与 `/var/cache/ankole` 属于可丢弃重建的缓存，但 Agent Home 绝非缓存。使用 Docker 本地卷存放 Home 时，数据绑定在单台宿主机磁盘上，备份后务必异机拷贝留存；使用 Cloudflare 后端时，数据库备份中必须包含与 R2 快照对应的最新 `storage_ref`，若强制杀停实例，可能会丢失最近一次 R2 同步之后的增量写入。

## 取得一致备份

按以下停机静默顺序执行，可获得严格一致的全量快照：

1. 暂停外部流量入口与定时调度任务，在控制台中停用各 Agent，等待在途任务自然收尾。在接下来关闭 Worker 的过程中，**请保持控制面进程处于运行状态**。
2. 调用各计算平台的正常停机或销毁接口关闭所有 Worker 实例（含处于暂停状态的实例）。切勿使用 `docker kill` 强制杀容器、切勿在 Kubernetes 中使用 `--grace-period=0` 强制删除 Pod，也不要在控制台中删除 Agent。等待控制面观测到所有实例均已退出并将最新的存储引用落盘（Cloudflare 后端须确认目录备份已同步完成）；若仍有未结清的实例创建请求，须等其收敛完毕后再进入下一步。
3. 停止控制面服务。注意：仅停止控制面并不会自动终止由外部平台独立托管的 Worker 实例，因此在进入下一步前，请再次确认没有任何残留的 Worker 进程仍在向 Home 目录写入数据。
4. 保持 PostgreSQL 运行并导出数据库：单库部署（未设置 `BASE_DB_URLS`）只需执行一次 `pg_dump` 即可原子导出控制面与 Base 表；多分片部署（设置了 `BASE_DB_URLS`）则须同时备份控制面数据库与每一个物理 Base 分片库。趁所有写入进程均已停止，同步备份对象存储与全部 Agent 的持久 Home，完整保留原有卷名、分片标识、Provider 配置、Agent UID、文件属主（uid 1000）及目录权限。
5. 备份完成后，重新启动控制面、启用各 Agent，并抽查已知的 Home 工作区文件与云盘文件是否正常可读。

Docker Compose 环境下的数据库导出命令示例：

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc > ankole-backup.dump
```

数据卷与对象存储桶请分别采用对应底层存储原生的快照或同步工具完成备份。每次版本升级或执行有破坏风险的运维变更前，都应先留存一份完整备份——仅将容器镜像回退到旧版本并不能回滚已经执行的数据库迁移。

## 恢复与验证

执行恢复期间，请确保所有控制面节点与 Worker 实例均处于停止状态。首先在目标 PostgreSQL 实例上还原控制面数据库：

```bash
docker compose exec -T postgresql \
  pg_restore -U ankole -d ankole --clean --if-exists < ankole-backup.dump
```

若部署配置了 `BASE_DB_URLS`，请一并还原每一个物理 Base 分片数据库。对多分片部署执行时间点恢复（PITR）时，**每个 Base 分片数据库的恢复目标时间戳都必须晚于或等于（`>=`）控制面数据库的恢复目标时间戳**，以防控制面元数据引用尚不存在的分片表结构或行记录。

在重新拉起控制面之前，先将配套的对象存储、全部持久 Home、Worker Provider 存储位置、`BASE_DB_URLS`、`ANKOLE_FUNCTION_RUNTIME_TOKEN` 以及原环境的 `ANKOLE_SECRET_BASE` 全部就位。`ANKOLE_SECRET_BASE` 用于解密数据库中保存的各类 Provider 密钥及未结清 generation 的重试凭据——切勿重新生成一把新密钥来凑数，否则已加密的凭据将全部无法解密。

持久 Home 必须严格按原有存储路径布局还原，并保持 `uid 1000` 文件属主不变。还原过程中不支持为已有 Agent 更换 Worker Provider，也不得改动 Provider 的存储路径与持久化存储键；如需迁移底层存储架构，必须另行制定专项数据迁移方案。

开展灾备恢复演练时，务必将演练环境还原出的计算与存储资源同生产环境彻底隔离，严禁让两套独立的控制面同时接管同一个 Agent 的底层存储；遇到状态未明的平台实例时，也切勿通过手工清空数据库中的 generation 字段来强行绕过安全栅栏。

系统拉起后，请逐项核验：已知的工作区文件是否完好、控制面云盘文件能否正常下载、后台 Agent 任务能否从持久 Home 断点续跑，以及发起一轮真实对话能否正常回复。每当调整底层存储布局或更新备份脚本后，都应重新跑通一次完整的恢复演练。更多故障处置细节请参阅[灾难恢复](../disaster-recovery/)与[工作节点](../worker-management/)。
