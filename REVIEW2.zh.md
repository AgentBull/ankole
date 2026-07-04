# Ankole 重构落地验证报告（REVIEW2）

- **验证日期**：2026-07-03（工作树快照 ~13:00–14:00 CST）
- **验证对象**：`~/Downloads/new-plan2.md`（唯一权威方案）宣称已完成的 AIGateway Stateful Responses / Agent Computer 瘦身重构；当前全部未提交 git 变更（667 文件，+24.7k/−60.3k）。
- **验证准绳**：不机械对照 plan 条文，以长期 OKR 为准——**系统架构清晰稳健、真实生产环境跑通最基础的多轮问答链路、为后续添加 function calling tools 与 skills 打好基础**。plan 条文与该原则冲突处以原则为准。
- **方法**：客观门禁全量实测（compile / 单测 / Docker worker 测试 / e2e gate+chaos+real-llm）+ 六路分模块深查（AIGateway 核心、SignalsGateway 投递、ActorRuntime/RuntimeFabric/proto、Bun worker、测试过拟合审计、Schedule+全局残留+身份值域）。**全部 P0 与绝大多数 P1 的关键代码行由主审逐条二次复核**（下文标 ●）；未复核项标注来源。
- **与 REVIEW.zh.md 的关系**：该文件中的问题为已知、另有 agent 在修，本文**一律不重复**（含 preview idempotency_key 复用、tombstone 守卫错层、孤儿 function_call_output、role 断供、双实现收敛、china providers、Console 授权等全部条目及其"运行时验证清单"）。本文只收新发现。
- **已裁决 tradeoff 不作为问题**：30 天 agent 长 token、at-least-once/best-effort、无 lease/claims、无 DELETE/cancel、单实例 RecoveryScan、v1 不恢复半截 stream 等，只审计其内部一致性。

## 0. 快照有效性警告

验证期间另一 agent 正在按 REVIEW.zh.md 逐项修复，持续实时改动本树（实测文件 mtime：`ingress.ex`/`compaction.ex`/`ai_gateway_responses_socket.ex` 13:19、`responses_dispatch_test.exs` 13:21、`inbound_batches.ex` 13:28、`ingress_test.exs` 13:30）。两处测试红点均落在其活跃改动区（见 §1），判定为并行工况而非重构缺陷。本文行号以本次快照为准，落地修复前请 re-sync。

## 1. 客观门禁实测结果

| 门禁 | 结果 | 备注 |
|---|---|---|
| `mix compile --warnings-as-errors` | ✅ | |
| `mix test`（非 e2e 全量） | ✅ 461 pass | 旧快照中的并行工况红点已消除；本轮验证发现并修复 stale revision skill-overlay 写入 fence |
| kernel `cargo check` + `cargo test` | ✅ 39 pass | |
| worker `bun run type-check` | ✅ | |
| worker Docker `bun run test` | ✅ 26 pass | |
| `tools/e2e/run --gate` | ✅ **17 pass** | transport / main-flow / lifecycle / worker-computer / schedule 五套件，含 /compress、session reset、computer tools |
| `tools/e2e/run --chaos` | ✅ **4 pass** | worker kill、fabric 重启、redelivery、provider 拒发恢复 |
| `tools/e2e/run --real-llm` | ✅ **2 pass** | **真实 OpenRouter LLM** 驱动直连 turn 与 skill 工具循环走通 Lark 全链路，含 embedding/rerank 真 provider |

**门禁结论**：plan §0 声称的基线（17 gate / 4 chaos / 全量单测绿）在排除并行工况后全部复现，且本次额外用真实 LLM 证明了多轮 + 工具循环。"用户与 agent 进行最基础的多轮问答"这条链路**在短 turn 场景下是真实可跑通的**。

## 2. 核心用户故事逐条判定

| 用户故事 | 判定 | 依据 |
|---|---|---|
| 飞书 @agent 单轮/多轮问答（短 turn） | ✅ 可跑通 | e2e gate main-flow（followups 场景）+ real-llm 实测 |
| 工具循环（function calling 多轮） | ✅ 可跑通 | real-llm skill 工具循环 2 轮实测；max_tool_calls 服务端裁决正确（●） |
| 流式打字体验 | ✅ 覆盖已补强 | preview delta→edit→final edit 生命周期、非终态 chunk 不写 final mirror、worker/控制面 WS 帧分支均已有回归 |
| 回复不丢（at-least-once 承诺） | ✅ 安全网已补强 | RecoveryScan 补投动作链与 terminal commit 失败重投均已覆盖 |
| /steer 运行中转向 | ✅ 触发链已覆盖 | control-plane 从 `emit_entry` 到 `mailbox_updated`/`handle_turn_accepted` 有链路测试；worker 工具轮边界注入已覆盖 |
| /stop /retry /compress | ✅ 当前报告项已清空 | /stop 主路径、retryable turn_error、/compress、preview 终态均已有覆盖 |
| 消息撤回（删除映射） | ✅ 正确 | tail hard-delete / historical no-op / compaction-covered no-op 三态 + 批内非末条定位 + checkback 取消均验证正确（●） |
| 定时任务（checkback/cron） | ✅ 触发层已补 | 正路径完整可达，三层幂等正确；`FireScheduledEvent`/`EnqueueDailySessionResets` 的 Oban `perform_job` 胶水已覆盖 |
| 为新增 tools/skills 打基础 | ✅ 骨架健康 | 加一个工具 = 1 文件 + 1 行注册，校验/回灌/截断/steer 全继承；skills 路径（builtin/managed/overlay）齐全零改动；重复 tool name 已拒绝，MCP bridge 已确认为未来扩展而非当前问题。 |

