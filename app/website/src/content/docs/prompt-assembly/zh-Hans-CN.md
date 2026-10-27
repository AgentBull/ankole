---
title: Prompt 组装
section: Developer guide
order: 118
description: 控制面如何装配主 Agent 的系统指令，以及 Codex Job 与 Workflow 各自独立的上下文路径。
---

主 Agent 的模型系统指令统一由控制面负责装配：每次启动推理时，先由 `Ankole.Sessions.Context.resolve/2` 读取最新领域事实，再交由 `Ankole.Sessions.Prompt.system/1` 渲染为完整的系统提示词，最后由 `Ankole.Sessions.Driver` 通过 AIGateway 发往上游模型；Worker 仅负责承接具体的环境工具调用与 Codex Job。整体执行链路见 [Agent 循环](../agent-loop/)。

## 当前上下文

解析出的会话上下文涵盖 Agent 身份与人设文档、当前生效的 Skill 与插件、会话起始频道以及所在时区。其中，`SOUL.md` 定义行为准则与判断原则，`MISSION.md` 明确职责边界与交付目标；这两份核心文档均由所属领域模块持久化保存在 PostgreSQL 中，而 Worker 上的环境工具则通过工作区契约读取物化到磁盘的运行时文件副本。

主对话系统提示词按固定顺序拼装以下段落：Agent 身份、SOUL、MISSION、任务收尾与权限指令、可用后台任务（Job）与 Workflow 的调用策略、记忆使用指南、运行环境与工具说明、Skill 目录以及运行时环境后缀。对应的模板文件存放在 `app/control_plane/priv/sessions/prompts/` 下，渲染逻辑位于 `app/control_plane/lib/ankole/sessions/prompt.ex`。

渲染 Skill 目录时会略过标记为 `brain-recall-only: true` 的条目，避免挤占常规上下文窗口；不过这些 Skill 仍属于当前有效集合，模型可通过 Brain 检索发现它们，再调用 `skill_view` 按需加载全文。末尾的运行时后缀则会注入当前 Agent 标识、`/workspace` 路径、当前 Session 专属工作区路径、时区、会话创建时间及起始频道信息。对于飞书与国际版 Lark，底层共用同一个 Lark 适配器，并依据配置的 `domain` 选择对应的上游 API。

## 设置与历史

`AgentConfig` 负责解析租户级的回合运行限制：`ai_agent.max_iterations` 默认为 90 轮，`ai_agent.max_output_tokens` 默认不设显式上限，`ai_agent.inactivity_timeout_ms` 默认为 30 分钟；这些参数直接约束控制面驱动的推理回合。

对话历史由 AIGateway 统一持有，并完整归档每次模型请求以备审计。当前回合的新输入与外部提供商观测数据会经由 `Prompt.Input` 组装为用户消息（User Message），不会重复塞入系统提示词；控制面则在每次运行时基于最新领域状态重新渲染系统指令。

## Codex Job 与 Workflow 任务

Codex Job 走独立的 Worker 端组装路径：Worker 上的 Runner 先解析任务创建时冻结的执行配置，再通过 RPC 向控制面拉取最新领域上下文，据此初始化任务工作目录并生成 `AGENTS.md`，随后交由原生 Codex 接管该任务的模型推理循环。详见 [后台 Agent 任务](../background-agent-jobs/)。

Workflow 任务则调用 `Prompt.workflow_system/1` 渲染专用系统提示词，内容涵盖 Agent 身份、任务 ID、已保存的结果 Schema、结果提交规范，以及子任务委派与休眠等待规则；主动介入（Proactive）路由同样使用各自独立的专用提示词。各条执行路径严格遵循自身的运行时契约，互不混用。
