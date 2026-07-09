# Ankole 文档

[English](./README.md)

请从这里开始读。本文是 Ankole 唯一的架构入口：它说明系统是什么、展示运行时拓扑、把子系统映射到代码、沿着一条消息走完整条运行链路，并指出下一步该读哪些设计契约。

## Ankole 是什么

Ankole 是一个自托管的 Agent Operating System，用来承载长期运行的数字工作。一个 Ankole Installation 就是一个运行域：它包含自己的 agents、provider 连接和数据。Installation 内部没有 SaaS 式的多租户边界，代码也不应该凭空发明这样的边界。

Ankole 里的 agent 不是简单的 chat completion 封装，而是一个持久化的 actor：它从聊天平台、webhook 和定时任务接收工作项；在真实环境里运行 tool loop（shell、文件、浏览器）；会话状态存在 PostgreSQL 中，进程崩溃之后仍然保留；还能在未来把自己唤醒。Human 和 agent 都是带权限授予的 Principal，因此授权是运行时问题，而不是 prompt 里的约定。

## 如果你熟悉 Vercel AI SDK

如果你脑子里的模型是“在 route handler 里拼好 `messages`，用 `tools` 调 `streamText`，循环到没有 tool call 为止，最后在 `onFinish` 里持久化”，那么 Ankole 里也有同样的职责，只是它们分散在不同进程中：

| 在 ai-sdk 应用里 | 在 Ankole 里 |
| --- | --- |
| 自己拼好 `messages` 数组后调用 `streamText`/`generateText` | Worker 通过 WebSocket 向 AIGateway 发送 `response.create`。历史在服务端：`ai_gateway_messages` 行用 `previous_response_id` 串起来。请求只带新的 input items，不带历史。 |
| Provider packages（`@ai-sdk/openai` 等）跑在 app 进程内 | Provider module 在 AIGateway 后面（`Ankole.AIGateway.Providers.*` 加上 plugin providers）。上游 API key 不离开 control plane；worker 只拿到 30 天有效、agent 范围的 AIGateway key。 |
| 服务端函数里的 `tools:` + `maxSteps` 循环 | Bun worker 里的 tool registry 和循环（`app/agent_computer/src/tools/`、`src/core/agent-loop.ts`），就在真实 sandboxed workspace 旁边执行。停止策略由服务端执行。 |
| `onFinish` 回调持久化结果 | AIGateway 的 terminal commit：一个 PostgreSQL 事务把最终行标记为 `complete`、设置 `actor_events.completed_at`、清理 live delivery，而且这一切发生在 worker 看到 terminal frame 之前。 |
| 来自你自己 UI 的 HTTP 请求 | SignalsGateway 从 IM 消息、webhook 或定时任务生成的持久 actor event。它会永久留在 `actor_events` 里；完成只是一个时间戳。 |
| 向浏览器流式输出 token（`useChat`） | Streaming 的 provider 原生预览，例如飞书卡片。文本增长时编辑它，最后再替换成最终内容。 |
| Serverless function 的生命周期 | 带激活租约、delivery fence、重试和崩溃恢复的长期运行 session actor。 |

最深层的差异是持久性。Ankole 的每一跳都围绕一个问题设计：“如果这个进程现在死掉，还有什么活着？”答案永远是：“PostgreSQL 里的行，其他都不是。”

## 系统地图

```text
   Feishu / Slack / webhooks / schedules
                  |
                  v
        +------------------+     writes      +--------------------------+
        |  SignalsGateway  | --------------> |  PostgreSQL              |
        |  ingress, mirror,|                 |  signal_gateway_channels |
        |  delivery        |                 |  signal_gateway_entries  |
        +------------------+                 |  actor_events            |
                  |                          |  actor_event_deliveries  |
                  |                          |  ai_gateway_messages     |
                  | actor_events             |  ai_gateway_conversations|
                  v                          |  signal_gateway_outbox   |
        +------------------+                 |  actor_scheduled_events  |
        |   ActorRuntime   |                 +--------------------------+
        |  scheduling,     |                        ^
        |  fences, retry   |                        | terminal commit
        +------------------+                        |
                  | turn_start (ZeroMQ,      +------------------+
                  | RuntimeFabric)           |    AIGateway     |
                  v                          |  providers, the  |
        +------------------+  WebSocket      |  stateful message|
        |  Agent Computer  | -------------> |  log, tool-loop  |
        |  (Bun worker)    | response.create|  state, compaction|
        |  tools, sandbox  |                +------------------+
        +------------------+                        |
                                                    v
                                          upstream LLM providers
```

六个部分，各一句话：

- **SignalsGateway**（Elixir）接收 provider event，镜像 provider 侧可见的状态，决定什么会唤醒 agent，并把回复送回 provider。它拥有 `signal_gateway_channels`、`signal_gateway_entries`、`actor_events`、`signal_gateway_outbox`。见 `design-docs/SignalsGateway.md`。
- **ActorRuntime**（Elixir）把 actor event 调度到 worker 上，每个 event 执行一次，并用 fence 挡住 stale 的 worker commit。它拥有 `actor_event_deliveries` 和 session activation。
- **AIGateway**（Elixir）是 AI 边界：管 provider 凭证和路由，外加有状态的 Responses 日志，包括 model 历史、tool-loop 状态、compaction 和 terminal commit。它拥有 `ai_gateway_messages` 和 `ai_gateway_conversations`。见 `design-docs/AIGateway.md`。
- **RuntimeFabric**（Rust + ZeroMQ）是 control plane 和 worker 之间的实时传输：turn envelope、RPC、文件字节。它永远不是持久事实来源。见 `design-docs/RuntimeFabric.md`。
- **Agent Computer**（Bun worker）执行工具：shell、文件、浏览器，以及当前 turn 的 worker 本地状态。它通过 WebSocket 驱动 model loop，但不保存会话状态。
- **PostgreSQL** 保存所有持久语义事实及持久文件的所有权引用。用户产物和可恢复运行时文件位于 worker 共享工作区；它们的生命周期与权威状态仍是由 Elixir 写入的 PostgreSQL 行。

