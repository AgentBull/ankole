---
title: 升级
description: 如何升级一套 Ankole 部署——把镜像固定到 digest，备份 PostgreSQL 和 Agent Home，然后用 Compose 或 Helm 向前滚动。数据库 migration 不可回滚。
section: Getting started
order: 6
---

一次 Ankole 升级是先镜像滚动、再数据库 migration，前面还要有备份。本页是两种受支持部署目标的升级流程，以及让一次升级可恢复的那条规则：**先备份 PostgreSQL 和 Agent Home，因为数据库 migration 无法通过回滚镜像来撤销。**

先把决定性的性质说清楚：控制面和 worker 的 tag 一起移动，并且只在发布工作流验证 RuntimeFabric 镜像对成功之后才移动。受控生产发布，把两个镜像固定到同一已验证对的 digest。回滚到旧镜像不会撤销 migration；若旧应用也需要旧 schema，你恢复的是数据库备份。

## 升级前：备份

每次都做，每种部署目标都做。跳过备份会把一次失败的升级变成数据丢失。

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

用卷快照或文件系统级备份来备份 `ankole_agents_data` 卷（Agent Home），并在 Ankole 停止时进行。PostgreSQL 数据住在 `ankole_postgresql_data`。在单独的主机上一起测试数据库和 Agent Home 的还原，再依赖它们——未经测试的备份不是备份。

## 受控发布：固定镜像

默认镜像是会移动的 `main-latest` tag：

```text
ghcr.io/agentbull/ankole-agent-control-plane:main-latest
ghcr.io/agentbull/ankole-agent-computer-worker:main-latest
ghcr.io/agentbull/ankole-postgres-for-ankole:main-latest
```

`main-latest` 跟随最近一次成功的发布。受控生产升级时，不要跟着会移动的 tag 走。把两个 Ankole 镜像都固定到同一已验证对的 digest——控制面和 worker 一起动，否则都不该动。

### Compose

在 `.env` 里设固定到 digest 的镜像：

```bash
ANKOLE_CONTROL_PLANE_IMAGE=ghcr.io/agentbull/ankole-agent-control-plane@sha256:<digest>
ANKOLE_WORKER_IMAGE=ghcr.io/agentbull/ankole-agent-computer-worker@sha256:<digest>
ANKOLE_POSTGRESQL_IMAGE=ghcr.io/agentbull/ankole-postgres-for-ankole@sha256:<digest>
```

### Helm

在 `values-production.yaml` 里，在同一次修订里设两个 digest：

```yaml
controlPlane:
  image:
    digest: sha256:<control-plane-digest>

worker:
  image:
    digest: sha256:<worker-digest>
```

只改其中一个，会破坏发布工作流为之存在的“已验证对”保证。

## 升级 Compose 部署

单主机升级有一次短暂的服务中断。备份已做、镜像已固定（或接受 `main-latest`）：

```bash
docker compose pull
docker compose down
docker compose up -d --force-recreate
docker compose ps
```

`down` 保留所有命名卷，但在 migration 之前停止旧应用。新的启动在新的控制面启动之前，再次运行 migration 和 bootstrap 服务。当 `docker compose ps` 显示栈健康时，升级完成。

## 升级 Helm 部署

备份已做，两个 digest 已在 `values-production.yaml` 设好：

```bash
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

Chart 的 init container 运行 migration（创建所需的 PostgreSQL 扩展并应用每一个待执行的 Ecto migration），然后存储部署 worker key。控制面只在两者都成功后启动。`--wait` 让命令等到滚动可观测完成；`--timeout 15m` 限定等待多久。

## 什么可逆，什么不可逆

镜像滚动可逆；数据库 migration 不可逆。

- **回滚镜像**——重建之前的镜像。Compose：在 `.env` 固定旧 digest 并 `up -d --force-recreate`。Helm：在 `values-production.yaml` 设旧 digest 并再次 `helm upgrade`。
- **回滚数据库 migration**——不受支持。`helm rollback` 不会反向执行 Ecto migration，重建旧控制面镜像也不会。若旧应用需要旧 schema，恢复的是你升级前做的 PostgreSQL 备份。这就是为什么备份不是可选的。

Agent Home（`ankole_agents_data`）是可变的运行时状态，不被 migration——回滚不需要还原它，但还是要备份，因为新镜像里的一个 worker bug 可能写入它。

## 升级后验证

栈健康几分钟之后：

- 打开 Console，确认一个 agent 能跑通一个真实回合（一次模型调用能解析，一个 signal binding 能回复）；
- 检查 `/background-agent-jobs`，看重启后有没有任务卡在意外状态；
- 读控制面日志，看 init container 在启动时发出过什么 migration 警告。

升级后一次回合以 provider 或选择符错误失败，migration 很少是原因——按 [FAQ](../faq/) 从模型向外查。migration 形态的失败通常是 init container 日志在启动时的可见错误，而不是悄悄的运行时问题。

## 下一步

- 原始部署步骤，读[安装部署指南](../installation/)。
- 每个镜像里有什么，读[架构概览](../architecture/)。
- 升级所面向的平台要求，读[平台支持](../platform-support/)。
