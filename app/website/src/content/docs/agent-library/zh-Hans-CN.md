---
title: Agent Library
description: 管理 Agent 可用的能力边界：以文件包形式组织的 Skill、基于 Codex 包规范的 Agent Plugin，以及“租户默认 + Agent 覆盖”的启用机制。
section: Developer guide
order: 107
---

Agent Library 用来回答一个核心问题：某个 Agent 在实际工作中究竟可以使用哪些能力？它由系统内的 Skill 与 Agent Plugin 目录，以及每个 Agent 的启用配置共同组成。本页按照 `Ankole.AIAgent.Library` 的实际实现说明这套管理模型。

随产品内置发布的 Skill 和 Agent Plugin 直接打包在应用镜像中；后期自行安装的 Skill 则保存在控制面管理的 Agent Files 云盘 `skills/` 目录下。数据归属上，PostgreSQL 保存能力目录、启用状态和权威文件引用，对象存储保存已安装 Skill 的文件内容，Worker 则在执行前将这些文件拉取到本地缓存。

## 两种能力

能力库管理着两类既相互关联又各有分工的能力单元：

- **Skill** 是以一份 `SKILL.md` 清单标识的文件包。Skill 名称必须以小写字母开头，仅允许使用小写字母、数字、`_` 和 `-`，最长 64 个字符。按来源分为两类：`builtin`（随应用镜像内置，从 `app/library/skills` 同步）与 `installed`（保存在 Agent Files 云盘的 `skills/` 目录下）。数据库表 `agent_skills` 仅记录启用状态、来源种类、内容哈希（content hash）与同步时间，不直接存储文件内容。
- **Agent Plugin** 是标准的 Codex Plugin 包，可附带 Ankole 专属的 `workspace-template/` 工作区初始化目录。插件的文件与版本信息保留在实例部署包内，PostgreSQL 只保存各 Agent 的启用覆盖配置。Plugin 标识符遵循与 Skill 名称相同的格式规则。

两者的关联在于：一个 Agent Plugin 可以包含多个成员 Skill，成员 Skill 的数据库记录通过 `agent_plugin_id` 指向所属插件，供父级联动开关与目录分组展示使用。不过，插件成员关系只是独立的目录元数据，不改变 Skill 本身的加载方式。

## 启用：租户默认值，再由 Agent 覆盖

Agent Plugin 和 Skill 的默认启用状态按“内置目录默认值 → 站点级设置 → 租户级设置 → 单 Agent 覆盖”逐层解析：当前租户未单独配置时继承站点设置；站点也未配置时则采用随产品发布的目录默认值。单个 Agent 只需保存自己显式覆盖的开关状态。

计算最终生效状态（`effective_enabled`）时，系统优先采用 Agent 自身的覆盖值，未覆盖时回退到解析出的租户默认值。归属于某个 Agent Plugin 的成员 Skill 还必须满足父 Plugin 已启用这一前提；如果关闭父 Plugin，成员 Skill 原有的开关记录会原样保留，待父 Plugin 重新启用后自动恢复生效。

通过 [Console](../console-api/) 的 Agent Library 能力路由，管理员既可以读写所选租户的默认启用状态，也可以针对单个 Agent 设置覆盖值。接口返回的 `global_default_enabled` 字段即表示合并站点继承关系后的当前租户有效默认值。

## 只通过 Brain 召回的 Skill 发现

随产品发布的独立 Skill 或 Agent Plugin 成员 Skill 可在清单中声明 `brain-recall-only: true`（自行安装到 Agent 的 Skill 不支持此模式）。所有内置 Skill 共用同一个全局命名空间，是否归属于某个 Plugin 不会改变 Skill 名称。

运行时，Agent Library 会将完整的有效 Skill 集合下发给 Worker：普通 Skill 直接进入模型每轮可见的 Skill 目录；而标记为仅通过 Brain 召回的 Skill 虽然保留在 `skill_view` 可加载集合内，但平时不会出现在该目录中。后台巡检任务（Library sweep）仅将这类 Skill 的名称、描述和标签投影为 `lazyload-agent-skills/<skill-name>` 下的轻量 Brain 记录；Skill 的完整正文、附属资源以及 Agent 专属技能教训，仍各自保存在原有的文件系统与数据库表中。

这些轻量投影由同一租户内的所有 Agent 共享，不会因为某个 Agent 关闭了某项 Skill 而被删除。不过，无论是在 Brain 中检索召回，还是调用 `skill_view` 加载指令，系统都会实时校验当前 Agent 对各 Plugin 和 Skill 的有效启用状态——已关闭的记录既不会占用召回名额，也无法被加载；重新启用该能力后，原有投影即可直接恢复使用。

## Agent 长期文档与技能教训

除管理能力开关外，Agent Library 还负责维护 Agent 自身的可写长期文档以及 Agent 专属的 Skill 操作指引：