Schedule（`design-docs/Schedule.md`）把时间变成 actor event。Principal 和 AuthZ（`design-docs/Principal.md`、`design-docs/AuthZ.md`）负责身份和权限。AppConfiguration（`design-docs/AppConfiguration.md`）区分启动用的 env var 和 operator 管理的 runtime setting。Plugins（`design-docs/Plugins.md`）是可信的第一方 Elixir 扩展，例如飞书 adapter（`design-docs/plugins/FeishuAdapter.md`）。Subagent Delegation（`design-docs/SubagentDelegation.md`）把长时间 Codex 执行变成会在完成后唤醒父会话的持久后台工作项。

## 运行时拓扑

一个运行中的 installation 包含一个 Phoenix/OTP control plane、一个 PostgreSQL，以及 N 个 Agent Computer worker container。浏览器和 Phoenix 通信；provider 和 plugin adapter 通信；worker 通过两条通道和 control plane 通信：ZeroMQ（RuntimeFabric）承载 turn 控制和 RPC，WebSocket/HTTP（AIGateway API）承载 model 调用。

```text
   Feishu / providers          Browser (operator)
        |  long conn / webhook      |  HTTPS
        v                           v
  +---------------------------------------------+
  |  Control plane (Elixir/Phoenix, one BEAM)   |
  |  SignalsGateway | ActorRuntime | AIGateway  |
  |  Principal/AuthZ | AppConfigure | Plugins   |
  |  Rust kernel (Rustler NIF): crypto, CEL,    |
  |  protobuf codec, ZeroMQ ROUTER              |
  +---------------------------------------------+
     |  SQL                  ^            ^
     v                       |            |
  PostgreSQL          ZeroMQ (fabric)  WebSocket /api/v1/ai-gateway
  (durable truth)     ROUTER <-> DEALER   (Responses wire shape)
                             |            |
                      +---------------------------------+
                      |  Agent Computer worker (Bun,    |
                      |  Docker): agent loop, tools,    |
                      |  bubblewrap sandbox, browser,   |
                      |  Rust kernel (N-API): DEALER    |
                      +---------------------------------+
                             |
                             v
                      upstream LLM providers (called from the
                      control plane, never from the worker)
```

默认本地端口：Phoenix 在 `4000`，devkit 的 PostgreSQL 在 `5433`，SPA 的 Vite dev server 在 `3035`，RuntimeFabric endpoint 由 operator 绑定（README 示例用 `tcp://127.0.0.1:6010`）。

两种传输，一条规则：

- **RuntimeFabric（ZeroMQ）** 只是实时传输：turn envelope、RPC、文件字节、心跳、背压。它永远不是持久事实来源。系统绝不能靠问 ZeroMQ“发生了什么”来恢复状态。
- **PostgreSQL** 拥有所有崩溃之后仍然重要的事实：actor event、AI 消息日志、镜像、outbox 行、fence、配置、记忆。所有写入都由 Elixir 负责。

## 语言所有权

三个 runtime，边界严格。不要因为某一侧更容易编辑或测试就把职责挪过去。

| Runtime | 负责 | 不应该 |
| --- | --- | --- |
| **Elixir**（`app/control_plane`） | PostgreSQL 语义和 migration、supervision、setup/console/auth 界面、Principal/AuthZ facade、AppConfigure、SignalsGateway、ActorRuntime 调度和 fence、AIGateway provider 和有状态消息日志、Memory、terminal commit 权威、plugin registry | 把持久状态的归属推给 worker 或 kernel |
| **Rust kernel**（`app/kernel`） | Elixir/Bun 需要保持一致的确定性共享机制：crypto（AEAD、key derivation）、UUIDv7、JWT、phone normalization、xxh3、zstd block codec、AuthZ 和 signal filter 的 CEL 求值、protobuf envelope codec + 校验、ZeroMQ socket 所有权（ROUTER/DEALER/ZAP 线程） | 碰 PostgreSQL，持有产品生命周期状态，膨胀成领域 owner |
| **Bun worker**（`app/agent_computer`） | Agent loop、tool、prompt、终端/浏览器状态、bubblewrap 沙箱、worker 本地文件系统、AIGateway client | 发明 control-plane 状态；任何必须跨重启存活的东西都要通过 RPC 或 AIGateway API 落到 PostgreSQL |

Kernel 从同一个 crate 编译两次：一次作为 Elixir 的 Rustler NIF（由 `app/kernel/lib/ankole/kernel.ex` 里的 `Ankole.Kernel` 包装），一次作为 Bun 的 N-API module（`app/kernel/index.js`，类型在 `index.d.ts`）。只有当逻辑是“给定明确输入的确定性函数”，并且两个 host 都需要时，才把它放进 Rust。CEL AuthZ evaluator 和 envelope codec 就是标准范例。

## 仓库地图

| Path | 内容 |
| --- | --- |
| `app/control_plane/` | Phoenix/OTP control plane。领域 context 在 `lib/ankole/`，web 界面在 `lib/ankole_web/`，migration 在 `priv/repo/migrations/`。 |
| `app/kernel/` | Rust kernel crate。`src/common/`（crypto/ids/jwt/zstd）、`src/authz/`（CEL）、`src/runtime_fabric/`（protobuf + ZeroMQ）、`proto/`（envelope schema）、`src/nif_exports.rs` / `src/napi_exports.rs`（绑定接口）。 |
| `app/agent_computer/` | Bun worker。`src/main.ts` 守护进程，`src/core/` agent loop + turn，`src/tools/`，`src/prompts/`，RuntimeFabric lane（`actor_lane.ts`、`rpc_lane.ts`、`lanes/file/`）。只能在 Docker 运行时里运行。 |
| `app/webapps/` | 三个 Vite + React SPA（`auth/`、`console/`、`setup/`），构建到 `app/control_plane/priv/static/assets/`。包含生成的 OpenAPI client。 |
| `app/library/` | 内置 skill（`skills/nano-pdf`、`skills/jupyter-live-kernel`、`skills/powerpoint`）和 agent 起步模板（`templates/MISSION.md`、`templates/SOUL.md`）。 |
| `app/locales/` | TOML 消息目录（`en-US.toml`、`zh-Hans-CN.toml`），Elixir I18n context 和 SPA 共用。 |
| `plugins/` | 公开的第一方 Elixir plugin：`lark_adapter`（飞书聊天 + identity provider）、`china_market_ai_providers`（AIGateway provider）。 |
| `internals/` | 私有的第一方资料：`plugins/`、`skills/`（例如金融数据 CLI）、`helm-chart/`、额外的 worker Dockerfile、内部测试笔记。 |
| `libs/` | `feishu_openapi`（Elixir Lark client：token、WS 长连接、crypto）和 `uikit`（共享 React 组件、Tailwind 4）。 |
| `tools/devkit/` | 工作区 CLI：`bun kit ...`（通过 Docker Compose 管理外部服务、codegen、分析）。 |
| `tools/e2e/` | E2E harness 和测试套件（fake Feishu、fake OpenAI、真实 Docker worker），由 `mix e2e.*` alias 驱动。 |
| `docs/` | 本文、`TradeoffsAndKnownLimits.md`、`design-docs/`。 |

