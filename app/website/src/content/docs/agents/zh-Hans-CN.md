---
title: Agent
description: 说明如何在 Console 中创建 Agent，并设置负责人、长期设定、模型、能力和环境变量。
section: User guide
order: 13
---

在 Ankole Agent Harness 中，Agent 是能够持续自主开展工作的数字主体。每个 Agent 都拥有独立的职责使命、人工负责人、权限边界、可用工具、模型档案与持久化文件空间，可在权限允许的范围内调取公司大脑（Company Brain）中的知识，并在 **Pod** 工作区或通过信号路由规则在外部渠道中协同工作。

## 个人助理与 AI 同事

`Ankole.Principals` 将 Agent 划分为两类子类型：

- **个人助理（`personal_assistant`）**：为每位启用态内部人类成员（`member`）按 1:1 比例在首次使用时自动开通（初始 UID 为 `<owner_uid>_assistant`）。个人助理在统一云盘（Unified Drive）、Pod 文档与多维表、以及 `all_humans` 等协作权限组中直接投射其人类主人的协作权限（不包含 `site_console:**` 与 `tenant_console:**` 管理面权限），强制采用**严格**群聊记忆披露模式且负责人不可变更。个人助理的行为契约与 Skill 绑定仅允许主人本人查看与编辑；当主人账户暂停、离职或降级为外部访客（`guest`）时，其个人助理会自动同步停用。
- **AI 同事（`ai_colleague`）**：由管理员或团队创建的共享专业岗位 Agent。AI 同事在云盘、Pod、Workflow、计划任务与后台 Agent 任务中严格凭借自身主体权限运行；遇到需要人工审批的敏感操作时通过 `propose_action_card` 发送交互式审批卡片，并可通过 `send_to_agent` 在隔离的 `agent_peer` 对话中向其他同级 Agent 委派协作子任务。

## 创建 AI 同事

1. 打开 **Console → 智能体**（或 Pod 工作区设置），点击「新增智能体」。
2. 输入显示名称，并设定一个语义清晰的租户内小写 `uid`（匹配 `^[a-z0-9][a-z0-9._@+-]{0,95}$`，例如 `research-analyst`），在租户内以 `(tenant_id, uid)` 唯一标识该 Agent。
3. 填写角色定位、可选头像 URL，并选择 `WorkerProvider`。
4. 选择一名人员主体（Principal）担任 Agent 负责人，再选择群聊记忆披露模式。
5. 保存 Agent，随后即可配置行为契约、模型档案覆盖与 Agent 专属环境变量。

「角色」字段用于简要概括 Agent 承担的岗位职责（例如「研究分析师」或「客户支持」），而具体的行为准则、职责边界与视觉设计体系则由 **Meta Ankole → Agents** 中的两份可组合契约文档（`AGENTS.md` 与 `DESIGN.md`）管理。

`WorkerProvider` 决定该 Agent 归属的 [WorkerProvider](../worker-providers/) 计算提供方：创建请求未显式指定时自动采用站点默认提供方；若站点未配置默认提供方，创建将直接失败，且保存后不可更改。即使多个 Agent 共用同一提供方，每个 Agent 仍拥有独立的 Worker 实例、`/drive` FUSE 工作区挂载以及持久化的 `/workspace` Home 目录。保存新建 Agent 时不会立即拉起实例，等到回合实际需要执行电脑环境任务时才由控制面按需启动。

## 设置负责人和群聊披露模式

每个 Agent 都必须指定一名人工负责人。负责人有权查看由该 Agent 编写、持有，或将该 Agent 列为可见对象的 Brain 知识；但如果某条知识限定了特定权限组（Group）可见，而负责人本人不属于该权限组，负责人身份并不能绕过该权限组的访问限制。

群聊记忆披露模式决定了 Agent 在多人可见的对话中可以引用哪些记忆：

- **严格**：群聊中的每一位参与者都必须处于该条记忆的可见范围内，Agent 才能在群内引用。
- **宽松**：系统仅校验当前提问者的访问权限，群内其他参与者不影响可见知识范围。

