---
title: 介绍
description: 了解 Ankole 数字总部、Agent Harness 与 Meta Ankole 公司大脑提供的核心能力及私有部署实例的协作方式。
section: Getting started
order: 1
---

**Ankole 是围绕 Meta Ankole 公司大脑构建的开源数字总部与企业级 Agent Harness，将 Pod 协作工作空间与个人助理、专业 AI 同事紧密结合，为 Agent 提供持续承担实际工作并呈现可核查证据所需的上下文、权限、工具与反馈闭环。**

在私有部署实例中，团队成员与 Agent 可跨越 Pod 文档（Docs）、物理分片多维表（Bases）、React + TypeScript 小应用（Applets）、Pod Chat 及外部企业 IM 协同办公，底层由共享组织知识、统一连接器（Connectors）、Function Runtime 与专属 Agent Computer Worker 共同支撑。

裸跑的大语言模型只能就传入的提示词做单次推理；Ankole 则负责在运行时汇聚最新企业事实、严格执行主体与云盘访问控制、跨隔离上下文协同委派、在进程崩溃后原地恢复在途任务，并将纠偏经验与真实业务结果持续反哺到后续工作中。

## Ankole 提供的核心能力

- **Pod 数字总部**：团队可在同一空间内协同编写层级文档（Docs）、使用物理分片多维表（Bases）管理业务数据、构建带零模型开销已发布 Action 的 React + TypeScript 小应用（Applets），并在多人 Pod Chat 以及飞书/Lark、钉钉、企业微信、Slack、Microsoft Teams 中无缝协作。
- **个人助理与 AI 同事**：每位内部成员拥有 1:1 专属**个人助理**（复用成员自身的业务协作权限），同时团队可配置拥有独立主体权限的**专业 AI 同事**，通过隔离的 Peer A2A 会话（`send_to_agent`）接收委派，并在越权写操作时发起 Action Card 人工审批。
- **Meta Ankole（`Brain`、`Skills` 与契约）**：将记录来源、断言、时间、置信度、冲突与受众范围的 **Brain** 本体图谱，与共享 **Skills** 及可组合继承的 `AGENTS.md` / `DESIGN.md` 行为与视觉契约统一纳入同一治理层。
- **统一连接器与控制面 MCP 网关**：`Ankole.Connectors` 集中管理租户级外部应用凭证、成员个人 OAuth 授权（`/connectors`）以及面向飞书/Lark、GitHub、Linear 和远端 MCP 服务的控制面网关，原始密钥绝不下发至 Worker 或小应用沙箱。
- **事件驱动与容错长时执行**：聊天消息、定时计划、Webhook 与连接器事件可自动唤醒 Session、后台 Agent 任务或确定性小应用 Action；遇到进程重启时直接从 PostgreSQL 恢复执行。
- **持续学习闭环**：Dreaming 会从真实后台任务轨迹中自动激活 7 天租期的技能警示（Skill 教训），并在预测到期后对照实际结果复盘打分；人工则负责沉淀长期警示与共享 Skill。

## 一个部署实例包含哪些部件

文档各处将频繁使用以下核心概念：