## Control Plane 启动顺序

`Ankole.Application`（`app/control_plane/lib/ankole/application.ex`）按顺序启动：Telemetry -> Repo -> `AppConfigure.Registry` -> `AppConfigure.Cache` -> `Setup.Bootstrap` -> Oban -> `Plugins.Registry`（发现 + 校验 + 激活）-> `Plugins.Supervisor`（活跃 plugin 贡献的 children）-> PubSub -> SignalsGateway preview registry/supervisor -> `InboundBatchFinalizer` 和 `RecoveryScan`（受 config 开关控制）-> `ActorRuntime.Supervisor` -> `AIGateway.ModelMetadata.Cache` -> `I18n.Catalog` -> DNSCluster -> Endpoint。

这个顺序不是随便定的（load-bearing）：在 plugin 读配置之前，配置必须已经存在；在任何地方解析 plugin 配置之前，plugin 必须先注册自己的 AppConfigure 定义；HTTP endpoint 最后才启动。

## 核心子系统

### SignalsGateway：provider 入口和 provider 可见的副作用

`Ankole.SignalsGateway`（`lib/ankole/signals_gateway/`）。Adapter 用归一化后的事实调 `emit_entry/emit_reaction/emit_action`；gateway 检查 binding（`bindings.ex`），应用 CEL filter（由 kernel 求值），挡住被 tombstone 的 entry，upsert provider 镜像（`channel.ex`、`entry.ex`），并把 IM 突发消息合并成 inbound batch（`inbound_batch*.ex`）。关闭 batch 时，在一个事务里写一条 `actor_events` 行，然后向 provider 确认。对外的显式副作用走 `outbox.ex` / `outbox_entry.ex`，由 binding 的 outbox adapter 执行。流式回复不是 outbox 行：`ai_reply_preview.ex` 订阅 AIGateway 的 chunk event，并驱动 provider 原生预览；`recovery_scan.ex` 会重发缺少镜像的 completed final。

拥有的表：`signal_gateway_bindings`、`signal_gateway_channels`、`signal_gateway_entries`、`signal_gateway_input_tombstones`、`signal_gateway_inbound_batches`、`signal_gateway_outbox`。

### Memory：channel 记忆和历史召回

`Ankole.Memory`（`lib/ankole/memory.ex`）。Layer A 是当前 channel 的人工策展短记忆，经 `memory_note` tool 写入 `memory_notes`，按 `{agent_uid, channel}` 限 40 条、单条 500 字符，并注入 addressed 与 ambient turn。Layer B 用 `signal_gateway_entries` 做 ground truth：Phase 1 提供 BM25 `memory_search` 与按时段 `memory_browse`；Phase 2 用 `memory_episodes` + embedding 增强排序，失败时降级回 BM25。设计入口见 `design-docs/memory/Basic.md`，详细 v1 设计见 `internals/docs/Memory.zh.md`。

拥有的表：`memory_notes`、`memory_episodes`、`memory_channel_cursors`。

### ActorRuntime：带 fence 的 worker turn 调度

`Ankole.ActorRuntime`（`lib/ankole/actor_runtime/`）。它监督 session controller、`ActivationManager`（session 激活租约）、`WorkerPool`（已连接的 worker、容量）、`Reconciler` 和 `Watchdog`。每个 session 同一时间只有一个 ready 的 actor event 会变成一个 `turn_start` envelope（`turn_envelope.ex`），由 `transport/broker.ex` 通过 fabric 发出。每次 delivery 都带 fence（`ActorTurnRef`）：activation uid、actor epoch、actor event id、revision。Stale 的 worker echo 如果过不了相等性检查，就不能 commit 到新的 actor 状态。重试会创建新的 actor event，并带上 `retry_of_actor_event_id`；恢复不会复活一条流。

拥有的表（UNLOGGED、可重建的运行时投影）：`actor_event_deliveries`、`actor_session_activations`、`actor_session_worker_assignments`、`agent_computer_workers`。持久工作日志 `actor_events` 本身由 SignalsGateway/Schedule 写入，由 AIGateway 的 terminal commit 完成。

### AIGateway：provider 加有状态 Responses 日志

`Ankole.AIGateway`（`lib/ankole/ai_gateway/`）。分成两半：

- **Provider 边界。** `providers.ex` 注册内置 provider module（`providers/openai.ex`、`openai_compatible.ex`、`openrouter.ex`、`google_ai_studio_openai.ex`、`claude.ex`、`azure_openai.ex`、`jina.ex`），以及通过 `ai_gateway.provider` contract 发现的 plugin provider（目前包括 `plugins/china_market_ai_providers` 里的 `xiaomi_mimo`、`volcengine_ark`、`alibaba_cn`、`zai_coding_plan`）。Provider module 返回一个 `provider_definition()`（设置 schema、base URL、capability，以及用来构造 `UniversalAIRequest` 的 `prepare/1`）；真正发往上游的 HTTP/SSE 传输跑在 kernel 的 `universal_ai_client` 里（feature-gated 的 Rust、NIF 驱动）。Operator 实例存在 `ai_gateway_providers` 行里（加密凭证、base URL 覆盖）；agent 在 `agents.options["ai_agent"]["models"]` 里绑定 model alias（`primary`、`light`、`heavy`、`embedding`、`rerank`）。
- **有状态 Responses 日志。** `stateful_responses.ex` 负责 run-row 生命周期：`start_response_run` 解析 `conversation` 或 `previous_response_id`；如果一个 `store=true` 请求两者都没有，就创建一个带 `metadata.managed_by_stateful_responses_api = true` 的 managed conversation。它通过 `previous_message_id` 图展开历史（跳过 `retracted`，折叠被 compaction 行覆盖的前缀），当历史消息记录的 provider usage 超预算时自动 compaction（`compaction.ex`，用 agent 的 `light` profile 总结），写入 `status = "generating"` 的行和可选的 `metadata.actor_event_id`，把 provider chunk 流式推到 PubSub，并用乐观的 `WHERE status = 'generating'` 守卫做 terminal commit。链尾的 terminal commit 还会设置 `actor_events.completed_at` 并清理 delivery。孤立的 `generating` 行会按 `updated_at` 的陈旧程度恢复成 `error`（300 秒宽限期）。