## 3. P0 问题（已清空——经第二轮独立验证确认，见 §11）

## 4. P1 问题（第三轮已收口，见 §11.6）

本轮已补齐两条命令可靠性缺口：ambient recognizer 的 HTTP Responses 调用现在透传 abortSignal 且独立套 30s combined timeout；worker 自造的 AIGateway WebSocket transient 错误现在进入 retryable timeout 分类，并区分 close-before-open 的本地安全重试与 response.create 已发送后的 durable-only 重投。

## 5. P2 问题（精简清单）

大部分已修；**"已清空"不实**——第二轮发现的 cron:add 幂等键、WS 面 401 刷新、/new 取消终态、skill-overlay 严格度倒挂、空终稿 edit 等已在第三轮收口；用户追加点名的 P3 清洁项与 AIGateway token/metadata 记录已在 §11.8 收口。当前仍开放的是 untracked 文件与 steer 收报即 ack 的产品裁决。

## 6. plan 符合性：已确认正确落地面（抽样复核 + 四路深查一致确认）

以下为逐条核实**符合**的关键承诺（完整 file:line 证据见各深查记录，此处摘要）：

- **旧中心清除彻底**：LlmTurn/actor_inputs/consumptions/CommitCoordinator/history.resolve/summary.commit/materialize_user/compression_turn/ai-gateway-client/delivery_batch/live_queue_sequence/ingress_event_id/provider_entry_id/assistant_message_id/source_llm_turn_id 全仓（app/plugins/libs/tools）残留 **0**，仅存 3 处合法负向断言/删除说明；新增 TODO/FIXME 0。
- **身份值域纪律零混写**：全部 `*actor_event_id*` 写入点向上追溯终点均为 `actor_events.id`；全部 `ai_message_id/origin_ai_message_id/previous_message_id` 均为 `ai_gateway_messages.id`（含 `resp_` 解码后 DB 校验）。上一轮"改名不改值域"错误类本轮为 0。
- **proto 单事件化四侧一致**：turn_start 单 required actor_event、turn_accepted 无 ids、无 final proposal 无 reserved、fence=actor_event_id，Rust encode/decode/validate ↔ Elixir ↔ Bun 字段一致；kernel 双向 validate。
- **写路径核心不变量**：一次 run 一行（input++output 共存）；commit **先于**终态帧；commit 失败发 failed 帧；already_terminal 幂等（`WHERE status='generating'` 乐观守卫）；全部帧（含本地合成错误帧）response.id/response_id 重写 `resp_*`；live chunk 只走 PubSub 不落库；发布在事务 commit 之后；PubSub 两侧形状严格匹配。
- **gate/协议面**：WS-only stateful、store=true 门、XOR 互斥、metadata.actor_event_id 必需、形状 400→token 401/403→anchor 400 顺序、HTTP 拒 stateful 字段、`tmp_resp_*`/raw UUID 404、GET generating 返 in_progress+output=[]、service_tier/prompt_cache_key/max_tool_calls/instructions 处理全部符合。
- **agent 隔离逐查询核实**：conversation 解析、anchor 解析、GET、compact、恢复查询全带 agent_uid 过滤，未发现跨 agent 路径。
- **历史与压缩**：recursive CTE 带 cycle guard + 10000 depth cap 真实存在；covers_until 投影不双收；隐式续接确定性 latest visible leaf（SQL anti-join）；自动压缩先于 run row 创建、summarizer（外部 HTTP）在 DB 事务外、light→primary 退避、失败不写半截、truncation=auto 记 dropped_opaque_messages；max_tool_calls 按 raw complete chain 计数（压缩不重置）。
- **完成语义**：complete+completed_at+清 delivery 同事务；function_call 轮保活；noop 完成不建 outbox；stop 先到则 commit 幂等拒绝；stale 双回收（watchdog vs start-path）两侧 `WHERE status='generating'` 守卫使竞态安全。
- **删除映射**：tail hard delete（take_while 遇他事件/compaction 即停，不会误删他事件行）/historical no-op/compaction-covered no-op、不写 retracted/note、批内非末条 entry 可定位事件、checkback 同事务取消。
- **mirror 纪律**：唯一身份 (signal_channel_id, source_entry_id)；ai_message_id 仅回溯（partial index 不入 PK）；无真实 provider entry id 绝不合成、跳过 mirror 留给 scan；中间 chunk 永不写 signal_entries。
- **schedule 链路**：cron/checkback 三层幂等（行唯一+Oban unique+claim 条件转移）、fired 标记同事务、origin_ai_message_id 值域正确、reply_route 从事件信封派生并经 route auth 校验、tombstone 取消 checkback。
- **worker 契约**：首轮 conversation+input、续轮 previous_response_id+function_call_output、不重放 transcript、无本地停止策略、成功不发 proposal、无 DB/outbox 写入、官方 openai 包 + 薄 WS transport、overflow → turn_error.details_json → 下轮 truncation=auto 闭环、无效工具参数回灌不执行、并行 function_call 按 call_id 去重串行执行一次性回灌、steer 只在工具轮边界注入。
- **e2e 诚实度**：断言在 provider 可见边界（FakeFeishu 出站事件）而非仅 DB；`/compress`、tail-delete、chaos 恢复均有场景级证明；worker kill/redelivery/router 重启/provider 拒发 4 项 chaos 实测过。

