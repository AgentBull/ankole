---
title: Agent Library
description: 在 Meta Ankole 中管理技能包、Agent 启用关系与指令契约。
section: Developer guide
order: 107
---

Agent Library 负责 PostgreSQL 中的技能包与 Agent 指令契约。在 Pod 中，打开 **Meta Ankole → Skills** 管理技能包，打开 **Agents** 管理 AI 同事、我的助理与全局指令。Meta 导航树的目录默认折叠。协作页面与 Brain 知识图谱分别由各自的领域管理。

## 技能包与启用范围

每个 Skill 包含租户内唯一的 `slug`、必选的 `SKILL.md` 清单，以及可选的参考文件、脚本和二进制资产。具有自定义技能权限的成员可以新建或导入技能包；新建的自定义技能默认关闭。Agent 先读取清单，再按其中的指引读取附件。`skill_view` 也会提供经过审核的技能经验。

技能可以为所有 Agent、指定 AI 同事或自己的助理开启。为所有 Agent 开启时，个体开关锁定，已保存的个体绑定仍然保留；关闭全员选项后，恢复各个体原先的选择。插件技能还要求所属 Agent Plugin 已开启；插件自身的默认值与覆盖设置独立生效。

技能只取决于 Agent 身份，切换提问者或参与者不会移除其已启用的技能包。Brain 读取则执行 Agent、提问者与披露对象的权限交集。

## 编辑与上游同步

Skills 编辑器管理清单、元数据与包内文件。保存时校验 `base_revision`，拒绝覆盖过期版本。技能与指令契约只保留当前版本，不保存历史快照。官方技能的 `slug` 固定；自定义技能可以改名或删除。

上游同步比较清单与托管文件的哈希。未被本地修改的官方包会原子接收文件新增、更新与删除。本地修改会暂停该包的上游更新，直到完成协调；用户额外上传的本地附件保持不变。

## Agent 指令契约

**Meta Ankole → Agents → 全局设置** 管理全局 `AGENTS.md` 与 `DESIGN.md` 基线。每个 AI 同事或助理可以分别选择继承、追加或覆盖。DESIGN 的追加模式递归合并元数据，并用分隔线连接正文。空白覆盖表示有意清空继承内容。

助理配置仅主人本人可读、可改。新助理默认用助理模板覆盖 AGENTS，并继承 DESIGN。正式成员可读取 AI 同事和全局设置，由获授权的管理员修改。

Worker 在 `/drive/Skills/<slug>/` 挂载已启用的完整技能包，并通过 `/drive/AGENTS.md` 与 `/drive/DESIGN.md` 提供合并后的指令。这些只读挂载跨会话共享常热缓存，可执行脚本保留执行权限；保存修改后，系统通知 Worker 刷新缓存。后台 Job 在恢复时使用准入时记录的技能集合与当前启用集合的交集。

参阅[技能经验](../skill-lessons/)、[编写 Skill](../writing-a-skill/)与[提示词组装](../prompt-assembly/)。
