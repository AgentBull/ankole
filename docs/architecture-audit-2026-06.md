# BullX-Agent 全量架构审计报告

> 审计时间：2026-06-07
> 审计对象：`/Users/ding/Projects/bullx-agent` 整个仓库
> 方法：逐文件通读全部**后端 TypeScript 业务代码**（`app/src` 非测试约 23k 行，含审计后期出现的 `llm-providers`）+ `plugin/lark-adapter`（1845 行）+ `packages/sdk`（657 行）+ 三份设计文档；`packages/native-addons`（Rust NAPI）读了模块结构与对外接口；`app/webui`（~8200 行 React/shadcn）做结构勘察与关键文件抽样。分析方式是「业务意图 Why（设计文档）对比实际结构 How（代码）」，按**比例原则**评估结构复杂度是否与本质业务复杂度成正比。
> 结论由你决定取舍——部分判断可能是假阳性，已在每条标注置信度。

---

## 0. 总体结论

先把话说在前面：**这套代码库整体质量很高，BullX 自己写的业务代码（ai-agent / external-gateway 运行时 / principals / 配置 / 插件 / 启动骨架）的结构复杂度，与其本质业务复杂度基本成正比。** 设计文档里那种刻意的复杂度控制（`ai-agent-pi-...md` 的「Kill List / 控制复杂度」章节、`external-gateway.md` 的「保持足够小、可由三张事实表解释」）**绝大部分忠实地落到了代码里**——甚至有的地方实现比设计还简单（见 §6.1）。

所以这份报告不是「这个项目很乱」。它只有 **一个真正算得上「结构性脱节」的大问题**，外加若干轻量重复和前置脚手架。我把它们按影响排序，并单独列出「我特意复核、但判定不算问题」的部分，以免你怀疑我漏看或误判。

> **审计快照说明（重要）**：审计期间**工作树在被主动开发**——有确凿证据：`ai-agent/config.ts` 在我两次查看之间从 183 行变成了 ~398 行；`console/service.ts` 长出了 `llmProfile`；一个全新的 `llm-providers` 模块（DB provider 注册表 + 502 行 service + console/setup 路由）在我初次扫描后才出现。我已回头重新同步了「模型配置 / LLM provider」这一片区域并确认它是**一次有意的迁移**（详见 §7 末），不是缺陷。但请注意两点：(1) 本报告是某个时间点的快照，模型配置那一片可能已再变；(2) 报告里的 `file:line` 是快照行号，可能有小幅漂移——**结论本身不依赖具体行号**，依赖的是结构关系（谁消费谁、是否重复），这些已逐一核验。后端业务代码我已全部通读；`app/webui`（~8200 行标准 React/shadcn 前端）做的是结构勘察 + 抽样，未逐行精读——对「业务架构」审计这是有意的范围取舍。

| 编号 | 严重度 | 一句话 | 置信度 |
|---|---|---|---|
| **F1** | 🔴 高 | `external-gateway/core` 的富内容渲染层（~4000 行，占后端 ~17%）是从一个多平台 chat SDK 整体移植来的，几乎完全没被使用 | 高 |
| F2 | 🟡 中 | `agents.metadata.external.adapters` 的解析在 console 和 external-gateway 各写了一遍 | 高 |
| F3 | 🟡 中 | JSON 清洗 helper（`toJsonValue`/`toJsonObject`）三处定义，其中两处几乎逐字相同 | 高 |
| F4 | 🟢 低 | `AiAgentRuntime` 自带一层未接线的 tool registry；core fork 携带一批 v1 不用的上游面 | 中 |
| F5 | 🟢 低 | 一批「空转 / 前置」小表面：`envelope.session.id`、`ambient` 的死分支、`run-registry` 未用方法、`login_subject`/`outbound_actor` 仅定义未写入 | 中 |
| F6 | 🟢 低 | `lark-adapter` 单文件 1845 行（chat+identity+connection 混在一起）；config 引擎 API 面偏大 | 低 |

---

## F1 —— External Gateway 富内容渲染层：~4000 行整体移植、基本未使用 🔴

### 现象

`app/src/external-gateway/core/` 下有一整套「跨平台富消息渲染」子系统：