在单人私聊中，两种模式的行为一致。建议仅在群组成员明确接受宽松共享规则时选择「宽松」，其余场景一律选择「严格」。完整的知识权限与披露模型请参阅 [Brain](../brain/)。

## 设置 Agent 规范

打开 **Meta Ankole → Agents**，编辑全局基线或个体 Agent 的 `AGENTS.md` 和 `DESIGN.md`。`AGENTS.md` 定义行为与职责，`DESIGN.md` 保存网页、幻灯片、文档和图表的视觉规范。

每个 Agent 契约可以继承全局基线、在其后追加，或完全覆盖。DESIGN 的元数据保存设计令牌，正文说明用法。个人助理的配置仅由主人本人查看和编辑。详见 [Agent Library](../agent-library/)。

保存的修改从下一轮生效，包括 Codex Job 的续跑回合；当前回合使用启动时完整读取的规范。

## 配置模型

Agent 的模型档案通过 **Console → Model Profiles** 的三层稀疏继承链（`Agent -> Pod -> Site`）解析，并内置 `coding -> heavy -> primary` 与 `light -> primary` 跨槽位回退。只要站点或 Pod 已配置好 `primary` 默认模型，新建的 Agent 无需逐槽位手动填表即可直接运行；仅当该岗位需要不同于 Pod 默认值的模型档位、独立 Provider 或自定义语言模型别名时，才需在 Agent 级别单独覆盖：

- 当该 Agent 需要比 Pod 默认值更强或更专精的模型时，单独覆盖 `primary`、`light` 或 `heavy`。
- 当 `primary` 不支持原生识图而该 Agent 需要读取图片时，配置 `vision_fallback`。
- 当该 Agent 的联网检索权限需与 Pod 默认值区分时，单独配置 `web_search` 和 `web_fetch`。
- 当该 Agent 需要通过独立生图 Provider 生成图片时，配置 `image_generate`。
- 当后台 Agent 任务（`coding`）需要使用独立的模型提供商或编码专用模型时单独配置（留空时沿 `heavy -> primary` 自动回退；ChatGPT 订阅额度同样通过 [ChatGPT 订阅 Provider](../chatgpt-subscription-provider/) 在此处选择）。

配置覆盖项时，先选择模型提供商，再选择或手动输入模型名称。选定提供商后，表单会显示「上下文长度」字段；留空时自动采用该提供商与模型的默认值。删除某个槽位的覆盖配置后，该槽位会立即恢复继承 Pod 与站点默认值。

「高级设置」仅展示当前所选提供商声明支持的选项：其中「推理摘要」仅适用于 Responses API，「回答详略」设置输出的默认详略程度，「服务等级」用于覆盖当前模型档案请求的服务等级。各选项的可用值取决于上游提供商、账号权限与具体模型；字段留空时一律沿用提供商默认值。

