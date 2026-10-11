---
title: 任务清单与澄清
section: Developer guide
order: 124
description: 控制面的任务清单、决策问题，以及 Codex Job 的独立输入路径。
---

`todo` 与 `clarify` 是控制面工具，由 `Ankole.Conversations.Tools.Session` 拥有。Driver 校验参数，经 AIGateway 保存模型可见结果，并把效果应用到当前运行。Worker 不拥有这些主回合工具。

## 任务清单

`todo` 读取、替换清单，或按条目 ID 合并。状态为 `pending`、`in_progress`、`completed`、`cancelled`，声明最多接受 256 项。工具指令要求三步以上的复杂任务使用清单，按优先级排列，同时一项进行中，完成后立即标记，失败后新增修订项。

清单是 `Ankole.Conversations.Run` 的工作状态，不是组织知识。恢复时从当前运行历史中成功记录的工具调用重建清单。新 Session 不继承另一个 Session 的清单。需要跨 Session 共享的知识属于 [Brain](../brain/)。

## 一个决策问题

`clarify` 只在答案会决定结果或下一步时提出一个自足的问题。Agent 先使用当前请求与此前对话，不重复询问已给出的偏好，也不在有安全、低风险默认值时中断工作。

问题可以开放回答，或提供二至四个实质不同的选项。问题上限 2,000 字符，选项标签 200 字符，可选说明 500 字符。用户可以拒绝的行动须包含不行动选项。

成功结果记录规范化后的问题与选项，并结束当前回合。Agent 不再调用工具，也不追加最终回答；用户的下一条消息开始继续的回合。问题与答复留在持久会话记录中。

## 后台 Job 与运维

原生 Codex Job 使用独立的输入请求路径。请求人工输入时，Job 进入 `waiting_on_user` 并释放运行槽位；owner 的回复使其继续。这是 Job 生命周期契约，不是在 Worker 中执行主 Agent 的 `clarify`。参见 [后台 Agent 任务](../background-agent-jobs/)。

规划状态与回合结束行为没有 Console 调节开关。若 Agent 选择规划或提问的方式需要调整，应修改 Agent 的指导与能力。参见 [Agents](../agents/) 与 [Agent 循环](../agent-loop/)。