| 文件 | 行数 | 内容 |
|---|---|---|
| `jsx-runtime.ts` | 867 | 一个自定义 JSX 运行时（`jsxImportSource: "chat"`），把 JSX/React element 转成 card element |
| `cards.ts` | 778 | Card / Button / Section / Field / Table / Actions / Image… builder + React element 转换 |
| `emoji.ts` | 573 | ~150 个 `WellKnownEmoji` 名 + Slack/Google-Chat 双格式映射 + singleton 注册表 |
| `markdown.ts` | 608 | 完整 mdast 解析/序列化、AST node builder、type guard、ASCII 表、`BaseFormatConverter` 基类 |
| `modals.ts` | 377 | Modal / Select / RadioSelect / ExternalSelect / TextInput（Slack Block Kit 概念） |
| `plan.ts` | 260 | 交互式任务 Plan |
| `streaming-markdown.ts` | 378 | 流式 markdown 渲染（表格缓冲） |
| `streaming-plan.ts` | 82 | 流式 Plan |
| `postable-object.ts` | 80 | PostableObject 协议 |
| **合计（孤岛）** | **~4003** | **= 非测试后端 23,157 行的约 17%** |

文件头自述出处非常清楚——`cards.ts`：「Card elements for **cross-platform** rich messaging: Slack: Block Kit, Teams: Adaptive Cards, Google Chat: Card v2」，`import ... from "chat"`。即这是从一个**面向 Slack/Teams/Google Chat 的多平台 chat SDK** 整树搬过来的。

### 证据：它几乎没被任何东西消费

我对 app + plugin（排除 core 内部互相引用、排除测试）逐符号 grep：

```
Modal            : 0      StreamingPlan            : 0      toCardElement   : 0
Plan             : 0      StreamingMarkdownRenderer: 0      toModalElement  : 0
markdownToPlainText:0     tableToAscii             : 0      walkAst         : 0
stringifyMarkdown: 0      BaseFormatConverter      : 0      isPostableObject: 0
convertEmojiPlaceholders:0  createEmoji:0  EmojiResolver:0  fromReactElement: 0
```

真正被「活路径」用到的，只有 `outbox.ts` 里这几处（[outbox.ts:6-7](app/src/external-gateway/outbox.ts)）：

- `parseMarkdown(text)` —— 把 outbound 文本解析成 mdast 存进投影列 `external_messages.formatted`；
- `isCardElement` / `cardToFallbackText`（→ `tableElementToAscii`）—— **防御性**地处理「万一 payload 是个 card 就降级成文本」，但 agent 从不产生 card。

也就是说：**这 ~4000 行里实际可达的不到几十行**，剩下的 JSX runtime、card/modal/plan builder、emoji 表、mdast builder/converter 全是孤岛——它们之间互相 import（`cards↔markdown↔modals↔jsx↔plan↔postable`），但孤岛之外没人 import，且**没有任何测试覆盖它们**。

### 证据：它与设计意图直接冲突，且唯一的真实 adapter 明确拒绝用它

1. `docs/design-docs/external-gateway.md` 把 gateway 定位成「**not an audit subsystem**、保持足够小、卡片只存 fallback visible text，provider-native 渲染归 adapter 拥有」。富 builder 层与这个「极简」定位相反。

2. 唯一的真实出站通道 `AiAgentRuntime` 只发纯文本 `{ operation: 'post', finalPayload: { text } }`（[runtime.ts:937-952](app/src/ai-agent/runtime.ts)），从不构造 card/modal/plan。

3. 唯一的真实 adapter `lark-adapter` **显式注释拒绝使用这套 core**（[index.ts:1539-1544](plugin/lark-adapter/src/index.ts)）：

   > "Plugin adapters should not depend on the app-local mdast serializer from External Gateway core. This small renderer intentionally covers the normalized facts this adapter emits itself."

   它自己写了极简的 `markdownAstFromText`（其实就是把整段文字塞进一个 paragraph）、`stringifySimpleMarkdownContent`、`larkEmojiMap`/`toLarkEmojiType`——完全不碰 core 的 markdown.ts / emoji.ts。而且它对 card 的处理是 `JSON.stringify(record.card)`（[index.ts:1342](plugin/lark-adapter/src/index.ts)），等于卡片**根本没真支持**。

4. 插件契约 `packages/sdk/src/plugins.ts` 里，card/modal/streaming **只作为 capability 字符串**出现，消息 payload 和 `renderFormatted(content: unknown)` 全是 `unknown`。也就是说**连插件边界都是不透明的**——未来第三方 adapter 也不会 import 这套 core（它们 import 的是 SDK）。所以它连「给插件用的共享渲染层」都不是。

### 为什么这算「本质复杂度膨胀」而不是「未来能力」

