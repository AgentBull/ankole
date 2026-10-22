---
title: Prompt 组装
section: Developer guide
order: 118
description: 控制面如何渲染主 Agent 指令，以及 Codex Job 上下文的独立路径。
---

控制面组装主 Agent 的模型指令。`Ankole.Sessions.Context.resolve/2` 读取当前领域事实，`Ankole.Sessions.Prompt.system/1` 渲染指令，`Ankole.Sessions.Driver` 经 AIGateway 发送。Worker 接收环境操作与 Codex Job。参见 [Agent 循环](../agent-loop/)。

## 当前上下文

上下文包含 Agent 身份与文档、有效 Skill 和插件、会话起始频道及时区。`SOUL.md` 提供行为与判断准则，`MISSION.md` 提供职责。这些文档由领域 owner 在 PostgreSQL 中保存。环境工具经工作区契约获得物化的运行时文件。

主 Prompt 依次包含身份、SOUL、MISSION、完成与权限指令、可用 Job 和 Workflow 的策略、记忆指导、环境与工具指导、Skill 目录、运行时上下文。模板位于 `app/control_plane_core/priv/sessions/prompts/`，渲染器位于 `app/control_plane_core/lib/ankole/sessions/prompt.ex`。

Skill 目录省略 `brain-recall-only: true` 的条目。这些 Skill 仍在有效集合中，可经 Brain 发现并由 `skill_view` 加载。运行时后缀包含 Agent、`/workspace`、当前 Session 工作区、时区、会话开始时间与起始频道。Lark adapter 同时表示 Lark 和飞书，其 domain 选择上游 API。

## 设置与历史

`AgentConfig` 解析租户级设置：`ai_agent.max_iterations` 默认 90，`ai_agent.max_output_tokens` 默认无显式上限，`ai_agent.inactivity_timeout_ms` 默认 30 分钟。这些设置约束控制面的回合。

AIGateway 拥有会话历史，并保存模型请求供审计。当前输入与 provider 观察经 `Prompt.Input` 组成用户消息，不重复放入系统指令。控制面在每次运行时用当前上下文渲染指令。

## Codex Job 与 Workflow 任务

Codex Job 使用独立的 Worker 路径。runner 解析已冻结的 Job 执行选择，经 RPC 获取当前领域上下文，准备 Job 工程与 `AGENTS.md`。原生 Codex 拥有该 Job 的模型循环。参见 [后台 Agent 任务](../background-agent-jobs/)。

Workflow 任务使用 `Prompt.workflow_system/1`，包含身份、任务 ID、已保存的结果 schema、提交规则，以及委托与休眠规则。主动介入路由使用独立 Prompt。这些路径分别遵守各自的执行契约。