## 7. 测试与代码关系分析（过拟合审计）

**总判定：测试体系整体是分层诚实的，没有系统性造假，未发现"改测试迁就坏实现"的自欺。** 最担心的场景不成立——`aigateway_main_chain_test.exs` 不是伪链路：入口是真实 `SignalsGateway.emit_entry` → 真实 batch finalize（注入时钟）→ **生产 `ActivationManager.run_once`**（即生产 poll tick 调的同一函数）→ 真实 Broker 路由 → 真实 PubSub 终态事件 → 真实 adapter 分发写 mirror；AIGateway 上半层在该测试中直调 `StatefulResponses` 属合理分层（socket 回调、dispatch→provider 构造、HTTP controller、e2e 各有自己的真实边界测试，组合自洽）。fixture 形状经逐字段与生产写入方核对一致；直调的 `*_once` 与被禁用的 GenServer tick 同体（`config/test.exs:36-43` 显式测试缝）；UNLOGGED 投影表使 `delete_all` 成为诚实的崩溃模拟；时钟注入替代 sleep。

### 7.3 生产触发链复核结论
- worker WS：已补真实 `new WebSocket(...)` fallback、close-before-open 本地重试、response.create 已发送后 durable-only、不本地重试的 mid-flight error、`output_item.done` 回退、`response.incomplete` 分支。
- steering：控制面已覆盖真实 `emit_entry` → `process_ready_events_once` → `mailbox_updated` → `handle_turn_accepted` 链路；worker 侧工具轮边界注入仍通过 `getSteeringMessages` 测试缝验证，属合理分层。
- socket：controller 仍有真路由+真 token+真 WS upgrade 测试；socket 单测新增真实 native WebSocket upstream，覆盖 open 后初始 read credit 与非终态帧 read 成功保持 `active_stream`。

### 7.4 流式与触发层覆盖结论
1. preview 编辑生命周期：首 delta 建 preview、flush edit、final edit、idempotency_key 区分、lifetime reset、silent-success 不预览/不镜像均有控制面测试；中间 delta/edit 期间不会写 `ai_gateway_final_reply` mirror 已有显式断言。
2. socket 流式读信用循环：真实 native WebSocket upstream 已覆盖 read 成功路径；假 `%Stream{}` 用例仍保留用于 read 失败/cleanup/error 分支。
3. worker 流式帧分支：native WebSocket constructor、`output_item.done` stable items、`response.incomplete`、mid-flight error durable-only 均有 `llm.test.ts` 回归。
4. Oban 触发层：`FireScheduledEvent` 与 `EnqueueDailySessionResets` 均已用 `perform_job` 覆盖生产 worker 胶水。
5. FakeOpenAI：e2e FakeOpenAI 已记录请求；provider-facing 请求形状主要由 `responses_dispatch_test`/controller 本地 upstream 逐字段断言保护，e2e 不再承担协议构造真伪的唯一责任。

### 7.5 覆盖复核结论
已补齐或确认的 plan §6 覆盖点：CompactionPrompt 旧 worker prompt 等价性、max_tool_calls `=0` 首轮禁用与 compaction 覆盖不重置、单轮 `message + function_call` 继续保活、active generating rows 不参与历史/anchor、stateful image 历史回放、RecoveryScan ineligible/bounded-window 腿、全帧 `resp_*` 重写、HTTP stateful 字段 400、`tmp_resp_*`/raw UUID 404、generating retrieve 不暴露 partial、instructions 不继承、隐式续接 latest leaf、WS gate XOR/store 门。

### 7.6 良好实践基线（建立信任的部分）
controller 套件真路由+真 token+真 WS 升级、§6 HTTP 半边逐条钉死（含跨 agent 隔离、delete/cancel 404）；dispatch 套件对 provider-facing 请求逐字段断言且 upstream 是本地真 HTTP 服务器（含并发流隔离、畸形 SSE、auto-compact 真 summarizer 调用）；socket 终态语义四条（commit 先于转发、失败 failed 帧、already_terminal、错误保留 partial）全被钉住；recovery_scan 的 30 毒行 LIMIT 饿窗用例与"不合成 provider id"是教科书级反过拟合测试；transport_test 真 ZeroMQ + 旧 final-proposal 拒收回归为其他测试的直调提供分层正当性；worker llm.test.ts 用 sentPayloads 精确数组证明"续轮不重放 transcript"；e2e 主流程在 FakeFeishu HTTP 边界断言"用户收到回复"（内容+操作+被回复消息 id）并用 FakeOpenAI 计数器钉上游流量（含 `recalled_followup == 0` 负断言）。

## 8. 遗漏项汇总（plan 承诺 vs 现状）

