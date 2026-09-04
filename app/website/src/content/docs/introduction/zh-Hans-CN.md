---
title: 介绍
description: 介绍 Ankole Agent Harness、公司大脑和私有部署实例的工作方式。
section: Getting started
order: 1
---

**Ankole 是配备公司大脑的开源 Claude Code 替代方案，也是一套企业级 Agent Harness。**

实时信号唤醒 Agent。Agent 使用共享知识、企业权限和 Agent Computer 工作环境执行长任务。进程发生故障后，任务可以恢复。

模型根据收到的上下文推理。Harness 选择与任务相关且当前有效的企业事实，执行访问规则，选择可用能力，在故障后恢复任务，并记录结果供后续决策使用。

## Harness 提供的能力

- Brain 记录知识的来源、时间、持有者、置信度、冲突和可见范围。
- 系统保留证据、不确定性、竞争假设和信息缺口，供人工复核。
- 消息、计划任务、Webhook 和外部事件会唤醒负责该工作的 Agent。
- 身份、AuthZ、审批节点、审计记录和升级路径限定每个 Agent 可以执行的操作。
- 任务可以连续运行数小时或数天，在执行期间接收新输入，并在进程故障后恢复。任务完成后，结果会发送到发起任务的上下文。
- 系统会在下一次决策前用人工纠正和实际结果更新公司大脑。

## 一个实例包含哪些部件

下文使用以下核心概念。

| 部件 | 说明 | 详见 |
|---|---|---|
| **Agent** | 具备明确使命、授权、工具和对外身份的工作主体。可编辑文件定义 Agent 的使命与交付标准。一个部署实例可以包含多个 Agent。 | [Agent](../agents/) |
| **Brain** | 共享的公司知识层。Brain 保留来源、结论、时间、置信度、冲突和可见范围，让获授权的 Agent 使用同一份当前企业上下文。 | [Brain](../brain/) |
| **会话（Session）** | 承载上下文、工作区状态、运行中引导、取消和恢复的执行单元。 | [Actor Runtime](../actor-runtime/) |
| **信号路由规则** | 将指定 Agent 连接到信号源，并定义 Agent 在该信号源中的操作范围。 | [信号路由规则](../signal-bindings/) |
| **后台任务** | 独立于发起会话运行数小时的任务。任务完成后，结果会发送到发起任务的频道。 | [Background Agent Jobs](../background-agent-jobs/) |
| **技能** | 针对特定工作的标准作业程序。Agent 可以提出改进方案，经人工批准后在后续会话中生效。 | [Skills](../skills/) |
| **主体（Principal）** | 人员和 Agent 都以 Principal 作为权限主体。运行时对每个 Principal 应用权限与审计规则。 | [主体与 AuthZ](../principal-authz/) |
| **Agent Computer Worker** | 运行 LLM 循环、工具调用、文件管理、终端状态与流式输出的执行环境。 | [Agent Computer Worker](../agent-computer-worker/) |

Agent 还可以通过 [Deep Research](../deep-research-job/) 完成长时间、多来源调研，并通过 [浏览器自动化](../browser-automation/) 操作真实网页。

## Ankole 支持的决策工作

Ankole 适用于能通过数字系统执行，并产生可供检查的证据和实际结果的决策工作。

典型场景包括比较竞争假设的行业研究、使用情景模型的产品与市场选择，以及采用可复现方法并列出备选因果解释的深度数据分析。

一个 Agent 可以负责整项决策。需要降低错误之间的相关性时，Workflow 可以将工作分配给多个 Agent，每个 Agent 使用独立上下文。

企业知识和信号提供上下文。企业权限规则限定 Agent 可以执行的操作。证据和实际结果更新后续决策所用的知识。

## 当前状态

Ankole 已在生产环境中运行，是一套完整的企业级 Agent Harness。企业可以在自己的基础设施上托管控制面、Agent Computer Worker、内核、公司大脑和运维控制台。

公共 API 的兼容性契约仍在制定。版本迭代中可能包含破坏性变更。

## 下一步

按照 [快速开始](../quickstart/) 在本地部署 Ankole。[架构概览](../architecture/) 说明各组件的职责和边界。
