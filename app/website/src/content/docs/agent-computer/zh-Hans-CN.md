---
title: Agent Computer
description: Bun + TypeScript 执行底座——模型循环、工具、文件、终端状态与流式输出如何在贴近工作空间的 worker 内运行，以及把一个 worker 绑到一个 activation 上的隔离栏。
section: Concepts
order: 14
---

Agent Computer 是执行底座。一个 session 被唤醒时，Actor Runtime 把一个带隔离栏的回合交给一个 worker；Agent Computer worker 跑这个回合——模型循环、工具、文件与终端工作、流式输出——再把结果交回去。本页对照 `app/agent_computer` 里的真实代码，画出这个 worker。

先把决定性的性质说清楚：worker 拥有实时执行和可重建的 worker 本地状态，仅此而已。持久状态——转写、隔离栏、最终提交——留在控制面。worker 是可替换的，一个迟到或走偏的 worker 写入会撞上隔离栏失败并被丢弃。

## 归属边界

worker 自己的契约里把这条划分写得清清楚楚。Agent Computer 拥有实时执行和可重建的 worker 本地状态。Elixir 控制面拥有 PostgreSQL 状态、actor 与 delivery 隔离栏、最终提交权、provider 出箱、运行时凭证和恢复事实。worker 不得擅自创造持久的控制面状态。

实际排除了什么：`DATABASE_URL`、`ANKOLE_AGENT_UID`、`ANKOLE_SESSION_ID` 和 `ANKOLE_ACTOR_EPOCH` 不是 worker 的输入。actor 身份通过 `turn_start` 到达，不在环境变量里。worker 用一个 `WORKER_ID`、一个带着 worker 认证 key 的 `RUNTIME_FABRIC_URL`，以及 `ANKOLE_AGENTS_ROOT` 向 RuntimeFabric 鉴权。它不持有数据库连接，也不决定自己在替谁做事。

## 回合隔离栏

worker 跑的每一个回合，都由一个 `ActorTurnRef` 钉住，它带三个字段——`activation_uid`、`actor_epoch` 和 `actor_event_id`。一次 worker 执行恰好处理一个 `actor_event_id`。worker 把内存中的活跃回合状态以 `${activation_uid}:${actor_event_id}` 为键，它发回控制面的每一个信封都带着这个 ref。

这就是 [Actor Runtime](../actor-runtime/) 三重隔离栏在 worker 那一侧的样子。控制面把每一个进来的 worker 写入，拿去和 activation、epoch 以及 delivery 行核对；如果 worker 的 ref 不再匹配——因为 activation 被取代、租约过期，或事件以更高的 epoch 被重试——这次写入被当作过期拒绝。worker 没有机会向一个它已经不再拥有的回合提交。

## 模型循环

agent 循环是一个由 worker 驱动、跑在 AIGateway 有状态传输之上的 Responses 循环，并且它刻意很小。四步：

1. 通过一个回合范围内的 OpenAI Responses 适配器调用模型。
2. 如果响应带有 function-call 项，在本地执行它们。
3. 通过 AIGateway 记录 function-call 输出。
4. 从记录下的日志锚点继续，直到不再有 function-call 项返回。

worker 拥有循环的终止和本地的迭代预算。它**不**拥有历史扩展、压缩、续接锚点或持久的响应状态——那些都留在 AIGateway。循环结束时，结局是两者之一：`loop_finished`（模型返回时不再有工具调用）或 `iteration_exhausted`（worker 触及迭代上限，于是模型被轻推去综合一个最终答案，而不是继续调用工具）。worker 把整回合的结局报告给控制面；控制面把它记下来。

## 工具：在 worker 里跑的是什么

工具是模型在一个循环里能驱动的本地动作。worker 把它们按类别交付，每一类背后都是真实的 worker 代码：

- **Computer**——shell 命令（在 bubblewrap 约束下）、文件读取与打补丁、apply-patch，以及驱动真实浏览器桌面的 v4a computer-use 工具。终端状态和文件编辑就在这里。
- **Web**——web 搜索和 web 抓取，经 worker 路由。
- **Brain**——回到长期记忆里的召回与知识工具。
- **Memory、schedule、todo、clarify**——agent 用来规划、推迟、提问的那些较小的结构化工具。
- **Codex**——CodexRunner 任务工具，用于把工作委派给一个后台 Agent 任务。
- **Library 与 MCP**——访问 agent 已启用的 skill，以及原生 MCP server。
- **Background Agent Job**——创建或续接持久任务的交接工具。

worker 产出的每一次工具结果，都作为 function-call 输出通过 AIGateway 记录，而不是直接提交。模型看到结果；控制面决定什么才持久。

## 文件系统契约

持久、共享、可写的运行时挂载是 `/agents`，按 actor key 布局：

```text
/agents/<agent-key>/
├── .codex/
├── SOUL.md
├── MISSION.md
├── DESIGN.md
├── user-files/
├── installed-skills/
├── sessions/<base64url-session-id>/
└── jobs/<job-id>/
    ├── .codex/config.toml
    ├── .ankole/skills/
    └── temp/
```

模型可见的绝对路径就是容器路径——worker 不为模型翻译路径。人设文档（`SOUL.md`、`MISSION.md`、`DESIGN.md`）就是 [Agent Library](../agent-library/) 暴露的那些 agent 拥有的库文档；`installed-skills/` 是 agent 安装的 skill bundle 所在；`sessions/` 和 `jobs/` 是按 session 和按任务的工作空间。文件在控制面之间双向传输，走的是一条专用的 file lane，带自己的编解码和路径安全检查，不走 RPC lane。

## 流式与进度

回合跑着的时候，worker 以尽力而为、不重叠的信封发布进度——每隔一段时间一个检查点，有值得说的内容时附上一段活动摘要。进度刻意不是一种持久机制：一次卡住的进度发送不得堆起定时器，也不得阻塞它所描述的那个循环。模型和工具产出的流式输出，经同一组 RuntimeFabric lane 流回；什么成为持久，由控制面在提交时决定，而不是由 worker 边流边定。

worker 还发布一条很小的准入提示——从它内存状态得出的剩余回合容量——好让控制面避免把工作发给一个已满的进程。调度始终归控制面；提示只是提示。

## Agent Computer 不是什么

它不是一个独立本地 CLI；它跑在 Linux worker 镜像里，后者提供原生 kernel 绑定、bubblewrap、Chromium、Python/Jupyter 与文档工具、ZeroMQ，以及共享的 agent 文件系统。它不是用来创造持久状态的地方——worker 的职责是跑一个带隔离栏的回合并回报，每一项持久的决定都归控制面。它也不是第二个调度器；唤醒、租约、重试都归 Actor Runtime。边界是干净的：控制面拥有回合的身份与事实，worker 拥有回合的执行。

## 下一步

- 把一个 worker 钉到一个 activation 上的隔离栏，读 [Actor Runtime](../actor-runtime/)。
- 循环所调用的有状态 Responses 传输，读 [AIGateway API](../ai-gateway/)。
- worker 从 `/agents` 读到的 skill 与文档，读 [Agent Library](../agent-library/)。