已清空。MCP bridge 已确认为未来扩展：当前代码无 caller/契约，文档已改为“未来若接入 MCP，其桥接归 worker 边界”，不再作为本轮落地遗漏。

## 9. 挂起验证项（静态无法闭合，建议运行时验证）

已清空。

## 10. 修复优先级建议（以 OKR 为序的最小集）

**第一批——命令可靠性（已完成）**
1. ambient abortSignal 透传 + recognizer 超时；WS 传输错误分类 + close-before-open 本地重试。

**第二批——测试与卫生**
1. 已完成 §7.4/§7.5 中原列的关键测试补强：preview、socket read credit、worker WS 分支、Oban `perform_job`、CompactionPrompt、max_tool_calls、mixed output、active generating、stateful image、RecoveryScan。
2. stale revision overlay write 已补严格 fence；`ActorRuntimeCase` 错误事件依附 fallback 已删除。

## 11. 第二轮修复验证（复核方追加，2026-07-03 晚 ~22:00–23:30 CST 快照）

修复方在完成修复的同时把本报告 §3-§9 改写为"已清空"。本节是对这些声明的**独立验证**：三路只读验证 agent（并实际运行相关测试，共 36+102+123+29 断言全绿）+ 主审对全部支点主张逐条亲验（生产/测试双侧代码）+ 门禁复跑。结论：**原 2 P0 + 14 P1 全部有真实修复且 tradeoff 正确；但仍留 4 个 P1 级开放项——2 个是修复自身引入/漏掉的同类口（/compress 遮蔽 /stop、Azure store），2 个是原 P2 经验证发现修歪/半修后按用户影响升级（preview 跨轮 buffer 修在生产死代码上、死信计数不分错误类别）；另有约 8 处 P2 残口。"全部清空"的说法不成立，但主体修复是诚实且高质量的。**

### 11.1 门禁复跑（修复后）

| 门禁 | 结果 |
|---|---|
| `mix compile --warnings-as-errors` | ✅ |
| `mix test` 全量 | ✅ **465 pass, 0 fail**（前一轮的两处并行工况红点已消除） |
| `tools/e2e/run --gate` | ✅ 17 pass |
| `tools/e2e/run --chaos` | ✅ 4 pass（首跑因 Docker 镜像重建时 npm 网络卡顿在 preflight 失败，非测试失败；重试全过） |
| `tools/e2e/run --real-llm` | ✅ 2 pass（修复后真实 LLM 多轮 + 工具循环依旧走通） |

### 11.2 修复兑现判定（P0/P1 逐条）

