---
title: 轨迹与消息格式
description: Ankole 如何持久化与投影会话消息及后台任务执行轨迹——详解两类存储结构、标准 ChatML 格式与剥离底层协议的模型可见投影。
section: Developer guide
order: 121
---

针对主对话与后台长任务两类工作负载，Ankole 分别在两套独立的存储结构中记录 Agent 的执行全过程：AIGateway 负责存储**会话消息**（有状态 Responses 会话产出的实时对话转写），后台 Agent 任务模块则负责存储**回合轨迹**（持久化任务按回合追加的执行流水）。本文详解这两类存储形态、统一的 ChatML 规范格式，以及隐去底层协议细节的模型可见投影。阅读前建议先了解 [AIGateway](../ai-gateway/) 与 [Background Agent Jobs](../background-agent-jobs/)。

贯穿全文的核心设计原则是：**模型永远不会直接看到底层的原始数据库行**。无论底层采用哪种表结构，在送入模型上下文前都会先投影为干净的模型可见视图——剔除内部协议标识，并将工具调用 ID 替换为回合内的局部序号别名（例如模型看到的是直观的“工具调用 1 → 工具结果 1”，而非内部 UUID 或传输层私有字段）。简言之，底层存储面向持久化与审计，上层投影面向模型推理。

需要注意，本文提及的 AIGateway Conversation 特指单个执行会话（Session）私有的模型上下文链，与 `Ankole.Conversations` 所维护的多方共享聊天记录（Conversation 与 Message）分属不同概念：公开聊天记录可用于补充当前回合的背景上下文，但不能替代持久化的模型消息链与工具调用日志。

## AIGateway 会话消息

AIGateway 全权管理实时推理会话的转写记录，每条消息对应 `ai_gateway_messages` 表中的一行：

| 字段 | 含义 |
|---|---|
| `subject_uid` | 该会话归属的权限主体 UID |
| `conversation_id` | 消息所属的 AIGateway 会话 ID |
| `type` | 消息条目类型（如助手回复、工具返回结果等） |
| `role` | 消息在对话转写中扮演的角色 |
| `status` | 条目的生命周期状态 |
| `previous_message_id` | 自引用续接锚点——在对外 API 中映射为 `previous_response_id`，将整场会话串联成链 |
| `content` | 结构化消息内容（JSON 值，而非纯文本字符串） |
| `metadata` | 调用方透传的不透明元数据，外加 AIGateway 记录的响应事实（实际模型、提供商、Token 用量及上游原始响应 ID） |

`previous_message_id` 充当链式续接锚点：每条新消息都指向紧邻的前一条消息，由此构成一条完整的有向消息链。在 API 层面，该字段映射为 `previous_response_id`，使调用方或上下文压缩流程能够从任意历史锚点无缝分支续接。`metadata` 字段同时承载调用方透传的自定义元数据与 AIGateway 权威记录的运行事实（所用模型与提供商、Token 消耗及上游原始响应 ID），严禁在其中塞入第二份冗余的消息条目列表。

触发上下文压缩（Compaction，详见 [上下文压缩与 compaction](../context-compression-and-caching/)）时，系统会写入一条摘要检查点（Checkpoint）作为新的可见起始锚点：更早的历史行依然保留在表中以备故障恢复与合规审计，但投影给模型的上下文会直接从该摘要节点起步，不再重放摘要之前的早期原始消息。

## 后台 Agent 任务轨迹

后台 Agent 任务将其按回合推进的执行过程保存在 `background_agent_job_turn_items` 表中，形成一条只追加（append-only）的语义线程条目流。每条记录归属于某次具体任务回合，包含顺序位置、修订号、稳定键名及语义条目载荷：

| 字段 | 含义 |
|---|---|
| `turn_id` | 该条目所属的后台任务回合 ID |
| `position` | 条目在当前回合内的先后序号 |
| `revision` | 接纳该条目时对应的回合修订版本号 |
| `item_key` | 条目的稳定幂等键（以 `client:` 开头的键标识调用方注入的消息） |
| `item` | 带类型的结构化语义线程条目 |

