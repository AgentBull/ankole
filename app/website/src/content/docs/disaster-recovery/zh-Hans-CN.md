---
title: 灾难恢复
description: 从丢失中恢复一套 Ankole 部署的完整形态——什么可恢复、什么不可、跨主机迁移、让恢复成为真实能力的演练。
section: Guides
order: 320
---

灾难恢复是当部署没了——主机死了、集群丢了、卷毁了——你需要在别处把它带回来时做的事。它不是事故（系统不是行为异常，是缺席），也不是升级（没有东西要往前滚）。本页是端到端恢复形态，建立在其它指南覆盖的备份纪律与迁移机制之上。

先把决定性的性质说清楚：恢复是*在一个全新部署上还原*，不是修旧的。你从零部署 Ankole、从备份还原 PostgreSQL 和 Agent Home、重输入引导 secret。你恢复的恰是你备份的——不多不少——而未经演练的恢复是计划，不是能力。

## 什么可恢复，什么不可

| 状态 | 可恢复？ | 从什么 |
|---|---|---|
| Principal、agent、session、任务、Brain 知识、审计、AuthZ 授予 | 是 | PostgreSQL `pg_dump` 归档 |
| 按 agent 的工作空间、人设文档、已安装 skill、session/任务文件 | 是 | Agent Home 卷快照 |
| Provider 凭证、adapter secret、WorkerEnv secret | 是 | 它们住在 PostgreSQL 和 Agent Home 里——随之还原 |
| 引导 secret（`ANKOLE_SECRET_BASE`、worker 认证 key） | **手工重输入** | 它们不在备份里；生成新的或复用记录的 |
| 进行中的回合、运行中的后台任务、live worker 状态 | **否** | 临时；随进程丢失 |
| 从未发往外部摄入器的日志 | **否** | 住在丢失的主机上 |

引导 secret 那一行让人意外：派生其它密钥的 secret 是部署时输入，不是 PostgreSQL 状态，所以不在 `pg_dump` 里。把它们存在你的 secret 管理器里（不在部署备份里，而是与之并列），或重新生成并接受派生密钥变化。

## 恢复流程

### 第 1 步：从零部署 Ankole

在新主机或集群上按[安装部署](../installation/)起一套新部署。**不要**试图把新部署接到旧主机的卷或数据库——旧的正是你要从中恢复的东西，半接的部署比全新的更糟。用新数据库、新 Agent Home 卷、新引导 secret（或记录的旧的——见第 4 步）。

### 第 2 步：还原 PostgreSQL

在真正启动控制面之前，从归档还原数据库：

```bash
# 在全新部署上，控制面停止或处于 setup 模式
docker compose exec -T postgresql \
  pg_restore -U ankole -d ankole --clean --if-exists \
  < "ankole-YYYYMMDD.dump"
```

然后跑 migration（本地 `bun run control-plane:setup`，或让 Helm init container 做），把还原的 schema 带到镜像版本。还原的数据库持有备份那一刻的 Principal、agent、session、任务、Brain 知识、AuthZ 授予。

### 第 3 步：还原 Agent Home

从快照还原 `ankole_agents_data` 卷（或 Helm 上的 RWX PVC）到同一 `/agents` 挂载路径。按 agent-key 的目录结构精确重建 `/agents/<agent-key>/...`。把它与 PostgreSQL 还原配对——数据库行引用 Agent Home 下的文件，不匹配的一对产生看起来活着却指向缺失文件的部署。

### 第 4 步：处理引导 secret

引导 secret（`ANKOLE_SECRET_BASE`、`ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`、`POSTGRES_PASSWORD`）不在备份里。两条路径：

- **复用记录的**——如果你把它们存在一个 secret 管理器里、与部署备份并列（不在其内），重输入它们。还原的 PostgreSQL 里的加密行正确解密，因为派生密钥相同。
- **重新生成**——在 `.env`（Compose）或 Secret（Helm）里生成新的。还原的 PostgreSQL 完整，但从旧 `ANKOLE_SECRET_BASE` 派生的加密值（adapter secret、WorkerEnv secret）无法解密。恢复后你需要通过 Console 重输入那些凭证。

复用更简单且保留 secret；若旧 secret 可能在灾难中被入侵，重新生成更安全。选匹配你为何恢复的路径。

### 第 5 步：重输入不在备份里的东西

还原后，走一遍配置界面，确认每一项完整：

- **Provider 与 model profile**——住在 PostgreSQL，已还原。
- **Signal binding**——住在 PostgreSQL，已还原；但它们引用的 adapter 凭证若你在第 4 步重新生成了 `ANKOLE_SECRET_BASE`，可能需要重输入。
- **Identity provider**——同上：行还原了，凭证可能需要重输入。
- **Control Plane Plugin 启用清单**——已还原，但下次进程启动生效。

通过一个 binding 发一个真实回合，确认端到端路径在新部署上工作。

## 跨主机迁移（计划版本）

到新主机的计划迁移是同一流程，刻意做：

1. 停旧部署（让 worker 静默、停写）。
2. 取最终 PostgreSQL 备份和 Agent Home 快照——这些是迁移的事实来源。
3. 在新主机全新部署、还原这对、处理引导 secret。
4. 在新主机用一个真实回合验证。
5. 把 DNS（或负载均衡器）切到新主机；确认后旧的可下线。

与灾难恢复的差异是"停旧部署"这一步——灾难里旧部署自己停了，你有的备份是那之前的。取最终备份尽量接近切换，以最小化差距。

## 演练

未经演练的恢复是计划，不是能力。演练是本指南单一最高杠杆的事：

- **每月一次，在随手主机上**，还原昨晚的 PostgreSQL 和 Agent Home、部署镜像、跑一个真实回合。若还原奏效，你的恢复是真实的。若不奏效，你在随手主机上发现，不在灾难中。
- **包含引导 secret 步骤。** 跳过它的演练没测那个让人意外的部分。要么复用记录的 secret，要么重新生成并重输入凭证——做你真正会做的那一个。
- **换主机。** 每次还原到同一主机测的是备份，不是恢复。定期还原到不同主机（不同 OS、不同云），因为那正是灾难给你的。

## 与其它指南的关系

- [备份与还原](../backup-and-restore/)是让恢复可能的纪律——备份是来源。
- [事故响应](../incident-response/)针对系统行为异常、不是缺席；它的遏制动作不是本页的关注。
- [升级](../updating/)是往前移的受控版本；灾难恢复是往后移的不受控版本。
- [安全加固](../security-hardening/)假设你会还原的备份经过测试——本页是那个测试。

## 本指南不是什么

它不是无数据丢失的保证——不在备份里的都没了，进行中的工作总是临时的。它不是演练的替代；演练是全部要点。它也不是单一命令——恢复是全新部署+还原这对+secret，每步有自己的验证。为省时间跳步是恢复产出坏部署的方式。

## 下一步

- 恢复所依赖的备份纪律，读[备份与还原](../backup-and-restore/)。
- 全新部署步骤，读[安装部署](../installation/)。
- 事故情形（系统行为异常、不是缺席），读[事故响应](../incident-response/)。
