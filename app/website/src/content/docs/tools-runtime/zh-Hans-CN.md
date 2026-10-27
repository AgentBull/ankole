---
title: 工具运行时
description: 控制面的工具声明、权限校验与调用分发，以及 Worker 环境工具的执行边界。
section: Developer guide
order: 120
---

主 Agent 的模型推理循环与工具调用分发统一由控制面执掌：`Ankole.Sessions.Driver` 调用 AIGateway 获取模型响应，按需分发执行模型请求的工具并记录返回结果，随后推进下一轮迭代；涉及沙箱环境的工具操作与 Codex Job 则交由 Agent Computer 执行。整体协作关系见 [Agent 循环](../agent-loop/) 与 [Agent Computer Worker](../agent-computer-worker/)。

## 构建当前工具集

每次启动运行时，`Ankole.Sessions.ToolCatalog.for_run/1` 都会将控制面当前的领域工具声明与从 `worker_tools.json` 导出的 Worker 工具声明动态合并。最终暴露给模型的工具列表取决于当次回合类型、所选模型自身能力、已启用的 Skill 与插件，以及主动介入权限——工具集始终按单次运行实时组装，不会作为静态的 Agent 全局工具表持久化保存。

`Ankole.Sessions.Tool` 结构体定义了每项工具对模型可见的 JSON Schema、实际执行方、并发或串行顺序、允许调用的场景，以及只读、破坏性与失败重试元数据。进入调用阶段时，`Ankole.Sessions.Tools.prepare/2` 会先核验调用方资格并解析原始入参，再交由该工具的所属领域模块完成参数规范化与 JSON Schema 校验。

## 在 owner 执行

不同类别的工具按职责归属在各自的执行端运行：

- **控制面领域工具**：会话规划、定时调度、后台 Agent 任务管理、Workflow 编排、Skill 正文读取与领域级联网操作，均由控制面内对应的领域模块直接执行。
- **沙箱环境（Computer）工具**：通过 RuntimeFabric 协议委托给该 Agent 专属的 Worker 执行。首次调用环境工具时会自动初始化并打开对应的 Session 工作区；Worker 负责维护并发槽位与子进程运行态，控制面则负责持久化最终结果。
- **挂载 MCP 的 Skill**：在 Worker 内通过 `command` 终端工具调用 `mcporter` 完成外部交互。
- **提供商托管工具**：经由 AIGateway 直接透传至上游模型提供商执行，组装工具目录时会严格对照当前所选模型声明支持的能力范围。

Driver 会依照各工具声明的并发属性安排并行或顺序调用。凡涉及持久化业务副作用的控制面工具均通过 `Ankole.Sessions.Receipts` 执行，确保领域数据变更与执行回执在同一数据库事务内原子提交；AIGateway 则负责保存工具输出供下一轮模型推理读取。若调用途中遭遇 Worker 连接闪断，Driver 会严格按照工具预先声明的重试契约处置结果存疑的环境操作。

## Workflow 任务工具

Workflow 子任务仅能使用经过严格裁剪的工具子集：联网检索抓取、用于委派与轮询子任务的后台 Agent 任务操作、`sleep` 休眠等待以及 `submit_result` 结果提交；托管 Brain 能力也仅开放只读的 `recall` 与 `get_page`。子任务不具备沙箱文件操作、Shell 终端、Skill 加载、定时计划或嵌套发起新 Workflow 的工具权限。

调用 `submit_result` 时，系统会对照任务创建时持久化保存的结果 Schema 严格校验返回值：若校验未通过，模型可根据报错修正后重新提交；一旦校验通过并获采纳，该子任务即告完结。注意，在正式提交最终结果前，必须先等待或结清名下所有仍在运行中的委派后台任务。详见 [Workflow](../workflows/)。

## 新增工具

新增领域工具时，应将其声明与执行逻辑直接放入控制面对应的领域模块中；新增 Worker 环境工具时，则需在注册进 Worker 工具目录后重新导出生成 `worker_tools.json`。Worker 侧工具统一遵循 `WorkerAgentTool` 接口与 Zod 参数校验契约，开发时务必确保对外暴露的 Schema 与实际执行边界完全一致。
