---
title: Agent Library
description: 一个 agent 能做什么——skill 作为文件包，Agent Plugin 作为 Codex 包，以及按 agent 解析的“默认再覆盖”启用模型。
section: Developer guide
order: 107
---

Agent Library 回答一个问题：这个 Agent 实际可以使用哪些能力？它由实例内的 Skill 和 Agent Plugin 目录，以及每个 Agent 的启用状态组成。本页以 `Ankole.AIAgent.Library` 的实际代码为准说明这套模型。

随产品发布的 Skill 和 Agent Plugin 是应用镜像中的文件包。已安装 Skill 保存在控制面管理的 Agent Files 盘的 `skills/` 下。PostgreSQL 保存目录、启用状态和权威文件引用，对象存储保存已安装文件的内容。Worker 将这些文件下载到本地执行缓存。

## 两种能力

库持有两种相关但不相同的东西：

- **一个 Skill** 是一个文件包，由一份 `SKILL.md` 标识。skill 名小写，以字母开头，只用字母、数字、`_` 和 `-`，最长 64 字符。一个 skill 要么是 `builtin`（随应用镜像发布，从 `app/library/skills` 同步），要么是 `installed`（保存在 Agent Files 盘的 `skills/` 下）。`agent_skills` 行记录启用状态、来源种类、content hash 和同步时间——它明确不是一张文件内容表。
- **Agent Plugin** 是标准 Codex Plugin 包，可以附带 Ankole 的 `workspace-template/` 初始化目录。包的文件和版本留在实例的部署包中；PostgreSQL 只保存每个 Agent 的启用覆盖。Plugin 标识符与 Skill 名称使用相同的格式规则。

两者相连：一个 Agent Plugin 可以带 skill，而 skill 行记录它的 `agent_plugin_id`，供父级启用和目录展示使用。但 Agent Plugin 成员只是独立的元数据——它不改变 skill 的加载方式。

## 启用：租户默认值，再由 Agent 覆盖

租户设置提供 Agent Plugin 和 Skill 的有效默认值。租户没有覆盖时继承站点设置；运维没有设置时使用随产品发布的目录默认值。Agent 只保存自己的覆盖值。

`effective_enabled` 使用 Agent 覆盖值或继承的租户默认值。Plugin 成员 Skill 还要求父 Plugin 已启用。关闭父 Plugin 会保留成员原来的设置，父级重新启用后继续生效。

[Console](../console-api/) 的 Agent Library 能力路由读写所选租户的默认值，再允许按 Agent 覆盖。API 字段保留 `global_default_enabled` 名称，返回的是该租户包含站点继承的有效默认值。

## 只通过 Brain 召回的 Skill 发现

随产品发布的独立 Skill 或 Agent Plugin 成员 Skill 可以声明 `brain-recall-only: true`。所有随产品发布的 Skill 共用一个全局名称空间，Plugin 成员关系不会改变 Skill 名称。安装到 Agent 的 Skill 不参与这种模式。

Agent Library 会把完整的有效 Skill 集发送给 Worker。普通 Skill 进入模型可见的 Skill 目录；只通过 Brain 召回的 Skill 保留在 `skill_view` 可加载集合中，但不会进入该目录。Library sweep 只把它们的名称、描述和标签投影为 `lazyload-agent-skills/<skill-name>` 下的轻量 Brain 记录；Skill 正文、资源和 Agent 专属教训仍留在各自的文件与数据库所有者中。

投影由同一租户内的 Agent 共享，不会因为某个 Agent 关闭 Skill 而删除。Brain 查询和 `skill_view` 都会应用该 Agent 当前的 Plugin 与 Skill 有效状态，因此已关闭的记录不会占用召回名额，也不能被加载。重新启用能力后会直接恢复已有投影。

## Agent 长期文档与技能教训

除了能力，库还持有 Agent 自己的可写文档和 Agent 专属的 Skill 指引：

