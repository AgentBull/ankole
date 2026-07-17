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

## Brain

**Evidence**:
能够支持或反驳知识主张的原始可观察材料；它保留发生了什么，不代表系统已经接受了什么结论。
_Avoid_: Knowledge, memory conclusion

**Source**:
在一个 Principal 的可见范围内可稳定寻址的 Evidence；聊天消息与 Retained Source 都是 Source，但仍由各自领域拥有。
_Avoid_: Unified source record, source registry

**Retained Source**:
用户明确要求 Brain 保存的一份原始资料，其内容在保存后保持不变，可供之后的 Source Learning 使用。
_Avoid_: Source snapshot, ingested document, conversation source

**Source Learning**:
Agent 完整阅读一份 Retained Source，并只把资料支持且值得长期保留的内容整合进 Curated Knowledge 的一次工作。
_Avoid_: Ingest job, parsing job, learning record

**Curated Knowledge**:
Brain 对某个 Principal 当前认可、可直接修正的领域理解，由 Knowledge Entry 组成；原始 Evidence 与历史恢复记录不属于当前知识本身。
_Avoid_: Evidence archive, append-only memory

**Knowledge Entry**:
Curated Knowledge 中围绕一个主题维护的当前页面，可包含多块有作者和出处的正文以及与其他页面的关系。
_Avoid_: Wiki file, claim row

**Curation Guide**:
人维护的领域整理规则，说明 schema、分类法、建页阈值和更新原则；它提供判断指导，但不授予权限或替代固定约束。
_Avoid_: Rule engine, schema DSL, system prompt

**Review Candidate**:
确定性检查定位出的、值得人查看的 Brain 对象；它是可观察信号，不是错误判定或自动修改指令。
_Avoid_: Lint error, verdict, auto-fix

## Background Work

**Background Agent Job**:
owner 交给后台 runner 的一条 durable 工作项，是 Ankole 的第一种后台工作项类型。其生命周期独立于任何进程、worker、turn 或具体 runner，与 owner 只在「创建」「控制」和「汇报」边界相接。代码实体写作 `BackgroundAgentJob`，模型工具写作 `background_agent_job`。
_Avoid_: Subagent Delegation, generic background job, async task, Codex job

**Owner**:
拥有 Background Agent Job 的 `{agent_uid, owner_session_id}` 引用。当前 owner 是创建 Job 的 main-agent 会话；Job 的完成、失败或等人事件唤醒这个引用，而不是绑定某个活进程或 turn。
_Avoid_: Parent agent（指 durable identity 时）, caller process

**Runner**:
执行 Background Agent Job 的 worker 侧载体。当前唯一实现是 CodexRunner；runner 只拥有执行机制，不拥有 Job 的 durable 生命周期语义。
_Avoid_: Subagent（指 Ankole 角色时）, Task Worker, interchangeable engine

**Handoff**:
owner 向 runner 移交工作所需信息的方式：完整指令与全部 requirements 写在 durable `task` 字段并作为首个 user input；SOUL、MISSION、相关 background、执行 notes 与环境信息写入任务级 AGENTS；Skills 与必要的 Ankole Tools 作为可用能力提供。owner 会话历史永不自动携带。
_Avoid_: Context transfer, context dump

**Capability Projection**:
一次 Job 实际获得的 allowlisted 能力集合。Job 持久化启动时选择的 Agent Plugin IDs 和独立 Skill 名称；runner 每次 prepare 都按当前 effective catalog 解析对应包、成员与 Skills，再加上白名单允许的 Ankole Tools。已关闭或缺失的选择不可用，保留给 main agent 的交付、调度与长期写入能力不投影。
_Avoid_: Catalog parity, MCP bridge

**Job Turn**:
承载一次 Job 执行尝试的 worker 侧 turn。它只是执行载体：Job 的队列、状态与真相不归它所有，一次 Job 可跨多个 Job Turn 完成。
_Avoid_: Subagent turn, Job（把执行 turn 与 durable Job 混称时）