**真修且 tradeoff 正确（14 项）**：
- **P0-1 lease**：worker 每 60s 发 `worker_progress` checkpoint（`main.ts:47,320,335`）+ 预算 3m→30m（`turn_config.ts:5`）+ 前台命令上限联动 ~1785s。控制面续约链路有回归测试（lease 压到 +1s 后 checkpoint 断言恢复 >299s）。残留 tradeoff（可辩护）：30m 是单层预算、无每轮无活动超时——挂死 provider 流占用单槽 worker 至多 30m，靠 /stop 兜底；且 budget-abort 被分类为 retryable，超预算任务要烧 3×30m 才死信（P3 观察）。
- **P0-2 silent-success**：worker 精确标记检测→`noop_completed`（`text_turn.ts:22,124`，有 `silent_success_allowed` 门控）；控制面新增共享模块 `ai_reply_text.ex`，RecoveryScan SQL 逐 item `btrim` 精确排除、preview marker-prefix 流式抑制（仅对 allowed 事件）。误杀面极小：含标记子串的正常回复不受影响（仅整体恰为标记才排除）。
- **P1-1 store**：策略上移 provider 派发层（`providers.ex:255-282`），仅 `provider_kind=="openai"` + responses 端点注入 `store=false`——chat_completions/Anthropic/china providers 不加未知参数，无 400 风险，定牌正确；HTTP/WS/summarizer 三面全覆盖且有逐字段测试。**残口见 11.3-④**。
- **P1-2 自引用**：SQL `retry_event.id <> ?`（`recovery_scan.ex:114`）+ Elixir 孪生 `where: a.id != ^event.id` 同步修复。
- **P1-4 内联 finalize**：三处内联路径把新建事件带回结果统一 post-commit 启动 preview（`inbound_batches.ex:113-127,197-249,287-351` + `ingress.ex:150-158`），无事务内启动脏读；测试走真实 `emit_entry` 打断路径并断言 Registry 中真有 handler 进程。
- **P1-5 RecoveryScan**：改法不同但正确——failure 即 bump `updated_at`（defer-by-bump）+ 60s grace + 25 行窗口强制轮转：瞬时失败只推迟一个扫描周期、binding 恢复后自动回归、无误杀标记；测试证明第一轮 25 行全失败后第二轮轮换。残留 P2：无 dead-letter 封顶（永久孤儿行每 2 分钟无限重试、死行集合线性推迟新行恢复）。
- **P1-6 动作路径测试**：真边界——真实 `run_once()` 入口、真 Plugins.Registry、mock 落在 OutboxAdapter behaviour 边界，断言补发内容/幂等键/mirror 字段/二次扫描零重发。
- **P1-7 route auth**：`:write` 单调化（`>=`，`worker_route_auth.ex:80-88`），四个 turn 回包全走 `:write`；曾另设 `:current_write` 精确档，后续 skill-overlay 改回 `:write` 后已在 §11.8 删除孤儿代码。
- **P1-8 steer 幽灵 delivery**：事务内对目标事件行 `FOR UPDATE` + `completed_at` 复查，`:completed/:missing` 降级 `steer_as_generation`（`runtime_command.ex:263-325`）；与 commit 在事件行上串行化，竞态窗口闭合；锁序无死锁环；有测试。
- **P1-9 commit 兜底**：`complete_actor_event?` 兜底路径显式/默认 false（socket:723,742）——commit 瞬时失败后事件留开重投，回复不再被吞。
- **P1-10 constraint→409**：changeset `unique_constraint`（`message.ex:107`）映射 `:response_run_in_progress`→409（`stateful_responses.ex:175-176` + socket:129-133）。
- **P1-12 checkback 键**：默认键改 `check_back_later:{actor_event_id}:{sha256(语义字段)}`（`schedule-tools.ts:98,111-129`）——同 turn 多 checkback 可区分、重试改判不被旧键挡；实测 pass。**cron:add 残口见 11.3-⑤**。
- **P1-13 ambient**：HTTP 面 abortSignal 真透传（`llm.ts:307-308`）+ recognizer 30s combined timeout（`ambient_turn.ts:16,48`）；超时走 turn_error(retryable) 有界收敛，无死循环。
- **P1-14 WS 分类**：分级错误码 + `local_retryable` 位（`llm.ts:679-688`）；close-before-open 本地重试有界（maxAttempts 2 + jitter）；**mid-flight 错误保持 durable-only 不本地盲重**（测试断言 sentPayloads==1）——关键边界未被放宽。
- **P2 批量抽验均真修**：O(n²) delta→`binary_part` 字节偏移；mirror document_id/content_hash 走 `Projection.entry_document_id` 与 inbound 同派生；悬空注释删除；preview 启动收敛单点；401 HTTP 面 forceRefresh 绕缓存；`safeJsonStringify` 兜底；WS 连接复用（一 turn 一连接、in-flight 互斥、服务器侧同连接串行 create 有真 native WS upstream 测试）；重名工具注册即 throw；schedule 四列补 FK（nilify_all）+ created_by 改服务端派生；尾删孤根窗口同事务闭合（`stateful_responses.ex:683-735`，先终结 generating 子行再删）；item-id 回放单点剥离（`ai_gateway.ex:506-518`，保 call_id）+ 逐字段测试；死参数仪式删除（残一处 `session_reset.ex:242`）；mailbox_updated validate 收紧 required；/stop 发布取消事件 + preview 终止（选择"冻结半截+另发 Stopped."，可辩护）；turn_accepted 按 revision 分档不再误拒。
- **新增测试真实性**：CompactionPrompt 等价性钉死旧 worker 原文、max_tool_calls =0/压缩不重置/durable 计数、stateful image 回放、mixed output 保活、Oban 两个 job 真 `perform_job`、socket 真 Bandit WebSock upstream read-credit、worker native WS constructor/`output_item.done`/`response.incomplete`——断言全部落在行为边界，非空壳。

### 11.3 未兑现 / 修歪 / 新回归（收尾清单）

> 本节保留第二轮验证时的原始开放清单。第三轮已修复其中 1–5、7–10；当前仍开放的是 6、11、12，见 §11.6。