| 部件 | 说明 | 详见 |
|---|---|---|
| **Pod** | 人类与 Agent 协同办公的数字总部，集成层级文档（Docs）、物理分片多维表（Bases）、React + TypeScript 小应用（含已发布小应用 Action）、统一云盘（Unified Drive）与多人 Pod Chat。 | [架构概览](../architecture/) |
| **个人助理与 AI 同事** | 两类 Agent 角色：每位内部成员 1:1 配备、映射本人协作权限的**个人助理**，以及持有独立主体权限、支持跨 Agent 隔离委派（Peer A2A `send_to_agent`）的**专业 AI 同事**。 | [Agent](../agents/) |
| **Meta Ankole（`Brain`、`Skills`、契约）** | 企业共享制度与认知层，涵盖 **Brain** 本体图谱与带出处的结构化断言、可复用的 **Skills**（含单 Agent 租期教训），以及可继承组合的 `AGENTS.md` / `DESIGN.md` 契约。 | [Brain](../brain/)、[Skills](../skills/)、[Agent 能力库](../agent-library/) |
| **统一连接器（Connectors）** | 统一托管租户应用连接（`authConfigId`）、成员个人 OAuth 授权（`/connectors`）、外部事件订阅与控制面 MCP 网关，向 Worker 与 Function Runtime 提供飞书/Lark、GitHub、Linear 等工具集。 | [使用 MCP](../using-mcp/) |
| **主体（Principal）** | 以 `(tenant_id, uid)` 唯一标识的责任主体，涵盖人员、Agent 与内置 `system` 服务（`system`、`ankole_brain`）；`Ankole.AuthZ` 在运行时按主体执行权限校验与审计归因。 | [主体与 AuthZ](../principal-authz/) |
| **会话（Session）** | 单次对话或 Peer A2A 协作中的 Agent 执行单元，统一管理对话上下文、中途引导、取消、冷唤醒会话轮转与崩溃恢复。 | [Sessions](../sessions/) |
| **信号路由规则** | 将外部 IM 渠道、Webhook、定时任务、多维表/小应用事件或连接器触发器路由至目标 Agent 会话或已发布小应用 Action。 | [信号路由规则](../signal-bindings/) |
| **后台 Agent 任务** | 在专属 Worker 上异步运行数小时的持久化 Codex 任务，支持中途向发起对话澄清问题并在完成后回传成果。 | [Background Agent Jobs](../background-agent-jobs/) |
| **Function Runtime** | 无状态的 `ankole-function-runtime` 服务，在隔离实例中执行 TypeScript 程序，承载 Pod 小应用后端、零模型已发布小应用 Action（[自动化任务](../automation-jobs/)）、程序化工具调用（PTC）与 Workflow，并桥接控制面 MCP 宿主。 | [架构概览](../architecture/) |
| **Agent Computer Worker** | 每个 Agent 独享的计算环境，运行终端工具、无头浏览器、Codex 任务、MCPorter、Git 凭证助手、持久 `/workspace` 主目录，以及挂载统一云盘、Brain、Skills 与契约的 `/drive` FUSE 文件系统。 | [Agent Computer Worker](../agent-computer-worker/) |

此外，Agent 还可通过 [Deep Research](../deep-research-job/) 开展多信源交叉验证的深度调研，并借助 [浏览器自动化](../browser-automation/) 操作真实网页。

## 支持的决策与业务协作

Ankole 专为需要可核查证据与可验证交付物的关键数字工作而设计——例如跨竞争假设的行业深度调研、基于情景推演的产品与市场评估、代码可复现的深度数据分析，以及跨越 Pod 多维表、小应用、GitHub、Linear 与企业 IM 的日常持续运营。

根据任务形态，成员可让个人助理在自身权限内直接处理，通过 Peer A2A（`send_to_agent`）委派给专业 AI 同事，利用 [Workflow](../workflows/) 在多个隔离的子上下文中并行拆解分析，或配置零模型开销的小应用 Action 执行确定性巡检与同步。在整个运行过程中，Meta Ankole 与实时信号提供最新上下文，主体与 AuthZ 严格守护操作边界，观测到的真实结果则反哺后续决策。

## 当前状态

Ankole 已作为完整的企业数字总部与 Agent Harness 投入生产运行。企业可在自有基础设施上完整托管 Elixir 控制面、Pod 工作空间、Function Runtime（`ankole-function-runtime`）、Agent Computer Worker、Rust 内核、Meta Ankole、统一连接器与运维 Console。核心代码路径与关键状态机均经过形式化验证，端到端测试全面覆盖消息路由、云盘 ACL、故障恢复、并发控制与版本升级路径。

Ankole 不提供公共 API 向后兼容性承诺，版本发布可能包含破坏性变更。

## 下一步

请按照 [快速开始](../quickstart/) 部署实例，或阅读 [架构概览](../architecture/) 了解各组件的职责划分与协作边界。
