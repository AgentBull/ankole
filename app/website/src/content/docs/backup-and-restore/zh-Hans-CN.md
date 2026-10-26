---
title: 备份与还原
description: 一起备份和验证 PostgreSQL、文件存储、Agent 持久 Home 与部署密钥。
section: Guides
order: 315
---

备份必须同时覆盖 PostgreSQL（控制面数据库及 `BASE_DB_URLS` 中的所有物理 Base 分片数据库）、对象存储（控制面的文件存储），以及每个 Agent 的持久 Home。部署配置与密钥另存于密钥管理系统。Worker 实例、`ankole-function-runtime` 和 `/var/cache/ankole` 缓存可以重建，持久 Home 与数据库必须恢复。

## 备份内容

| 数据 | 内容 | 备份来源 |
|---|---|---|
| 控制面 PostgreSQL | 主体、Session、Job、Pod 元数据与文档、provider 配置、加密凭据、generation 与存储引用 | `pg_dump -Fc` 或 PITR |
| 物理 Base 分片库（`BASE_DB_URLS`） | 租户物理 Base 表行数据（未设置 `BASE_DB_URLS` 的单库 FOSS 部署中，Base 表位于控制面库内，一次原子 `pg_dump` 即可同时备份） | 对每个分片数据库执行 `pg_dump -Fc` 或 PITR |
| 对象存储（文件存储） | Pod `file` 页面、Pod 与会话附件、编译后的 Applet 产物包、发布的文件、已安装 Skill、Automation 脚本 | Compose `files_data`、文件存储 PVC 或 S3 桶 |
| Agent Home | 工作区、用户软件、`/workspace/.codex` 中的线程 | provider 的独享卷、共享目录、Drive、EFS 或 Cloudflare R2 备份 |
| 部署配置与密钥 | `ANKOLE_SECRET_BASE`、`ANKOLE_FUNCTION_RUNTIME_TOKEN`、`BASE_DB_URLS` 与其他启动凭据 | 独立的密钥管理系统 |

`/var/cache/ankole` 和容器镜像可以重建，Home 不是缓存。Docker Home 卷依赖宿主机，备份要复制到其他机器。Cloudflare 的数据库备份必须包含对应 R2 备份的 `storage_ref`；强制停止可能丢失上次备份之后的写入。

## 取得一致备份

1. 停止新请求与定时工作，禁用 Agent，等待正在进行的工作结束。关闭 Worker 期间保持控制面运行。
2. 通过各平台的正常停止或删除操作结束 Worker 实例，包括暂停中的实例。不要强制删除容器、使用 Kubernetes 宽限 0，也不要删除 Agent。等待控制面观察到实例消失并保存当前存储引用；Cloudflare 必须确认目录备份完成。尚未结清的创建请求需要先收敛，才能继续本流程。
3. 停止控制面。仅停止控制面不会结束单独管理的 Worker；确认没有 Worker 还能写 Home。
4. 保持 PostgreSQL 运行，导出数据库。单库部署（未设置 `BASE_DB_URLS`）通过一次 `pg_dump` 原子导出控制面与 Base 表；多分片部署（设置了 `BASE_DB_URLS`）必须同时备份控制面数据库与每一个物理 Base 分片数据库。所有写者停止期间，备份对象存储与全部持久 Home，保留卷名、分片标识、provider 配置、Agent UID、属主与权限。
5. 启动控制面、启用 Agent，验证已知的 Home 文件和云盘文件。

Compose 的数据库备份命令：

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc > ankole-backup.dump
```

卷与桶使用各自存储系统的备份机制。升级与破坏性维护之前都要备份；切换旧镜像不能撤销数据库迁移。

## 恢复与验证

恢复期间保持所有控制面与 Worker 停止。在目标数据库执行：

```bash
docker compose exec -T postgresql \
  pg_restore -U ankole -d ankole --clean --if-exists < ankole-backup.dump
```

同时恢复 `BASE_DB_URLS` 中的每一个物理 Base 分片数据库。对多分片部署执行时间点恢复（PITR）时，每个 Base 分片数据库的恢复时间戳必须大于或等于（`>=`）控制面数据库的恢复时间戳，确保控制面元数据不会引用缺失的分片表结构或行。

启动控制面之前，恢复配套的对象存储、持久 Home、provider 位置、`BASE_DB_URLS`、`ANKOLE_FUNCTION_RUNTIME_TOKEN` 与原 `ANKOLE_SECRET_BASE`。`ANKOLE_SECRET_BASE` 用于解密 provider 凭据及未结清 generation 的重试凭据，重新生成密钥不能替代完整恢复。

按原存储布局恢复，保留 uid 1000 属主。Agent 不能更换 provider，provider 的位置与持久存储键也不可修改。换存储布局需要单独的迁移方案。

恢复演练必须将还原的平台资源与生产隔离，不能让两个独立控制面管理同一个 Agent 的存储。不要通过清空 generation 绕过不确定的平台结果。

验证已知工作区文件、云盘文件、Background Job 从 Home 恢复，以及一次真实回合。存储布局或备份流程变化后，重新做恢复演练。参见[灾难恢复](../disaster-recovery/)与[工作节点](../worker-management/)。
