---
title: 成本管理
description: 调控 Ankole 模型开销的七项核心配置：模型档案分档、推理强度、网页工具开关、单回合预算、Workflow 并发上限、后台任务重试及周期配额。
section: Guides
order: 314
---

Ankole 运行成本的大头来自上游大模型的 Token 消耗，而这部分开销完全可由控制面中几项明确的配置开关精准调控，绝非一笔失控的黑盒账单。本页逐一梳理这七项控费手段，讲清每一项背后的省钱逻辑与调优先后顺序——所有手段均对应控制台中真实存在的配置项，绝不靠“让大家少用 Agent”来省钱。

先抓住最核心的账单公式：总成本完全取决于**调用了哪个档位的模型、调用了多少次、以及每次跑了多少轮**。其中，模型档案决定选哪个模型，Agent 循环预算约束单回合内的迭代轮数，Workflow 与后台任务上限则管住并发扇出规模与异常重试次数。账单偏高时，只需先查清消耗大头落在哪一环，再去拧对应的那个旋钮即可。

## 杠杆 1：model profile 档位

模型档案（Model Profile）在 **Console → Model Profiles** 中通过三层稀疏继承链（`Site -> Pod -> Agent/System`）解析。每个 Agent 提供八个内置槽位（五个语言模型槽位，外加 `web_search`、`web_fetch` 与 `image_generate`）；站点、Pod 与内置 `system` 主体（`ankole_brain`、`system`）则在此基础上增加 `rerank`、`decision`、`speech`、`transcription`、`ocr`、`video` 与 `music` 七个槽位。未单独覆盖的槽位自动继承 Pod 与站点默认值，并支持 `coding -> heavy -> primary` 与 `light -> primary` 跨槽位回退。

| 档案槽位 | 触发场景 | 控费要点 |
|---|---|---|
| `primary` | 日常主推理模型，承接绝大多数常规对话回合 | 占比最高的核心开销项 |
| `light` | 高频、低风险的轻量处理路径（未配置时回退至 `primary`） | 务必绑定真正低成本的轻量模型，避免批量处理按主力单价计费 |
| `heavy` | 高难度综合分析与 Dreaming 复盘 | 单价昂贵；只要 `primary` 选型得当，平时极少动用 |
| 后台 Agent 任务（内部键名 `coding`） | 每一个持久化后台 Agent 任务（按 `coding -> heavy -> primary` 回退） | 决定长时异步任务使用哪个 Provider 与模型 |
| `vision_fallback` | 当 `primary` 模型不支持视觉输入时的识图回退 | 仅在该 Agent 确实需要看图时才配置 |
| `web_search`、`web_fetch` | 公网网页搜索与正文抓取工具 | 见下文“杠杆 3” |
| `image_generate` | 图像生成工具 | 按张计费较高；仅在确有生图需求时绑定 |
| `rerank`（Site / Pod / `system`） | Brain 召回重排与 `/rerank` 默认路由 | 绑定响应快、单价低的专用 Rerank 模型 |
| `decision`（Site / Pod / `system`） | `/decisions` 带概率的作答 | 绑定决策模型；留空时由 `light` 模型作答 |
| `speech`（Site / Pod / `system`） | `/audio/speech` 语音合成 | 绑定语音合成模型；留空时语音合成请求会失败 |
| `transcription`（Site / Pod / `system`） | `/audio/transcriptions` 语音转写 | 绑定语音转写模型；留空时转写请求会失败 |
| `ocr`（Site / Pod / `system`） | `/ocr` 把 PDF 和图片识别为 Markdown | 需要识别 PDF 时绑定 OCR 模型；留空时由语言模型识别，只能读图片。绑定后，Pod 还会把新上传的 PDF 中的扫描页自动送去识别，服务商按页收费 |
| `video`（Site / Pod / `system`） | `/videos` 生成视频 | 绑定视频模型；留空时视频请求会失败。服务商按每次生成收费 |
| `music`（Site / Pod / `system`） | `/audio/music` 生成音乐 | 绑定音乐模型；留空时音乐请求会失败。服务商按每次生成收费 |

企业大脑维护与 Pod Applet 调用分别按各自的执行主体归属：

