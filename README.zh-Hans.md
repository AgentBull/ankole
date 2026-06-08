# BullX — 与 AI 同事并肩工作的 AgentOS

[![License](https://img.shields.io/badge/license-Apache%202.0-red.svg?logo=apache&label=License)](LICENSE)

[English](./README.md) | [日本語](./README.ja.md)


BullX 是一个帮助你与有主观能动性的 AI 同事（AI Colleague）并肩工作的 AgentOS。



聊天机器人让 LLM 会对话。[OpenClaw](https://grokipedia.com/page/OpenClaw) 和 [Hermes-Agent](https://hermes-agent.nousresearch.com/docs/user-stories) 这一代让 Agent 有了手：channel、tool、skill、shell/browser、记忆文件、SubAgent 和定时任务。[Dify](https://docs.dify.ai/en/use-dify/getting-started/key-concepts)、RPA 和 RAG workflow builder 让 AI 更容易被封装成特定业务应用。BullX 面向的是下一步：让 AI 同事像真正入职的员工那样承担长期工作——对一个岗位的结果负责、凭自己的判断行动、并从结果中改进。

BullX 的核心是 AI 同事，而不是换壳 RAG 客服机器人，也不是被动响应指令的数字助理。一个 BullX Agent 应该有自己的长期使命（mission）、KPI/OKR 式成功指标、责任边界、长期记忆和出站身份；它能长时工作，也能与人类或其他 Agent 协作，并跨交互保留持久历史。

BullX 不追求“再多一个聊天入口”。当前仓库围绕更小的运行时表面组织：

- **Principal 和 AuthZ** 为人类和 Agent 提供稳定身份、组、外部身份绑定和权限授权。
- **Plugin runtime** 加载可信本地插件，并允许插件注册 External Gateway adapter、identity-provider adapter、web provider 和 app-config 定义。
- **External Gateway** 接收 chat adapter 归一化后的 provider 事实，维护外部可见状态的最新投影，把与 agent 相关的事件投递给绑定的 agent，并通过 outbox 执行显式出站意图。
- **AIAgent runtime** 拥有 conversation、message、LLM turn、generation lease、addressed/ambient 输入、slash-command stub、lifecycle revision、clarification、compression 和 web tool。
- **Setup 和 Console** 负责 first-admin bootstrap、admin session、identity-provider setup、LLM provider 配置、Agent 和 chat-channel 配置。
- **PostgreSQL-backed state** 是 principal、配置、外部投影、gateway input/outbox row 和 AIAgent conversation record 的持久真相。Redis visible-output stream 只是弱进度状态，不是最终真相。

有些 BullX 产品表面仍然是核心模型的一部分，只是当前仓库还没有完整支持：

- **Work** 是面向业务结果的工作单元，不应退化成一次 chat turn 或 assistant transcript。
- **Brain** 是从对话、外部事件、决策、domain record、纠正和结果中生长出来的长期世界模型。
- **Trajectory data** 是从实际发生的执行过程里改进后续 planning、skill、policy 和 execution 的学习材料。

## 为谁打造

BullX 面向的是你本来会"雇人"去干的活：一个需要有人专门负责、而你无法、不愿、或暂时无法用人手填满的岗位（seat）。

适配的岗位有三个共同特征：

- **天生远程。** 数字同事没有手，所以整份活必须能在一块键盘前干完——就像一个远程员工那样。
- **由真实结果衡量。** 这个岗位有一个谁都能核验的具体成功指标：代码过测试、策略有实盘 P&L、投放打到 ROAS、研报按时交付且无事实错误、阅读量与粉丝增长。正是这个指标，让同事能自我改进——也让你能信任结果、并判断它是否挣回了自己的工钱。
- **产出型，而非响应型。** 这份活是*产出*一个东西、或*驱动*一个数字，而不是等着回答请求。

这指向的是一线 IC（个人贡献者）岗位——工程师、quant 开发、研究员、效果广告与增长操盘手、社群运营、测试——而**不是**：

- **让你更快的 copilot** —— BullX 是把活干了，不是让你干得更快。
- **客服或秘书 bot** —— 基于知识库回答请求，是上一代 RAG 助手已经覆盖的。
- **"AI 高管"** —— 判断、权威和担责留在人这边；同事是被人管理的做事者。

你想起 BullX，是在一个岗位缺主人、而你又缺人手的那一刻。从那以后你不是像用工具那样*操作*它——你是像管一个下属那样*管理*它：定下职责与指标、验收产出、纠偏。它更接近 headcount，而不是软件。而且因为 BullX 是开源、自托管的，你**自己跑**这个同事——它的工钱就是它消耗的算力，和雇任何人一样，只要结果撑得起这份工钱，你就留着它。没有按席位的 license，你和这份活之间没有中间厂商。

## 三类模型，一个关键区别

很多系统现在都自称 agent 或数字员工，但它们优化的方向不同。

- **OpenClaw / Hermes 式助理** 是 prompt 驱动的 Agentic Loop。它们擅长个人助理、工具调用、channel 集成、cron、记忆文件、skill 和 SubAgent。核心主体仍然是一个在被 prompt、定时或消息触发时行动的 assistant session。
- **Dify / RPA / RAG workflow 数字员工** 是 app 或 workflow 驱动的自动化。它们适合客服机器人、BI 报告 bot、发票审核 bot、文档抽取等边界明确、可重复的流程。
- **BullX AI 同事** 是 mission 驱动的工作主体。这里的 mission 指长期使命，更接近 KPI 或 OKR，而不是一次性任务。它有权限、已配置的模型和工具、记忆、出站身份和责任边界。它能观察世界、判断什么重要，并与人类或其他 Agent 协作。

| 维度 | OpenClaw / Hermes 式助理 | Dify / RPA / RAG workflow 数字员工 | BullX AI 同事 |
| --- | --- | --- | --- |
| 核心单元 | Agentic Loop 或 assistant session。 | App、Bot、RPA flow 或 Workflow run。 | 由 Principal 支撑、拥有持久 conversation 和 external-event 上下文的 Agent。 |
| 自主性 | 响应 prompt、消息、cron 或用户配置的任务。 | 执行某个具体业务场景的既定流程。 | 观察 Event、排列优先级、请求帮助、委派任务，并围绕长期使命推进工作。 |
| 动作 | Tool call、shell/browser 操作、消息、文件、SubAgent。 | 表单填写、API 调用、抽取、路由、审批、报告生成。 | AIAgent generation、配置好的 tool 与 web provider，以及通过 External Gateway outbox 发出的 provider-visible 消息。 |
| 记忆与推理 | Session memory、Markdown 文件、skill notes 或外部 memory layer。 | RAG 知识库、workflow 变量和 app-specific state。 | 持久 conversation、summary、LLM turn、外部投影，以及预期从 Work 和 domain fact 中生长出来的 Brain 世界模型。 |
| 自我进化 | 从过往 session 学习新 skill 或 notes。 | 依赖人工修改 workflow 或知识库来改进。 | 利用 trajectory data 改进后续 planning、skill、policy 和 execution；当前持久 conversation 与 turn record 是基础。 |
| 权限与预算 | 通常是 tool policy、模型配置和本地 runtime 控制。 | App credential、node permission、rate limit 和 workflow setting。 | Principal 身份、组成员关系、permission grant、外部身份和已配置的 provider credential。 |
| 人类协作 | 常见形态是 approval prompt、DM gate 或人工确认。 | 某个流程内的 approval node 或人工复核步骤。 | 人类可以是上级、平级或下级：审批、纠正、升级、接管、补充上下文、帮忙完成现实世界任务，或接收 Agent 分配的任务。 |
| 外部事件 | Channel、cron、webhook 和 integration 进入 assistant loop。 | Trigger 启动一个预定义 app 或 workflow。 | External Gateway 保存 provider-visible 事实，并把 CloudEvents 风格的事件投递进 AIAgent conversation state。 |
| 可追责性 | Transcript 和 tool history 解释一次 session 里发生了什么。 | Workflow log 解释一次 app run。 | Work 和 product fact 应解释所负责的结果；当前持久记录解释已接受的外部事实、conversation state、assistant output、model turn 和 provider-visible side effect。 |

## 为什么是 BullX

BullX 保留上一代 agent 系统有用的表面：channel、tool、web access、plugin-provided integration 和对话入口。差异在于持久事实归属哪里。在当前仓库里，持久状态属于 PostgreSQL 记录，例如 Principal/AuthZ row、External Gateway projection/outbox row、AIAgent conversation、message、summary 和 LLM turn。预期产品模型会在这个基础上扩展出 Work、Brain、domain record 和 trajectory data，而不是停在一次 assistant session transcript。

BullX 也不同于 Palantir 式 ontology 工程。Brain 应该通过 Work 自然生长，而不是要求专家在 day one 先把完整业务图谱预定义出来。当前代码还没有完整实现 Brain，但对话、外部事件、决策、纠正、summary 和未来的 domain record，都是它可以生长的材料。正是在这里，价值为你复利：底层的模型智力是租来的、人人共享，但一个同事在*你的*工作里、在*你自己的*基础设施上攒下的 context 只属于你，而且它在岗越久就越深。

BullX 想做的不是“更好的 bot”，也不是“更聪明的 workflow app”，而是一个让 AI 同事能够旁听、判断、委派、等待、记忆和行动，并由它们所负责的结果来衡量的操作系统。

## 它应该带来的体验

**群聊可以被旁听，而不是被打扰。** 客户成功 Agent 可以镜像相关群聊事实，判断是否重要，并最终创建或更新 Work，再私下提醒负责人，而不是默认在群里插话。

**一个输入可以进入正确的工作路径。** 一条客户预算冻结的消息由 External Gateway 保存，并作为 agent event 投递。AIAgent 会把输入记录到正确 conversation，能批处理相邻的 addressed message，能把 ambient message 单独保留，也能排队发送显式的 provider-visible 回复。

**记忆可以包含世界，而不只是聊天记录。** 投研 Agent 应该把对话与市场、政策、产品、运营和外部事件放在一起理解。当前存储基础是 conversation、summary、LLM turn 和外部投影；Brain 和更丰富的 domain memory 可以建立在这些事实之上。

**世界模型可以像人类同事一样成熟。** 一个 BullX Agent 入职后，应该越来越熟悉业务、行业、内部规则、反复出现的例外和隐性知识，而不是要求组织在 day one 把一切建模完成。

**Agent 可以拥有长期使命，而不只是接任务。** Coding Agent、投研 Agent 或客户成功 Agent 可以跨多次交互持续工作，与人类或其他 Agent 协作，并用 trajectory data 和持久历史辅助后续 planning。

**人类可以在 Agent 的上级、平级或下级位置协作。** 人类可以审批或纠正 Agent，也可以作为平级一起推进工作、接管某个 case、补充现实世界信息，甚至接收 Agent 分配的任务，例如线下打听某件事，或帮忙扫码登录一个网站。

**工作可以由结果而非感觉来评判。** 一个同事持有一个带具体成功指标的岗位——代码过测试、研报按时且无事实错误、投放打到目标——所以它的产出可以像人类同事的产出那样被核验、被信任。

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