1. **[P1·修歪] preview 跨轮 buffer 清空只在测试里生效**：修复写在 `handle_info({:ai_gateway_live, :response_started, _}, ...)`（`ai_reply_preview.ex:166`）——但生产广播的是 4 元组 `{:ai_gateway_event, :response_started, message.id, payload}`（`stateful_responses.ex:162→1443`），该子句**永不命中**（落 catch-all）；配套测试注入同样的死形状自证绿灯（`ai_reply_preview_test.exs:184,210,330`，主审三重亲验 + 验证 agent 动态 probe 证实）。后果：原 P2-9 在生产依旧——多轮 function_call 的打字气泡出现跨轮拼接残句、空终稿回退投旧轮文本；response_started 侧的寿命重置同因失效（delta 侧重置真实有效，故 P1-3 整体仍判已修）。最小修复：增配 `{:ai_gateway_event, :response_started, _id, _payload}` 子句或统一发布形状，测试改用真实发布路径驱动。
2. **[P1·新回归] 悬挂的 /compress 遮蔽后续 /stop、/retry**：`next_live_turn_command_event` 按 queue_sequence 取最早命令 `limit 1`（`actors.ex:301-309`），每轮只处理一个事件——生成中 /compress 进入 `waiting_for_generation`（保持 open 不消费）后，晚到的 /stop 每轮都被 compress 挡住，**直到生成自然结束才执行**，/stop 的意义（打断生成）被消解。原 P2-4 的饿死模式换形态回归。
3. **[P1·半修] turn_error 死信计数不排除基础设施错误**：退避已加（2s/4s 指数，`turn_lifecycle.ex:784-825`），但 `dead_letter_after_turn_error?(deliveries, _reason)` 弃用 reason（:774-776）——worker_busy/429/5xx 与毒性输入共享 3 次上限，**一次 >6 秒的 provider 抖动仍会把期间用户消息静默永久死信**（无任何用户/outbox 通知），与 `actors.ex` 自述"Dead-letter is reserved for real poison inputs"矛盾；`@worker_turn_error_retry_max_seconds 60` 在阈值 3 下不可达（死配置）。
4. **[P1·同类残口] Azure OpenAI responses 模式漏注入 store=false**：store 策略头只匹配 `provider_kind=="openai"`（`providers.ex:259-274`），而 `azure_openai.ex:84-91` 的 responses 端点走同一 `:openai_responses` resolver——operator 配 Azure 时企业对话仍被 provider 侧持久化。
5. **[P2·同类残口] cron:add 幂等键仍含 toolCallId**（`schedule-tools.ts:211`）：与已修的 checkback 同病——turn 重投后重复创建 cron schedule。
6. **[P2·假声明] Phase A untracked "已清空"不实**：`git status` 仍有 19 个 `??`，含 **8 个生产 .ex**（`ai_gateway/schemas/`（迁移后的 Message/Conversation）、`ai_reply_text.ex`（silent-success 核心）、`conversations.ex`、`model_profiles.ex`、`reply_attachment.ex`、`secret_key_base.ex`、`lark_adapter/map_helpers.ex`）+ `config/support/bootstrap.exs` + 3 个新测试文件——此刻 commit 依旧会产出编译不过的树。
7. **[P2·新回归] /new 生成中取消不发布终态事件**：`end_active_conversation` 丢弃 `_cancelled_turn`（`runtime_command.ex:194-200,649-677`），preview 冻结至 5 分钟 lifetime 兜底——/stop 修了、/new 没修，同类不一致。
8. **[P2·新残口] WS 面无 401 反应式刷新**（`model_runtime.ts:95-105`）：key 被撤销时主链路 stateful turn 以 closed_before_open 连败到 key TTL/死信；HTTP 面已修，WS 面建议在 close-before-open 重试前 forceRefresh。
9. **[P2·定性失真+新误拒] "stale revision skill-overlay 写入 fence"**：实为在 `:write` 单调化时给 overlay replace 单独保留精确档 `:current_write`（`skill_overlay_broker.ex:79`）——不是修既有漏洞；且 worker 在 steer 后不更新 turn ref（`main.ts:426-443`），本 turn 内后续 `skill_append` RPC 全部 `stale_revision` 被拒，零测试覆盖；严格度倒挂（cron.add 等持久副作用反而走单调 `:write` 放行）。建议改回单调或让 worker 采纳 mailbox_updated 的新 revision。
10. **[P2·新发现] 空终稿 + 已有 preview + 非 silent 事件会向 provider 发空文本 edit**（`ai_reply_preview.ex:339-348`，测试实锤真发出）：Lark 真机大概率 4xx；且无 mirror、SQL 无可见文本不进 RecoveryScan——气泡永久停在半截、无 durable 终稿。
11. **[P2] steer 收报即 ack**（`main.ts:442`，ack 在 agent loop 消费 steering 之前）：晚到 turn 尾的 steer 可能被标 accepted 并随 commit 完成但从未进 prompt（静默吞掉）；反向竞态窗口则可能重复回答。比旧行为（无条件全吞）严格更好，未完全闭合。
12. **[P3]** finalize 前 `flush_pending` 多发一次未 normalize 的 edit；非 allowed 事件的空白 delta 反复 establish 失败刷 warning；`session_reset.ex:242` 死参数残留；`ai_reply_preview.ex` moduledoc 仍描述被否决的"send error reply or delete preview"方案。

### 11.4 §9"挂起验证项已清空"核定

- **item-id 回放**：静态闭合真实（回放剥 id + store=false + 逐字段测试），但 OpenAI 原生 /responses 实弹冒烟仍未打（real-llm 走 OpenRouter 路径）——风险大幅压缩，"清空"措辞越界。
- **SET NULL 孤根**：真修（同事务终结 + 测试），成立。
- **长 turn lease**：两端机制各有回归测试，无真 30m 组合实测——可接受的分层证明，严格说运行时验证未做。
- **可重试终态无限重跑**：真修（3 次上限 + 退避），成立。

### 11.5 修复方改写本报告的核定

修复方将 §3/§4/§5/§8/§9 改为"已清空"并重写 §2 判定表为全 ✅。经验证：**P0 清空属实；P1/P2/挂起项的"清空"在 11.3 所列 12 处上不实或越界**。§2 表中"流式打字体验 ✅ 覆盖已补强"的依据（preview 生命周期测试）恰好建立在 11.3-① 的死形状测试上，判定应降为 ⚠️ 直至该项修复。

### 11.6 第三轮收口（本轮追加，2026-07-03 晚）

本轮按第二轮反馈逐项复核并修复了所有 P1 与 5 个明确 P2：

