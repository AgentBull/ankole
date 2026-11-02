---
title: Agent Library
description: 管理 Agent 可用的能力边界：以文件包形式组织的 Skill、基于 Codex 包规范的 Agent Plugin，以及“租户默认 + Agent 覆盖”的启用机制。
section: Developer guide
order: 107
---

Agent Library 负责计算每个 Agent 当前启用的 Skill 与 Agent Plugin。共享技能存放在 Pod 的 `/AnkoleBrain/skills/<name>`：主页是知识页，脚本和模板是其下的文件子节点。Agent 也可以在个人 Files 空间的 `skills/` 下安装私有技能包。PostgreSQL 保存内容、权限与启用状态，Worker 文件是执行时的副本。

## 能力与启用规则

每项 Skill 都有 `SKILL.md` 清单，名称采用全局唯一的小写标识。Agent Plugin 将相关 Skill 与可选的 `workspace-template/` 打包。系统依次解析出厂默认值、站点与租户设置、Agent 个体覆盖；Plugin 内的 Skill 还要求父 Plugin 已启用。

启用状态与访问权限各自独立。Ankole 只在目录中列出当前会话可读且已启用的技能。人类发起的回合按 Agent、提问者与适用房间参与者的权限交集读取；无人值守自动化按 Agent 自身权限读取。目录提供名称与简介，`skill_view` 按需加载内容。

## 共享内容与升级

管理员在 Pod 中编辑共享技能。系统将当前会话可读的知识子页追加到技能指令中；标记 `metadata.role = "reference"` 的章节保留为按子路径读取的参考资料。Agent 加载技能时，还会收到适用于它的已审核教训，详见[技能教训](../skill-lessons/)。

启动和目录同步时，Ankole 将官方技能包与已保存的基准对账，比较主页元数据、正文，以及每个托管文件的路径、内容摘要与文件模式。内容未被本地修改时，系统原子应用上游更新，包括文件增删；存在本地修改时，系统保留整包并记录待审阅的上游摘要。租户自建的补充知识页与自定义文件不计入托管基准。

## Agent 规范

`/AnkoleBrain/AGENTS.md` 定义组织行为与职责，`/AnkoleBrain/DESIGN.md` 定义视觉规范。在 `/AnkoleBrain/agents/<uid>/` 下，`AGENTS.md` 追加岗位职责，`AGENTS.override.md` 完整替换全局规范。对应的 DESIGN 文件分别采用正文追加并合并元数据，或整份替换。空的 override 表示主动清空继承内容。

个人助理页面仅对主人和助理开放：主人管理，助理读取。内部同事默认继承组织规范，只有需要定制时才创建个体规范页。

Console 展示有效能力，并通过链接进入 Pod 编辑规范。`GET /agents/:agent_uid/library-documents` 返回有效 AGENTS、DESIGN 及其来源页。Worker 每轮刷新 `~/AGENTS.md`、`~/DESIGN.md` 和 `$CODEX_HOME/AGENTS.md`，项目目录使用项目自己的指令文件。

安装方法见[技能](../skills/)，执行路径见[Prompt 组装](../prompt-assembly/)，能力接口见[Console](../console-api/)。
