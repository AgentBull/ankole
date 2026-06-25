# Ankole 主链路对齐审计报告

**审计日期：** 2026-06-25  
**审计范围：** Ankole 主仓库 `main` 分支（`app/agent_computer`、`app/control_plane`、`app/kernel`、`libs/`、`plugins/`）  
**参考基准：** `backup/bun-legacy`（能力与用户故事参考）；`backup/elixir-legacy`（历史意图参考）  
**审计方法：** 静态代码路径追踪；不运行破坏性命令；不修改业务代码

---

## 1. 审计结论摘要

- **当前主链路不可视为已验收。** 存在至少两个 P0 级阻断性缺陷，会导致多轮对话彻底失效，以及 steer 命令在生产路径中完全不可达。
- **最大阻塞：对话历史无法传递给 worker。** 控制面（Elixir）将消息写入 Postgres，但从不把消息写出到 worker 可读的文件系统路径。Worker 每轮读取 `messages.jsonl` 时，文件根本不存在，每轮均以空上下文启动。这使得 Ankole 不是"长期运行的数字工作执行体"，而是一个失忆的单轮聊天机器人。
- **第二大阻塞：生产 ZMQ 主循环阻塞，steer 信封被丢弃。** `main.ts` 是单线程同步事件循环，在 `await handleActorBusEnvelope(...)` 期间不处理其它信封；`handleActorBusEnvelope` 对 `mailbox_updated`（控制面 steer 传输信封）走 `default: return []` 静默丢弃。`pollSteering` 也未传入生产路径。
- **必须优先修的问题：** P0-1（conversation history 从未写入 workspace）、P0-2（steer 命令在生产路径中断）、P1-1（worker 容量上报失真 + 单线程阻塞心跳）、P1-2（LLM usage/token 数据无法持久化）。
- **其次修的问题：** P1-3（provider source ↔ catalog 映射缺口）、P1-4（stale worker 检测 TTL 为 3600s）、P1-5（dead-letter 逻辑有字段无实现）、P1-6（docker run 命令缺少 `actors/` 挂载）。
- **不应算 bug 的未来能力：** 多 agent 协作、桌面端、语音、budget/billing、全量搜索/Codex 调度、细粒度企业权限、跨频道上下文学习——这些均未声称已实现，不属于当前验收范围。
- **结构性复杂度：** `signals_gateway.ex`（2406 行）和 `actor_runtime.ex`（1727 行）超出单文件可维护上限，需要拆分。`turn_child.ts` 是独立的 stdin 子进程入口，与 `main.ts` ZMQ 循环是并行实现，但当前生产路径只使用 `main.ts`，`turn_child.ts` 的 steer 逻辑实际上是死代码。

---

## 2. 当前版本边界

### 本轮必须验收的能力

| 能力 | 说明 |
|---|---|
| IM/消息入口 → agent/conversation 归属 | 用户通过 IM 发送消息，系统识别 agent 和会话 |
| durable message 持久化 | 消息写入 Postgres，具备 crash 恢复 |
| Actor Computer turn loop | 控制面调度 worker，ZMQ 传递 TurnStart |
| 真实 LLM 调用 | Worker 解析 credential，调用 Anthropic/OpenAI/Google |
| Tool/function calling | Agent loop 支持工具调用（computer tools、skill tools、todo） |
| Assistant reply/outbox | Worker 返回 FinalProposal，控制面写入 assistant message，outbox 回写 IM |
| 多轮对话上下文 | 每轮能读取历史消息，对话连续 |
| steer 命令 | 用户可在 agent 回复过程中注入指引 |
| compress 命令 | 支持压缩历史对话降低 token 占用 |

### 明确不作为当前 bug 的未来能力

- 多 agent 协作、subagent
- 桌面端、语音输入
- 复杂企业权限、细粒度审计
- budget/billing 系统（catalog 中的 cost 全为零是已知 tradeoff）
- 全量搜索、Codex 调度、ambient 主动提醒
- 跨频道上下文学习
- Google Vertex、Amazon Bedrock、Mistral 等 catalog 中存在但控制面未开放的 provider（属于未来扩展，不是当前 bug）

### 判断边界的理由

问题陈述明确表示：如果代码或文档已经声称某项能力属于当前主链路，或直接影响 IM 对话 → LLM turn loop → tool calling → assistant reply/outbox 的闭环，则必须按当前功能审计。多轮对话上下文和 steer 均被声称为已实现功能，因此列入验收范围。

---

## 3. 文档预期与实现映射