这张表严格遵循只追加写入：运行中途注入引导消息（steer 或 nudge）只会向流末尾追加新行，绝不原地覆写既有记录。所有读取方在消费时都会将已存条目统一投影为标准 ChatML 消息；部分无法映射为对话消息的纯控制条目同样保留在表中以支撑完整线程重放。若某个回合尚未产生任何条目行，其轨迹视图即显示为空列表。

此外，工具结果消息的 `metadata` 中会固定记录 `execution_mechanism` 字段：由上游模型提供商直接托管执行的工具记为 `provider_hosted`，由 Codex 调用的 Ankole 本地动态工具则记为 `local_dynamic`。即便两类工具的对外展示名称完全相同，也能凭这一稳定标记准确区分实际执行路径。

之所以不与 AIGateway 会话消息混表存储，是因为后台任务的执行轨迹归属于该任务自身，而非发起它的主对话会话——后台任务的各个回合自成一条独立执行线，主会话在任务收尾时接收的只是最终交付结论，而非冗长的中间过程轨迹。

## 模型可见投影

当主 Agent 需要查阅后台任务的执行进展时，控制面会通过 `Ankole.Sessions.Tools.Jobs.visible_trajectory/1` 对已落库的 Job 条目做投影转换，具体规则如下：

- **剥离底层协议标识**：剔除内部数据库消息 ID、传输协议私有字段等一切不应暴露给模型做决策依据的内部实现细节；
- **将工具调用 ID 替换为回合内局部别名**：统一重命名为 `call_1`、`call_2` 等简短序号，让模型无需接触冗长的内部 UUID 即可清晰识别“哪份工具结果对应哪次工具调用”；
- **完整保留正文内容与对话角色**：严格按实际发生顺序呈现消息文本、工具调用入参及返回结果；
- **保留内容脱敏与截断标记**：继续透出 `metadata.redacted` 与 `metadata.content_truncated` 状态；当控制面为满足单页体积上限而裁剪超长输出时，会显式打上 `content_truncated` 标记告知模型。

## 两种形态如何关联

| 对比维度 | AIGateway 会话消息 | 后台任务轨迹 |
|---|---|---|
| 记录内容 | 主会话的实时推理转写 | 后台任务按回合记录的执行流水 |
| 归属模块 | AIGateway | 后台 Agent 任务（Background Agent Jobs） |
| 标准表示 | AIGateway 消息 Schema | 语义条目投影为标准 ChatML |
| 模型读取方式 | 有状态 Responses API | `visible_trajectory/1` 投影转换 |
| 上下文压缩 | AIGateway 写入新摘要检查点，保留历史旧行 | 不做摘要压缩（受任务自身重试预算约束） |

两套存储严格隔离、互不混写：主会话消息归 AIGateway 管理，后台任务轨迹归任务自身管理；任务完结后通过发送唤醒事件（详见 [Background Agent Jobs](../background-agent-jobs/)）向归属主会话回传最终结果，而不会直接向主会话的消息表中插入记录。

## 本指南不是什么

- **不是 ChatML 格式标准文档**：ChatML 本身是通用行业规范，Ankole 的读取投影只是对齐这一标准形态，并未另起炉灶重新定义它。
- **不是面向外部业务系统的公开查询接口文档**：Console 下的 `/api/v2/ai-gateway/conversations/:id/messages` 与 `/api/v2/background-agent-jobs/:id` 属于运维管理路由，具体参数见 [Console API 参考](../console-api/)。
- **不替代各子系统的存储设计文档**：本文聚焦于横跨两套子系统的消息格式与投影层，底层存储细节仍以各自专题页为准。

## 下一步

- 了解会话消息表的完整设计，请参阅 [AIGateway](../ai-gateway/)。
- 了解后台任务及其轨迹存储机制，请参阅 [Background Agent Jobs](../background-agent-jobs/)。
- 了解上下文摘要压缩与可见检查点机制，请参阅 [上下文压缩与 compaction](../context-compression-and-caching/)。
- 查阅读取上述记录的管理端接口，请参阅 [Console API 参考](../console-api/)。