我知道你的原则是「暂时未用、但未来要用的代码不算死代码」。我专门为这条做了反向论证，请你判断：

- 它瞄准的是 **Slack / Teams / Google Chat**，而 BullX 的明确定位（README + `external-gateway-provider-limitations.md`）是 **Feishu/Lark**。这不是「BullX 规划中的未来能力」，而是「把别人的多平台 SDK 整棵树搬进来放着」。
- 你说过：*「使用了实现复杂的类库，并不会让我们自己的实现变得复杂」*——这句话的前提是**把它当依赖调用**。但这里是把那个库的**源码 vendored 进了自己的树**，于是它的全部表面积都变成了 BullX 自己的维护负担、type-check 负担、和阅读 `external-gateway/core` 时的认知摩擦。这恰好踩中你列的反模式：*「不要为虚构的未来拓展性编写任何冗余抽象」*。
- 判断「复杂」的标准你定得很准：是否影响整体架构的清晰与直观。一个新人打开 `external-gateway/core/`，会看到 9 个文件、~4000 行的富渲染体系，**完全无法从中看出「这个 gateway 其实只发纯文本」**。这就是结构性脱节——`How` 在尖叫「这是个多平台富消息系统」，`Why` 其实是「把一段文本发到飞书」。

### 建议（分级，你定）

- **最彻底**：删掉 `jsx-runtime / cards(只留 isCardElement+cardToFallbackText) / modals / plan / streaming-markdown / streaming-plan / postable-object / emoji`，`markdown.ts` 只保留 `parseMarkdown`（喂投影列用）。outbox 里的 card/divider 操作分支可保留（它本来就只做「透传 + 降级文本」，很薄）。预计净删 ~3500 行，`external-gateway/core` 立刻回归到「投影 + 输入窗口 + outbox + 弱可见流」这个设计文档描述的清爽形状。
- **折中**：把整套 builder 层抽成一个独立未启用的包（如 `packages/chat-rich-content`），从 `app/src` 里移走。等真的要做 Slack/Teams 多平台时再接。好处是 app 主树不再被它污染，认知摩擦消失；坏处是仍要维护它的编译。
- **保守**：什么都不删，但至少在 `external-gateway/core/README`（目前没有）里写明「以下文件是 v1 未接线的多平台渲染储备」，避免后人误以为它在生产路径上。

> 注：`visible-output-stream.ts`（弱可见流，键为 `{agentUid, sessionId, streamId}`）和 `normalizeBullXStream`（[stream.ts](app/src/external-gateway/core/stream.ts)）同属「v1 未接线的 streaming 特性」。设计文档明说 v1 不做可见 streaming，所以它们是**有计划的前置**，不在上面的删除建议内——只是顺带说明它们也还没接上。

---

## F2 —— `agents.metadata.external.adapters` 解析逻辑重复 🟡

同一份「agent 的 channel binding 元数据」结构，在两个地方各写了一套解析/校验：

- `external-gateway/metadata.ts` 的 `parseAgentExternalBindings`（[metadata.ts](app/src/external-gateway/metadata.ts)），产出 `AgentExternalBinding`，错误用 `AgentChatMetadataError`；
- `console/service.ts` 的 `readStoredChannelBindings` / `writeStoredChannelBindings`（[service.ts:407-452](app/src/console/service.ts)），产出 `StoredChannelBinding`，错误用 `ConsoleDomainError`。

两者都解析 `metadata.external.adapters`、都带 `?? metadata.chat`（legacy 兼容）回退、都做 name 去重校验。区别只是返回类型和抛错类型。这意味着：以后改 binding 结构（比如加个字段、或去掉 legacy `chat` 回退）要改两处，漏一处就行为漂移——这正是「读取侧 / 写入侧各一份 parser」的经典坑。

**建议**：把 binding 解析收敛到 `metadata.ts` 一处，console 复用它（需要时再在上面包一层把 `AgentChatMetadataError` 映射成 `ConsoleDomainError`）。顺带说一句：legacy `chat.adapters` 兼容分支在两处都有——这是个 greenfield v2，没有存量数据，这条兼容路径大概率可以直接删掉（两处一起删）。置信度：高。

---

## F3 —— JSON 清洗 helper 三处重复 🟡

`toJsonValue` / `toJsonObject` 在三个文件里各定义了一份：

- `external-gateway/handlers.ts`（[:577](app/src/external-gateway/handlers.ts)）
- `external-gateway/core/projection.ts`（[:412](app/src/external-gateway/core/projection.ts)）
- `ai-agent/json.ts`（[json.ts](app/src/ai-agent/json.ts)，较简版）