| 文档/用户故事预期 | 当前实现证据 | 状态 | 问题摘要 | 建议动作 |
|---|---|---|---|---|
| IM 消息 → actor input → 持久化 | `SignalsGateway.emit_entry/1` 写入 `actor_inputs`，有 migration | 已满足 | — | — |
| Conversation/channel 归属 | `Conversation` schema、`signal_binding`、`signal_channel` | 已满足 | — | — |
| 控制面调度 → ZMQ TurnStart | `ActorRuntime.start_llm_turn/2` → `Transport.Broker.send_mandatory/3` | 已满足 | — | — |
| Worker ZMQ 接收 TurnStart | `main.ts` DEALER 循环 → `handleActorBusEnvelope` | 已满足 | — | — |
| 真实 LLM 调用（Anthropic/OpenAI/Google） | `runtimeModelFromCredential` + `createSdkModel` + AI SDK 调用 | 已满足 | provider_source 仅 4 个，catalog 覆盖 15+ | 扩展 DB constraint 或对齐 provider mapping |
| 多轮对话历史 | Worker 尝试读 `messages.jsonl`；控制面从不写该文件 | **未满足** | **P0：每轮均为空上下文** | 控制面在 TurnStart 前将历史导出到 workspace 文件，或在 TurnStart 信封内嵌入 |
| Tool/function calling | `runAgentLoop` + computer tools + skill tools | 已满足 | `observeAgentEvent` 为 no-op，tool events 全丢弃 | 实现 event sink，至少记录 usage |
| steer 命令（活跃 turn 期间） | 控制面发送 `mailbox_updated`；`handleActorBusEnvelope` 丢弃；`pollSteering` 未传入生产路径 | **未满足** | **P0：生产路径 steer 完全不可达** | 在生产循环中传递 steer 或切换到 `turn_child.ts` 子进程模式 |
| compress 命令 | 控制面构建压缩 LlmTurn；Worker 侧有 `runCompressionTurnHandler`；`actor_input_envelope` 注入压缩 payload | 部分满足 | compress 路径逻辑存在，但未测试；conversations 历史本身就读不到（P0-1 影响） | 依赖 P0-1 修复后验证 |
| LLM usage/token 持久化 | `LlmTurn.usage` 字段存在但始终为 `{}`；`FinalProposalBody` 无 usage 字段 | **未满足** | **P1：token 计量完全缺失** | 在 FinalProposal 中加入 usage；commit_coordinator 写入 |
| Assistant reply → outbox | `CommitCoordinator.commit_final_proposal` + `OutboxDispatcher` | 已满足 | — | — |
| Worker 心跳 / liveness 检测 | `workerHeartbeatEnvelope` 15s 间隔；但 turn 期间主循环阻塞 | 部分满足 | **P1：长 turn 期间心跳停发** | 将 turn 执行移到 worker 线程或子进程，主循环持续心跳 |
| stale worker 检测与清理 | `Watchdog`；stale_worker_ttl 默认 3600s | 部分满足 | P1：1 小时才能检出崩溃 worker | 缩短 TTL 到 60-120s |
| dead-letter 保护（actor input 无限重试） | `dead_letter_at` 字段有，`@states ~w(open dead_letter)` 有，但无任何代码设置 dead_letter 状态 | **未满足** | **P1：失败 input 无上限重试** | 实现最大尝试次数后标记 dead_letter |
| Worker 容量上报 | 总是上报 `available_turn_slots: 4, active_turns: 0` | 部分满足 | P1：容量数字失真，不反映实际并发 | 跟踪活跃 turn 数并在 heartbeat 中上报 |
| 文件组织（单文件行数） | `signals_gateway.ex`(2406)、`actor_runtime.ex`(1727)、`agent-loop.ts`(1295) | 部分满足 | P2：超大文件，可读性和维护性差 | 拆分模块 |
| Docker worker bootstrap | `WorkerBootstrap.docker_run_command/1`；未挂载 `actors/` 目录 | 部分满足 | P1：workspace 挂载不完整 | 挂载 actors/ 目录（前提是 P0-1 修复方案依赖文件系统） |

---

## 4. 问题清单

### P0-1: 对话历史文件从不写入 workspace，每轮均为空上下文

- **严重程度：** P0
- **影响范围：** 主链路 / Agent Computer / 多轮对话
- **相关用户故事：** 用户与 agent 多轮对话，agent 能记住之前说了什么
- **具体位置：**
  - `app/agent_computer/src/llm_runtime/text_turn_loop.ts:369-408`（`loadConversationContext` 读取 JSONL）
  - `app/agent_computer/src/llm_runtime/text_turn_loop.ts:376`（`if (!existsSync(path)) return { messages: [], ... }`）
  - `app/control_plane/lib/ankole/actor_runtime/commit_coordinator.ex`（写 Postgres，从不写文件）
  - `app/control_plane/lib/ankole/actor_runtime/worker_bootstrap.ex`（`docker run` 命令：挂载 `user-files`、`temp`、`library-containers`，不挂载 `actors/`）
- **当前行为：**
  - Worker 调用 `loadConversationContext(workspaceRoot, turnStart, model)`，构造路径 `{workspaceRoot}/actors/{agent_uid}/{session_id}/conversation/messages.jsonl`
  - `safePath` 将 `/workspace/actors/...` 相对于 `workspaceRoot`（默认 `/workspace`）解析为 `/workspace/actors/...`
  - `existsSync(path)` 返回 false（文件根本不存在），函数立即返回空 `ConversationContext`
  - `conversation.messages === []`，用于构建 LLM 请求的历史为空
  - 控制面 `CommitCoordinator` 将消息写入 Postgres `messages` 表，但没有任何组件将这些消息导出到文件系统
  - `WorkerBootstrap.docker_run_command/1` 不挂载 `actors/` 目录
- **预期行为：**
  - Worker 启动每轮时能读取当前会话的完整历史消息
  - LLM 接收包含前序对话的 `messages` 数组，具备上下文连续性
- **为什么这是问题：**
  - 多轮对话是 Ankole agent 的基本用户故事，没有历史上下文就不是"智能助手"
  - 每轮都是全新起点，agent 无法引用用户之前说过的任何内容
  - compress 命令写入 `kind: "summary"` 的 Message 也永远不会被 worker 读取，compress 功能虽然实现了但毫无效果
- **证据：**
  - 全仓库 grep `writeFileSync|File.write|appendFileSync` 无任何写入 `messages.jsonl` 的代码
  - `commit_coordinator.ex` 只调用 `repo.insert()` 写 Postgres，无任何文件系统写入
  - `worker_bootstrap.ex` 的 `docker_run_command/1` 中没有 `actors/` 挂载点
  - `loadConversationContext` 行 376：`if (!existsSync(path)) { return { messages: [], materializedInputIds: new Set(), systemNotes: [] } }`