Wire 接口是 OpenAI Responses 形状：worker 连接 `GET /api/v1/ai-gateway/responses`（WebSocket，`AnkoleWeb.AIGatewayResponsesSocket`），发送带 `store=true` 的 `response.create` frame；`conversation` 和 `previous_response_id` 是 AIGateway state anchor，`metadata.actor_event_id` 是 ActorRuntime correlation metadata，不是通用 Responses 的必填项；id 会被改写成 `resp_<message-row-uuid>`；HTTP 路由提供无状态调用、检索、手动 compaction、embedding 和 rerank。拥有的表：`ai_gateway_messages`、`ai_gateway_conversations`、`ai_gateway_providers`。

### RuntimeFabric：实时 ZeroMQ 传输

设计见 `docs/design-docs/RuntimeFabric.md`；机制在 `app/kernel/src/runtime_fabric/`。Control plane 上有一个 ROUTER socket（由专用 Rust 线程持有，接受 `Ankole.ActorRuntime.Transport.Broker` 的命令），每个 worker 一个 DEALER（由 Rust 线程持有，从 `src/runtime_fabric_sender.ts` 驱动）。Worker 用 ZAP PLAIN 认证：username 是 `WORKER_ID`，password 是 installation 的 worker auth key（AppConfigure 持有，落盘加密）。

Envelope 是 protobuf（`app/kernel/proto/ankole/runtime_fabric/v1/envelope.proto`），在任何 host 看到它们之前，先由 Rust 校验。四条 lane：CONTROL（`worker_ready`、心跳、容量、`turn_control`、关停）、TURN（`turn_start`、`mailbox_updated`、`turn_accepted`、`turn_error`、`turn_noop_completed`）、PROGRESS（`worker_progress`，只用于可观测性）、RPC（`rpc_request`/`rpc_response`/`rpc_error`）。另外还有一条 raw-frame 文件 lane（`ANKOLE_FILE/1`，2 MiB zstd 块、信用流控），在 control plane 和 worker 可见根 `user_files`、`agent_installed_skills` 之间搬运字节（`lib/ankole/actor_runtime/file_transfer_lane.ex` <-> `src/lanes/file/`）。

Worker->control-plane 的 RPC 方法注册在 `lib/ankole/actor_runtime/rpc_lane.ex`：`ai_gateway.api_key_for.create_or_find_by_agent`、`agent_conversation.context.resolve`、`skills.overlay.resolve` / `.replace`、`schedule.check_back_later.create`、`schedule.cron.*` 系列、`memory_note.*`、`memory_search`、`memory_browse`。

### Agent Computer：Bun worker

`app/agent_computer/src/`。`main.ts` 解析 env（`WORKER_ID`、形如 `tcp://:worker_auth_key@host:port` 的 `RUNTIME_FABRIC_URL`），启动 DEALER，宣告 `worker_ready`，每 15 秒发一次心跳，并分发 envelope。一个 `turn_start` 会跑 `core/turns/` 里的 turn pipeline（文本 turn 是 `text_turn.ts`）：通过 RPC 拿会话上下文和 AIGateway API key，构造 system prompt（`src/prompts/`），组装 tool，然后驱动 `core/agent-loop.ts`：通过官方 `openai` SDK 加自定义 WebSocket 传输，发起有状态路径的 `response.create`（`core/llm.ts`），在本地执行返回的 tool call，再用 `previous_response_id` 把 `function_call_output` item 链回去；没有 tool call 时停止。Steering 通过 `mailbox_updated` 到达，并在轮次之间注入；`turn_control` 会中止。

Model 可见的 tool 接口有意保持很窄（扩大前先看 `docs/TradeoffsAndKnownLimits.md`）：`todo`（`src/tools/todo/todo-tool.ts`）；computer tool `command`、`interactive_terminal`、`read_file`、`patch`、`reply_attachment`（`src/tools/computer/`）；异步委托工具 `subagent`（`src/tools/subagent/`）；结束当前 turn 的提问工具 `clarify`（`src/tools/clarify/`）；browser tool `browser_navigate`、`browser_snapshot`、`browser_find`、`browser_click`、`browser_open`、`browser_run`、`browser_extract`（`src/tools/browser/`）；schedule tool `check_back_later`、`cron`（`src/tools/schedule/schedule-tools.ts`）；memory tool `memory_note`、`memory_search`、`memory_browse`（`src/tools/memory/`）；skill tool `skill_view`、`skill_append`（`src/tools/library/`）。Shell 命令在 bubblewrap 里运行（优先 strong mode，启动时若为 weak mode 给警告，绝不无沙箱：`src/tools/computer/bubblewrap.ts`）。当前代码树没有 MCP 支持；如果以后加入，它应该作为另一个本地 tool 源，放在这个 worker 边界里。

Tool 运行边界由各 tool 自己负责，不存在一个 worker 全局 wall-clock timeout。`command` tool 的 foreground 默认是 `180s`；background run 立即返回 `backgroundId`，默认不设置 command timeout，除非调用方显式传 `timeout`。运行中的后台命令会一直被跟踪，直到进程退出、被 `kill`，或 worker 自身结束。`subagent(start)` 会创建由 PostgreSQL 持有的工作项并立即返回；独立 delegation turn 运行 Codex，在完成、失败或需要用户输入时唤醒父会话。委托本身没有 wall-clock timeout，worker 失活后可恢复；单次 Codex app-server 请求仍使用类别预算：`initialize` 为 `15s`，`thread/start` 为 `30s`，普通请求为 `60s`。这个取舍写在 `docs/TradeoffsAndKnownLimits.md`。