其中 handlers 和 projection 两份**几乎逐字相同**（都处理 `Date→ISO`、剥掉 function/bigint/symbol、剥掉 `ArrayBuffer`/`Blob`/TypedArray）。这类「把任意值安全落成 jsonb」的清洗逻辑是全仓库共性需求（`@/common/database` 的 `jsonbParam` 也在解决相邻问题）。

**建议**：抽一个 `common/json.ts`（或并入现有 `ai-agent/json.ts` 提升到 common），三处共用。这正是你提示的「不同模块共性功能值得抽 common」。置信度：高。

> 同类（更轻）观察：`plugins/config-json.ts` 提供的不可变 JSON path get/set/merge/clone 是另一套 JSON 工具；它被后端 console 和前端 console 共用（[webui console/main.tsx](app/webui/src/apps/console/main.tsx) 直接 import 了它），属于**良性复用**，不必动。只是说明「JSON 操作工具」在仓库里有点散，整合时可一并理顺。

---

## F4 —— AIAgentRuntime 自带未接线 tool registry；core fork 携带 v1 不用的上游面 🟢

### 4a. AiAgentRuntime 里的 tool registry 当前是纯脚手架

`AiAgentRuntime` 上有 `setTools` / `setActiveTools` / `getTools` / `getActiveTools` + `validateUniqueNames` / `validateToolNames` + 三个 passthrough hook（`transformGenerationContext` / `beforeToolCall` / `afterToolCall`）（[runtime.ts:96-149](app/src/ai-agent/runtime.ts)）。其中**写入侧 `setTools`/`setActiveTools` 没有任何调用者**，`getActiveTools()` 恒返回空数组，于是 `runGeneration` 里 tool 相关分支恒走 `undefined`。

这是 v1「纯文本、无 tools」下的前置脚手架。设计文档确实要求保留 pi core 的 tool 形状——**但那指的是保留 `core/` 里 vendored 的 tool 形状**；`AiAgentRuntime` 又在它之上叠了**第二层** tool 注册/校验，而底层 `Agent`（`core/agent.ts`）本来就持有 tools。这层 runtime 端的 registry 在 tools 真正落地前，是可以不写的（等接 tools 时再加，成本不高）。

### 4b. core fork 携带一批 BullX 不用的上游表面

`app/src/ai-agent/core/` 是 `@earendil-works/pi` 的 fork。按你「fork = 整树 cp + 最小改、删什么交给我定」的哲学，下面这些**不算我主张要删的死代码**，只是如实告诉你 fork 里目前 BullX 没走到的面，方便你将来精简时心里有数：

- `agentLoop` / `agentLoopContinue`（返回 EventStream 的变体，[agent-loop.ts:31-93](app/src/ai-agent/core/agent-loop.ts)）：非 core、非测试处 **0 调用**（BullX 走 `Agent` → `runAgentLoop`/`runAgentLoopContinue`）。
- `Agent` 的整套 steer/followUp 队列机制（`steer()`/`followUp()`/`getSteeringMessages`/`QueueMode`…）：BullX **完全没用**——它的 `/steer`、follow-up 是用 PG `generation.pending_steering[]`/`pending_followups[]` + 「本轮结束后物化成新 row 再起一轮 generation」实现的（见 §6.1），不走 Pi 的进程内队列。
- `skills.ts`（375）/ `system-prompt.ts` / `harness/types.ts` 里的 `FileSystem`/`Shell`/`ExecutionEnv`/`Skill`：明确的「未来能力」，符合设计文档「保留 skills/filesystem 形状、v1 不闭环」。
- `harness/session/session.ts` 的 `buildSessionContext`：**不是死代码**（`compaction.ts` 内部用它估算 tokensBefore），但它做的「summary + firstKept 路径投影」与 BullX 手写的 `context-renderer.render` / `conversation-service.renderedMessages` 概念重叠——两套都在做「把压缩后的可见路径投影成消息」。输入不同（`SessionTreeEntry[]` vs PG rows），所以不算重复 bug，只是这块认知上有点绕。

**建议**：4a 可以在接 tools 时再补，现在删掉 runtime 端 registry 写入侧能少一点噪音（也可保留，影响很小）。4b 整体维持现状即可，属于 fork 的正常代价；真要做「fork 瘦身」时按上面清单逐个和你确认。置信度：中。

---

## F5 —— 一批「空转 / 前置」小表面 🟢

