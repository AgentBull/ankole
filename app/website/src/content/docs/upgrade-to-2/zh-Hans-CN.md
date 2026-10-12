---
title: 从 1.0 升级到 2.0
description: 将 1.x 站点迁到 2.0，完成数据库、独享 Worker、Agent Home 和控制面云盘迁移，并验证恢复路径。
section: Guides
order: 313
---

本指南适用于从 1.0 及后续 1.x 版本升级到 2.0 的自托管站点。升级需要维护窗口：先停止旧版本的全部写者，再运行新版本的迁移。数据库迁移不能通过切换镜像撤销。

仓库的 Compose 升级测试以最后一个池化 Worker 版本 `v1.6.18-rc.1` 为起点。更早的 1.x 版本、自定义部署和修改过的 schema，应先用备份在隔离环境演练相同流程；这项测试不代表所有 1.x 起点都已验证。

## 升级后改变什么

| 1.x 中的旧布局 | 2.0 中的布局 | 运维操作 |
| --- | --- | --- |
| 池化 Worker、共享 `/agents` | 每个 Agent 一台 Worker，独享 `/workspace` | 迁移或接管旧 Home，并指派 WorkerProvider |
| Home 中的已安装 Skill 与 Automation 脚本 | 控制面云盘中的 `skills/` 与 `automation/` | 执行一次文件导入 |
| Worker 临时 Codex 状态 | `/workspace/.codex` 保存线程，`/var/cache/ankole/codex` 保存可重建缓存 | 保留 Home，另配缓存盘 |
| 无租户的数据与配置 | 原数据归入 `default` 租户，站点配置与租户配置分开 | 运行数据库和加密配置迁移，保留原密钥 |

已经采用独享 Worker 或云盘的 1.x 站点，只需执行仍适用的迁移步骤。不要把已有 Home 或云盘替换成空存储。

## 升级前准备

1. 记录当前版本、目标 2.0 版本、镜像 digest、Compose project 或 Helm release 名称、安装标识、卷/PVC 名称和 provider 配置。控制面与 Worker 必须来自同一源码 revision；官方控制面镜像自带匹配的 Worker 引用。
2. 保留原 `ANKOLE_SECRET_BASE`、数据库凭据和部署配置。新部署还需要独立的 `RELEASE_COOKIE`。不要在升级时重新生成 `ANKOLE_SECRET_BASE`，它用于解密已有凭据和配置。
3. 在旧 Console 检查是否有自建的 `siteadmin` 组；如有，先重命名。2.0 保留这个名称，冲突会中止迁移。
4. 停止新请求和定时工作，禁用 Agent，等待现有工作结束。正常停止全部旧 Worker，包括暂停的实例，再停止所有旧控制面副本。不要通过删除 Agent 来停止 Worker。
5. 一起备份 PostgreSQL、已有文件存储、全部 Agent Home 和部署密钥，并验证备份可恢复。Compose 复制旧 Home 需要额外预留至少与旧卷已用空间相同的容量。完整流程见 [备份与还原](../backup-and-restore/)。

目标版本的迁移还会重新加密租户身份提供方配置，拆分旧 Slack/Teams 共享配置，并解析平台应用身份。迁移环境需要原密钥、有效的平台凭据和对应平台的网络访问。失败时按日志修复配置后重试，不要复制密文到新的 scope。

## Docker Compose 升级

