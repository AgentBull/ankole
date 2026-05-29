# BullX 架构审视：三问

通读 `lib/`、`plugins/`、`docs/` 与 `native/` 后，对三个问题给出有依据、不骑墙的判断。

## 0. 规模基线（事实）

`*.ex` 行数分布（`lib/` 合计 49,808 行）：

| 子系统 | 行数 | 文件 | 占 lib |
| --- | ---: | ---: | ---: |
| `lib/bullx/llm` | 22,695 | 61 | 45.6% |
| `lib/bullx/ai_agent` | 10,509 | 38 | 21.1% |
| `lib/bullx/principals` | 1,954 | 10 | 3.9% |
| `lib/bullx/setup` | 1,540 | 6 | 3.1% |
| `lib/bullx/config` | 1,199 | 22 | 2.4% |
| `lib/bullx/im_gateway` | 1,014 | 9 | 2.0% |
| `lib/bullx/mail_box` | 965 | 9 | 1.9% |
| `lib/bullx/authz` | 705 | 6 | 1.4% |
| `lib/bullx/i18n` | 686 | 4 | 1.4% |
| `lib/bullx/plugins` | 633 | 7 | 1.3% |
| `lib/bullx/cache` | 252 | 1 | 0.5% |

插件层 10,890 行：Feishu 4,471 / Discord 2,817 / Telegram 2,400 / 国产 LLM provider 1,202。
另有 webui（已是 TypeScript）约 1 万行手写 + Rust NIF 约 2,500 行。

LLM provider 实现单独占 11,487 行（`lib/bullx/llm/providers/*.ex`，12 家），约为整个 LLM 层的一半：

```
google 2780  anthropic 1484  azure 1345  amazon_bedrock 1341
xai 1275     google_vertex 1017  openai 999  zai 529
mistral 252  openrouter 307  deepseek 95  vllm 63
```

**一个贯穿全文的事实**：LLM(45.6%) + AIAgent(21.1%) ≈ lib 的三分之二；而本项目真正原创、无现成轮子的"投递骨干"——MailBox(965) + IMGateway(1,014)——合计仅约 2,000 行，占 4%。下面三问都要回到这个分布。

---

## 一、换用 pi-agent + TypeScript 会更简单吗？

**结论：不会。** 只有 agent-loop 这一个叶子节点会更简单，而它在总盘子里占比很小；其余部分要么持平、要么明显更糟。

pi 的价值主张是"4 个工具 + <1000 token system prompt + pi-ai 统一各家 LLM"。把它逐层套到 BullX 的实际分布上：

- **LLM 层（46%，最大头）：持平甚至更糟。** pi-ai 之于 TS，等价于 `req_llm` 之于 Elixir，BullX 已经站在 `req_llm` 上（`lib/bullx/llm/req_client.ex` 直接转发 `ReqLLM.generate_text/stream_text`，没有重造）。换语言不会让这 22,695 行蒸发——它们大头是 provider 适配：`google 2780`、`anthropic 1484`、`azure 1345`、`amazon_bedrock 1341`、`google_vertex 1017` 这些是 Bedrock/Vertex/Azure/国产模型的原生实现。pi-ai 在这些长尾 provider 上的覆盖未必比 `req_llm` 好，换过去这 1 万多行得照样重写一遍，毫无节省。

- **Agent 核心（21%）：唯一会更简单的地方，但只是叶子。** pi-agent-core 的循环确实比 `BullX.AIAgent.Runner` 轻。但 BullX 这一层的体量不在"循环"上，而在 AgentOS 的状态机：写进数据库的 generation lease + 心跳（进程重启后可恢复）、`conversation_messages` 的消息树（`parent_id` + CAS 追加）、压缩 overlay（原始消息保留、摘要叠加）、ambient 批处理、消息修订（edit/recall/delete 作为对话版本控制）、工具执行处的 ACL。这些是"OS"的部分，pi 没有；换语言不会让它们消失，只会让你在一个更弱的运行时上重建它们。