按契约，worker 进程是无状态的：它持有 WebSocket、tool 本地状态和当前 turn。持久语义状态与文件所有权引用是通过 RPC 或 AIGateway 落到 PostgreSQL 的行；产物和可恢复运行时文件位于 installation 的共享 RWX 工作区。杀掉一个 worker，turn 会在别处基于同一语义账本与共享文件重试。

#### 用户可见的上下文边界

Ankole 会持久保存 provider mirror 和 AI Gateway history，但单个 turn 不会拿到无限的原始群聊记录。

- **Addressed 批**：相邻的 addressed 消息会先合并，再变成一条 `actor_events` 行。批次最多 8 条，普通文本软预算约 4,000 字符；长文本连续消息可以放宽到约 8,000 字符硬上限。如果精确的旧细节很重要，请在当前请求里重述，或让 agent 使用 memory/history tool 查。
- **Ambient 回查**：开启 `may_intervene` 时，ambient recognizer 拿到的是有界的房间快照。相关 channel/thread 窗口里的 observed messages 最多 80 条；单独的 recent-history helper 最多 10 条。因此 ambient 判断是局部房间感知，不是全历史搜索。
- **实际使用规则**：交代任务时请重述关键 ID、日期、约束和期望验收条件。持久记忆适合稳定事实，但当前 turn 最可靠的上下文仍然是用户在这一轮明确写出来的内容。

### Principal 和 AuthZ：身份与权限

`Ankole.Principals` 和 `Ankole.AuthZ`（`lib/ankole/principals/`、`lib/ankole/authz/`）。Principal 是 installation 范围内的 subject，用小写文本 `uid` 作主键，`type` 是 human | agent，并有按类型区分的行（`human_users`、`agents`）和 `external_identities`（平台 subject、channel actor、登录 subject、outbound actor）。AuthZ 拥有 group（静态和 CEL 计算，内置 `admin` / `all_humans`）、grant（`owner + resource_pattern + action + condition`）、membership，以及从 identity provider 同步来的 external binding。一次 authorize 调用会构造显式 snapshot（`authz/snapshot.ex`），交给 kernel（`Ankole.Kernel.authz_authorize/1`）做确定性的 CEL + pattern 求值。Kernel 永远不碰数据库。

### AppConfigure：operator 管理的运行时设置

`Ankole.AppConfigure`（`lib/ankole/app_configure/`）。每个运行时设置都是一个声明的 key（`AppConfigure.define/1` 或 pattern definition），存在 `app_configure` 表里，形状是 `{scope, key, value}`，scope 为 `global` 或 `agent:<id>`；解析的回退顺序是 agent -> global -> 代码默认值。Secret 值用 kernel 的 AEAD 和按行派生的 key 封装；读路径前面有 ETS 缓存。环境变量只用于进程启动（`DATABASE_URL`、`SECRET_KEY_BASE`、fabric endpoint）；任何 operator 在运行时管理的东西都应该放这里，而不是 env。

### Plugins：可信的第一方 Elixir 扩展

`Ankole.Plugins`（`lib/ankole/plugins/`）。启动时，`Discovery` 从 `plugins/` 和 `internals/plugins/` 加载 plugin 源（可用 `ANKOLE_PLUGIN_PATHS` 覆盖）；plugin 是实现 `Ankole.Plugins.Plugin` behaviour 的 module：`plugin_id/0`、`api_version/0`（= 1），以及可选的 `display_name/0`、`description/0`、`app_config_definitions/0`、`app_config_patterns/0`、`setup_metadata/0`、`adapter_declarations/0`、`children/0`。Registry 校验 spec，跳过列在 `plugins.disabled_ids` 配置里的 id，注册活跃 plugin 的 config definition，启动它们受监督的 children，并按 contract id 索引 adapter declaration：聊天/provider adapter 用 `signals_gateway.adapter`，model provider 用 `ai_gateway.provider`。没有动态第三方加载，没有 marketplace，没有热激活；plugin 是随 installation 一起交付的可信代码。

`plugins/lark_adapter` 是参考 adapter：每个 `{domain, app_id}` 一条长连接（通过 `libs/feishu_openapi`），对 message/recall/reaction/card action 做入口归一化，提供用于 post、回复、编辑、删除、reaction 和流式 CardKit 卡片的 outbox adapter，并提供独立的 identity-provider contract（OIDC 登录 + 用户/部门同步进 Principal）。

### Schedule：把时间变成 actor event

`Ankole.Schedule`（`lib/ankole/schedule/`）。两个原语：checkback（一次性的 `check_back_later`）和 cron schedule，存在 `actor_scheduled_events` 和 `actor_cron_schedules` 里。Oban 只是唤醒边：`FireScheduledEvent` 用带守卫的 `status = 'scheduled'` 更新抢占行，用稳定的 `source_event_id`（`check_back_later:<id>:wakeup`、`cron:<id>:<slot>`）追加 actor event；对于 cron，还在同一个事务里计划下一次触发。Worker 通过 `schedule.*` RPC 创建 schedule（这就是 `check_back_later` 和 `cron` tool 调的东西）；operator 通过 console REST API 管理它们。

### Skill 和 library

内置 skill 随 worker 镜像从 `app/library/skills/` 发货（每个都有 `SKILL.md` 加 asset）；agent 安装的 skill 是 shared skill 根目录下的真实文件，通过文件 lane 移动。worker 每个进程对某 agent 的首个 turn、以及目录指纹变化后的 turn，都会在 resolve context 前发送 `skills.installed.replace` observation。PostgreSQL 持有 registry、enablement、overlay 和 observation（`Ankole.AIAgent.Library`，`lib/ankole/ai_agent/library/`）。Model 看到的是 `skill://enabled/...` 引用；`skill_view` 读 base 文件并合并数据库 overlay，`skill_append` 替换 overlay。不要合成假的 `/workspace/skills` 路径。