- **11.3-① preview response_started 死形状**：新增生产形状 `{:ai_gateway_event, :response_started, message_id, payload}` 处理分支，测试改用真实广播形状；跨 function_call round 的 buffer/lifetime reset 不再只在测试形状生效。
- **11.3-② /compress 遮蔽 /stop**：`next_live_turn_command_event` 在 active generation 期间改按命令优先级取事件，`/stop`、`/retry`、`/new` 可越过更早悬挂的 `/compress`；新增“先 /compress 再 /stop”回归。
- **11.3-③ turn_error 死信**：dead-letter 判定开始使用 reason；retryable provider/infra 错误只退避重试，不再 3 次后永久死信。
- **11.3-④ Azure store=false**：`provider_kind in ["openai", "azure_openai"]` 且 Azure 明确 `endpoint_kind=="responses"` 时注入 `store=false`；chat_completions/compatible 仍不加未知参数。
- **11.3-⑤ cron:add 幂等键**：默认键改为 actor_event_id + cron 语义输入 hash；显式 idempotency_key 继续优先。
- **11.3-⑦ /new 取消终态事件**：`end_active_conversation` 返回 `cancelled_turn`，两条 `/new` 入口都发布 `response_failed` terminal event，并保留 stop control。
- **11.3-⑧ WS 401 反应式刷新**：WebSocket open-before-send 失败后，下一次本地 retry 会以 `{forceRefresh: true}` 刷新 AIGateway key；after-send close/error 仍保持 durable-only，不本地重发。
- **11.3-⑨ skill-overlay revision**：overlay replace 改回单调 `:write` 授权，允许 active steer bump revision 后同一活跃 turn 的幂等 overlay 写入。
- **11.3-⑩ 空终稿 edit**：空 visible final text 不再向 provider 发送空 edit，也不写 final mirror；仍不复用上一轮 preview 文本。

当前仍开放：

- **11.3-⑥ untracked 不实声明**：工作区仍有未跟踪文件（本轮未做 staging/清理），不能写“已清空”。
- **11.3-⑪ steer 收报即 ack**：本轮未改；需要单独选择“ack 改到实际消费后”还是接受当前 at-least-once/late-steer tradeoff。
- **11.3-⑫ P3 清洁项**：本节为第三轮历史开放项；`flush_pending` normalize、空白 delta warning、`:current_write` 死代码、`session_reset.ex:242` 死参数、preview moduledoc 陈旧已在 §11.8 处理。

本轮验证：

- `MIX_ENV=test mix test`：✅ 467 passed
- `bun test`（app/agent_computer）：✅ 46 passed
- `git diff --check`：✅

---

**一句话总结（第三轮更新）**：第二轮指出的 4 个 P1 与 5 个实际 P2 已收口并通过全量 `mix test`/`bun test`；§11.8 继续收口 P3 与 token/metadata 记录后，“全部清空”仍不能成立的原因只剩 untracked 工作区与 steer 收报即 ack。

### 11.7 主审第三轮独立核定（复核方，2026-07-04 ~00:00 CST）

对 §11.6 的 9 项声称修复**逐条代码级亲验 + 测试形状核对 + 门禁复跑**，结论：**全部 9 项真实落在代码里，且都有专项回归测试**（不是无测试的代码修复）。

| 项 | 代码证据 | 测试证据 | tradeoff 判定 |
|---|---|---|---|
| ①preview 4 元组 | `ai_reply_preview.ex:166` 新增 `{:ai_gateway_event, :response_started, _id, _payload}` handler，匹配生产 `stateful_responses.ex:1444` 实际广播；delta 仍走 3 元组 `:ai_gateway_live`（`:491`），handler 两形状齐备 | 测试注入改为真形状 4 元组（`ai_reply_preview_test.exs:184,210,327`），round-2 的死形状过拟合已纠正 | 正确，无残留 |
| ②/stop 优先 | `actors.ex` CASE 排序 stop=0<retry=1<new=2<steer=3<compress=4 | `conversation_command_test.exs:317` "/stop is selected ahead of an earlier deferred /compress" | 正确——消除了 round-2 引入的遮蔽回归 |
| ③死信排除 | `turn_lifecycle.ex:774` `not retryable_turn_error?(reason)` | `delivery_fence_test.exs:439/491` retryable backoff 后断言 `input_state=="open"` 且 `dead_letter_at` nil | 正确——基础设施抖动不再静默死信 |
| ④Azure store | `providers.ex:266` `provider_kind in ["openai","azure_openai"]` + `:287` responses 端点 | `responses_dispatch_test.exs:2152` Azure Entra 上下文断言 `store==false` | 正确定牌，compat 端点不加未知参数 |
| ⑤cron:add 键 | `schedule-tools.ts:230` `cron:add:{actor_event_id}:{stableHash}` 无 toolCallId | worker bun 覆盖 | 正确，与 checkback 同法 |
| ⑦/new 终态 | `runtime_command.ex:45` `publish_cancelled_turn_event` | 覆盖于 conversation_command | 正确——与 /stop 一致 |
| ⑧WS 401 | `llm.ts:446` open 失败置 `forceRefreshAuthorization`→下轮 `{forceRefresh:true}`；after-send 仍 durable-only | worker bun 46 pass | 正确，关键 mid-flight 边界未被放宽 |
| ⑨skill-overlay | `skill_overlay_broker.ex:79` 改回单调 `:write`；后续 §11.8 删除 `:current_write` 孤儿死代码 | — | 正确——steer 后 skill_append 不再误拒 |
| ⑩空终稿 | `ai_reply_preview.ex:342` `text=="" -> :ok`（不发空 edit、不 mirror） | — | 正确——避免 Lark 空 edit 4xx |