有关模型提供商接入与首次配模的完整步骤，请参阅 [快速开始](../quickstart/#3-添加模型提供商并创建-agent)。

## 设置 token 额度

模型档案旁的 **Token 额度**区域用于限制该 Agent 在单个循环周期内允许消耗的 Token 总量。启用时需设定周期长度（天）、周期起始时间和 Token 上限；未设置额度的 Agent 不受此限制。

配置后，面板会以进度条展示当前已用 Token 数、占上限的比例以及当前周期的起止时间。Ankole 按上游提供商为该 Agent 每次模型调用报告的输入 Token 与输出 Token 之和进行统计，涵盖计划任务回合、Workflow、后台 Agent 任务，以及由这些调用触发的上下文压缩；但 Brain 内部模型调用、向量嵌入（Embedding）、网页工具、图片生成，以及人类成员使用个人凭证发起的请求均不计入。

一旦消耗达到上限，该 Agent 收到新的聊天消息后将不再正常作答，而是自动回复一条说明已用 Token、配额上限及本周期结束时间的提示；与此同时，该 Agent 名下的后台 Agent 任务会直接失败，不会挂起等待下一个周期。由于配额检查在每次模型调用发起前执行，触发阈值的最后一次调用可能会因当次消耗而略微超出上限。被拦截的聊天消息不会自动重放，待周期结束后由用户重新发送即可。

点击**重置周期**会立即开启一个新周期，让 Agent 不必等到原周期结束即可恢复工作；点击**取消额度**则会移除配额限制。无论执行哪种操作，历史用量记录都会保留以备审计。更多成本管控手段请参阅 [成本管理](../cost-management/)。

## 配置能力、连接与环境变量

新建的 Agent 默认继承当前租户启用的 Agent Plugin 和 Skill。需要调整时，可打开 Pod 中的 **Meta Ankole → Skills**（或 **Console → Agent 能力库**）修改租户默认设置，或为该 Agent 单独配置覆盖开关，具体方法见 [Skills](../skills/) 与 [Agent Library](../agent-library/)。

对接飞书/Lark、GitHub、Linear 等外部平台、个人 OAuth 账号以及 Skill 声明的远程 MCP 服务时，请在 **Pod → Connections**（`/connectors`）中通过 `Ankole.Connectors` 集中配置共享应用凭据与个人授权，由控制面安全托管密钥（详见 [使用 MCP](../using-mcp/)）。Agent 编辑页中的「环境变量」则专供 Agent Computer 内的自定义命令行工具与脚本读取；此处添加的变量仅对当前 Agent 可见，优先级高于同名的租户与站点变量，详见 [环境变量](../worker-env/)。

## 接入聊天渠道

在内置的 **Pod Chat** 中，工作区成员可以直接与自己的个人助理或启用态 AI 同事发起私聊（`dm`），或将 AI 同事拉入群组会话（`group`），无需配置信号路由规则（Signal Binding）。Agent 之间也可通过 `send_to_agent` 在隔离的 `agent_peer` 会话中直接协同通信。

信号路由规则专用于管理外部 IM 渠道与专用邮箱。如需让该 Agent 接收来自 Slack、Microsoft Teams、飞书（Lark）、钉钉、企业微信、Telegram、Discord、LINE、WhatsApp 或专用邮箱的消息，请打开 **Console → 信号路由**，绑定外部聊天应用与目标 Agent（支持直接复用 `Ankole.Connectors` 中已登记的共享应用连接）。一个聊天应用可以配置多条路由规则分发给不同 Agent，也可以为不同 Agent 分别创建独立的机器人应用，详见 [信号路由规则](../signal-bindings/)。

## 修改、重命名或停用

Agent 的显示名称、角色定位、`AGENTS.md` 与 `DESIGN.md` 契约、模型档案覆盖以及可用能力均可随时修改。如需修改某个 AI 同事在租户内的 `uid`，请先停用该 Agent 并移除运行中或已暂停的 Worker 实例，再执行留痕重命名操作（调用 `POST /api/v2/agents/:uid/rename` 或通过工作区管理界面操作）——系统会在同一事务内原子更新该租户下的权限授权、权限组成员关系、Brain 路径与提及引用以及多维表关联记录。

停用 Agent 后，它将停止接收新工作，并在智能体列表中显示为「已停用」状态；已停用的 Agent 可随时重新启用。只有处于「已停用」状态的 Agent 才允许永久删除，且永久删除会一并清除关联的会话、任务与历史记录。如果只是想暂停某个外部聊天入口，停用对应的信号路由规则即可。

## Agent 没有回复时

若发送消息后未收到回复，请按以下顺序逐项排查：

1. 确认该 Agent 处于「已启用」状态。
2. 确认该 Agent 能够解析出有效的 `primary` 模型档案（来自站点/Pod 默认值或 Agent 覆盖配置），且关联的 LLM Provider 健康可用。
3. 若从外部渠道发信，确认信号路由规则已指向当前 Agent。
4. 打开 **Console → 工作节点**，检查该 Agent 的 Worker 是否处于「就绪」状态，或正在正常启动且无失败原因。
5. 打开 **Console → 会话**，确认刚才的消息是否已进入会话列表，并检查回合附带的报错信息。

针对特定外部聊天渠道的排查方法，请参阅 [快速开始的故障排查部分](../quickstart/#agent-没有回复时)。
