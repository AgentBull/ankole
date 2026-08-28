---
title: Workflow：并行子 Agent
description: 把有界工作拆给并行子 Agent，并在原会话中收回一个结构化结果。
section: User guide
order: 19
---

Workflow 让主 Agent 运行一段固定、有界的程序，把相互独立的任务交给多个子 Agent。它适合批量评审候选项、从有限来源中提取相同字段、比较独立判断，或先并行核验再集中综合。

Workflow 从当前会话启动，并立即返回 `run_id`。任务运行期间，当前会话仍可继续使用。Workflow 完成或失败后，Ankole 会唤醒原会话，让主 Agent 读取结果并继续处理。

## 选择合适的执行方式

| 需求 | 使用 | 原因 |
|---|---|---|
| 一项需要当前对话上下文的短任务 | 主 Agent 回合 | 它保留当前上下文和主回合的完整工具集。 |
| 有限数量的独立核验或固定分析阶段 | Workflow | 它并行运行有界的子 Agent 任务，并返回一个汇总结果。 |
| 一项需要文件、工作区、后续消息或人工确认的长期有状态任务 | [后台 Agent 任务](../background-jobs/) | 它拥有可暂停、可恢复的持久 Codex thread。 |
| 由定时器或 Webhook 触发的机械脚本 | [Automation Job](../automation-jobs/) | 不需要判断时，触发器可以直接运行确定性处理。 |

Workflow 不是通用 DAG 引擎、调度器或事件总线，也不能等待外部事件或你的后续决定。工作开始后还需要调整方向时，应使用后台 Agent 任务。

## 让 Agent 启动 Workflow

在请求中说明有限输入、每个独立任务、完成条件和最终格式。例如：

```text
请把这项工作作为 Workflow 执行。按下面五项标准并行评审这 40 份方案，
返回一份 JSON 结果，包含每份方案的结论、失败的评审和最终候选名单。
不要把范围扩大到这 40 份方案之外。
```

主 Agent 会编写编排程序并启动运行，你不需要自己写 JavaScript 或调用 API。Agent 可以设置单次运行的并发数、子 Agent 调用总数，以及它当前可用的自定义模型档案。未指定模型档案时，Workflow 任务使用 `primary`。

启动后，Agent 会得到运行 ID 和当前的 `running` 状态。主 Agent 不应轮询运行状态。你可以继续在同一会话中交流，也可以稍后主动询问进度。

## 编排程序怎样运行

程序读取创建时固定的 JSON `args`，并调用 `agent(prompt, options)`。放进 `Promise.all` 的调用可以并行执行；前一阶段结束后，普通 JavaScript 条件可以决定是否进入核验或综合阶段。所有集合和循环都必须有明确的有限上界。

下面的简化示例最多评审 20 项，把失败调用保留为 `null`，再综合成功结果：

```js
const items = args.items.slice(0, 20)
const reviews = await Promise.all(
  items.map(item =>
    agent(`评审此项目：${JSON.stringify(item)}`, {
      label: `review-${item.id}`,
      schema: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          verdict: { type: 'string', enum: ['accept', 'reject'] },
          reason: { type: 'string' }
        },
        required: ['id', 'verdict', 'reason'],
        additionalProperties: false
      }
    })
  )
)

const successful = reviews.filter(review => review !== null)
const summary = await agent(`汇总这些评审：${JSON.stringify(successful)}`, {
  label: 'summary'
})

return { reviews, summary }
```

运行开始后，程序和 `args` 都不能修改。控制面重启时，会根据已持久保存的任务结果重放固定程序。已经保存成功结果的任务不会重新创建，但被中断的任务可能重试，因此不要把任务执行理解为严格一次。

## 每个子 Agent 可以访问什么

每次 `agent()` 调用都在独立、短期的会话中运行。子 Agent 会得到 Agent 的身份、使命和当前任务提示，但不会得到原会话转写。除非编排程序把前一阶段的结果写进后续提示，否则任务之间也看不到彼此的结果。