## 一条消息的生命周期，带代码指针

Canonical 链路：用户在飞书群里 mention 一个 agent，agent 在跑了一个 shell 命令之后作答。

1. **入口。** `plugins/lark_adapter/.../inbound.ex` 在长连接上收到 `im.message.receive_v1`，调用 `Ankole.SignalsGateway.Ingress.emit_entry/4`。Gateway 解析 binding、求值 filter（kernel CEL）、检查 tombstone、upsert `signal_gateway_channels` / `signal_gateway_entries`，并打开或扩展 inbound batch。
2. **一个工作项。** `InboundBatchFinalizer` 关闭 batch；一个事务写入一条 `actor_events` 行，`type = "im.message.addressed"`，对 `(agent_uid, binding_name, source_event_id)` 唯一，然后向 provider 确认。这一行就是持久的工作项；它会永久保留，工作完成时设置 `completed_at`。
3. **分发。** ActorRuntime 的 session controller 选择下一个 ready event（`input_state = 'open' AND completed_at IS NULL`，且没有 live delivery），`ActivationManager` 持有激活租约，`WorkerPool` 分配 worker，`TurnLifecycle.start_worker_turn` 写入 `actor_event_deliveries` 的 fence 行，`Transport.Broker` 通过 ZeroMQ 发送 `turn_start` envelope（由 `turn_envelope.ex` 构造）。这里不传历史，只有一个 fence、一个 actor event、一个 model 引用。
4. **Worker turn 准备。** `src/main.ts` 分发到 `core/turns/text_turn.ts`，后者通过 RPC 拿会话上下文和 agent 范围的 AIGateway key，构造 system prompt，组装 tool set。
5. **第一次 model 调用。** `core/agent-loop.ts` 通过 AIGateway WebSocket 发送 `response.create`（`store=true`、`conversation`、用户文本作为 input items，并带 `metadata.actor_event_id`）。`conversation` 是 Responses state anchor；`actor_event_id` 只是这个主 agent 用户故事里的 ActorRuntime correlation。`AnkoleWeb.AIGatewayResponsesSocket` 把它交给 `StatefulResponses.start_response_run`，后者展开历史、必要时自动 compaction、写入 `generating` 行；provider 的 `prepare/1` 加 kernel `universal_ai_client` 流式调用上游。Chunk 发到 PubSub，绝不进数据库。
6. **实时预览。** `SignalsGateway.AIReplyPreview` 订阅这些 chunk，通过 lark adapter 的 CardKit 调用驱动流式飞书卡片：第一个 chunk 时发送，文本增长时编辑。
7. **工具执行。** Model 返回 `function_call`；AIGateway 把行 commit 成 `complete`（input items + output items 在同一个 `content` 数组里）并发送 terminal frame。Worker 在 bubblewrap 里跑 shell 命令，然后用 `function_call_output` 发下一次 `response.create`，并通过 `previous_response_id` 链接。
8. **Terminal commit。** 没有 tool call 的轮次是链尾，也就是这个 actor event 的最终 AI 输出。AIGateway 在一个事务里把它 commit 成 `complete`、设置 `actor_events.completed_at`、清理 delivery，然后 worker 才看到 terminal frame。Worker 成功时自己不报告任何东西；`turn_error` 和 `turn_noop_completed` 覆盖其他结束方式。
9. **定稿。** `AIReplyPreview` 用最终内容替换卡片。Provider 确认成功之后，它 upsert 最终镜像：一条 `signal_gateway_entries` 行，其 `ai_message_id` 指向最终 message 行。那一行就是送达凭证。
10. **恢复。** 如果 8 和 9 之间有任何东西死掉，`RecoveryScan` 会找到缺少镜像的 completed final 并重发（设计上是 at-least-once）。Worker 在 turn 中途死亡表现为 fence 失败的 delivery；重试是一条新的 actor event，带 `retry_of_actor_event_id`；孤立的 `generating` 行会老化成 `error`，下一次 run 会重新 anchor 到最后一条 `complete` 行。

Side chain 复用同样的形状：

- **定时唤醒**：`check_back_later` / `cron` tool -> `schedule.*` RPC -> `actor_scheduled_events` 行 + Oban 作业 -> 触发时写入新的 actor event -> 走同样的分发路径。
- **显式副作用**（附件、reaction、命令反馈）：`reply_attachment` 等在 terminal commit 时变成 `signal_gateway_outbox` 行；outbox executor 调 binding 的 outbox adapter 并记录 provider 结果。
- **Steering**：running turn 期间来的新消息会变成 actor event，它的到达通过 `mailbox_updated` 推送；worker 在 model 轮次之间注入它。`/steer` 在这个 nudge 成功发送或排队给 active turn 时即 ack，不等待模型证明已经消费。
- **`/compress`**：一个 IM 命令，通过 `POST /api/v1/ai-gateway/responses/compact` 写入 compaction 行。
- **Recall**：被 recall 的 provider 消息会 tombstone 镜像；对于 completed 的工作，还会硬删除或 retract 消息链的尾部。

## Identity Layers

四层 id 到处都会出现。它们绝不可互换：

| Layer | 标识 | 示例 |
| --- | --- | --- |
| `source_event_id` | 一个 provider event；入口幂等键 | 飞书 `Event.id` |
| `source_entry_id` | 一个 provider entry（message、post） | 飞书 `message_id` |
| `actor_event_id` | 一个 Ankole 工作项（`actor_events.id`） | uuid |
| `ai_message_id` | 一个已存的 model 输出（`ai_gateway_messages.id`） | uuid |

Canonical 定义在 `design-docs/SignalsGateway.md` 的 Identity Layers 部分。

## Data Model Essentials

持久表（崩溃后的事实来源）：`principals`、`human_users`、`agents`、`external_identities`、`principal_groups`、`permission_grants`、`app_configure`、`signal_gateway_bindings`、`signal_gateway_channels`、`signal_gateway_entries`、`signal_gateway_outbox`、`actor_events`、`actor_cron_schedules`、`actor_scheduled_events`、`ai_gateway_conversations`、`ai_gateway_messages`、`ai_gateway_providers`、`memory_notes`、`memory_episodes`、`memory_channel_cursors`，以及 skill library 表。