- **IM 适配器（插件 ~1 万行）：TS 有更成熟的库，但要赔上 OTP 的隔离。** discord.js / grammY 的确比手写 Discord/Telegram 客户端省事。但 BullX 每个 channel source 是一棵独立监督树（`source_supervisor.ex` 按 source 拉起 `Channel.child_spec`），单个源的连接崩溃不波及其它源。换成 TS 单进程事件循环，这种"按源故障隔离 + 背压"要自己用 worker/队列重搭，得不偿失。

- **投递骨干（MailBox + IMGateway，~2k，4%）：BEAM 的主场，pi 无对应物。** `FOR UPDATE SKIP LOCKED` 租约领取、GenServer dispatcher、CloudEvents 路由规则、按 agent 的 SHA-256 去重——这是一个 Postgres 支撑的并发投递队列。这恰恰是 Elixir/OTP 最擅长、而单进程 TS agent 最不擅长的形态。

- **平台层（config/principals/authz/i18n/setup）：两种语言都得自己写，无差别。** 这些没有现成轮子，换语言不省。

- **未实现路线只会让天平更偏向 OTP。** `docs/Architecture.md` 列的未实现项——Workflow 运行时、Work 记录、SubAgent、Brain 记忆/自我演化、非 IM Gateway、多租户——整体上比当前更"操作系统化"：长生命周期、有状态、需要监督树与背压、需要可恢复。这些正是 BEAM 的强项，是 pi 单进程模型的弱项。题目要求"架构上支持未来实现"，这一条本身就把答案推向"不要换"。

**唯一成立的 TS 理由**：前后端统一语言与类型（webui 已是 TS）。这是开发体验收益，不是架构收益，且不足以抵消上面四层的损失。

**真正该学的不是换语言，是搬哲学**：把 pi 的极简主义搬进 Elixir——更克制的工具集、更短的 system prompt、把 `req_llm` 当基底而非起点（见第二问）。

---

## 二、100% 功能不变下，第一性原理 / 奥卡姆的优化空间

**结论：系统整体已经相当精简，多数复杂度是本征的；真正值钱的杠杆只有一个，其余是次要项。**

**#1（最高 ROI）——LLM 层占 lib 的 46%，是唯一的大杠杆：把 `req_llm` 当基底，只携带"差量"代码。**
`openrouter.ex`（307 行）自述是"覆盖 `req_llm` 内置的 OpenRouter provider"。这意味着部分 provider 是在**影子替换** `req_llm` 已有的实现，只为加上 reasoning 翻译、归因 header、结构化输出等特性。第一性原理的问法是：每个 provider 的覆盖，到底是"`req_llm` 没有、必须自带"（如 Bedrock/Vertex/Azure/国产模型的原生实现，几乎肯定要留），还是"`req_llm` 已覆盖、只为加特性而整体 fork"（这类应收敛成最小差量扩展，而非平行重写）。建议逐 provider 审计 override 边界——这是唯一能动到万行级别的优化，方向明确：**差量扩展，不要分叉**。

**#2（次要）——近空壳的 OpenAI 兼容 provider 可降为注册数据。**
`vllm.ex` 仅 63 行、`deepseek.ex` 95 行，本质是 `use ReqLLM.Provider.Defaults` + base_url + 模型列表。这类纯兼容端点可以做成"配置数据行"（base_url + 模型清单）而非独立模块。收益有限（百行级），且模块形态保留了未来挂 override 的位置，故列为低优先。

**#3（适度，已满足 rule-of-three）——抽取 Telegram/Discord 重复的 source 监督与 outbound 派发。**
两个适配器各有结构高度相似的 `source_supervisor.ex` / `source_runtime.ex` / `outbound.ex` / `streamer.ex`。重复已达三例门槛（连同 Feishu 的等价物），可上提为共享适配器件（见第三问）。注意：这是"度量后"的抽取，不是预防性抽象。

