# BullX — 与 AI 同事并肩工作的 AgentOS




BullX 是一个帮助你与有主观能动性的 AI 同事（AI Colleague）并肩工作的 AgentOS。



聊天机器人让 LLM 会对话。[OpenClaw](https://grokipedia.com/page/OpenClaw) 和 [Hermes-Agent](https://hermes-agent.nousresearch.com/docs/user-stories) 这一代让 Agent 有了手：channel、tool、skill、shell/browser、记忆文件、SubAgent 和定时任务。[Dify](https://docs.dify.ai/en/use-dify/getting-started/key-concepts)、RPA 和 RAG workflow builder 让 AI 更容易被封装成特定业务应用。BullX 面向的是下一步：让 AI 同事在可审计、可恢复、可治理、会改进的操作模型里长期承担工作。

BullX 的核心是 AI 同事，而不是换壳 RAG 客服机器人，也不是被动响应指令的数字助理。一个 BullX Agent 应该有自己的长期使命（mission）、KPI/OKR 式成功指标、责任边界、长期记忆、权限和出站身份；它能长时工作，也能与人类或其他 Agent 协作，并从轨迹数据中改进。

BullX 不追求“再多一个聊天入口”。它把 AI 同事组织进持久工作系统：

- **Agent** 承载长期使命、责任边界、权限、记忆、出站身份，以及 KPI/OKR 式成功指标。
- **IMGateway 和其他 Gateway** 保存外部世界事实，并发出 CloudEvents mail。
- **MailBox** 为 AIAgent、Workflow、SubAgent、gateway、blackhole 等 Receiver 创建内部投递条目。
- **Receiver** 承担处理工作：最常见的是负责灵活判断的 AIAgent，或负责显式流程结构的 Workflow。
- **Principal**、**Budget** 和人类协作机制让责任、成本与授权在高风险动作前变得明确。
- **Capability** 暴露 model、tool、browser、sandbox、消息通道、API 和外部 agent harness，但不把执行权藏进 prompt。
- **Brain** 将提供长期记忆与推理世界模型：不是原始向量日志，也不是越写越大的 Markdown 记忆文件，更不是一次性预定义完整本体，而是从对话、事件、行动和结果中提炼、修订、整合出来的知识。

## 三类模型，一个关键区别

很多系统现在都自称 agent 或数字员工，但它们优化的方向不同。

- **OpenClaw / Hermes 式助理** 是 prompt 驱动的 Agentic Loop。它们擅长个人助理、工具调用、channel 集成、cron、记忆文件、skill 和 SubAgent。核心主体仍然是一个在被 prompt、定时或消息触发时行动的 assistant session。
- **Dify / RPA / RAG workflow 数字员工** 是 app 或 workflow 驱动的自动化。它们适合客服机器人、BI 报告 bot、发票审核 bot、文档抽取等边界明确、可重复的流程。
- **BullX AI 同事** 是 mission 驱动的工作主体。这里的 mission 指长期使命，更接近 KPI 或 OKR，而不是一次性任务。它有权限、预算、记忆、出站身份和责任边界。它能观察世界、判断什么重要、与人类或其他 Agent 协作，并从轨迹数据中改进。

| 维度 | OpenClaw / Hermes 式助理 | Dify / RPA / RAG workflow 数字员工 | BullX AI 同事 |
| --- | --- | --- | --- |
| 核心单元 | Agentic Loop 或 assistant session。 | App、Bot、RPA flow 或 Workflow run。 | 拥有长期使命、责任、Work 和 MailBox 路由上下文的 Agent。 |
| 自主性 | 响应 prompt、消息、cron 或用户配置的任务。 | 执行某个具体业务场景的既定流程。 | 观察 Event、排列优先级、请求帮助、委派任务，并围绕长期使命推进工作。 |
| 动作 | Tool call、shell/browser 操作、消息、文件、SubAgent。 | 表单填写、API 调用、抽取、路由、审批、报告生成。 | 受治理的 Capability、AIAgent 行动，以及在需要显式流程结构时使用的 Workflow step。 |
| 记忆与推理 | Session memory、Markdown 文件、skill notes 或外部 memory layer。 | RAG 知识库、workflow 变量和 app-specific state。 | Brain 是从对话、事件、行动、关系、结果和 domain object 中生长出来的推理式世界模型。 |
| 自我进化 | 从过往 session 学习新 skill 或 notes。 | 依赖人工修改 workflow 或知识库来改进。 | 利用轨迹数据改进 planning、Skill、policy 和未来执行。 |
| 权限与预算 | 通常是 tool policy、模型配置和本地 runtime 控制。 | App credential、node permission、rate limit 和 workflow setting。 | Principal 身份、delegated authority、Budget、出站身份和审计边界。 |
| 人类协作 | 常见形态是 approval prompt、DM gate 或人工确认。 | 某个流程内的 approval node 或人工复核步骤。 | 人类可以是上级、平级或下级：审批、纠正、升级、接管、补充上下文、帮忙完成现实世界任务，或接收 Agent 分配的任务。 |
| 外部事件 | Channel、cron、webhook 和 integration 进入 assistant loop。 | Trigger 启动一个预定义 app 或 workflow。 | Gateway 保存外部事实，MailBox 投递 CloudEvents mail，Receiver 通过业务记录更新长期 Work。 |
| 可追责性 | Transcript 和 tool history 解释一次 session 里发生了什么。 | Workflow log 解释一次 app run。 | Product fact 记录谁行动、谁审批、花了多少预算、改变了什么，以及轨迹数据如何改进后续行为。 |

## 为什么是 BullX

BullX 保留上一代 agent 系统有用的表面：channel、tool、Skill、sandbox、browser、SubAgent、schedule 和对话入口。差异在于产品事实归属哪里。在 BullX 里，持久工作属于 Work、Conversation、ApprovalRequest、ChildRun、Principal、Budget、Brain、domain record 和轨迹数据等业务记录，而不只属于一次 assistant session 或一次 workflow run log。

BullX 也不同于 Palantir 式 ontology 工程。Brain 受本体论和语义网启发，但 BullX 不要求专家先把完整业务图谱预定义出来。它的世界模型应该在工作中自然生长：对话、Event、domain record、决策、交接、纠正和结果，会逐步教会 AI 同事理解业务、行业、公司内部语境，以及人们真实完成工作的那些隐性知识。

BullX 想做的不是“更好的 bot”，也不是“更聪明的 workflow app”，而是一个让 AI 同事能够旁听、判断、委派、等待、请求、花钱、记忆和行动，并且在产品层可追责的操作系统。

## 本地开发工具

本仓库内置 `@agentbull/devkit`，入口是根目录脚本：

```shell
bun run kit --help
```

常用命令：

```shell
# 创建或更新 VS Code workspace 文件
bun run workspace:update

# 启停本地 Postgres/Redis，默认拉取官方 latest 镜像
bun run services:start
bun run services:stop
bun run services:status

# 创建 app 数据库；数据库名默认来自 app/.env.local 或 app/.env.development
bun run db:create

# 重建 app 数据库并执行 Drizzle migration；重建是破坏性操作，需要显式确认
bun run db:rebuild --yes
```

本地 Compose 文件在 `tools/devkit/external-services.docker-compose.yml`，默认端口与 `app/.env.development` 对齐：Postgres `localhost:5433`，Redis `localhost:6379`。

## 它应该带来的体验

**群聊可以被旁听，而不是被打扰。** 客户成功 Agent 可以在群聊中发现风险、创建 Work，并私下提醒负责人，而不是默认在群里插话。

**一个输入可以进入正确的工作路径。** 一条客户预算冻结的消息由 gateway 保存，经 MailBox 投递，并到达 Receiver。这个 Receiver 可以是直接处理 case 的 AIAgent，也可以是表达显式分支、审批、并行和确定性步骤的 Workflow。

**记忆可以包含世界，而不只是聊天记录。** 投研 Agent 应该把对话与市场、政策、产品、运营和外部事件放在一起理解，再通过从实际工作中生长出来的 ontology-backed world model 检索上下文。

**世界模型可以像人类同事一样成熟。** 一个 BullX Agent 入职后，应该越来越熟悉业务、行业、内部规则、反复出现的例外和隐性知识，而不是要求组织在 day one 把一切建模完成。

**Agent 可以拥有长期使命，而不只是接任务。** Coding Agent、投研 Agent 或客户成功 Agent 可以跨多次交互持续工作，与人类或其他 Agent 协作，并从轨迹数据中改进后续 planning。

**人类可以在 Agent 的上级、平级或下级位置协作。** 人类可以审批或纠正 Agent，也可以作为平级一起推进工作、接管某个 case、补充现实世界信息，甚至接收 Agent 分配的任务，例如线下打听某件事，或帮忙扫码登录一个网站。

**高风险工作可以被显式 gate。** 面向客户、金融、法律、权限变更或不可逆外部动作，应该先经过 approval 或 policy gate，再执行真正产生副作用的步骤。
