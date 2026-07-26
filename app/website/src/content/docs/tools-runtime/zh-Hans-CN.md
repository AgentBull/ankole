---
title: 工具运行时
description: worker 如何收集、schema 化、分发一个回合提供给模型的工具——AgentTool 契约、按回合组装、schema 转换、调用分发路径。
section: Developer guide
order: 120
---

一个回合中，worker 组装模型可调用的工具集，把每个工具的 schema 转成模型看到的 JSON Schema，并把模型发出的每次 function call 分发回工具的 `execute` 函数。本页文档化该运行时：`AgentTool` 契约、按回合工具集如何组装、schema 如何收集、循环如何分发一次调用。它建立在 [Agent 循环](../agent-loop/) 和 [Agent Computer Worker](../agent-computer-worker/) 之上。

先把决定性的性质说清楚：工具**按回合组装，不静态注册**。每个回合从回合所需的类别——computer、web、brain、schedule、MCP、后台任务——构建工具集，且集合对每个回合是全新的，因为已启用 skill、MCP server、worker 环境可能在回合间变化。没有全局工具注册表；只有按回合的集合。

## AgentTool 契约

每个工具实现 `AgentTool` 接口。运行时关心的字段：

| 字段 | 类型 | 做什么 |
|---|---|---|
| `name` | string | 模型看到并调用的工具名 |
| `description` | string | 工具做什么——模型读它来决定是否调用 |
| `schema` | Zod schema | 输入参数，在 `execute` 运行前校验 |
| `executionMode` | `'parallel' \| 'sequential'` | 工具能否与同响应中的其他工具并行 |
| `isReadOnly` / `isDestructive` | boolean | 活动报告和安全检查的元数据 |
| `describeActivity` | function | 从已校验参数构建简短人类可读标签（用于进度） |
| `describeCompletedActivity` | function（可选） | 工具完成时用结果摘要替换标签 |
| `execute` | function | 运行工具；返回内容、详情、可选呈现事件，可终止回合 |

`execute` 函数是工具的实际工作。它接收已校验参数（schema 已解析并检查）、一个 abort signal，返回一个 `AgentToolResult`——模型看到的内容、用于日志的结构化详情、可选回复呈现事件，以及可选的完成 actor 事件或终止回合标志。

## 工具集如何按回合组装

`text_turn.ts` 在每个回合开始时构建工具集，从各类别创建器组合工具：

```typescript
tools = [
  createTodoTool(...),
  ...createComputerTools({...}),
  ...webTools,
  ...mcpTools,
  ...brainTools,
  ...scheduleTools,
  ...backgroundAgentJobTools,
  ...
]
```

每个类别创建器是一个函数，返回一个或多个 `AgentTool` 对象，用回合上下文（worker 环境、agent home、RPC client、abort signal）配置。组装是显式且有序的——没有反射、没有自动发现、没有装饰器扫描。工具在数组里就可用；不在就不可用。

按回合组装是让工具集动态的原因：

- **MCP 工具**从 agent 已启用 skill 的 `openai.yaml` 声明创建——不同的已启用 skill 集产生不同的 MCP server 集，从而不同的 MCP 工具集。
- **Web 工具**从 worker 的 `web_search`/`web_fetch` provider 可用性创建——profile 未绑则工具缺席。
- **后台任务工具**从回合上下文创建——仅在回合支持派生任务时可用。

这就是工具集不是静态注册表的原因：它反映 agent 在此回合、此配置下实际能做什么。

## Schema 收集

模型需要 JSON Schema，不是 Zod。`tool-schema.ts` 转换每个工具的 Zod schema：

```typescript
export function zodToJSONSchema(schema: z.ZodType): JSONObject {
  const jsonSchema = z.toJSONSchema(schema) as JSONObject
  if (jsonSchema.type !== 'object') {
    throw new Error('function tool parameters must use a root object schema')
  }
  return jsonSchema
}
```

收集的 schema——每个工具一个，加工具名和描述——在 Responses 请求中发给模型。模型看到工具名、描述和每个工具参数的 JSON Schema，并决定调哪个。

模型返回 function call 时，参数以 JSON 字符串到达。`validateToolArguments` 把字符串按工具的 Zod schema 解析，对畸形参数（截断的 JSON、代码围栏 JSON、不平衡对象）带一个有界修复阶梯。工具的 `execute` 永远不接收原始模型输出——它接收 schema 已校验的参数。

## 循环如何分发一次调用

模型响应包含 function-call 项时，agent 循环：

1. **构建工具 map**——`agentToolMap(tools)` 把数组变成以工具名为键的 `Map<string, AgentTool>`。
2. **校验参数**——每次调用的参数字符串按工具 schema 解析校验，需要时修复。
3. **执行**——工具的 `execute` 函数带着已校验参数和 abort signal 运行。`executionMode: 'parallel'` 的工具可并发；顺序工具按序。
4. **记录结果**——`AgentToolResult` 作为 function-call-output 消息发给 AIGateway，模型在下一次迭代看到。

循环拥有迭代——它调模型、执行工具、记录结果、重复，直到模型不再返回 function call。工具不决定何时运行；循环决定，基于模型请求了什么。

## 本指南不是什么

它不是工具编写教程——一个新工具是从类别创建器返回的 `AgentTool` 对象，已有类别（`tools/computer/`、`tools/web/`、`tools/brain/`）是参考。它不是模型行为指南——模型调哪些工具是人设的事，不是运行时的。它也不是 agent 循环页的替代；分发路径是循环的一部分，循环页是上下文。

## 下一步

- 分发工具调用的循环，读 [Agent 循环](../agent-loop/)。
- 跑工具的 Agent Computer Worker，读 [Agent Computer Worker](../agent-computer-worker/)。
- MCP 工具（从 skill 声明创建），读 [MCP server 参考](../mcp/)。
- 携带 MCP 依赖的 skill，读[编写 skill](../writing-a-skill/)。
