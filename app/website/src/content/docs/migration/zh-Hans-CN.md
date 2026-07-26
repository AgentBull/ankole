---
title: 从其它系统迁入
description: 没有自动迁移工具。上 Ankole 的路径是一套全新部署，重新配置 provider、agent 和 signal binding，并手工重建人设与记忆。
section: Getting started
order: 7
---

没有工具能把另一个自托管 agent 系统导入 Ankole，我们也不打算假装有。本页如实告诉你迁移到 Ankole 涉及什么，让你决定要不要做、怎么做。

先把决定性的性质说清楚：Ankole 不读其它系统的数据库、扁平文件记忆或聊天日志。你带过来的东西，都通过 Console 重建。最短的诚实总结是：部署 Ankole、配置 provider 和 agent、手工重建你在意的人设文档，并接受对话历史和运行时记忆不迁移。

## 为什么没有导入器

Ankole 的持久状态按它自己的模型塑形：Principal、agent、session、signal binding、Brain 知识行、actor 事件。这些没有一个干净映射到另一个系统的表或文件。一个忠实的导入器得发明源系统没有的语义——Ankole 的 Principal 范围、它的 signal-binding 模型、它的 Brain 写入权限模式——而发明这些的导入器比没有导入器更糟，因为它会产出一个看起来迁过来了、其实并没有的部署。

所以迁移是一次重新配置，不是转换。活是运维者的活，通过 Console 做，下面各节是顺序。

## 第 1 步：部署 Ankole

用[安装部署](../installation/)或[快速开始](../quickstart/)起一套全新部署。不要试图把 Ankole 指向另一个系统的 PostgreSQL 或 Agent Home——schema 不兼容，而且 Ankole 的内置 PostgreSQL 带有源系统几乎肯定没有的 `pg_search` 扩展。用一个新数据库、一个新的 Agent Home 卷、新的引导 secret。

## 第 2 步：配置 provider 与模型

通过 [Provider 与模型](../providers-and-models/)重建上游 AI provider 配置。你在源系统上用过的 provider 凭证仍然有效——带上同样的 API key 和端点——但作为新的 Ankole provider 行录入。绑定必需的 model profile 槽（`primary`、`light`、`heavy`）以及 agent 需要的可选槽。

## 第 3 步：创建 agent 与人设

通过 [Agent](../agents/) 创建每一个 agent。为每一个手工重新撰写人设文档：

| Ankole 文档 | 该放什么 |
|---|---|
| `MISSION.md` | agent 的范围与职责 |
| `SOUL.md` | 语气、风格与边界 |
| `DESIGN.md` | agent 必须遵守的工作约定与约束 |

如果源系统只有一份人设 prompt，按目的拆到这三份里，而不是整段贴进一个文件。Ankole 每个回合都读这三份；这种拆分让每一份都可寻址、可复核。

## 第 4 步：连接聊天平台

通过 [Signal binding](../signal-bindings/) 和各平台的 adapter 专页重建 signal binding——[Lark](../adapters-lark/)、[钉钉](../adapters-dingtalk/)、[Slack](../adapters-slack/)、[Microsoft 365](../adapters-microsoft-365/)、[Google Workspace](../adapters-google-workspace/)。聊天平台侧的机器人应用可以保留——复用已有的应用注册和凭证——但把它们绑到新的 Ankole agent。

计划一次切换，而不是并行运行：两个系统在同一个频道里回答会让用户困惑，还可能双重回复。在启用 Ankole binding 之前，先在频道里禁用源系统的机器人，或在一个计划窗口里迁移频道。

## 什么不迁移

把这一点说清楚，因为它是迁移显得有损的地方：

- **对话历史**——聊天转写不会被导入。Ankole 每个 session 全新开始；过往回合留在源系统的日志里，仍可读，但不再驱动 agent。
- **长期记忆**——没有扁平文件记忆可拷贝进来。Brain 知识是 PostgreSQL 里经运维者复核的行；把那少数几条要紧的持久事实，通过 Brain 界面作为策展知识重建。
- **后台任务与调度**——任何周期性 schedule 通过[调度](../schedules/)重建。源系统上在跑的任务不迁移。
- **习得的模型行为**——源系统通过 prompt 累积调出来的任何东西，在你把它写进人设文档或策展知识之前，在 Ankole 里不存在。

## 切换清单

1. Ankole 部署并健康；一个测试 agent 跑通一个真实回合。
2. 每个 agent 的 provider 行和 model profile 已绑。
3. 每个 agent 的人设文档已撰写。
4. signal binding 已创建，但在生产频道上**禁用**。
5. 源系统的机器人在你要迁移的频道里已禁用。
6. 启用 Ankole binding；端到端验证头几条真实消息。
7. 旧部署保留为只读一段时间，然后下线。

## 本页不是什么

它不是“迁移很容易”的承诺，也不是按源系统分类的导入器目录。如果你的源系统有结构化导出，且能映射到 Ankole 的模型，你可以针对 Console API 自己写一个导入器——但 Ankole 不自带，而且你理解的手工重建配置，胜过你不理解的导入配置。

## 下一步

- 开启迁移的部署，读[安装部署](../installation/)。
- 迁移中你花最多时间的运维界面，读 [Console 运维操作](../console-operations/)。
- 你要重新撰写的人设文档，读 [Agent](../agents/)。