运行时投影（UNLOGGED、可重建）：`actor_event_deliveries`、`actor_session_activations`、`actor_session_worker_assignments`、`agent_computer_workers`。

需要遵守的约定（见 `CLAUDE.md`）：

- Principal uid 是小写文本主键，并直接作为外键使用；不要加影子 UUID。
- 不透明的行 id 用应用代码生成 UUIDv7（schema 里用 `Ankole.Ecto.UUIDv7`，schema 插入之外用 `Ankole.Kernel.gen_uuid_v7/0`），绝不用 `gen_random_uuid()` 默认值。
- 优先用 PostgreSQL 原生建模：enum 走 `Ecto.Enum`，declared payload 用 `jsonb`，必须跨崩溃存活的 invariant 用 check constraint 保护。
- 状态机是由事务性 `WHERE` 子句（乐观 commit）守卫的 status 列，而不是 advisory lock。

## 在哪里做修改

**新增 AI model provider。** 写一个返回 `provider_definition()` 的 provider module（参考 `lib/ankole/ai_gateway/providers/openai.ex` 或 `plugins/china_market_ai_providers/` 里的 plugin provider）：设置 schema、默认 base URL、带 `prepare/1` 的 capability，用它针对 kernel 的某个 API resolver 构造 `UniversalAIRequest`（responses / chat-completions / claude / embedding / rerank 形状）。内置 provider 注册在 `Ankole.AIGateway.Providers`；plugin provider 声明 `ai_gateway.provider` contract。可选实现：`prepare_connection_check/1`、`models_metadata_source/1`。之后 operator 通过 console 创建 `ai_gateway_providers` 行，并绑定 agent model profile。用 `mix e2e.ai_gateway_real_provider` 做冒烟测试。

**新增 worker tool。** 在 `app/agent_computer/src/tools/` 下实现它（Zod 参数 schema + `execute`），在 `src/core/turns/text_turn.ts` 的 turn 装配里注册，并通过 bubblewrap helper 路由任何命令执行。Tool 接口是 allowlist，也是产品决策；扩大它时更新 `docs/TradeoffsAndKnownLimits.md`。持久副作用必须走 RPC 或 AIGateway API，不能写本地文件。测试要在镜像里跑：`bun run agent-computer:test`；跨边界行为放在 `tools/e2e/suites/worker_computer_e2e_test.exs`。

**新增聊天/signal provider adapter。** 在 `plugins/` 下新建 Elixir plugin，实现 `Ankole.Plugins.Plugin`，声明 `signals_gateway.adapter`，包含 inbound/outbox module、setup metadata、凭证的 config pattern。Inbound 代码把 provider event 归一化成 `SignalsGateway.Ingress.emit_*` 事实；outbox module 实现它能诚实支持的 operation。长连接作为 plugin 的 `children/0` 运行。`plugins/lark_adapter` 是参考；contract 在 `design-docs/SignalsGateway.md` 和 `design-docs/plugins/FeishuAdapter.md`。E2E 使用遵循 `tools/e2e/support/fake_feishu/` 的 fake provider server。

**新增 worker->control-plane RPC。** Elixir 侧的 handler 注册在 `lib/ankole/actor_runtime/rpc_lane.ex`；像现有 broker 一样校验 turn ref 和已认证路由。Worker 侧从 `src/rpc_lane.ts` 调用。如果负载在崩溃之后仍然重要，handler 写 PostgreSQL；worker 永远不直接写。

**新增运行时设置。** 在负责的子系统里声明 key（`AppConfigure.define/1`，或 plugin 的 `app_config_definitions/0`），标记 secret 需要加密，通过 `AppConfigure.get/2` 读取。不要为 operator 在运行时管理的东西新增环境变量。

**新增内置 skill。** 在 `app/library/skills/<name>/` 下建目录，放 `SKILL.md` 和 asset；它会随 worker 镜像发货。Enablement 和 overlay 是 PostgreSQL 行（`Ankole.AIAgent.Library`）；`skill_view` / `skill_append` 无需其他改动即可工作。安装到 shared skill 根的 agent skill 还需要 worker 在 turn 前扫描并推送 observation，文件 lane 只负责移动字节。

**新增 console API + UI。** 在 `lib/ankole_web/router.ex` 的 `:console_api` pipeline 下加 OpenAPI-spec'd controller（open_api_spex），重新生成 `app/webapps` 里有类型的 client（`openapi/` + TanStack Query hook），用 `libs/uikit` 组件构建 screen。生成的 client code 是构建产物，绝不要手改。

## 开发工作流

```shell
bun install                      # workspace deps
bun run services:start           # devkit Docker Compose: PostgreSQL on :5433
bun run control-plane:setup      # mix deps.get + ecto.create/migrate/seed
bun run control-plane:dev        # Phoenix on :4000 (serves built SPAs)
bun run webapps:dev              # optional: Vite on :3035 with HMR

# Worker image (required for worker tests and e2e)
docker build -f app/agent_computer/Dockerfile -t ankole-agent-computer:0.1.0 .

# Render the docker run command for an external worker against local fabric
cd app/control_plane
mix ankole.actor_runtime.worker_bootstrap \
  --endpoint tcp://127.0.0.1:6010 --worker-id worker-a
```

测试分层：保持快路径快，并在正确的层验证运行时声明（见 `docs/TradeoffsAndKnownLimits.md` § Worker E2E）：

| Tier | Command | Needs |
| --- | --- | --- |
| Control-plane 单元/集成 | `bun run control-plane:test`（= `mix test`） | 只需要 PostgreSQL |
| Worker tool | `bun run agent-computer:test` | Docker + worker 镜像（bubblewrap 只在容器内可用） |
| 类型/lint/format | `bun run type-check`、`bun run lint`、`bun run fmt` | 无 |
| 主链 e2e | `cd app/control_plane && mix e2e.gate` | Docker worker 镜像；fake Feishu + fake OpenAI |
| 混乱/性能 | `mix e2e.chaos`、`mix e2e.perf` | 同上 |
| 真实 provider | `mix e2e.real_llm`（`ANKOLE_REAL_LLM_E2E=1`）、`mix e2e.ai_gateway_real_provider` | 真实凭证 |