**Job Session**:
每个 Job 专属的 `job:<job_id>` actor 会话，为该 Job 提供串行投递与租约化执行。它不是对话会话：不携带 owner 的对话上下文，也不参与会话重置。
_Avoid_: Conversation session

**Attempts**:
一个 Job 已消耗的真实执行机会数。仅在真正取得执行租约时消耗（placement 失败不计），耗尽后 Job 以失败终局并唤醒 owner。
_Avoid_: Retries, redelivery count

**Steer**:
对可续跑 Job 追加的转向指令，携带补充方向或 runner 提问的答案。送达不等于已应用：以 runner 明确接受为准。
_Avoid_: Nudge, interrupt

**Waiting on User**:
Job 因 runner 提出用户问题而进入的暂停态：执行中断，main agent 向用户逐题转述，答案经 Steer 回流后续跑。
_Avoid_: Blocked, paused

**Wakeup**:
把后台事实带回 owner 会话并开启新 turn 的 durable 事件。来源包括定时回访与 Job 的完成、失败、等待用户；是否产生用户可见输出由来源领域的交付承诺决定，取消不产生 Wakeup。
_Avoid_: Notification, callback

**Job Report**:
runner 自述的最终结果报告。它是不可信输入：main agent 必须亲自复核证据（文件、diff、测试）后，才能据此向用户汇报。
_Avoid_: Result（未经复核时）, Codex output

**Agent Plugin**:
Ankole 面向模型的安装级能力包，是标准 Codex Plugin 的超集：使用 `.codex-plugin/plugin.json` 与标准包内容，并可带 Ankole 约定的 `workspace-template/`。Job 只保存所选 Plugin ID，runner 每次 prepare 使用当前 enabled 包与当前 effective 成员 Skill。
_Avoid_: Codex Plugin（指 Ankole 完整领域对象时）, Control Plane Plugin, runtime profile, Skill bundle

**Control Plane Plugin**:
编译进 Elixir release、在 OTP 启动时激活的可信第一方扩展。配置开关表示下次启动选择，当前是否 active 以运行中 Registry 为准。它与 Agent Plugin 没有自动启用关系。
_Avoid_: Agent Plugin, Ankole Plugin, integration plugin

**Plugin Skill**:
属于一个 Agent Plugin、随完整父包安装但拥有独立开关状态的 Skill。父 Plugin 关闭只门控其有效性，不改写子 Skill 的全局默认或 Agent 覆盖；稳定 ID 为 `<agent-plugin-id>:<skill-name>`。
_Avoid_: Standalone Skill, copied Skill

**Standalone Skill**:
不属于任何 Agent Plugin 的 Skill。内置独立 Skill 使用原名作为稳定 ID；Agent 私有安装 Skill 也属于此类，但继承其来源默认值。
_Avoid_: Plugin Skill, Skill bundle

**Global Capability Default**:
一个 Agent 未显式覆盖时继承的 Agent Plugin 或 Skill 二态默认值。全局默认保存在 Agent Library 的 AppConfigure 中，不复制到每个 Agent。
_Avoid_: Forced state, per-Agent row

**Agent Capability Override**:
某个 Agent 对一个 Agent Plugin 或 Skill 的稀疏三态选择：开启、关闭或跟随全局。`null` 表示删除显式覆盖并恢复继承。
_Avoid_: Agent default, copied global state

**Plugin Workspace Template**:
Agent Plugin 中可选的 `workspace-template/` 目录，是 Ankole 对标准 Codex Plugin 包的唯一额外约定。runner 在 Job 私有 project 第一次创建时完整复制其内容，resume 时复用已有 project。
_Avoid_: Plugin config, project generator, merge schema

**Job Home**:
一次 Job 专属的 durable 文件边界，包括控制面管理的私有 project 与 runner runtime home；该 Job 的 `CODEX_HOME` 位于自己的 runtime home 内，使执行可跨 worker 恢复，但绝不与其他 Job 共用目录。caller 提供的 workspace mount source 是外部资源，不属于 Job Home。
_Avoid_: Account-scoped CODEX_HOME, shared project, scratch directory