- **Agent 长期文档**包括 `mission`、`soul`、`design` 和 `confidentiality_policy`，即容器表接受的四个 `source_kind`。前两项定义职责与行为，`design` 保存视觉内容使用的设计系统，`confidentiality_policy` 指导 Agent 向 Brain 写入知识时选择受众范围。它们存放在 `agent_library_container_entries` 中，并按内容哈希寻址。
- **技能教训**是 `agent_skill_lessons` 中不可原地修改的语义记录。每条记录属于一个 Agent 和一个 Skill，并保存作者、证据、租约状态与退场历史。Dreaming 写入有证据支持的租约教训；运维人员可以新增没有租约的人工教训，也可以让任意教训退场。

Skill 视图读取 Skill 文件，并把符合投递条件的教训渲染到 `Agent-specific additions` 区块。基础 `SKILL.md` 不会改变。证据、复审和投递规则见[技能教训](../skill-lessons/)。

## 同步：让注册表保持诚实

控制面的 `sync_agent_skills` 将两种来源合并为一个 Agent 的能力目录：

- **随产品发布的 Skill** 来自应用镜像，包括独立 Skill 和 Agent Plugin 成员 Skill。新镜像可在下一次同步时新增或更新这些 Skill。
- **已安装 Skill** 直接来自 Agent Files 盘中的 `skills/<name>/SKILL.md`。Library 读取全部列表分页和每份 manifest 后才修改目录。新增或变更的 manifest 更新目录记录；删除 manifest 会移除对应记录。读取或解析失败时，目录保持不变。更新会保留运维人员已有的 `enabled_override`。

Worker 将已安装 Skill 下载到执行缓存，不扫描缓存来上报或替换能力目录。内容哈希让同步跳过未变化的记录。

## 运维界面

[Console](../console-api/) 页里已经覆盖的路由驱动这套模型。尤其是能力路由：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/agent-library/capabilities` | 所选租户的目录与默认值 |
| `PUT` | `/agent-library/agent-plugins/:id` | 设定一个 plugin 的租户默认值 |
| `PUT` | `/agent-library/skills/:id` | 设定一个 skill 的租户默认值 |
| `GET` | `/agents/:agent_uid/library-capabilities` | 某个 agent 的有效能力 |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 为某一个 agent 覆盖一个 plugin |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | 为某一个 agent 覆盖一个 skill |
| `GET` | `/agents/:agent_uid/library-documents` | 列出该 Agent 的 mission/soul/design/confidentiality policy |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | 设定一份文档 |
| `GET` | `/agents/:agent_uid/skill-lessons` | 列出生效和已退场的技能教训 |
| `POST` | `/agents/:agent_uid/skill-lessons` | 新增一条人工技能教训 |
| `POST` | `/agents/:agent_uid/skill-lessons/:lesson_id/retire` | 让一条技能教训退场 |

读取 `/agents/:agent_uid/library-capabilities` 会从应用镜像和 Agent Files 盘同步 Skill，无需正在运行的 Worker。

## Agent Library 不是什么

它不是 marketplace，也不是热加载系统。Skill 和 Plugin 是受信任的第一方文件包。内置文件包随部署发布，已安装 Skill 保存在 Agent Files 盘中。没有第三方发现，没有 worker 之外的额外隔离机制。库也不是定义模型工具的地方；它是运维者决定一个 agent 能把哪些能力带进一个回合的地方。执行时，控制面加载主 Agent 的 Skill 指令；Worker 准备电脑工具与 Codex Job 的 Skill。

## 下一步

- 配置库的路由，读 [Console](../console-api/)。
- Agent 专属的过程指引，见[技能教训](../skill-lessons/)。
- 在一个回合中运行已启用 skill 的 worker，读 [Actor Runtime](../actor-runtime/)。
- 能力库所属的 Agent 主体，见 [主体与 AuthZ](../principal-authz/)。