- **`ankole_brain`**：承载企业大脑（Company Brain）的全部模型调用并将用量记入 `ankole_brain` 名下——其中 `light`（回退 `primary`）用于从对话与文档 Source 中抽取事实，`heavy`（回退 `primary`）用于离线 Dreaming 归纳与技能教训复审，`web_fetch` 用于抓取网页 URL Source 正文，`rerank` 用于知识召回重排，同时从 [AppConfigure](../app-configuration/) 读取站点级的 `brain.embedding_model`。若希望将后台知识治理与前台对话预算解耦，可直接在 **Console → Model Profiles** 中单独覆盖 `ankole_brain` 的各档槽位；管理员也可在 **Brain → 健康**页面核查各档案就绪状态，详见 [Brain](../brain/)。
- **Pod Applet `ctx.ai`**：普通调用以当前调用方执行，管理能力以 Applet 所有者执行。AIGateway 解析该主体适用的模型档案并记录使用量；Applet 来源的调用不计入 Agent Token 配额窗口。

在模型分档上，有两条立竿见影的省钱铁律：

- **在站点或 Pod 层给 `light` 配一款便宜好用的小模型**：`light` 未配置时会回退至 `primary`，且同时承接高频辅助调用与 `ankole_brain` 的日常事实抽取；在默认层绑好低成本模型，所有继承默认值的 Agent 与企业大脑都会同步受益。
- **`primary` 默认够用即可，不必盲目拉满顶配**：很多让人觉得“烧钱”的 Agent，往往只是因为在 `primary` 槽位绑了远超日常任务难度的重型模型。建议先从性价比均衡的主力模型起步，仅为少数回答质量确实吃紧的专家岗位单独上调 `primary` 或 `heavy`。

修改 Agent 覆盖项前，先检查从 Site 与 Pod 继承后的有效档案。有效 `vision_fallback` 档案为空时，才没有对应的图像输入回退能力。图像生成的**由模型的 Provider 执行**开启时，使用主提供商的原生能力，专用档案不参与调用；关闭该开关才使用 `image_generate`。后台 Agent 任务（`coding`）留空时则会沿 `heavy -> primary` 自动回退执行；当希望长时编码或调研任务改走专用编码模型或订阅池时，再单独配置 `coding` 槽位即可。

## 杠杆 2：reasoning effort

对于支持调节思考深度（Codex Reasoning Effort）的 Provider，`model_reasoning_effort` 提供了从浅到深共六档精细调节：`minimal | low | medium | high | xhigh | max`（默认值为 `high`）。Console 只列出所选模型支持的档位。档位越低，响应越快、推理 Token 消耗越少；档位越高，面对复杂难题时推演越周密，但开销也成倍增加。

这是比直接降级换模型更平滑的控费旋钮：如果一个负责常规问答的 Agent 把 `primary` 挂在 `high` 档，往往白白多烧了大量内部思考 Token，对最终回复质量却毫无肉眼可见的提升。建议将日常型 Agent 的 `primary` 推理强度调至 `medium` 等匹配实际难度的档位，只为少数真正承担高难度综合研判的专家型 Agent 保留高档位，切忌全员一刀切拉高。

## 杠杆 3：web 工具，按需

`web_search` 与 `web_fetch` 是两个按调用次数计费的独立档案槽位，可从两方面收敛开销：

- **先确认搜索执行路径**：网页搜索默认开启**由模型的 Provider 执行**。关闭该开关才使用专用 `web_search` 档案；解绑档案本身不会禁用原生搜索。通过 Agent 的任务指令减少不必要的调用。
- **已知确切网址时优先走 `web_fetch` 而非 `web_search`**：直接抓取已知 URL 只产生一次确定调用；而先搜再看往往意味着一次搜索调用外加模型随后自主发起的好几次网页抓取。

顺带一提，租户级配置键 `agent_workers.rendered_fetch_idle_ttl_ms` 控制的是动态渲染版 `web_fetch` 浏览器边车实例在空闲多久后自动回收释放——它管的是容器计算内存回收，并非网页响应缓存时长。

## 杠杆 4：agent 循环预算与冷唤醒轮转

租户级（`scope: :tenant`）[AppConfigure](../app-configuration/) 配置键既为单个对话回合划定开销硬顶，也防止长寿会话在上游提示词缓存失效后反复按全量无缓存输入重计费：

| 配置键 | 约束目标 |
|---|---|
| `ai_agent.max_iterations` | 单个 Agent 回合内允许执行的模型迭代最大轮数 |
| `ai_agent.max_output_tokens` | 单次模型响应允许生成的最大输出 Token 数 |
| `ai_agent.inactivity_timeout_ms` | 上游无响应空闲多久后终止回收当前回合 |
| `sessions.wake_recycle` | 冷唤醒会话轮转策略（`min_cold_gap_seconds`: `3600`、`min_context_tokens`: `128000`、`im_max_idle_seconds`: `259200`） |