**明确不动的——是设计选择，不是缺陷，不应以"奥卡姆"为名重litigate：**
- `ai_agent/steering.ex` 的 ETS 表（按 lease_id 索引）：moduledoc 已说明这是流向"在途 lease"的控制面信号，runner 在工具边界消费并随下一条工具结果持久化，重启恢复不依赖进程内存。这是刻意的控制面/数据面分离。
- ambient 批处理的 Redis Lua 脚本：批窗口的原子入队需要它。
- ambient 识别处的 LLM 调用：`may_intervene` 模式下的介入判定本就是模型决策。

`AGENTS.md` 的纪律——"少量重复优于过早抽象""不要重litigate已定的取舍"——在这一问里是约束而非装饰：除了 #1 这个真杠杆，本系统没有多少"为简化而简化"的空间。

---

## 三、逐模块开发后的整体 review

逐模块开发的典型痕迹是**局部各自正确、跨模块归属/切分不一致**。找到三处，均非功能缺陷：

**#1 Redis 归属错位（最值得修）。**
裸 `Redix` 进程在 `BullX.MailBox.StreamingOutput.Redis` 下命名与启动，却被 AIAgent 的 ambient 批处理直接借用（`lib/bullx/ai_agent/ambient_batch.ex:9` `alias BullX.MailBox.StreamingOutput.Redis`）。一个以"MailBox 流式输出"自命名的进程，成了 AIAgent 的依赖——跨子系统耦合穿过了一个按单一属主命名的模块。应上提为中性的 `BullX.Redis`，两个子系统平等依赖。

**#2 适配器分解漂移（结构问题，非功能问题）。**
三个适配器满足同一逻辑契约（attention 判定、命令归一化、按源监督、流式输出），但**切分方式因开发时序不同而漂移**：
- Telegram/Discord 把 attention 拆进 `attention_policy.ex`、命令拆进 `command_normalizer.ex`、运行态拆进 `source_runtime.ex`、流式拆进 `streamer.ex`；
- Feishu 把 attention 与命令解析内联进 `event_mapper.ex`（`attention_decision`、`parse_command_text`），`source_supervisor.ex` 直接映射 `Feishu.Channel.child_spec`，流式用 `streaming_card.ex`（卡片更新，与前两者的 chunk 追加是合理的 provider 差异）。

行为等价，只是模块边界各画各的。这正是"逐模块开发"的签名。一个共享适配器骨架（behaviour + attention/命令/监督的公共 helper）能把切分收敛一致，新增 provider 时也有模板。**注意**：`streamer` vs `streaming_card` 是正当的 provider 差异，不要强行统一。

**#3 Setup 是每个子系统的"第三投影"。**
`lib/bullx/setup`（1,540 行）让每个子系统被表达三次：facade API → `Setup.X` 包装 → controller + React 页面（×5 步）。这是向导本身决定的复用形态，不是错误，但它意味着任何子系统接口变更要在三处同步——值得在文档里点明这条放大关系。

**正面对照（说明这套代码有能力干净复用）：**
- `BullX.Ext`（Rust NIF）集中了 UUIDv7 / AEAD 加密 / Argon2 / CEL / 规则匹配——加密能力没有散落各处。
- CEL 求值被 AuthZ（权限授予）与 MailBox（投递规则）共享，是两个业务面、一套引擎。

Redis 与适配器件应当照 `BullX.Ext` / CEL 这个已经成立的模式收敛：能力中性化、属主明确、跨子系统平等依赖。

---

## 一句话总结

不要换语言——BullX 的体量与未实现路线都坐实在 OTP/Postgres 的主场上，pi 的价值是**哲学**（极简工具集、把 `req_llm` 当基底）而非**载体**；100% 功能不变下唯一的大杠杆是占 lib 近半的 LLM 层 provider override 收敛为差量扩展，其余是适配器件抽取与 Redis 归属中性化这类逐模块开发遗留的整理工作。
