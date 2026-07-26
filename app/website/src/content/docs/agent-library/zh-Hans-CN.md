---
title: Agent Library
description: 一个 agent 能做什么——skill 作为文件系统 bundle，Agent Plugin 作为 Codex 包，以及按 agent 解析的“默认再覆盖”启用模型。
section: Developer guide
order: 107
---

Agent Library 回答的是一个问题：这个 agent 实际上被允许做什么？它是一套部署自带的 skill 与 Agent Plugin 目录，加上决定其中哪些对某个 agent 开启的按 agent 状态。本页对照 `Ankole.AIAgent.Library` 里的真实代码，画出这套模型。

先把决定性的性质说清楚：skill 和 plugin 本身是文件系统 bundle，不是数据库行。PostgreSQL 持有启用状态、注册表语义和文件观察——是叠在部署范围默认值之上的、稀疏的按 agent 覆盖。字节和版本留在部署库中；数据库只记录谁把什么打开了。

## 两种能力

库持有两种相关但不相同的东西：

- **一个 Skill** 是一个文件系统 bundle，由一份 `SKILL.md` 标识。skill 名小写，以字母开头，只用字母、数字、`_` 和 `-`，最长 64 字符。一个 skill 要么是 `builtin`（随应用镜像发布，从 `app/library/skills` 同步），要么是 `installed`（agent 安装到 worker 可见的存储下）。`agent_skills` 行记录启用状态、来源种类、content hash 和同步时间——它明确不是一张文件内容表。
- **一个 Agent Plugin** 是一个标准的 Codex Plugin 包，加上 Ankole 可选的 `workspace-template/` 初始化目录。包的字节和版本留在部署库中；PostgreSQL 只存储稀疏的按 agent 启用覆盖。plugin 标识符遵循和 skill 名相同的格式规则。

两者相连：一个 Agent Plugin 可以带 skill，而 skill 行记录它的 `agent_plugin_id`，供父级启用和目录展示使用。但 Agent Plugin 成员只是独立的元数据——它不改变 skill 的加载方式。

## 启用：默认，再覆盖

一个 agent 的有效能力，是带着两层走过目录解析出来的：

1. **部署范围的默认值**——每个 skill 上的 `default_enabled`，以及运维者设定的全局 plugin 默认值。
2. **按 agent 的覆盖**——某条 skill 行上的 `enabled_override`，或限定到某一个 agent 的 Agent Plugin 覆盖。

解析结果就是能力端点返回的 `effective_enabled` 字段：取默认值，若存在覆盖则应用覆盖。没有覆盖的能力继承默认值；有覆盖的能力遵从覆盖。目录上限 256 个 plugin，所以解析保持廉价，界面保持清晰可读。

这就是 [Console](../console-api/) 的 Agent Library 能力路由所暴露的模型：先设全局默认值，再按 agent 收窄或放宽。

## 人设文档与 skill overlay

除了能力，库还持有 agent 自己的可写文档和 skill 定制：

- **agent 文档**是按 agent 播种的运行时文档——`mission`、`soul` 和 `design`，即容器表接受的三个 `source_kind`。它们住在 `agent_library_container_entries` 里，是 agent 拥有的、按内容寻址的行（每行一个 `content_hash`），并且是这张表所持有的唯一一种 agent 拥有的文件。
- **skill overlay** 是 `agent_skill_overlays` 里的语义行，每个 `(agent, skill)` 一条。它们让运维者为某一个 agent 定制某个 skill 的行为，而不必 fork 这个 skill bundle。一个 overlay 支持比较并交换（compare-and-swap）替换，所以并发编辑以确定的方式分出胜负。

一次 skill 视图读取该 skill 的文件，外加该 agent 对它的任何 overlay，于是 agent 看到的是一个连贯的 skill，而不是一个 bundle 外加一份单独的补丁。

## 同步：让注册表保持诚实

因为 skill 是文件系统 bundle，数据库注册表必须跟踪文件系统。两条同步路径做这件事：

- **`sync_builtin_skills`** 把 `app/library/skills` 树与 builtin skill 行对账，返回是否有变化、content hash 以及 skill 数和文件数。它从应用镜像运行，所以新镜像能在下一次同步时新增或更新 builtin skill。
- **`sync_agent_skills`** 把某个 agent 的已安装 skill 与 worker 可见存储的实际内容对账，而 `replace_installed_skill_observations` 写下观察到的文件集。从存储里消失的 skill 会反映到注册表；新出现的 skill 会被捡起来。

同步是“读取并对账”，不是“推送后祈祷”。`content_hash` 让同步幂等：同一棵树产出同一个 hash，只有真正的变化才写一行。

## 运维界面

[Console](../console-api/) 页里已经覆盖的路由驱动这套模型。尤其是能力路由：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/agent-library/capabilities` | 带默认值的全局目录 |
| `PUT` | `/agent-library/agent-plugins/:id` | 设定一个 plugin 的全局默认值 |
| `PUT` | `/agent-library/skills/:id` | 设定一个 skill 的全局默认值 |
| `GET` | `/agents/:agent_uid/library-capabilities` | 某个 agent 的有效能力 |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 为某一个 agent 覆盖一个 plugin |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | 为某一个 agent 覆盖一个 skill |
| `GET` | `/agents/:agent_uid/library-documents` | 列出该 agent 的 mission/soul/design |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | 设定一份文档 |
| `GET` | `/agents/:agent_uid/library-skill-overlays` | 列出 skill overlay |
| `PUT` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | 设定一个 skill overlay |
| `DELETE` | `/agents/:agent_uid/library-skill-overlays/:skill_name` | 移除一个 skill overlay |

读取 `/agents/:agent_uid/library-capabilities` 会触发一次 agent skill 同步，所以运维者看到的是注册表与当前存储对账后的结果——不是过期的快照。

## Agent Library 不是什么

它不是 marketplace，也不是热加载系统。skill 和 plugin 是受信任的第一方 bundle，随部署发布，或安装到 worker 可见的存储里；没有第三方发现，没有 worker 之外的额外隔离机制。数据库不是 skill 字节的来源——字节在文件系统上，注册表只跟踪它所见到的。库也不是定义模型工具的地方；它是运维者决定一个 agent 能把哪些能力带进一个回合的地方。从“已启用”跨到“真正被调用”，是 Agent Computer 在回合时刻的事。

## 下一步

- 配置库的路由，读 [Console](../console-api/)。
- 在一个回合中跑起一个已启用 skill 的 worker，读 [Actor Runtime](../actor-runtime/)。
- 库所绑定的 agent Principal，读 [Principal 与 AuthZ](../principal-authz/)。
