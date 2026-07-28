---
title: Prompt 组装
description: agent 每个回合看到的系统 prompt 如何构建——控制面数据提供者、两条传给 worker 的通道、worker 侧组装出最终 prompt 的过程。
section: Developer guide
order: 118
---

每个回合，worker 构建模型看到的系统 prompt。该 prompt 从回合时解析的 PostgreSQL-backed agent 上下文组装，在 worker 上渲染。本页文档化各部件如何从控制面到达 worker、每个部件是什么、组装发生在哪里。它建立在 [Agent Computer Worker](../agent-computer-worker/) 和 [AIGateway](../ai-gateway/) 页之上。

系统 prompt **在 Worker 上组装**，不在控制面。控制面通过两条通道提供 Agent 长期文档、Skill、Brain 快照、Agent 设置和聊天上下文；Worker 再把这些数据渲染成模型收到的最终 prompt。

## 两条数据通道

worker 通过两条路径从控制面接收上下文，各携带一类数据：

| 通道 | 携带什么 | 何时 |
|---|---|---|
| `turn_start.request_context` | agent 循环设置（`ai_agent.max_iterations`、`max_output_tokens`、`inactivity_timeout_ms`）、回合局部事实（信号、channel、回合种类） | 嵌入 TurnStart 信封，循环开始前 |
| `AgentConversationContextBroker` RPC | Agent 长期文档（`SOUL`/`MISSION`/`DESIGN`）、已启用 skill、Brain 快照（pinned memo + channel 条目）、安装时区、agent profile | worker 在循环开始时经 RuntimeFabric RPC 获取 |

划分是刻意的：回合局部事实走 `turn_start`，因为它们每回合变；会话范围上下文由 worker 经 broker 获取，因为它在一会话内跨回合稳定且 broker 缓存它。broker 模块文档明确："此 RPC 刻意不返回转写消息或回合局部请求上下文。转写历史归 AIGateway；回合局部事实走 `turn_start`。"

## 控制面提供什么

### Agent 长期文档

`AgentConversationContextBroker` 通过 `Library.list_agent_documents/1` 读取 Agent 的长期文档，并按 `soul`、`mission`、`design` 返回。`SOUL.md` 定义沟通与判断方式，`MISSION.md` 定义职责，`DESIGN.md` 提供视觉内容使用的设计系统。

### 已启用 skill

`Library.skills_for_system_prompt/1` 返回 agent 的有效 skill 集——默认再覆盖启用的 skill，带其描述和元数据。worker 用它们构建系统 prompt 的 skill 块，告诉模型它有哪些 skill、各自做什么。

### Brain 快照

`Brain.Snapshot.get_or_create/1` 解析会话的 Brain scope 并返回快照：agent 的 pinned memo（`agent_context`）和 channel 的持久上下文（`group_context`）。这些是已保存的上下文条目——agent 被告知记住的持久事实——不是完整 Brain 知识库。快照是投影，不是查询；召回（完整搜索）在循环中通过 Brain 工具发生，不通过此快照。

### Agent 设置（来自 AppConfigure）

`AgentConfig` 从 AppConfigure 解析循环级设置，快照进 `turn_start.request_context.ai_agent`：

- `ai_agent.max_iterations`（默认 90）——agent 循环的迭代预算
- `ai_agent.max_output_tokens`（默认 nil = 无显式上限）——每响应 token 上限
- `ai_agent.inactivity_timeout_ms`（默认 30 分钟）——回合可 inactive 多久

它们属于 actor 回合，不属于任何单次模型响应，所以走 `turn_start`。

## Worker 侧组装

worker 上的 `system_prompt.ts` 构建最终 prompt。其模块文档说明了设计："慢变指令在前；会话范围运行时、skill 和 Brain 快照构成后缀。" 各块按序：

1. **核心指令**——agent 的基础行为契约，从回合上下文组装。
2. **Agent 长期文档**——`SOUL`、`MISSION`、`DESIGN`，从 broker 响应渲染。
3. **持久上下文**——Brain 快照的 pinned memo 和 channel 条目，带指引渲染（"仅当条目仍然有效时使用……否则忽略"）。
4. **Skill**——已启用 skill 的描述，告诉模型可以够到什么。
5. **Channel 与运行时上下文**——当前 channel、工作空间路径、可用工具名。

worker 每回合从当前 PostgreSQL-backed 上下文重新渲染完整 prompt——它不信任缓存版本。AIGateway 保留先前请求指令供审计，但回合渲染当前状态。

## 不在系统 prompt 里的东西

- **转写历史**——归 AIGateway 的有状态 Responses；系统 prompt 不重复它。
- **回合局部观察**——信号、入境消息、用户当前输入。这些留在当前用户消息里，不在系统 prompt 里。
- **Brain 召回结果**——召回（完整搜索）在循环中通过 Brain 工具发生，不作为系统 prompt 块。快照是底；召回是顶。

这种分离让系统 prompt 稳定（它在人设/skill/记忆变化时变，不在会话增长时变），并让每回合载荷小。

## 本指南不是什么

它不是 prompt 工程教程——`system_prompt.ts` 里的字面字符串是与模型的契约，改它们是行为变更，不是文档变更。它不是 prompt 组装的控制面侧描述——组装在 worker 上，控制面的角色是提供数据。它也不是读 `system_prompt.ts` 的替代；本页是通往它的地图。

## 下一步

- 使用此 prompt 的 agent 循环，读 [Agent 循环](../agent-loop/)。
- 跑组装的 Agent Computer Worker，读 [Agent Computer Worker](../agent-computer-worker/)。
- 喂给持久上下文块的 Brain 快照，读 [Brain](../brain/)。
- skill 块，读 [Agent Library](../agent-library/)。
