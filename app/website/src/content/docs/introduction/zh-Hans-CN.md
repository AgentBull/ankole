---
title: 介绍
description: Ankole 是什么、它与私人聊天框有何不同，以及它支持的产品形态。
section: Getting started
order: 1
---

**Ankole 是一个自托管的 AgentOS，用来运行共享 AI 同事。**一套部署、多个 agent、真实的职责——运行在你自己掌控的基础设施上。

它把 AI 工作从私人聊天框里移出来，放进工作本来发生的地方：频道、代码仓库、日程、仪表盘、内部系统和长期项目上下文。一个 Ankole agent 拥有自己的身份、记忆、权限、工具、工作空间和责任边界——因此它能**持有正在进行的任务**，而不只是回答一条一次性消息。

[Claude Tag](https://claude.com/product/tag) 是一个容易理解的公开参照：在 Slack thread 里 tag 一个 AI，让它读取共享上下文、使用组织工具、记住 channel context，并在工作需要时间时主动跟进。Ankole 面向的是这个模式更开放、更泛化的版本：**不只 Slack，不只 Claude，不只一个 agent，也不把上下文交给某个厂商托管。**

Ankole 适合的是需要负责人承担的工作，而不只是需要一个回答的问题。一个适合 Ankole 的岗位应该有可见结果：代码合并、报告交付、客户问题处理、告警分流、市场变化被发现，或者 backlog 被推进。

## Ankole 与其它方案的区别

- **默认共享，而不是私人聊天。** Agent 进入团队可见的 channel 和 provider context；多个人可以观察、steer，并接着推进同一件事。
- **持久身份，而不是 prompt 约定。** 人类和 agent 都是 Principal，有权限授权和审计轨迹，因此 authorization 是 runtime 关注点。
- **长时 actor session，而不是 request/response。** Session 可以 wake、接收 signal、checkpoint、stream progress、hibernate，并带着上下文恢复。
- **部署者掌控上下文，而不是厂商托管。** 记忆、配置、凭证和审计都在你自己的基础设施里，是自托管部署。
- **Live 控制加上 durable 事实，而不是二选一。** ZeroMQ RuntimeFabric 承载 actor/worker/RPC 的 live 流量，PostgreSQL 仍然是 replay、fence 和 final commit 的来源。

## Ankole 增加了什么

- **多种来源。** IM、webhook、定时提醒、内部系统和未来 provider adapter 都会被归一化为 signal input。
- **多个 agent。** 一套 Ankole 部署可以托管多个 agent，它们有不同的 mission、访问权限、工具、记忆和出站身份。
- **Session actor。** 长期执行单元是 `actor_id = {agent_id, session_id}`。Session 是上下文、workspace state、steering、cancel 和恢复交汇的地方。
- **自己的上下文。** Conversation、model turn、summary、signal projection、决策、纠正和未来 domain record 都留在你的基础设施里。
- **部署者控制。** 访问控制、配置、Agent Library 默认值、Control Plane Plugin 启动状态、actor lease、outbox side effect 和 audit surface 都由部署和运维 Ankole 的人掌握。

## 产品形态

Ankole 应该让这些工作流变得自然：

- **coding agent** 关注 issue、复现 bug、修改代码、打开 draft PR，并报告哪些地方还需要人类决策；
- **customer-success agent** 观察共享群聊，记录重要事实，更新 work state，只在需要时私下升级；
- **research agent** 监控市场、政策、竞品和内部 notes，并在变化真正重要时跟进；
- **QA agent** 推进测试 backlog，收集证据，并把带上下文的 failure 交给人复核；
- **operations agent** 观察 alert、准备 runbook，并在采取高风险动作前请求批准。

共同模式不是“回答这个问题”，而是**“持有这个岗位、使用可用上下文、并由结果接受评价”**。

## 当前状态

Ankole 是一个完整、可自托管的 AgentOS，已在生产环境中运行：control plane、Agent Computer、kernel 和运维 console 端到端可用。公共 API 目前没有兼容性承诺，版本之间会有 breaking change。

## 下一步

- 按照[快速开始](../quickstart/)从源码在本地运行 Ankole。
- 阅读[架构概览](../architecture/)，了解 actor runtime 及其组件。
- 在 [GitHub](https://github.com/AgentBull/ankole) 上浏览源码、提交 issue。
