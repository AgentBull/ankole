---
title: 工具运行时
description: 控制面的工具声明与分发，以及 Worker 环境执行边界。
section: Developer guide
order: 120
---

控制面拥有主 Agent 的模型循环与工具分发。`Ankole.Sessions.Driver` 调用 AIGateway，执行模型请求的工具，记录结果，然后继续回合。Agent Computer 执行环境操作与 Codex Job。参见 [Agent 循环](../agent-loop/) 和 [Agent Computer Worker](../agent-computer-worker/)。

## 构建当前工具集

`Ankole.Sessions.ToolCatalog.for_run/1` 把当前领域声明与 `worker_tools.json` 导出的 Worker 声明合并。结果取决于回合类型、模型能力、选定的 Skill 和插件，以及主动介入权限。工具集按本次运行构建，不作为 Agent 的全局工具集保存。

`Ankole.Sessions.Tool` 保存模型可见 schema、执行方、执行顺序、允许的调用方，以及只读、破坏性和重试元数据。`Ankole.Sessions.Tools.prepare/2` 先检查调用方、解析参数，再由工具 owner 规范化参数并校验 JSON Schema。

## 在 owner 执行

- 会话规划、调度、Background Agent Job、Workflow、Skill 读取与领域 Web 操作由控制面的对应 owner 执行。
- Computer 操作经 RuntimeFabric 委托给 Agent 的 Worker。第一次环境操作打开 Session 工作区。Worker 拥有槽位与进程状态，控制面拥有持久结果。
- MCP-backed Skill 在 Worker 上通过 computer command 工具与 mcporter 执行。
- Provider 托管工具经 AIGateway 执行。工具目录遵守所选模型声明的能力。

Driver 按声明调度并行或顺序调用。持久副作用经 `Ankole.Sessions.Receipts` 执行，使领域变更与结果在同一事务中提交。AIGateway 保存工具输出，供下一次模型迭代读取。Worker 断连后，Driver 按工具声明的重试契约处理结果不确定的环境操作。

## Workflow 任务工具

Workflow 任务的工具集受限：Web 操作、用于委托与检查的 Background Agent Job 操作、`sleep` 和 `submit_result`。托管 Brain 只允许 `recall` 与 `get_page`。任务没有 computer、shell、Skill、调度或创建 Workflow 的工具。

`submit_result` 按任务已持久保存的结果 schema 校验提交值。拒绝后可以修正；接受后任务结束。任务提交前须结清仍在运行的委托 Job。参见 [Workflow](../workflows/)。

## 新增工具

领域工具的声明与实现放在控制面的领域 owner 中。环境工具加入 Worker 目录后，重新生成 `worker_tools.json`。`WorkerAgentTool` 与 Zod 定义了 Worker 工具的实现契约。schema 与执行边界必须一起保持一致。