- **建议解决方案：**
  - **方案 A（推荐）：在 TurnStart 信封中内嵌历史消息（无文件系统依赖）**
    - 控制面在构建 `turn_start_envelope` 时，从 Postgres 查询当前 conversation 的历史消息，序列化为 JSON 数组，嵌入 TurnStart 的 `context` 字段
    - Worker 从 `turnStart.context.messages` 读取历史，不再依赖文件
    - 优点：无文件系统挂载问题；控制面完全掌控历史内容；crash safe；deployment 简单
    - 缺点：大型对话会使 TurnStart 信封变大（但可 token-bound 截断）
  - **方案 B：控制面在每次 TurnStart 前将历史导出到 workspace 文件**
    - CommitCoordinator 在 commit 后，将完整历史写入 `/workspace/actors/{uid}/{session}/conversation/messages.jsonl`
    - WorkerBootstrap 挂载该目录
    - 缺点：文件系统必须在控制面和 worker 间共享（需 NFS/shared volume）；维护两份真实来源
- **不建议的修法：**
  - 不要在 worker 侧写入文件后再读——worker 没有持久存储
  - 不要把文件系统作为主要真实来源（Postgres 才是 SSOT）

---

### P0-2: 生产路径 steer 命令完全不可达

- **严重程度：** P0
- **影响范围：** 主链路 / Agent Computer / steer 命令
- **相关用户故事：** 用户在 agent 正在回复时发送指引消息，agent 能在当前轮次中感知并调整输出方向
- **具体位置：**
  - `app/agent_computer/src/runtime.ts:142-174`（`handleActorBusEnvelope`：只处理 `turn_start`，`default: return []`）
  - `app/agent_computer/src/main.ts:79-101`（生产 ZMQ 主循环，`await handleActorBusEnvelope` 阻塞期间无法处理新信封）
  - `app/agent_computer/src/llm_runtime/text_turn_loop.ts:127`（`pollSteering?.() ?? []`：生产调用未传入 `pollSteering`）
  - `app/control_plane/lib/ankole/actor_runtime.ex:620-635`（`prepare_active_steer`：发送 `mailbox_updated` 信封）
  - `app/agent_computer/src/turn_child.ts`（正确实现了 steer via stdin，但此文件未被生产路径使用）
- **当前行为：**
  - 控制面收到 `command.steer` 输入后，通过 `prepare_active_steer` 创建 `mailbox_updated` 信封并通过 ZMQ ROUTER 发送给 worker
  - 生产 worker（`main.ts`）在执行 turn（`await handleActorBusEnvelope(...)`）期间，ZMQ DEALER 的 `dealer.recv(500)` 被包在内层 credential 等待循环中，外层主循环暂停
  - 即使外层循环能接收到 `mailbox_updated`，`handleActorBusEnvelope` 的 switch 也会走 `default: return []`，完全丢弃
  - `runLlmTurnHandlers` 调用 `runTextTurnLoop`，传入 `pollSteering: undefined`（`opts.pollSteering?.() ?? []` 永远返回 `[]`）
  - `turn_child.ts` 实现了正确的 stdin 协议，包括 `pollSteering()` 和 steer 消息队列，但 `main.ts` 从不 spawn 子进程
- **预期行为：**
  - 控制面发送 steer 指令后，worker 当前正在执行的 LLM loop 能在下一个 `getSteeringMessages` 回调时感知到 steer 内容并注入到 system prompt 或 user turn
- **为什么这是问题：**
  - steer 是 Ankole 产品中区别于普通聊天的核心能力之一；没有 steer，用户无法干预正在运行的 agent
  - `turn_child.ts` 已经有完整实现，但生产路径完全绕过它，造成"代码看起来完整，实际完全不工作"的误导
- **证据：**
  - `runtime.ts:172`：`default: return []`——任何非 `turn_start` 类型信封均被丢弃
  - `runtime.ts:163-166`：`runLlmTurnHandlers(turnStart, { workspaceRoot: config.workspaceRoot, requestCredential: deps.requestCredential })`——无 `pollSteering`
  - `turn_child.ts:55`：`pollSteering` 作为参数传入，但此文件无法从 `main.ts` 到达
  - 整个 `main.ts` 没有任何 `spawn`、`fork`、`Bun.spawn`、`child_process` 调用
- **建议解决方案：**
  - **方案 A（推荐）：`main.ts` 切换到子进程模式（对齐 `turn_child.ts`）**
    - 每收到一个 `turn_start`，main 进程 `Bun.spawn(['bun', 'src/turn_child.ts'])` 启动子进程
    - 通过 stdin/stdout 传递 `turn_start`、credential response、steer 消息
    - 控制面发送 `mailbox_updated` 时，main 进程解析内容后通过 stdin 向子进程写入 `{ type: 'steer', ... }`
    - 主循环持续运行，能同时心跳和接收 steer
    - 这也自然解决了"turn 阻塞心跳"的问题
  - **方案 B：在 `handleActorBusEnvelope` 中处理 `mailbox_updated`，通过共享内存或队列传递 steer**
    - 增加一个全局 steer 队列，`mailbox_updated` 处理函数将 steer 内容写入，`pollSteering` 从队列读取
    - 问题：主循环阻塞期间仍无法接收信封，需要配合异步化改造
- **不建议的修法：**
  - 不要用轮询 DB 的方式获取 steer（引入不必要的数据库依赖和延迟）
  - 不要只在测试中传入 `pollSteering` 就认为已经修复

---

### P1-1: Worker 容量上报失真，单线程主循环在 turn 期间无法心跳

- **严重程度：** P1
- **影响范围：** 主链路 / 调度 / worker liveness
- **相关用户故事：** 控制面准确知道 worker 的空闲程度，合理调度 turn
- **具体位置：**
  - `app/agent_computer/src/runtime.ts:64-65`（`workerReadyEnvelope`：`available_turn_slots: 4`）
  - `app/agent_computer/src/runtime.ts:93-94`（`workerHeartbeatEnvelope`：`active_turns: 0`）
  - `app/agent_computer/src/runtime.ts:118-123`（`workerCapacityEnvelope`：同样硬编码）
  - `app/agent_computer/src/main.ts:63-101`（主循环：`await handleActorBusEnvelope` 在 turn 期间阻塞外层循环）
