---
title: Agent Library
description: 一个 agent 能做什么——skill 作为文件系统 bundle，Agent Plugin 作为 Codex 包，以及按 agent 解析的“默认再覆盖”启用模型。
section: Developer guide
order: 107
---

Agent Library 回答一个问题：这个 Agent 实际可以使用哪些能力？它由实例内的 Skill 和 Agent Plugin 目录，以及每个 Agent 的启用状态组成。本页以 `Ankole.AIAgent.Library` 的实际代码为准说明这套模型。

Skill 和 Plugin 本身是文件系统中的 Bundle，不是数据库记录。PostgreSQL 保存启用状态、注册表语义和文件观察结果，并在实例级默认值之上记录每个 Agent 的少量覆盖。文件内容和版本留在实例的部署包中，数据库只记录哪些能力由谁启用。

## 两种能力

库持有两种相关但不相同的东西：

- **一个 Skill** 是一个文件系统 bundle，由一份 `SKILL.md` 标识。skill 名小写，以字母开头，只用字母、数字、`_` 和 `-`，最长 64 字符。一个 skill 要么是 `builtin`（随应用镜像发布，从 `app/library/skills` 同步），要么是 `installed`（agent 安装到 worker 可见的存储下）。`agent_skills` 行记录启用状态、来源种类、content hash 和同步时间——它明确不是一张文件内容表。
- **Agent Plugin** 是标准 Codex Plugin 包，可以附带 Ankole 的 `workspace-template/` 初始化目录。包的文件和版本留在实例的部署包中；PostgreSQL 只保存每个 Agent 的启用覆盖。Plugin 标识符与 Skill 名称使用相同的格式规则。

两者相连：一个 Agent Plugin 可以带 skill，而 skill 行记录它的 `agent_plugin_id`，供父级启用和目录展示使用。但 Agent Plugin 成员只是独立的元数据——它不改变 skill 的加载方式。

## 启用：默认，再覆盖

一个 agent 的有效能力，是带着两层走过目录解析出来的：

1. **实例级默认值**——每个 Skill 的 `default_enabled`，以及运维者设置的全局 Plugin 默认值。
2. **按 agent 的覆盖**——某条 skill 行上的 `enabled_override`，或限定到某一个 agent 的 Agent Plugin 覆盖。

解析结果就是能力端点返回的 `effective_enabled` 字段：取默认值，若存在覆盖则应用覆盖。没有覆盖的能力继承默认值；有覆盖的能力遵从覆盖。目录上限 256 个 plugin，所以解析开销很低，界面保持清晰可读。

这就是 [Console](../console-api/) 的 Agent Library 能力路由所暴露的模型：先设全局默认值，再按 agent 收窄或放宽。

## 只通过 Brain 召回的 Skill 发现

随产品发布的独立 Skill 或 Agent Plugin 成员 Skill 可以声明 `brain-recall-only: true`。所有随产品发布的 Skill 共用一个全局名称空间，Plugin 成员关系不会改变 Skill 名称。安装到 Agent 的 Skill 不参与这种模式。

Agent Library 会把完整的有效 Skill 集发送给 Worker。普通 Skill 进入模型可见的 Skill 目录；只通过 Brain 召回的 Skill 保留在 `skill_view` 可加载集合中，但不会进入该目录。Library sweep 只把它们的名称、描述和标签投影为 `lazyload-agent-skills/<skill-name>` 下的轻量 Brain 记录；Skill 正文、资源和 Agent 专属教训仍留在各自的文件与数据库所有者中。

投影由实例共享，不会因为某个 Agent 关闭 Skill 而删除。Brain 查询和 `skill_view` 都会应用该 Agent 当前的 Plugin 与 Skill 有效状态，因此已关闭的记录不会占用召回名额，也不能被加载。重新启用能力后会直接恢复已有投影。

## Agent 长期文档与技能教训

除了能力，库还持有 Agent 自己的可写文档和 Agent 专属的 Skill 指引：

- **Agent 长期文档**包括 `mission`、`soul`、`design` 和 `confidentiality_policy`，即容器表接受的四个 `source_kind`。前两项定义职责与行为，`design` 保存视觉内容使用的设计系统，`confidentiality_policy` 指导 Agent 向 Brain 写入知识时选择受众范围。它们存放在 `agent_library_container_entries` 中，并按内容哈希寻址。
- **技能教训**是 `agent_skill_lessons` 中不可原地修改的语义记录。每条记录属于一个 Agent 和一个 Skill，并保存作者、证据、租约状态与退场历史。Dreaming 写入有证据支持的租约教训；运维人员可以新增没有租约的人工教训，也可以让任意教训退场。

Skill 视图读取 Skill 文件，并把符合投递条件的教训渲染到 `Agent-specific additions` 区块。基础 `SKILL.md` 不会改变。证据、复审和投递规则见[技能教训](../skill-lessons/)。

## 同步：让注册表保持诚实

因为 skill 是文件系统 bundle，数据库注册表必须跟踪文件系统。两条同步路径做这件事：

- **`sync_builtin_skills`** 把 `app/library/skills` 树与 builtin skill 行对账，返回是否有变化、content hash 以及 skill 数和文件数。它从应用镜像运行，所以新镜像能在下一次同步时新增或更新 builtin skill。
- **`sync_agent_skills`** 把某个 agent 的已安装 skill 与 worker 可见存储的实际内容对账，而 `replace_installed_skill_observations` 写下观察到的文件集。从存储里消失的 skill 会反映到注册表；新出现的 skill 会被捡起来。

同步是“读取并对账”，不是“发完就不管”。`content_hash` 让同步幂等：同一棵树产出同一个 hash，只有真正的变化才写一行。

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
| `GET` | `/agents/:agent_uid/library-documents` | 列出该 Agent 的 mission/soul/design/confidentiality policy |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | 设定一份文档 |
| `GET` | `/agents/:agent_uid/skill-lessons` | 列出生效和已退场的技能教训 |
| `POST` | `/agents/:agent_uid/skill-lessons` | 新增一条人工技能教训 |
| `POST` | `/agents/:agent_uid/skill-lessons/:lesson_id/retire` | 让一条技能教训退场 |

读取 `/agents/:agent_uid/library-capabilities` 会触发一次 agent skill 同步，所以运维者看到的是注册表与当前存储对账后的结果——不是过期的快照。

## Agent Library 不是什么

它不是 marketplace，也不是热加载系统。skill 和 plugin 是受信任的第一方 bundle，随部署发布，或安装到 worker 可见的存储里；没有第三方发现，没有 worker 之外的额外隔离机制。数据库不是 skill 字节的来源——字节在文件系统上，注册表只跟踪它所见到的。库也不是定义模型工具的地方；它是运维者决定一个 agent 能把哪些能力带进一个回合的地方。从“已启用”到“真正被调用”，由 Agent Computer Worker 在回合中完成。

## 下一步

- 配置库的路由，读 [Console](../console-api/)。
- Agent 专属的过程指引，见[技能教训](../skill-lessons/)。
- 在一个回合中运行已启用 skill 的 worker，读 [Actor Runtime](../actor-runtime/)。
- 能力库所属的 Agent 主体，见 [主体与 AuthZ](../principal-authz/)。