E2E harness（`tools/e2e/`）跑一个 fake 飞书平台，它用真实 WS 协议对接真实的 `lark_adapter`，再加 fake OpenAI endpoint 和一个通过 RuntimeFabric 连接的真实 Agent Computer container。因此，“主链能用”是一个可运行的 claim，而不是静态审查的 claim。`bun kit` 暴露 devkit helper（`external-services`、`analyze`、codegen）；包过滤器（`bun run --filter @ankole/... test`）让验证在工作区快速变动时仍然保持在包级别。

## 术语表

- **actor event**：一个 agent session 的持久工作项。它是 `actor_events` 里的一行。完成后仍保留；`completed_at` 标记完成。
- **actor session**：`{agent_uid, session_id}`。Signal 支持的 session 从 channel 派生 `session_id`；一个 channel，一个 session actor。
- **binding**：一个 agent 的一条 provider 入口配置，例如一个连接到 agent 的飞书 app。
- **run row**：一次 `response.create` 调用写入的 `ai_gateway_messages` 行。在一个 `content` 数组里保存请求 input items 和 model output items。
- **compaction artifact**：一条 `ai_gateway_compaction_artifacts` 行，保存 summary、canonical `response.compaction.output`、保留的 tail items 和 usage facts。
- **checkpoint row**：一条 `ai_gateway_messages` 行（`type = "checkpoint"`），其 `content` 只包含一个 `compaction_artifact` ref。它是 response-chain continuation anchor，不是 summary 的事实源。
- **anchor**：新 run 链接到的行（`previous_message_id`；在 API 边缘渲染成 `previous_response_id`）。
- **visible leaf**：没有其他行链接到它的 `complete` 行。隐式续接总是选最新的 visible leaf。
- **source mirror**：`signal_gateway_channels` + `signal_gateway_entries`，provider 侧当前显示内容的映像。不是队列，也不是 model 历史。
- **outbox**：`signal_gateway_outbox`，显式 provider 可见副作用（附件、reaction、命令反馈）的持久表。流式回复不走这里。
- **preview / finalize**：流式回复的生命周期：第一个 chunk 时发送 provider 消息，streaming 期间编辑它，在 terminal event 时替换成最终内容。
- **final mirror**：确认最终发送/编辑之后写入的 `signal_gateway_entries` 行（带 `ai_message_id`）。它是送达凭证。
- **fence**（`ActorTurnRef`）：一个相等性检查（activation、epoch、actor event id、revision），挡住 stale 的 worker commit 到更新的 actor 状态。
- **turn**：一个 actor event 的一次 worker 执行；可能有多次 model 调用，但只有一次完成。
- **dead letter**：被标记为不可送达的 actor event（`input_state = 'dead_letter'`）。它不同于 completed。
- **checkback**：agent 为自己安排的一次性自我唤醒（`check_back_later`）。
- **tombstone**：一个短期守卫行，用来挡住被移除的 provider entry 因迟到的 delivery 被重新镜像。

## 已定决策：在“修复”前先读

`docs/TradeoffsAndKnownLimits.md` 记录了一些看起来像 gap、但已经定下来的 tradeoff。新人最容易踩到的点：

- 流式 IM 送达是 at-least-once；恢复之前出现 stale 的预览卡片是接受的；error terminal 不发 IM 消息。
- 续接从消息图派生（最新的 visible leaf）。没有存储游标，没有 generation 租约，也没有半流恢复；坏掉一条流的代价是一轮。
- AIGateway 安全就两条规则：30 天 agent token 证明身份，每个查询都按 `agent_uid` 过滤。Worker 是可信的第一方节点；bubblewrap 才是不可信进程的边界，不是 worker。
- 一个 WebSocket 同一时间只有一个在途 response；排序由 ActorRuntime 保证，不靠 AIGateway 锁。
- ZeroMQ 永远不是持久队列；UNLOGGED 运行时表是可重建的投影，不是事实来源。

如果某个修改碰到这些点，它就是设计变更：先更新设计文档，再改代码。

## 阅读顺序

1. 本文。
2. `design-docs/AIGateway.md`：如果你改 AI 侧，包括 provider、有状态消息日志、tool loop、compaction。
3. `design-docs/SignalsGateway.md`：如果你改 IM/provider 侧，包括入口、batch、命令、流式送达、恢复。
4. `design-docs/memory/Basic.md`：如果你改 channel 记忆、历史召回、BM25/vector 检索或 memory tools；详细 v1 设计见 `internals/docs/Memory.zh.md`。
5. `design-docs/RuntimeFabric.md`、`design-docs/Schedule.md` 和 `design-docs/SubagentDelegation.md`：当你改传输、时间或持久后台工作。
6. `design-docs/Principal.md`、`design-docs/AuthZ.md`、`design-docs/AppConfiguration.md`、`design-docs/Plugins.md`、`design-docs/I18n.md`、`design-docs/Logger.md`：按需查阅。

## Design Doc Index

| Document | 修改这些内容时阅读 |
| --- | --- |
| `docs/README.md` | 任何内容：system map、code-level map、change guide、glossary |
| `design-docs/AIGateway.md` | Provider、message log、tool loop、compaction |
| `design-docs/SignalsGateway.md` | Ingress、mirror、outbox、delivery、命令 |
| `design-docs/memory/Basic.md` | Channel note、历史召回、BM25/vector search |
| `design-docs/RuntimeFabric.md` | Envelope、lane、socket、文件传输 |
| `design-docs/Schedule.md` | Checkback、cron、Oban 唤醒边 |
| `design-docs/SubagentDelegation.md` | 持久后台工作、Codex resume、steer、唤醒 |
| `design-docs/Principal.md`、`design-docs/AuthZ.md` | 身份、group、grant、CEL |
| `design-docs/AppConfiguration.md` | 配置 key、scope、加密 |
| `design-docs/Plugins.md`、`design-docs/plugins/FeishuAdapter.md` | Plugin contract、Lark adapter |
| `design-docs/I18n.md` | 本地化目录 |
| `design-docs/Logger.md` | 结构化 JSON 日志、severity、labels、请求和 operation 字段 |
| `docs/TradeoffsAndKnownLimits.md` | 任何看起来像 bug 的行为 |