- **当前行为：**
  - 每次 heartbeat 都报告 `active_turns: 0`，即使正在执行 turn
  - `workerCapacityEnvelope` 和 `workerReadyEnvelope` 固定报告 `available_turn_slots: 4`
  - 生产主循环是单线程，`await handleActorBusEnvelope` 期间外层 `while (!stopping)` 暂停，heartbeat 检查 `if (Date.now() >= nextHeartbeatAt)` 不执行
  - 在一次 30 秒 LLM turn 期间，可能 2-3 个 heartbeat 周期（15s × 2）被跳过
- **预期行为：**
  - Heartbeat `active_turns` 应反映当前并发 turn 数
  - Heartbeat 应在 turn 执行期间仍能持续发送（不因 turn 阻塞而停止）
- **为什么这是问题：**
  - 控制面依据 `available_turn_slots` 和 `active_turns` 判断是否可以再分配 turn；`active_turns: 0` 会导致控制面认为 worker 始终空闲，可能重复分配 turn
  - 心跳停止会使控制面误判 worker 已死（虽然 stale_worker_ttl 是 3600s，但依然是隐患）
  - 当 P0-2 修复为子进程模式后，此问题变得更容易解决（主进程始终循环）
- **证据：**
  - `runtime.ts:93`：`active_turns: 0`（硬编码）
  - `main.ts:67-101`：整个 turn 处理在 `for (const response of await handleActorBusEnvelope(...))` 中，主循环挂起
- **建议解决方案：**
  - 切换到子进程模式（P0-2 方案 A）后，主进程可以跟踪活跃子进程数，在 heartbeat 中上报真实 `active_turns`
  - 如果保持单线程，至少把 `available_turn_slots` 改为 1（实际单线程只能跑 1 个 turn），让调度更诚实
- **不建议的修法：**
  - 不要靠增加心跳轮询间隔来掩盖问题

---

### P1-2: LLM usage/token 数据从未持久化

- **严重程度：** P1
- **影响范围：** LLM runtime / 计量 / 可观测性
- **相关用户故事：** 运营者能了解每次 LLM turn 消耗了多少 token，便于成本分析和限额管理
- **具体位置：**
  - `app/agent_computer/src/llm_runtime/text_turn_loop.ts:558`（`observeAgentEvent` 为空函数）
  - `app/agent_computer/src/ping_pong_handler.ts:14-17`（`FinalProposalBody` 无 `usage` 字段）
  - `app/control_plane/lib/ankole/actor_runtime/commit_coordinator.ex:448-466`（`mark_llm_turn_succeeded` 不读取 usage）
  - `app/control_plane/lib/ankole/ai_agent/schemas/llm_turn.ex:50`（`field :usage, :map, default: %{}`——存在但永远是 `{}`）
- **当前行为：**
  - `runAgentLoop` 调用 LLM，SDK 返回包含 `usage.input/output/cacheRead/cacheWrite/cost` 的 `AssistantMessage`
  - `observeAgentEvent` 接收所有 agent 事件（包括含有 usage 信息的 `assistant` message 事件），但函数体是 `{}`，直接丢弃
  - `FinalProposalBody` 只有 `messages` 和 `reply` 字段，无 usage
  - 控制面接收 FinalProposal 后，`mark_llm_turn_succeeded` 只写 `status: "succeeded"` 和 `response`，不写 usage
  - `ai_agent_llm_turns.usage` 列始终为 `{}`
- **预期行为：**
  - Worker 完成 turn 后，FinalProposal 包含聚合的 token usage（input tokens、output tokens、cache tokens）
  - 控制面将 usage 写入 `ai_agent_llm_turns.usage`
- **为什么这是问题：**
  - 无法做任何成本分析或 token 限额保护
  - 基本可观测性缺失，调试 LLM 行为时无依据
  - 未来 billing 功能完全没有数据基础
- **证据：**
  - `text_turn_loop.ts:558`：`function observeAgentEvent(_event: AgentEvent): void {}`
  - `ping_pong_handler.ts:14-17`：`FinalProposalBody = { messages?: ..., reply?: ... }`（无 usage）
  - `commit_coordinator.ex:463-465`：只更新 `status`、`response`、`completed_at`，无 usage
- **建议解决方案：**
  - 在 `FinalProposalBody` 中增加 `usage?: { input_tokens: number, output_tokens: number, ... }` 字段
  - 实现 `observeAgentEvent`（或用 `runAgentLoop` 返回值）聚合最终 usage
  - `commit_coordinator.ex` 从 proposal 中读取 usage，写入 `llm_turn.usage`
- **不建议的修法：**
  - 不要只写 `observeAgentEvent` 日志而不传回控制面——日志不能代替持久化

---

### P1-3: Provider source 与 worker catalog 严重不对齐

- **严重程度：** P1
- **影响范围：** LLM runtime / provider routing
- **相关用户故事：** 管理员能为 agent 配置不同的 LLM provider 和模型
- **具体位置：**
  - `app/control_plane/priv/repo/migrations/20260624000000_create_actor_runtime_ping_pong.exs`（DB constraint：`provider_source IN ('openrouter', 'openai', 'claude', 'gemini')`）
  - `app/control_plane/lib/ankole/ai_agent/provider_sources.ex`（4 个 provider source）
  - `app/agent_computer/src/llm/catalog.ts`（15+ provider：openai, anthropic, google, google-vertex, mistral, amazon-bedrock, openai-compatible, openrouter, xai, groq, cerebras, deepseek, moonshotai, fireworks, together 等）
  - `app/agent_computer/src/llm_runtime/text_turn_loop.ts:253-290`（`createSdkModel` switch：只有 openai/anthropic/google/default 四条）
