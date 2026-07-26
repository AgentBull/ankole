---
title: 备份与还原
description: 必须备份的两样——PostgreSQL 和 Agent Home——如何备份、如何还原，以及为什么未经测试的备份不算备份。
section: Guides
order: 315
---

一套 Ankole 部署持有两样你无法重建的东西：PostgreSQL 数据库（全部持久控制面状态——Principal、agent、session、Brain 知识、任务、审计）和 Agent Home 卷（按 agent 的工作空间、人设文档、已安装 skill、session 与任务文件）。其余都是可重建的镜像或可重新派生的投影。本页是如何备份这两样、如何还原它们，以及让一份备份成为真实备份的那条规则。

先把决定性的性质说清楚：数据库 migration 无法通过回滚镜像来撤销。未经还原测试的备份是期望，不是备份。本页的全部要点是还原这一步——在事故依赖它之前，先在单独主机上测它。

## 备份什么，不备份什么

| 备份 | 为什么 | 怎么做 |
|---|---|---|
| **PostgreSQL**（Compose 上的 `ankole_postgresql_data`；Helm 上的外部服务器） | 全部持久语义事实 | `pg_dump -Fc` 归档 |
| **Agent Home**（Compose 上的 `ankole_agents_data`；Helm 上的 RWX PVC） | 按 agent 的工作空间、人设文档、已安装 skill、session/任务文件 | 卷快照或文件系统级备份，在 Ankole 停止时做 |

**不要**备份容器镜像——它们可从 registry 重建。不要备份 Caddy 数据或临时 worker 状态；两者都不持有你无法重建的东西。也**不要**只备份两者之一——PostgreSQL 引用 Agent Home 里的文件，而没有指向它的数据库行的 Agent Home 是孤儿。

## 备份 PostgreSQL

取自定义格式归档（还原步骤需要它）：

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

Helm 上用内置 PostgreSQL，`kubectl exec` 进 PostgreSQL pod 跑同样的 `pg_dump`。用外部 PostgreSQL，就在该服务器上跑 `pg_dump`——命令形态一致。

每次升级前、任何破坏性操作（`kit app-db rebuild`、`docker compose down -v`）前，以及按你对数据丢失容忍度所要求的节奏，都取这份备份。对小型部署，每日归档是合理的默认。

## 备份 Agent Home

Agent Home 是文件系统，不是数据库——在 Ankole **停止**时备份，这样没有 worker 在备份期间写它：

```bash
# Compose：快照命名卷，或在栈停时拷贝它
docker compose down
# 对 ankole_agents_data 做卷快照或文件系统级备份
docker compose up -d
```

Helm 上，Agent Home 是 RWX PVC；用你的 StorageClass 提供的快照机制。文件系统级拷贝（rsync、restic、云卷快照）都行，只要它一致——在某一刻取，不和写者赛跑。

停栈（或至少让 worker 静默）的原因是：worker 在备份中途写文件会产生撕裂副本。PostgreSQL 的 `pg_dump` 给你事务一致的归档；Agent Home 没有这种保证，所以你用时机来提供它。

## 还原 PostgreSQL

每次都先还原到单独主机。未经测试的还原是事故里你能拥有的最贵的东西。

```bash
# 在一台有全新 Ankole 数据库的测试主机上
docker compose exec -T postgresql \
  pg_restore -U ankole -d ankole --clean --if-exists \
  < "ankole-YYYYMMDD.dump"
```

然后跑 migration（本地 `bun run control-plane:setup`，或让 Helm init container 做），把 schema 带到镜像的版本——因为 migration 之前取的备份还原到 migration 之前的 schema。在宣布还原成功前确认数据——Principal、agent、一个已知的 Brain 条目——是你预期的。

## 还原 Agent Home

从你的快照把卷还原到同一路径（`/agents`，Compose 上挂载自 `ankole_agents_data`，Helm 上挂载自 RWX PVC）。目录结构按 agent-key，所以正确的还原精确重建 `/agents/<agent-key>/...`。把它和数据库还原配对——数据库行引用 Agent Home 下的文件，不匹配的一对会产生一个看起来活着、却指向缺失或陈旧文件的部署。

## 一起测试这对

README 的指示就是规则："在单独主机上一起测试数据库和 Agent Home 的还原。"两者是一对；只还原一个证明不了什么。每月一次在一台随手主机上——还原昨晚的 PostgreSQL 和 Agent Home、启动栈、跑一个真实回合——是"备份"与"期望"之间的差别。

若还原在测试主机上奏效，你的生产备份是真实的。若不奏效，你在测试主机上发现，不是在事故中。

## 备份不是可选的几种情况

有些操作让备份成为强制，不是建议：

- **每次升级**——migration 不可逆；备份是你 schema 回滚的唯一路径。见[升级](../updating/)。
- **`kit app-db rebuild --yes`**——删除本地 `ankole_dev` 数据库。只在数据确实可丢弃时跑，若有任何要紧先备份。
- **`docker compose down -v`**——删除命名卷，包括 PostgreSQL 和 Agent Home。这是删除，不是重启。
- **任何危害可能触及持久状态的事故**——见[事故响应](../incident-response/)。

## 本指南不是什么

它不是备份产品推荐——用你已有的卷快照、restic 或云快照工具。它不是还原测试的替代；还原这一步是全部要点。它也不是只备份你在意的部分的方式——PostgreSQL 和 Agent Home 是一对，部分备份还原出一个坏掉的部署。

## 下一步

- 需要这份备份的升级流程，读[升级](../updating/)。
- 假设这份备份的事故流程，读[事故响应](../incident-response/)。
- 命名这些卷的部署布局，读[安装部署指南](../installation/)。