- **Agent 长期文档**包含 `mission`、`soul`、`design` 和 `confidentiality_policy` 四种类型（对应容器表允许的四种 `source_kind`）。前两项定义核心职责与行为准则，`design` 保存制作视觉内容时使用的设计系统，`confidentiality_policy` 指导 Agent 在向 Brain 写入知识时如何选择受众范围。这四份文档存放在 `agent_library_container_entries` 表中，按内容哈希寻址。
- **技能教训**是保存在 `agent_skill_lessons` 表中、不可原地覆写的语义记录。每条记录归属于特定 Agent 和特定 Skill，完整记录作者、事实证据、租约状态与退役历史。后台反思任务（Dreaming）会写入有证据支撑的租约制教训；管理员也可以手动添加无租约限制的人工教训，或将任意教训标记为退役。

加载 Skill 视图时，系统会先读取原始 Skill 文件，再将符合投递条件的技能教训动态渲染到 `Agent-specific additions` 区块，基础 `SKILL.md` 文件本身不会改变。有关事实证据、定期复审和投递筛选的具体规则，请参阅[技能教训](../skill-lessons/)。

## 同步：让注册表保持诚实

控制面的 `sync_agent_skills` 函数负责将两类来源合并为单个 Agent 的能力目录：

- **随产品发布的 Skill** 读取自应用镜像，涵盖独立内置 Skill 和 Agent Plugin 成员 Skill。升级新镜像后，下一次同步即可自动纳入新增或更新的内置 Skill。
- **已安装 Skill** 直接读取自 Agent Files 云盘中的 `skills/<name>/SKILL.md`。同步过程必须完整读取所有列表分页并成功解析每一份清单（manifest）后，才会修改数据库目录：新增或变更的清单会更新目录记录，已移除的清单会删除对应记录；一旦读取或解析中途失败，目录保持原状不变。清单更新时，管理员已设置的 `enabled_override` 开关状态会完整保留。

Worker 仅将已安装 Skill 下载到本地执行缓存，不会反向扫描缓存来上报或替换能力目录。同步过程通过比对内容哈希自动跳过未发生变化的记录。

## 运维界面

[Console](../console-api/) 页面介绍的管理路由驱动着整套能力库模型，其中核心能力接口如下：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/agent-library/capabilities` | 查询所选租户的能力目录与默认启用状态 |
| `PUT` | `/agent-library/agent-plugins/:id` | 设置指定 Plugin 的租户默认启用状态 |
| `PUT` | `/agent-library/skills/:id` | 设置指定 Skill 的租户默认启用状态 |
| `GET` | `/agents/:agent_uid/library-capabilities` | 查询指定 Agent 的有效能力集合 |
| `PUT` | `/agents/:agent_uid/library-capabilities/agent-plugins/:id` | 为指定 Agent 覆盖某个 Plugin 的启用状态 |
| `PUT` | `/agents/:agent_uid/library-capabilities/skills/:id` | 为指定 Agent 覆盖某个 Skill 的启用状态 |
| `GET` | `/agents/:agent_uid/library-documents` | 读取该 Agent 的 `mission`、`soul`、`design` 与 `confidentiality_policy` 文档 |
| `PUT` | `/agents/:agent_uid/library-documents/:document_kind` | 更新指定类型的长期文档 |
| `GET` | `/agents/:agent_uid/skill-lessons` | 列出该 Agent 当前生效及已退役的技能教训 |
| `POST` | `/agents/:agent_uid/skill-lessons` | 手动新增一条人工技能教训 |
| `POST` | `/agents/:agent_uid/skill-lessons/:lesson_id/retire` | 将指定技能教训标记为退役 |

请求 `GET /agents/:agent_uid/library-capabilities` 时，控制面会直接从应用镜像和 Agent Files 云盘同步 Skill 目录，无需该 Agent 的 Worker 处于运行状态。

## Agent Library 不是什么

Agent Library 既不是第三方应用市场，也不是动态热加载系统。所有 Skill 和 Plugin 都是受信任的第一方文件包：内置包随部署镜像发布，已安装 Skill 保存在 Agent Files 云盘中，不存在外部第三方发现机制，也没有除 Worker 容器之外的额外沙箱隔离层。此外，能力库本身并不定义底层模型工具，而是供管理员决定“允许某个 Agent 将哪些能力带入对话回合”。实际执行时，控制面负责加载主 Agent 的 Skill 指令，Worker 则负责准备电脑环境工具与 Codex 任务所需的 Skill。

## 下一步

- 查看配置能力库的完整接口，请参阅 [Console](../console-api/)。
- 了解 Agent 专属的过程经验指引，请参阅[技能教训](../skill-lessons/)。
- 了解如何在对话回合中调度 Worker 运行已启用的 Skill，请参阅 [Sessions](../sessions/)。
- 了解能力库所归属的 Agent 主体与权限模型，请参阅 [主体与 AuthZ](../principal-authz/)。