- **当前行为：**
  - 控制面 DB 只允许 `provider_source ∈ {openrouter, openai, claude, gemini}`
  - `providerKindFromSource`：`claude → anthropic`，`gemini → google`，其余 default → `openai-compatible`
  - `createSdkModel` switch：`openai`/`anthropic`/`google`/`default(openai-compatible)`
  - catalog 中的 xai、groq、mistral、bedrock、google-vertex 等在控制面完全没有对应的 provider_source，无法配置也无法路由
- **预期行为：**
  - catalog.ts 中已测试支持的 provider 应该能从控制面配置并实际使用
- **为什么这是问题：**
  - catalog 和 provider_sources 是两套独立维护的列表，容易出现"catalog 中有，但控制面不支持"的虚假能力
  - 开发者在 catalog 中添加新 provider 时，可能误以为它能在生产中使用
- **证据：**
  - `catalog.ts`：`xai`、`groq`、`mistral`、`amazon-bedrock`、`google-vertex`、`fireworks`、`together` 等 provider 均有模型定义
  - `provider_sources.ex`：只有 4 个 source
- **建议解决方案：**
  - 短期：在 `catalog.ts` 中注释哪些 provider 是"控制面支持"的，哪些是"待开放"的，避免误导
  - 中期：扩展 DB constraint，添加对应 provider_source（如 `xai`、`groq`），同步 `providerKindFromSource` 映射
  - 长期：catalog 和 provider_sources 应该有统一的来源，防止分叉

---

### P1-4: Stale worker 检测 TTL 为 3600s（1 小时），crash 无法快速发现

- **严重程度：** P1
- **影响范围：** 主链路 / 运维 / worker liveness
- **具体位置：**
  - `app/control_plane/lib/ankole/actor_runtime/watchdog.ex`（`@stale_worker_ttl_seconds 3600`）
  - `app/control_plane/lib/ankole/actor_runtime/worker_bootstrap.ex`（没有健康检查循环）
- **当前行为：**
  - Worker 进程 crash 后，控制面最多需要 3600s 才能检测到 worker 已死并释放资源
  - 期间新的 turn 可能仍被分配给死亡的 worker，一直超时等待
- **预期行为：**
  - Worker 崩溃应在 60-120s 内被检测出来
- **为什么这是问题：**
  - 在生产环境中，worker crash 是常态（OOM、LLM 超时、代码 bug）
  - 1 小时检测延迟会导致长时间无法服务该 session 的用户
- **建议解决方案：**
  - 缩短 `stale_worker_ttl` 到 60s（heartbeat 周期 15s，4 次未收到视为死亡）
  - 配合 P0-2 子进程方案，主进程死亡时确保 ZMQ 连接断开，控制面能快速发现

---

### P1-5: dead-letter 保护机制定义但从未实现

- **严重程度：** P1
- **影响范围：** 主链路 / 错误处理 / 可靠性
- **具体位置：**
  - `app/control_plane/lib/ankole/actors/actor_input.ex:20`（`@states ~w(open dead_letter)`）
  - `app/control_plane/lib/ankole/actors/actor_input.ex:41`（`field :dead_letter_at, :utc_datetime_usec`）
  - 全仓库无任何代码将 actor_input 转移到 `dead_letter` 状态
- **当前行为：**
  - 一个持续失败的 actor input（如：因 worker crash 导致 turn 一直失败）永远保持 `open` 状态
  - `ActivationManager.list_ready_inputs` 每次都能返回它，无限触发失败
- **预期行为：**
  - 超过最大重试次数后，actor input 应被标记为 `dead_letter`，不再被调度
  - 管理员可查看 dead_letter inputs 并决策重试或丢弃
- **为什么这是问题：**
  - 持续失败的 input 会消耗调度资源，可能级联阻塞整个会话
  - 无法区分"暂时失败"和"永久失败"
- **建议解决方案：**
  - 在 `ActorRuntime` 中，turn 标记为 `failed` 时增加 attempt 计数
  - 超过阈值（如 3 次）后，将 actor_input 状态改为 `dead_letter`，同时创建 outbox 通知用户

---

### P1-6: Worker bootstrap docker run 命令缺少 actors/ 目录挂载

- **严重程度：** P1（与 P0-1 相关）
- **影响范围：** 主链路 / 部署 / worker 启动
- **具体位置：**
  - `app/control_plane/lib/ankole/actor_runtime/worker_bootstrap.ex`（`workspace_mount_args`：挂载 user-files、temp、library-containers，不包含 actors/）
- **当前行为：**
  - 生成的 `docker run` 命令中无 `/workspace/actors` 挂载
  - 即使控制面未来开始写入 `actors/` 目录（P0-1 方案 B），worker 容器内也看不到该目录
- **建议解决方案：**
  - 如果 P0-1 采用文件系统方案，则添加 `actors/` volume 挂载
  - 如果 P0-1 采用 TurnStart 内嵌方案，则此问题消失，可移除 actors/ 相关的文档描述

---

### P2-1: signals_gateway.ex 达到 2406 行，职责严重混合

- **严重程度：** P2
- **影响范围：** 目录组织 / 可维护性
- **具体位置：**
  - `app/control_plane/lib/ankole/signals_gateway.ex`（2406 行）
- **当前行为：**
  - 单文件承担：ingress 管道（`emit_entry`）、outbox dispatch（`dispatch_outbox`、`dispatch_due_outbox`）、ambient 检测、channel 管理、binding 配置、signal entry 管理
  - 超过 2000 行阈值
- **预期行为：**
  - 按职责拆分：ingress pipeline 模块、outbox dispatch 模块