这些都很小、单独看几乎无害，但累积起来是「读代码时的轻微认知摩擦」，列出来你批量决定：

1. **`envelope.data.session.id` 是空转字段**。`handlers.ts` 给每个 CloudEvents 信封算并塞入 `session: { id: externalGatewaySessionId(agentUid, roomId), scope }`（[agent-events.ts:435](app/src/external-gateway/agent-events.ts)），但 `AiAgentRuntime` 自己用 `conversationKey`（agentUid+binding+realm+room）做路由，**从不读这个 session.id**。grep 确认下游零消费。设计文档说 gateway「仍计算一个 operational session id」，但既然没人消费，它现在就是个噪音字段（未来若接 `visible-output-stream` 才会用到，因为那个流按 `sessionId` 建键——属同一个未接线的 streaming 特性）。

2. **`ambient.ts` `batchFromMember` 的 array 分支是死代码**（[ambient.ts:220-231](app/src/ai-agent/ambient.ts)）。`batchKey()` 只产出 JSON object 形式，redis 里从无 array 成员，所以 `Array.isArray(parsed)` 那一支永远进不去。`drainDue` 还接受 `Profile | {filter, profile}` 双形态 union（[:62-66](app/src/ai-agent/ambient.ts)），实际只用后者。

3. **`run-registry` 的 `get()` 和 `list()` 没人调用**（[run-registry.ts](app/src/ai-agent/run-registry.ts)）。实际用到的是 `set/delete/abort/abortAndWait`。两个小死方法。

4. **`login_subject` / `outbound_actor` 两种 identity kind 只在 schema 和校验分支里存在、从不被写入**（[external-identities/service.ts:305](app/src/principals/external-identities/service.ts)）。OIDC 登录走的是 `platform_subject`。schema 注释说 outbound 是「future outbound DM lookup」——属有计划的前置，按你的原则不算死代码，仅作范围说明。

5. **SDK 里 `'modal' | 'streaming' | 'ephemeral'` 出站 capability、`'modal_event'` 入站 capability** 无任何 adapter 声明、无 host 分发路径（outbox 只处理 post/reply/edit/delete/reaction/divider/card）。几个枚举值，成本可忽略，前瞻占位。SDK 里还有两个 `@deprecated` 别名为「迁移中的旧插件」保留——greenfield 单插件场景下略显投机，但是 trivial。

**建议**：1、2、3 可以顺手清掉（纯减法、零风险）；4、5 维持。置信度：中。

---

## F6 —— 两个维护性 nit（不是架构问题）🟢

1. **`plugin/lark-adapter/src/index.ts` 单文件 1845 行**，把 `SharedLarkConnection`（共享 WS 连接池）+ `BullXLarkIdentityProviderAdapter`（OIDC + 通讯录同步）+ `BullXLarkChatAdapter`（聊天收发）+ ~40 个 mapping helper 全塞在一个文件。内聚（都属 Lark）所以不是架构问题，但可读性上建议拆成 `connection.ts` / `chat-adapter.ts` / `identity-adapter.ts` / `lark-mappers.ts`。共享连接池本身是设计文档明确要求的（每 `domain+appId` 一条 WS、避免 cluster-mode 事件被随机分流），实现正确。

2. **`config/app-configure.ts`（555 行）的 API 面偏大**：`get/getByKey/set/setByKey/refresh/refreshByKey/delete/deleteByKey` + 内部 `*WithDefinition`，每个操作有 2~3 个近重复变体（by-definition 只是 by-key 的类型安全薄包装）。我特意提醒自己**不要过度纠结「通用配置引擎」**——它有真实理由（凭据 AEAD 加密、Zod 校验、per-agent-channel 的 pattern 用例真实存在），所以这只是「面可以更小」的口味问题，不是结构问题。如果要收，可把 by-definition 变体实现为 by-key 的一行转发，减少重复。

置信度：低（都偏主观）。

---

## 7. 我特意复核、但判定「不算问题」的部分

为了让你相信我不是只挑刺、也为了说明我评估过这些「最容易被 AI 误判成过度设计」的地方，单独列出：