使用目标版本的 [Compose 部署文件](https://github.com/AgentBull/ankole/tree/main/tools/deploy/docker-compose)，包括 `compose.yaml`、`worker-providers.yaml` 和 `migrate-agent-homes.sh`。保留原 `.env` 和 project 名称，将 `ANKOLE_CONTROL_PLANE_IMAGE` 固定为目标版本的 digest。配置 `ANKOLE_DOCKER_GID`，保持原 `ANKOLE_WORKER_INSTALLATION`。

下例使用官方 `fs` 配置。使用 S3 时按 [云盘存储配置](../drive-storage/)准备 override，并在所有 Compose 命令（包括文件导入）中使用同一组 `-f` 参数。

如果 `.env` 还没有 `RELEASE_COOKIE`，补入：

```sh
printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >> .env
```

首次导入的 provider 必须带 `legacy_agents: true`，且其 `provider_id` 与 Home 迁移服务的 `WORKER_PROVIDER` 一致；官方文件均使用 `docker`。种子只在 provider 表为空时导入，之后修改 YAML 文件不会更新数据库中的 provider。

当前部署包使用 `pg_search` 0.25.11。下面的扩展升级命令适用于已安装 `pg_search`、PostgreSQL 主版本兼容的数据库；主版本不同的数据库应先完成对应的数据库升级。

```sh
docker compose pull
docker compose stop
docker compose up -d postgresql
docker compose exec postgresql psql -U ankole -d ankole -v ON_ERROR_STOP=1 \
  -c "ALTER EXTENSION pg_search UPDATE TO '0.25.11'"
docker compose up -d --force-recreate
docker compose ps -a migrate migrate-agent-homes
docker compose logs migrate migrate-agent-homes
```

`migrate` 运行 schema 与配置数据迁移。`migrate-agent-homes` 停止挂载旧共享卷的容器，把仍存在的 Agent Home 复制到独享卷并修正为 uid 1000。两个服务均成功退出后，控制面才会启动。复制有完成标记，失败后重试不会覆盖已完成的目录。不存在旧卷时，Home 迁移直接完成。

保持 Agent 禁用。若旧版本没有云盘，先允许导入进程读取旧卷，再导入文件。下例使用默认 project 名称；自定义名称时把 `ankole_agents_data` 换成原旧卷：

```sh
docker compose run --rm --no-deps --user root --entrypoint chmod \
  -v ankole_agents_data:/agents control-plane -R a+rX /agents
docker compose run --rm --no-deps -v ankole_agents_data:/agents:ro control-plane \
  /app/bin/ankole eval 'Ankole.Release.import_agent_home("/agents")'
```

导入复制已安装 Skill、Automation 脚本和未发送的旧 Outbox 附件，不覆盖云盘已有路径。普通用户文件、Session 和 Job 工作区继续保留在 Home。保存导入报告；处理 `Skipped` 和缺少 `main.ts` 的 Job 后再次导入。旧卷保留到文件核验和恢复演练通过。

## Kubernetes / Helm 升级

1. 将旧控制面和池化 Worker Deployment 缩容到零，等待全部旧 Pod 消失。不要强制删除 Pod 或使用 `--grace-period=0`。
2. 保留旧共享 Agent Home PVC。将 `worker.agents.persistence.existingClaim` 指向它，保持原 `worker.installation` 和 release 名称。若旧数据库在卷根目录，保留原 `postgresql.pgdata`，不要采用新目录导致数据库看似为空。
3. 准备旧 Home 的属主和权限，再启动新控制面。下例适用于 Pod root 能执行 `chown` 的存储；把 `OLD_AGENTS_PVC` 换成实际名称。

```sh
kubectl -n ankole run ankole-agent-home-prepare --rm -i --restart=Never \
  --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{
    "containers":[{"name":"prepare","image":"busybox:1.37",
      "securityContext":{"runAsUser":0},
      "command":["sh","-ec","chown -R 1000:1000 /agents; chmod 2777 /agents; chmod -R a+rX /agents"],
      "volumeMounts":[{"name":"agents","mountPath":"/agents"}]}],
    "volumes":[{"name":"agents","persistentVolumeClaim":{"claimName":"OLD_AGENTS_PVC"}}]}}'
```

默认 root-squash NFS 不能从 Pod 执行这项 `chown`。需要在 NFS 服务器上准备文件，并提供支持 Worker root 写入和改属主的挂载，或将全部访问映射到 uid/gid 1000。通过 uid/gid 1000 接入点访问 EFS 时，已有文件无需这项属主转换。详见 [WorkerProvider 与缓存盘](../worker-providers/)。

在 `values-production.yaml` 中设置目标控制面 digest、[云盘后端](../drive-storage/)和上述旧 PVC，再执行：

命令示例使用 namespace 和 release 名称 `ankole`，并假设 `fullnameOverride: ankole`。

```sh
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole --values values-production.yaml \
  --set files.importAgentHomeClaim=OLD_AGENTS_PVC --wait --timeout 15m
kubectl -n ankole exec deployment/ankole-control-plane -c control-plane -- \
  /app/bin/ankole eval 'Ankole.Release.import_agent_home("/agents")'
```

Deployment 使用 `Recreate`，新 Pod 的 `db-migrate` init container 先运行迁移。保持 Agent 禁用直到导入完成。核验报告后，移除 `files.importAgentHomeClaim` 再升级一次；Worker 仍需要使用旧 Home PVC，不要移除它。自定义 release、namespace 或 Deployment 名称时调整命令。完整参数见 [Helm 部署说明](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.zh-Hans.md)。

## 验证与失败恢复

- 在 Console 确认 `default` 租户中的原 Agent、身份提供方、信号绑定和 Job。已有 Agent 的 WorkerProvider 必须已指派；默认 provider 只决定新 Agent 的选择。
- 启用一个 Agent，执行真实的文件读写和 Job。检查原 Home 文件、Codex 线程恢复、导入的 Skill 和 Automation 脚本，以及云盘上传、下载和附件发送，再恢复其他 Agent 与定时工作。
- 迁移失败时保持旧控制面停止，读取 Compose `migrate` 或 Kubernetes `db-migrate` 日志。修复日志指出的密钥、凭据、名称冲突或存储权限后，重试相同版本的迁移。
- 导入报告会列出已删除 Agent 遗留的目录；不会给它们创建新 Agent。确认不再需要这些文件后才清理旧目录或旧卷。
- 回滚需要停止所有新控制面与 Worker，并一起恢复升级前数据库、文件存储、Home、配置和原密钥，再启动对应旧镜像。`helm rollback` 或切换镜像不能撤销数据迁移，也不能保留未另行导出的升级后写入。

后续运维见 [工作节点](../worker-management/)、[云盘存储配置](../drive-storage/)和 [灾难恢复](../disaster-recovery/)。