- **建议解决方案：**
  - 将 outbox dispatch 相关函数（`dispatch_outbox`、`dispatch_due_outbox`、`OutboxDispatcher` 交互逻辑）提取到 `signals_gateway/outbox.ex`
  - 将 ingress pipeline（emit_entry、signal binding、channel routing）提取到 `signals_gateway/ingress.ex`
  - `signals_gateway.ex` 保留公共 API 入口，内部委托

---

### P2-2: actor_runtime.ex 达到 1727 行，调度/命令处理/watchdog 全部混合

- **严重程度：** P2
- **影响范围：** 目录组织 / 可维护性
- **具体位置：**
  - `app/control_plane/lib/ankole/actor_runtime.ex`（1727 行）
- **当前行为：**
  - 单文件包含：worker 接纳（admission）、turn 调度、命令处理（steer/compress/stop）、watchdog 逻辑、信封构建、turn_start 信封序列化
- **建议解决方案：**
  - 命令处理（`process_steer_command`、`prepare_compress_command` 等）提取到 `actor_runtime/command_processor.ex`
  - 信封构建（`turn_start_envelope`、`mailbox_updated_envelope` 等）提取到 `actor_runtime/envelopes.ex`
  - Watchdog 已有独立文件，可继续

---

### P2-3: agent-loop.ts 达到 1295 行，工具 helper 和 loop 核心混放

- **严重程度：** P2
- **影响范围：** 目录组织 / 可维护性
- **具体位置：**
  - `app/agent_computer/src/core/agent-loop.ts`（1295 行）
- **建议解决方案：**
  - `sanitizeToolPairs` 等工具调用验证逻辑提取到 `core/tool-sanitizer.ts`
  - grace turn 逻辑提取到 `core/grace-turn.ts`

---

### P2-4: turn_child.ts 与 main.ts 是两套并行实现，关系不明确

- **严重程度：** P2
- **影响范围：** 目录组织 / 架构清晰度
- **具体位置：**
  - `app/agent_computer/src/turn_child.ts`（stdin 协议子进程入口）
  - `app/agent_computer/src/main.ts`（ZMQ 主循环入口）
- **当前行为：**
  - `turn_child.ts` 实现了完整的 steer 支持（stdin 读取 steer 消息）
  - `main.ts` 直接调用 `handleActorBusEnvelope`，完全不使用 `turn_child.ts`
  - 两者功能重叠但走不同的协议（ZMQ vs stdin）
  - 没有注释说明两者的关系和设计意图
- **为什么这是问题：**
  - 新开发者不知道应该修改哪个入口
  - `turn_child.ts` 的 steer 逻辑被认为是"有实现"，但实际上是死代码
- **建议解决方案：**
  - 如果 P0-2 采用子进程方案，则 `turn_child.ts` 成为 `main.ts` 的子进程入口，关系清晰
  - 如果不采用子进程方案，则删除 `turn_child.ts` 或在文件顶部加注释说明其用途

---

### P3-1: observeAgentEvent 为 no-op，turn 内无任何可观测性

- **严重程度：** P3
- **影响范围：** LLM runtime / 可观测性
- **具体位置：**
  - `app/agent_computer/src/llm_runtime/text_turn_loop.ts:558`
- **当前行为：**
  - `function observeAgentEvent(_event: AgentEvent): void {}` — 所有 agent 事件（工具调用、工具结果、LLM 回调、错误）均被丢弃
- **建议解决方案：**
  - 至少将重要事件（tool_call、tool_result、assistant message）写入 stdout JSON 日志
  - 将最终 usage 聚合后包含在 FinalProposal 中（P1-2 的一部分）

---

### P3-2: catalog.ts 中所有模型 cost 为零

- **严重程度：** P3（当前阶段不做 billing，但影响未来）
- **影响范围：** LLM runtime / 成本追踪
- **具体位置：**
  - `app/agent_computer/src/llm/catalog.ts`（所有模型使用 `cost: zeroCost`）
- **建议解决方案：**
  - 近期：添加注释说明 cost 数据待填写，不影响当前功能
  - 中期：按模型填写实际 per-token 价格

---

### P3-3: UNLOGGED TABLE 在 PostgreSQL crash 后丢失关键运行时状态

- **严重程度：** P3（对生产可靠性有影响）
- **影响范围：** 主链路 / 可靠性
- **具体位置：**
  - `app/control_plane/priv/repo/migrations/20260624000000_create_actor_runtime_ping_pong.exs:372,436,474,504`（`actor_input_deliveries`、`agent_computer_workers`、`actor_session_worker_assignments`、`actor_session_activations` 均为 UNLOGGED）
- **当前行为：**
  - PostgreSQL crash/restart 后，这四张表的数据完全清空
  - 运行时状态（哪个 worker 在跑哪个 turn）在 Postgres crash 后自动重置，等待 Reconciler 重建
- **为什么这是问题（也是意图）：**
  - 这是有意的 tradeoff：UNLOGGED 表性能更好，且这些状态是可从 LOGGED 表（`actor_inputs`、`ai_agent_llm_turns`）重建的运行时投影
  - 但如果 Reconciler 的重建逻辑不完整，crash 后可能有些 turn 卡在中间状态无法恢复
  - 需要验证 Reconciler 是否能正确处理所有孤儿状态
- **建议解决方案：**
  - 这个 tradeoff 本身可以接受
  - 需要确保 Reconciler（`reconciler.ex`）能正确处理 Postgres crash 后的状态重建
  - 在 docs 中记录此设计决定和运维恢复步骤

---

## 5. 同类问题排查表