其中 `max_iterations` 能有效防止模型陷入工具调用死循环——避免原本调两次工具就能结案的任务反复拉锯空转；`max_output_tokens` 则约束单次长篇大论的体积。这三项 `ai_agent.*` 配置均作为租户级默认值生效（未覆盖时继承站点默认值），建议结合本租户的日常任务复杂度合理设定；当某个复杂回合触及迭代上限时，Agent 会基于手头已拿到的信息直接收敛给出最终答复。

一旦上游 Provider 的提示词缓存（Prompt Cache）过期，直接续接超长历史模型线程会在下一回合按全量无缓存输入重新计费。`sessions.wake_recycle` 专门消除这类冷缓存重计费损耗：当某个 Session 空闲达到 `min_cold_gap_seconds`（默认 `1` 小时）且上下文规模达到 `min_context_tokens`（默认 `128,000` Token），或在外部 IM 渠道空闲超过 `im_max_idle_seconds`（默认 `72` 小时）后再次唤醒时，Ankole 会将底层 AIGateway 模型会话平滑轮转到携带精炼 `<wake-briefing>` 摘要的新分支上，同时完整保留群聊或私聊的公开消息记录。

## 杠杆 5：Workflow fanout 与任务尝试

在 Workflow 编排中，每一次 `agent()` 子调用的每一次尝试都是一轮完整的模型推理，且单个子调用在失败时最多可尝试 3 次——这意味着哪怕用户在主对话里只发了一句指令，一旦触发大规模并行扇出（fan-out），依然会成倍放大模型与网页工具的消耗总量。

| `AppConfigure` 配置键 | 默认值 | 上限值 | 控制范围 |
|---|---:|---:|---|
| `workflow.max_concurrency_per_run` | `8` | `32` | 单次 Workflow 运行同时并发执行的子任务数 |
| `workflow.max_running_per_agent` | `8` | `64` | 单个 Agent 名下所有活跃 Workflow 合计正在运行的子任务总数 |
| `workflow.max_agent_calls_per_run` | `32` | `1,024` | 单次 Workflow 运行允许发起的子 Agent 调用总次数 |

请注意：调低并发度只会拉长整批任务跑完的耗时，**并不会减少子调用总次数**。控费的关键在于按有限输入集合收紧 `max_agent_calls_per_run`，并仅申请实际所需的并发度。单次 Workflow 运行时可在参数中申请更低的 `concurrency` 与 `max_agent_calls`，但无法绕过跨运行全局生效的 `max_running_per_agent`，也无法突破任何租户级 `AppConfigure` 上限。

此外，Workflow 层面不设横跨整批子任务的总 Token 或总金额封顶，但其中的每个子任务依然受常规回合的迭代轮数、输出上限与空闲超时约束。编写或触发 Workflow 时，应尽量保持每个子任务提示词聚焦精炼、要求返回紧凑的结构化 JSON、显式妥善处理 `null` 失败项；若待处理集合过大，建议分批拆成多次运行。详见 [Workflow](../workflows/)。

## 杠杆 6：后台任务重试与槽位上限

后台 Agent 任务在遇到瞬时异常重试时同样会消耗 Token，系统的内置上限正是防止无限烧钱的安全阀：

| 限制项 | 设定值 | 控费效果 |
|---|---|---|
| `max_execution_attempts` | `5` | 累计 5 次执行失败后转入 `failed` |
| `max_consecutive_turn_failures` | `5` | 连续 5 个回合失败后立即终止放弃 |
| `max_running_per_agent` | `3`（默认） | 单个 Agent 允许同时运行的后台任务数上限，支持按租户通过 `background_agent_jobs.max_running_per_agent`（`1..64`）调整 |
| 重试退避延迟 | 约 `30` 秒 | 相邻两次重试之间的最短冷却间隔 |

临时执行错误可重试，累计 5 次执行失败后终止；配置错误则立即失败。开始或恢复一次执行所需的 claim 单独计数，总上限为 25 次。凭据池背压不计入执行失败预算，claim 次数也不能直接换算为完整模型执行次数或 Token 开销。还须留意并发上限：一个跑满 3 个并发后台任务的 Agent，相当于同时全速运转着 3 条独立的大模型长循环。如果业务上并不急于三线并进，不妨将该上限调小，或在 Agent 长期设定中约定“同一时间只专心推进一项后台调研”，实际开销会平稳得多。

