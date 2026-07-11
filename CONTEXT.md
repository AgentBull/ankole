# Ankole Context

Ankole 是长期运行数字工作的 Agent Operating System。本词汇表统一描述 Actor 工作与 AI Agent 执行中的领域概念。

## AI Agent Execution

**Model Iteration**:
AI Agent 主循环中的一次逻辑模型调用；一次响应无论产生零个、一个或多个工具调用，都只构成一个 Model Iteration。同一次逻辑调用内部的 provider/transport retry 不产生新的 Model Iteration。
_Avoid_: Tool round, tool call, physical request

**Turn Iteration Budget**:
一次 actor turn execution 可使用的 Model Iteration 数量上限。它是 Loop Agent 自身的执行约束，在每次 execution 开始时重建，不跨 worker crash 或 redelivery 持久化，也不属于上游 LLM 的 Responses 协议，不是工具调用数、成本配额或 durable quota。
_Avoid_: Stop policy, max tool calls, tool-round limit, durable budget

**LLM Response Outcome**:
一次上游模型请求本身的结果，只描述该 Response 的生成是否完成、失败或被截断；它不描述 Loop Agent 是否完成用户任务，也不承载 Turn Iteration Budget 的状态。
_Avoid_: Agent turn outcome, task outcome

**Response Completion**:
一个 LLM Response 到达终态的事实，只关闭该次模型请求；它不关闭 Agent Turn 或 Actor Event。
_Avoid_: Turn completion, actor completion

**Response Tool Call Limit**:
Responses 协议中单个 Response 可由 provider 执行的 built-in tool call 总数上限，对应标准字段 `max_tool_calls`。未设置或为 `null` 时，不由该字段施加显式上限，系统不得自行补入数值默认值；这不排除 provider 或 model 自身的其他限制。Provider 原生支持时使用其原生约束；否则 AIGateway 在观察到调用后 best-effort late stop，允许已启动或并行的 built-in tool call 超调，因此它不是成本或副作用的硬配额。它不累计 `previous_response_id` 链，不计算交给 Loop Agent 执行的 function call，也不限制 Agent Turn 的循环次数。
_Avoid_: Turn iteration budget, function-call limit, cross-response quota

**Turn Execution Outcome**:
Loop Agent 执行一次 actor turn 的结果，由循环执行事实决定，与其中任意一次 LLM Response Outcome 分离。最终总结所对应的 LLM Response 可以完整生成，而整个 turn 仍可能因预算耗尽而未完整完成用户任务。
_Avoid_: Response status, provider stop reason

**Agent Turn Completion**:
Loop Agent 在确定 Turn Execution Outcome 后作出的显式终态声明。Durable runtime 依据该声明提交执行结果、用户可见最终回复与 actor event completion；不得根据任意一次 LLM Response 是否含 function call 来推断整个 turn 已结束。
_Avoid_: Response completed, final model response, implicit completion

**Actor Event Completion**:
SignalsGateway 确认一个 Actor Event 已处理并可推进同一 Actor 队列的 durable 事实；它由显式 Agent Turn Completion 或无输出完成事实驱动，而不是由 LLM Response 推断。
_Avoid_: Response completion, task success

**Iteration Exhaustion**:
Loop Agent 在完成用户任务前耗尽 Turn Iteration Budget 的 Turn Execution Outcome。它是 non-retryable：用户仍会收到一次无工具最终总结，但任务不得表示为完整成功；该总结请求本身仍是普通的上游 LLM 请求，其 Response 不因循环预算耗尽而变成 incomplete。
_Avoid_: Response incomplete, provider failure, retryable failure, timeout

**Clarify**:
主 agent 面向用户的 turn-ending 提问原语：提问发出即结束本 turn，用户答案作为新的入站开启下一 turn，进程内不驻留任何等待。独立于委托场景，凡需用户实质裁决即可用。
_Avoid_: Ask user, blocking question

## Background Work

**Subagent Delegation**:
父 agent 交办给 Subagent 的一条 durable 后台工作项，是 Ankole 的第一种后台工作项类型。其生命周期独立于任何进程、worker 或 turn，与父会话只在「创建」与「汇报」两点相接。
_Avoid_: Codex delegation, background job, async task

**Subagent**:
在隔离上下文中执行委托的后台执行者角色，由某个 Delegation Runtime 实现；不继承父会话历史，靠 Handoff 获得工作所需上下文。
_Avoid_: Codex（指角色时）, child agent

**Delegation Runtime**:
实现 Subagent 执行能力的具体引擎（当前唯一实现是 Codex）。委托的生命周期语义不属于 runtime，runtime 只拥有执行机制。
_Avoid_: Runtime（不加限定）, engine

**Brief**:
父 agent 为一次委托显式撰写的唯一任务输入：自包含的目标、路径、约束与验收标准。它是 durable 的，是重派与续跑时重建任务的依据。
_Avoid_: Prompt, task description

**Handoff**:
父会话向 Subagent 移交上下文的三层契约：身份层自动携带（SOUL 与 MISSION）、任务层经 Brief 显式给出、知识层由 Subagent 按需检索。会话历史永不自动携带。
_Avoid_: Context transfer, context dump

**Capability Projection**:
主 agent 能力面向 Subagent 的受限投影：白名单工具加全量 skills，每次派发时重组。Subagent 拿到的是投影，不是主 agent 的工具面本身。
_Avoid_: Tool sharing, MCP bridge

**Delegation Turn**:
承载一次委托执行尝试的 worker 侧 turn 种类。它只是执行载体：委托的队列、状态与真相不归它所有，一次委托可跨多个 Delegation Turn 完成。
_Avoid_: Subagent turn, job

**Delegation Session**:
每个委托专属的 actor 会话，为该委托提供串行投递与租约化执行。它不是对话会话：不携带对话上下文，也不参与会话重置。
_Avoid_: Conversation session

**Attempts**:
一次委托已消耗的真实执行机会数。仅在真正取得执行租约时消耗（placement 失败不计），耗尽后委托以失败终局并唤醒父会话。
_Avoid_: Retries, redelivery count

**Steer**:
对非终态委托追加的转向指令，携带补充方向或对 Subagent 提问的答案。送达不等于已应用：以 runtime 明确接受为准。
_Avoid_: Nudge, interrupt

**Waiting on User**:
委托因 Subagent 提出用户问题而进入的暂停态：执行中断，父 agent 向用户逐题转述，答案经 Steer 回流后续跑。
_Avoid_: Blocked, paused

**Wakeup**:
把后台事实带回父会话并开启一个不允许静默成功 turn 的 durable 事件。来源包括定时回访与委托的完成、失败、等待用户；取消不产生 Wakeup。
_Avoid_: Notification, callback

**Delegation Report**:
Subagent 自述的最终结果报告。它是不可信输入：父 agent 必须亲自复核证据（文件、diff、测试）后，才能据此向用户汇报。
_Avoid_: Result（未经复核时）, Codex output

**Subagent Home**:
一次委托专属的 durable 运行时状态目录，使执行可跨 worker 恢复；终态后限期保留、到期清理。
_Avoid_: CODEX_HOME, scratch directory