| 问题位置 | 问题类型 | 为什么属于同类缩水/reward-hacking/结构性脱节 | 参考能力（bun-legacy） | 建议修复 |
|---|---|---|---|---|
| `runtime.ts:handleActorBusEnvelope` default 丢弃 mailbox_updated | 迁移缩水 / happy path | bun-legacy 中子进程通过 stdin 接收 steer；迁移时改成 ZMQ 但没有实现 steer 接收路径 | bun-legacy `turn_child.ts` | 在生产路径传递 steer（P0-2） |
| `observeAgentEvent` 为空函数 | 简化实现 | 占位函数从未实现，丢弃所有 agent 事件包括 usage | bun-legacy agent loop 有 usage tracking | 实现 event sink（P1-2）|
| `active_turns: 0` 硬编码 | happy path 临时代码 | 容量上报不跟踪实际状态，控制面无法准确调度 | — | 跟踪并上报真实容量（P1-1）|
| `messages.jsonl` 路径从不写入 | 迁移缩水 / edge case 缺失 | 文件系统约定继承自 bun-legacy，但控制面写入逻辑未迁移 | bun-legacy commit 后写 JSONL | 内嵌 TurnStart 或写文件（P0-1）|
| `FinalProposalBody` 无 usage | 迁移缩水 | 接口未设计 usage 字段，无法向控制面传递 token 数据 | bun-legacy FinalProposal 含 usage | 扩展 FinalProposalBody（P1-2）|
| `dead_letter_at` 字段存在但从未赋值 | 旧架构残留 | 字段从之前版本遗留，对应的设置逻辑未实现 | — | 实现最大重试后 dead_letter（P1-5）|
| `signals_gateway.ex` 2406 行 | 目录组织问题 | 多次迭代叠加导致单文件职责过多 | — | 拆分为 ingress/outbox 模块（P2-1）|
| `actor_runtime.ex` 1727 行 | 目录组织问题 | 多次迭代叠加导致单文件职责过多 | — | 拆分命令处理/信封构建（P2-2）|
| `turn_child.ts` steer 实现未接入 `main.ts` | 重复路径 / 旧架构残留 | 两套入口并存，steer 逻辑被孤立 | — | 子进程化（P0-2 方案 A）|
| `catalog.ts` cost 全为 zeroCost | 简化实现 | 占位数据，成本计算完全无效 | — | 填写真实 cost 或明确标注（P3-2）|
| `stale_worker_ttl: 3600` | happy path | 开发时设置的宽松阈值进入了生产，1 小时才发现 crash | — | 缩短到 60-120s（P1-4）|
| `provider_source` DB constraint 与 catalog 不同步 | 旧架构残留 / 重复路径 | 两套 provider 列表独立维护，catalog 比控制面超前 | — | 对齐并注释（P1-3）|

---

## 6. 结构性复杂度与减法机会

### 本质业务复杂度（必要的）

- **Elixir 控制面 + Bun worker + Rust NIF 三语言架构**：控制面需要 Elixir OTP 保证调度可靠性，worker 需要 Bun 运行 AI SDK，Rust NIF 做 protobuf 编解码——这是合理的技术分层，不是无效复杂度。
- **ZMQ DEALER/ROUTER 传输**：异步消息传递在 worker 池调度中是正确选择，不应改为同步 HTTP。
- **Postgres 作为调度状态 SSOT + UNLOGGED 运行时投影**：这个 tradeoff 有明确设计意图，是合理的。
- **Credential broker over ZMQ RPC**：Credential 不持久化在 worker 是正确的安全设计。

### 结构性脱节造成的复杂度（可删减的）

- **`turn_child.ts` 与 `main.ts` 并存**：两套入口实现重叠功能，一个有 steer 但未接入，一个无 steer 但在生产使用。这是典型的"一次重构中途停止"留下的结构性脱节。修复 P0-2 后可以合一。
- **`messages.jsonl` 文件约定但无写入端**：文件路径设计（`/workspace/actors/{uid}/{session}/conversation/messages.jsonl`）继承自 bun-legacy，但写入逻辑未迁移。留下了一个"看起来有设计，实际不工作"的架构空洞。修复 P0-1 后可以消除这个空洞，或者改为 TurnStart 内嵌彻底删除文件系统依赖。
- **`provider_sources.ex` 与 `catalog.ts` 双重维护**：控制面和 worker 各自维护一套 provider 列表，独立演进，容易脱节。可以通过统一配置或添加明确边界注释来减少认知负担。
- **`observeAgentEvent` 占位**：空函数增加了"看起来有 observability"的错误印象。删除它或实现它，避免中间态。
- **`FinalProposalBody` 类型窄于实际需求**：这个接口只有 `messages` 和 `reply`，但 usage 和 steer 状态也需要传递。接口设计不完整导致调用方不得不绕过它。

### 可以通过删除/合并/移动大幅简化的地方

1. **删除 `turn_child.ts` 或接入它**：消灭两套实现的歧义（见 P0-2）
2. **删除 `messages.jsonl` 路径或实现它**：消灭"文件路径但无写入"的架构幻觉（见 P0-1）
3. **合并 `provider_sources.ex` 与 `catalog.ts` 的 provider 列表**：建立单一信息源
4. **收窄 `signals_gateway.ex` 职责**：拆分后每个文件只做一件事
5. **删除 `active_turns: 0` 硬编码**：改为实际跟踪，或缩小 `available_turn_slots` 到 1 反映单线程现实

---

## 7. 验证记录