## 杠杆 7：按 Agent 的 token 额度

前面六项手段管的是“每一轮怎么省着花”，而第 7 项 **Token 额度**则是为单个 Agent 设定周期总量封顶：它限制该 Agent 在一个循环统计周期内最多允许消耗多少输入与输出 Token；一旦触及红线，AIGateway 会直接拦截拒绝该 Agent 的后续模型调用，直至当前周期结束。

管理员可在 Agent 编辑页直接配置周期天数、起始时间与 Token 上限，面板会实时展示已用比例与本周期截止时间。配额耗尽期间，发给该 Agent 的聊天消息会收到一条自动回复（写明已用 Token、总额度及恢复时间），而该 Agent 名下的后台任务则会直接报错终止、不会挂起干等。若遇上合理的业务高峰确需立即放行，点击**重置周期**即可当场开启新周期恢复服务。

请把这项配额视作**异常止损熔断器**，而非精细的速度调节器：接近上限时它不会让 Agent 自动降速省流，且触发熔断前的最后一次模型调用本身可能会因当次输出而小幅越过上限。建议先结合下文的用量排查摸清正常峰值，按“最繁忙正常周用量 + 适度安全余量”来设定额度。具体统计口径详见 [Agent](../agents/)。

## 花费到底在哪

动手改配置之前，请先通过以下四个入口定位究竟是哪个 Agent、哪类会话、哪次 Workflow 或哪个后台任务拉高了用量：

- **查 `GET /api/v2/ai-gateway/conversations`**：查看近期各回合的模型调用明细——具体命中了哪个模型档案、调了多少次、走了哪个上游 Provider。这是判断钱究竟花在了 `primary`（日常量大）、`heavy`（少量重型调用）还是 `web_search`（高频零碎搜索）上最直接的办法。
- **在对话中让主 Agent 核查近期 Workflow**：通过子任务计数即可看清并发扇出规模与失败重试比例（注：Console 不设单独的 Workflow 账单页或按美元折算的单次汇总）。
- **查 `GET /api/v2/background-agent-jobs`**：`attempts` 表示 claim 次数；实际 Token 开销须结合已记录的模型调用核实。
- **聚合控制面结构化日志**：每条上游 Provider 请求日志均带有规范的事件名与维度字段，可在外部日志分析平台中按 Provider 与 Agent 维度汇总排行。

排查清楚后你会发现，真正的解法从来不是一刀切让大家少用 Agent，而是精准修正某个与实际岗位需求错配的配置参数。

## 一个完整示例

假设某实例的周账单突然翻了一倍。排查 `conversations` 接口发现，`primary` 主模型调用量十分平稳，反倒是 `web_search` 搜索调用暴涨了十倍——顺藤摸瓜发现，原来是一个开启了群聊 `may_intervene`（可主动介入）模式的团队群助理，开始对群里的每一句日常闲聊都跑去公网搜索求证一番。面对这种情况，正确的改法既不是去砍全局 Token 配额，也不是停用助理，而是直接在它的角色设定或频道常驻指令中补上一句明确纪律：“仅在有人明确询问外部事实信息时才调用网页搜索。”账单只是表象结果，Agent 的行为准则才是真正的源头开关。

这正是成本治理中最常见的一条规律：**许多看似棘手的成本飙升，拆穿了其实是 Agent 行为边界没立清楚；此时最管用的旋钮往往是角色规范（AGENTS.md）或信号路由策略，而非生硬的额度封顶。**

## 成本管理不是什么

Ankole 内置的成本管理并非实时美元计费大盘——控制面本身不维护各家上游厂商随行就市的美元价目表，所有调控手段约束的都是**调用次数、迭代轮数与 Token 数量**，最终美元账单等于这些实际用量乘以上游厂商费率。同时，再多上限开关也替代不了先看一眼调用明细：只有先看清是哪个环节配置失当，再去拧对应的旋钮才能药到病除。

## 下一步

- 为 Agent 配置并优化各档位模型，请参阅 [Agent](../agents/#配置模型)。
- 查阅单回合循环预算等运行时配置键（`ai_agent.*` 等），请参阅 [系统配置](../app-configuration/)。
- 查阅模型会话与后台任务的查询接口，请参阅 [Console API 参考](../console-api/)。
- 了解有界子 Agent 扇出编排与并发限制，请参阅 [Workflow](../workflows/)。
- 了解后台任务的并发槽位与重试规则，请参阅 [后台 Agent 任务](../background-jobs/)。