Workflow 任务可以使用 Web 工具；Brain 启用时，还可以使用只读的 `recall` 和 `get_page`。它唯一可以持久写入的工具是 `submit_result`。任务没有 shell、文件、MCP、Skill、调度、Workflow 或后台 Agent 任务工具，也不能继续创建嵌套任务。

每次调用最多进行三次完整任务尝试。成功调用会得到提交值；三次尝试都失败时，调用结果为 `null`。程序可以记录失败并继续，也可以在最终结果中说明为何未完整完成。单个任务失败不会自动让整个 Workflow 失败。

## 要求结构化结果

`agent()` 调用可以声明结果 schema。Ankole 会以 Provider strict 模式发送动态生成的 `submit_result` 工具，并在控制面再次校验提交值。schema 拒绝不会结束当前任务，子 Agent 可以修正后重新提交。

该 schema 是 OpenAPI 3 JSON Schema 的封闭子集，不是完整规范。结果只能有一个非空类型：`object`、`array`、`string`、`number`、`integer` 或 `boolean`。每个对象，包括嵌套对象，都必须声明 `properties`，在 `required` 中列出全部属性，并设置 `additionalProperties: false`。不支持可选对象属性、nullable、union、`$ref`、`oneOf`、`anyOf` 或 `allOf`。

未指定 schema 时，任务返回字符串。编排程序必须返回最终汇总结果：字符串会直接成为结果文本，其他 JSON 值会编码为 JSON 文本。

## 读取、列出或取消运行

可以让主 Agent 使用以下操作：

- `show_workflow` 返回状态、任务计数、最多十条失败摘要和终态错误。已完成结果从字节偏移量 `0` 开始读取，每段最多包含 8,000 个 UTF-8 字节。
- `list_workflows` 列出当前 Agent 的运行中或已结束 Workflow，每页最多 32 条。已结束状态包括 `completed`、`failed` 和 `cancelled`。
- `cancel_workflow` 是幂等操作。它先阻止新任务和迟到结果重新激活运行，再请求正在执行的任务回合停止。已经发出的模型调用可能需要短暂时间才能停止。

完成和失败会唤醒原会话；取消不会发送该完成事件。需要确认取消结果时，可以让 Agent 再查询一次状态。

当前版本没有 Workflow Console 页面。主 Agent 的 Workflow 工具是受支持的用户入口。

## 控制成本和容量

每次任务尝试都是一个完整模型回合，也可能产生付费 Web 调用。并发只改变完成时间，不会减少总调用数。应根据有限输入设置调用上限，并让每个任务的提示和结果保持精简。

| 边界 | 默认值 | 硬上限 |
|---|---:|---:|
| 单次运行的并发任务 | 8 | 32 |
| 单个 Agent 正在运行的 Workflow 任务 | 8 | 64 |
| 单次运行的子 Agent 调用 | 256 | 1,024 |
| 单次子 Agent 调用的尝试次数 | 最多 3 | 3 |
| 已保存程序 | — | 256 KiB |
| 已保存 `args` | — | 64 KiB |
| 单次调用参数对象 | — | 8 KiB |
| 单次提交结果值 | — | 24 KiB |
| 最终汇总结果 | — | 1 MiB |

管理员可以在 [AppConfigure](../app-configuration/) 中按硬限制范围设置前三项实例上限，单次运行请求不能抬高实例上限。Workflow 没有覆盖整批任务的 token 或金额预算；每个任务仍受普通回合的迭代次数、输出 token 和无活动超时限制。相关控制方法见[成本管理](../cost-management/)。

运行达到大小限制时，应减少 fanout、让任务返回更短的摘要，或把输入拆成多个 Workflow。程序或输入需要变化时，应创建新运行；失败的运行不能换一段代码后原地恢复。
