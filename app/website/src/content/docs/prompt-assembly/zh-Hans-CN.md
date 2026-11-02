---
title: Prompt 组装
section: Developer guide
order: 118
description: 控制面如何装配主 Agent 的系统指令，以及 Codex Job 与 Workflow 各自独立的上下文路径。
---

主 Agent 的模型系统指令统一由控制面负责装配：每次启动推理时，先由 `Ankole.Sessions.Context.resolve/2` 读取最新领域事实，再交由 `Ankole.Sessions.Prompt.system/1` 渲染为完整的系统提示词，最后由 `Ankole.Sessions.Driver` 通过 AIGateway 发往上游模型；Worker 仅负责承接具体的环境工具调用与 Codex Job。整体执行链路见 [Agent 循环](../agent-loop/)。

## 当前上下文

每轮上下文包括 Agent 身份、启用能力、起始会话与时区。Ankole 完整读取 `/AnkoleBrain/AGENTS.md`，再按个体页的追加或覆盖规则得到有效 `AGENTS.md`。`DESIGN.md` 遵循相同层级，并以完整运行时文件提供给 Agent。

`Ankole.Sessions.Prompt.system/1` 依次渲染完整 AGENTS 规范、任务收尾与权限规则、Job 和 Workflow 策略、记忆指南、环境与工具说明、技能目录以及运行时上下文。模板位于 `app/control_plane/priv/sessions/prompts/`。

技能目录展示当前会话可读且已启用的技能简介，`skill_view` 按需读取所选技能与有权访问的补充子页。运行时后缀记录 Agent、`/workspace`、Session 工作区、时区、会话起始时间和频道。飞书与 Lark 共用适配器，并根据配置的域选择上游 API。

## 设置与历史

`AgentConfig` 负责解析租户级的回合运行限制：`ai_agent.max_iterations` 默认为 90 轮，`ai_agent.max_output_tokens` 默认不设显式上限，`ai_agent.inactivity_timeout_ms` 默认为 30 分钟；这些参数直接约束控制面驱动的推理回合。

对话历史由 AIGateway 统一持有，并完整归档每次模型请求以备审计。当前回合的新输入与外部提供商观测数据会经由 `Prompt.Input` 组装为用户消息（User Message），不会重复塞入系统提示词；控制面则在每次运行时基于最新领域状态重新渲染系统指令。

## Codex Job 与 Workflow 任务

Codex Job 由 Worker 执行。每轮启动和续跑时，Worker 获取最新规范，原子刷新 `$CODEX_HOME/AGENTS.md`、`~/AGENTS.md` 与 `~/DESIGN.md`。原生 Codex 将全局 Agent 指令与项目自己的指令文件顺序组合。详见[后台 Agent 任务](../background-agent-jobs/)。

Workflow 任务则调用 `Prompt.workflow_system/1` 渲染专用系统提示词，内容涵盖 Agent 身份、任务 ID、已保存的结果 Schema、结果提交规范，以及子任务委派与休眠等待规则；主动介入（Proactive）路由同样使用各自独立的专用提示词。各条执行路径严格遵循自身的运行时契约，互不混用。