- **Principal / 授权（CEL）子系统**：`authorization/*` + native CEL 引擎 + groups/grants/memberships。结构与真实授权需求**成比例**，last-admin 双重保护 + 行锁是必要的防锁死。✅ 唯一要说明的是：`authorize()`/`allowed()` 目前**未在任何动作路径上强制执行**（非 authorization 模块、非测试处零调用点），即引擎建好了但还没接到「执行某动作前先鉴权」。按 README（Principal/授权/预算是核心架构元素）这是**有意的前置投资，不是缺陷**——只是供你排优先级时知道「这块还没闭环」。我没把它当复杂度问题（你提醒过我易过度沉迷权限链，这里确实不该 flag）。
- **`packages/native-addons`（Rust NAPI）**：CEL + crypto（blake3 / xchacha20-AEAD / siphash / present80 / crc32）+ encoding。典型的「复杂实现关在 Rust 库里、TS 侧 `genericHash()`/`aeadEncrypt()`/`authzAuthorize()` 清晰调用」。✅ 完全符合你说的「用复杂库不让自己实现变复杂」。（库里有些 crypto/encoding 原语 TS 侧未必全用到，但这是工具库的正常冗余，隔离在 Rust 里，不影响主架构清晰度。）
- **目录同步（`identity-providers/service.ts`，539 行）**：全量+增量、层级部门祖先展开、provider-as-truth、区分 provider-disabled vs operator-disabled、只禁用「受管」用户。这些都是**通讯录同步的本质复杂度**，不是脚手架。✅
- **generation lease / `pending_followups` / `pending_steering` / outbox 三态恢复（send_attempt_started / unknown_after_send）**：设计文档已逐条论证为「当前需求要求的、非未来幻想」的复杂度，代码实现与论证一致（崩溃恢复、防重复发、防错序）。✅ 这是 BullX「数据库驱动、进程崩溃不丢已接受事实」这一核心承诺的本质成本。
- **DI（tsyringe）**：只在 8 个文件用，`common/di.ts` 仅 4 行 re-export，主要服务于插件工厂注册和少量 singleton。用量小、用途正当。✅ 不是「企业级模板自嗨」。
- **插件系统（discovery/catalog/runtime/registry）**：对「目前只有一个 lark-adapter」来说机器略多，但 plugin 是 README 里的一等概念、也是从 OpenClaw 借鉴的明确架构方向，属合理的扩展基础设施。✅
- **三个 SPA + cookie-session gating + setup 激活码**：web 层比例恰当，origin/content-type 防护合理。✅
- **`external-gateway` 的输入窗口 / tombstone / batch window / 投影**：与设计文档逐条对齐，是 IM 接入的本质复杂度。✅
- **模型配置迁移（`llm-providers` 模块 + per-agent `ai_agent.models` + legacy `ai_agent.runtime` 兼容路径）**：这是审计期间正在落地的一次重构——从「安装级内联模型配置（含明文 apiKey）」迁移到「中央 `llm_providers` 注册表（AEAD 加密密钥）+ 每个 agent 在 `agents.metadata.ai_agent.models` 里引用 provider」。`loadAiAgentRuntimeProfile(agentUid)` 的优先级清晰（有 per-agent 配置就用之，否则回退 legacy），legacy 路径在配置键描述里明确标注为 "read-only compatibility input"。`llm-providers/service.ts` 本身质量很好（per-provider 派生密钥加密、拒绝 headers 夹带凭据、删除前校验 agent 引用、连通性检查）。按你「迁移 / tradeoff 不算问题」的原则，这是**有意的在途迁移、非缺陷**——仅作范围说明，提醒你它处于迁移中，迁移收尾后记得删掉 `resolveLegacyAiAgentRuntimeProfile` 这条兼容路径以免长期双轨。✅
- **OIDC provider 构造、adapter 注册表、enabled-adapter 列举**：`setup/routes` 的 `createSetupOidcProvider` 与 `admin-auth/api-routes` 的 `createOidcProvider` 近重复；`identity-providers/registry` 与 `external-gateway/adapter-registry` 是两套「按 id 注册工厂」的小实现；`identity-providers/adapters` 的 enabled-adapter 列举与 `console` 的同类逻辑平行。这些都是 <30 行的小平行结构，**不值得为消重而引入抽象**（强行抽反而增加耦合），列出只为说明我看到了、判定保持现状更划算。✅

---

## 8. 一句话收尾

如果只做一件事：**处理 F1**（把 `external-gateway/core` 的多平台富渲染孤岛删掉或移出主树）。它一个就占了后端约 17% 的体量，且是唯一一处「代码结构在描述一个 BullX 并不打算做的系统」。其余 F2/F3 是顺手的去重，F4/F5/F6 是可选的减噪。除此之外，这套代码的复杂度是**挣来的**，不是堆出来的。