| 命令/检查 | 目的 | 结果 | 备注 |
|---|---|---|---|
| `grep -rn "messages.jsonl"` | 确认谁写 JSONL 文件 | 只有 `text_turn_loop.ts` 和 `ambient_recognizer.ts` 读取，无任何写入代码 | 确认 P0-1 |
| `grep -rn "writeFileSync\|File.write\|appendFileSync"` | 查找文件写入 | 控制面无任何 JSONL 写入；`browser_cli.ts` 和 `computer/context.ts` 只写 workspace 用户文件 | 确认 P0-1 |
| `cat runtime.ts`（`handleActorBusEnvelope` 函数） | 确认 mailbox_updated 处理 | `default: return []` 静默丢弃 | 确认 P0-2 |
| `cat main.ts`（`runWorker` 函数） | 确认是否 spawn turn_child | 无 `Bun.spawn`/`child_process`；`await handleActorBusEnvelope` 直接调用 | 确认 P0-2 |
| `grep -n "pollSteering" runtime.ts` | 确认生产路径是否传 pollSteering | 无匹配，`runtime.ts` 不传 `pollSteering` | 确认 P0-2 |
| `cat turn_child.ts` | 确认 steer 实现在哪 | `pollSteering()` 函数完整，但 `main.ts` 不使用 `turn_child.ts` | 确认 P0-2 |
| `grep -n "active_turns\|available_turn_slots" runtime.ts` | 确认容量上报是否动态 | 全部硬编码 | 确认 P1-1 |
| `cat ping_pong_handler.ts`（FinalProposalBody 类型） | 确认是否有 usage 字段 | `{ messages?, reply? }`，无 usage | 确认 P1-2 |
| `grep -n "usage" commit_coordinator.ex` | 确认 usage 是否从 proposal 读取 | 只有 `tokens_before` 在 compression metadata 中，无 turn usage 写入 | 确认 P1-2 |
| `grep -rn "dead_letter_at\|dead_letter" app/control_plane/lib` | 确认 dead_letter 是否实现 | 只有 schema 定义，无任何赋值逻辑 | 确认 P1-5 |
| `cat worker_bootstrap.ex`（docker_run_command 函数） | 确认 workspace 挂载 | user-files、temp、library-containers 挂载，无 actors/ | 确认 P1-6 / P0-1 |
| `grep -n "UNLOGGED" migrations/...` | 确认哪些表是 UNLOGGED | actor_input_deliveries、agent_computer_workers、actor_session_worker_assignments、actor_session_activations 均为 UNLOGGED | 记录 P3-3 |
| `wc -l signals_gateway.ex actor_runtime.ex agent-loop.ts` | 确认大文件行数 | 2406 / 1727 / 1295 | 确认 P2-1/P2-2/P2-3 |
| `grep -n "provider_source" migrations/` | 确认 DB constraint | `IN ('openrouter', 'openai', 'claude', 'gemini')` | 确认 P1-3 |
| `cat catalog.ts`（zeroCost 搜索） | 确认 cost 数据 | 所有模型 `cost: zeroCost` | 确认 P3-2 |
| 未运行：真实 LLM e2e 测试 | 验证真实 LLM 路径端到端 | 未运行（只读审计，不运行 e2e，且需要真实 API key） | e2e 测试只覆盖 PING/PONG |
| 未运行：bun run test | 跑现有单元测试 | 未运行 | 不运行破坏性或依赖外部服务的命令 |

---

## 8. 建议修复顺序

### 第一优先级：主链路闭环

**1. 先修 P0-1：解决对话历史空白问题**

这是最根本的主链路缺陷。没有对话历史，Ankole 不能称为 agent 系统。建议采用"方案 A：TurnStart 内嵌历史"：
- 在控制面 `turn_start_envelope/3` 中查询 conversation 历史并内嵌到信封 `context` 字段
- Worker `loadConversationContext` 优先从 `turnStart.context` 读取，文件路径作为后备（可逐步过渡）
- 这个修复无需改变 worker 部署方式，最低风险

**2. 再修 P0-2：修复 steer 命令传递路径**

切换到子进程模式（`turn_child.ts` 作为真正的 turn 执行入口）：
- `main.ts` 修改为：收到 `turn_start` 后 spawn `turn_child.ts` 子进程
- 收到 `mailbox_updated` 后，向对应子进程 stdin 写入 steer 消息
- 子进程完成后通过 stdout 返回 FinalProposal，main 进程转发给 ZMQ
- 这也自然解决 P1-1（heartbeat 不再被 turn 阻塞）

### 第二优先级：生产可靠性

**3. 修 P1-2：LLM usage 持久化**

在 `FinalProposalBody` 中增加 `usage` 字段，`commit_coordinator.ex` 写入 `llm_turn.usage`。这是低风险的接口扩展。

**4. 修 P1-4 + P1-5：worker crash 检测 + dead-letter 保护**

缩短 `stale_worker_ttl` 到 60s；实现 actor input 最大重试后转 dead_letter。这两项是独立修改，风险低，对生产稳定性帮助大。

**5. 修 P1-3：provider source 对齐**

至少在 catalog.ts 中注释哪些 provider 已在控制面开放。中期再扩展 DB constraint。

### 第三优先级：结构性清理

**6. 修 P2-1 + P2-2：拆分超大文件**

`signals_gateway.ex` 和 `actor_runtime.ex` 拆分，减少认知负担。建议在第一、二优先级完成后再做，避免在已知有问题的代码上做大规模重构。

**7. 修 P2-4：明确 turn_child.ts 的角色**

如果 P0-2 采用子进程方案，则 `turn_child.ts` 正式成为生产入口，文档化其协议。如果不采用，则删除。

### 暂不处理

- P3-1（observeAgentEvent 日志）：在 P1-2 完成后顺带处理
- P3-2（catalog cost 数据）：当前不做 billing，优先级低
- P3-3（UNLOGGED 表）：设计意图明确，只需验证 Reconciler 重建逻辑完整性
- 未来能力（长期记忆、多 agent、billing、全量搜索等）：不在当前版本范围内

### 不应在当前阶段做的

- 不要引入 Kubernetes/Helm 编排（当前 bootstrap 是 docker run 命令，先把主链路跑通）
- 不要在主链路问题未修复前大规模扩展 provider 支持
- 不要过度抽象 event sourcing 或 CQRS 层（当前 Postgres + UNLOGGED 投影的设计足够，不需要再加层）
- 不要在 UNLOGGED 表上加 WAL（除非有明确的 crash 恢复要求，否则是负向 tradeoff）