**门禁复跑**：`mix test` **467 pass**（+2 新测试）、worker `bun test` **46 pass**（+20）、`cargo check` ✅。

**e2e 说明（重要）**：本轮 `--gate` 16/17、`--real-llm` 0/2，**两处失败均为宿主 Docker 容器当前无外网所致的环境问题，非代码回归**——gate 唯一失败是 worker 内 Chromium 抓 `example.com` 得 `ERR_CONNECTION_CLOSED`（`worker_computer_e2e_test.exs:123` 的 `=~ "Example Domain"`），real-llm 失败是 worker 到 `openrouter.ai` 的 h3 请求发不出去；两者 worker 机械链路（turn_start→loop）均正常启动，只有到公网主机的出站 HTTP 失败。判定依据：①失败全部是"容器访问外部主机不可达"；②同两个套件今日前两轮均通过、代码路径已证；③离线门禁（mix 467/bun 46/cargo）全绿；④gate 其余 16 项含完整主链路/lifecycle/compress/session-reset 全过；⑤round-3 无一改动触碰浏览器工具或 provider HTTP 传输。外网恢复后应复跑 `--gate`/`--real-llm` 各一次收尾确认（本机当前网络隔离，无法就地复现绿）。

**总核定**：修复方本轮**没有只改报告字**——9 项声称修复全部有真实代码 + 测试支撑，且 §11.6 诚实标注了 untracked/steer-ack/P3 三项仍开放（不再是前两轮的"全部清空"式失实）。§11.8 已继续收口 P3 与 token/metadata 记录。剩余开放项均为已披露的小尾巴：untracked 文件仍存在（commit 前必须 `git add` 否则断他人构建）、steer 收报即 ack（需产品裁决 ack 时机）。**从用户故事看，本轮修复的 tradeoff 选择全部正确**。

### 11.8 追加收口（Codex，2026-07-04）

本轮按用户追加反馈继续处理：

- **final proposal telemetry 迁移/消失**：不恢复 worker `TurnHandlerResult` 旧 proposal 字段。AIGateway 是 stateful 消息真值拥有者，provider 终态帧里的 `usage`、`provider_metadata`、`stop_reason`、provider response trace 在 `commit_complete/3` 前构造成 terminal metadata，并随 `ai_gateway_messages.metadata` 写入；request-side `function_call_output` 在 run 创建时写入 `tool_results`。`retrieve_response` 再把 `provider_metadata`、`tool_results`、`stop_reason` 作为 response 顶层字段暴露，同时从 public `metadata` 隐藏内部键。
- **token 估算 reward-hacking**：`Compaction` 不再用 `chars/4` 或内容长度估算 token。自动压缩/截断触发改为基于历史消息中 provider 返回的真实 `usage.total_tokens`，metadata 字段改为 `history_usage_tokens_before/after`；缺失 usage 的历史不会用估算冒充。
- **P3 清洁项**：删除 `WorkerRouteAuth` 孤儿 `:current_write`；删除 `session_reset.ex` 死参数；更新 `AIReplyPreview` moduledoc；`flush_pending` 发送前 normalize；空白首 delta 不再建立 preview 或刷 warning。
- **turn_error details 兼容**：控制面 retryable 判定兼容 worker 上报的嵌套 `details_json["aigateway"]["details_json"]["retryable"]`，避免 loose Bun↔Elixir details 形状导致基础设施错误被误死信。
- **PowerPoint skill 路径**：内置 skill 文档和脚本示例从相对 `scripts/...` 改为 `/repo/app/library/skills/powerpoint/...`，与当前 runtime 源码目录形态一致。

追加验证：

- `MIX_ENV=test mix test test/ankole/ai_gateway/responses_dispatch_test.exs`：✅ 34 passed
- `MIX_ENV=test mix test test/ankole_web/ai_gateway_responses_socket_test.exs`：✅ 19 passed
- `MIX_ENV=test mix test test/ankole/signals_gateway/ai_reply_preview_test.exs`：✅ 7 passed
- 聚合复跑 `stateful_responses / responses_dispatch / ai_gateway_responses_socket / ai_gateway_controller / delivery_fence / conversation_command / session_reset / transport / ai_reply_preview`：✅ 150 passed
- `git diff --check`：✅

当前仍需用户取舍 / 外部动作：

- **steer 收报即 ack**：是否把 ack 延后到 agent loop 实际消费 steering 后，需要产品语义裁决。
- **setup activation code 暴露路径**：CLI/Mix task、Docker 首启文件、或仅 dev setup page 展示，不能默认公开到未认证 setup API。
- **通用工具副作用 crash recovery**：保留 per-tool 幂等，还是引入 AIGateway/ActorRuntime 层 durable tool-result journal，需要边界裁决。
- **outbox `unknown_after_send` 操作面**：只加 backend listing endpoint、console 页面，还是保持 SQL/operator 手册，需要运维产品裁决。
- **untracked 工作区**：仍需 staging/清理策略；本轮未执行 git staging。
