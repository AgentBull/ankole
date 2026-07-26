---
title: Codex 集成
description: Ankole 如何经 Codex app-server 跑代码密集的回合——CodexRunner 执行引擎、coding 模型档位、Console 里管理的 Codex 账户、后台 agent 任务如何落到一个 Codex 账户上。运维配什么，runner 拥有什么。
section: User guide
order: 37
---

Codex 是 Ankole 跑代码密集回合的方式。当一个回合要读改代码、跑测试、或驱动 shell 时，worker 把活交给 Codex app-server——一个基于 stdio 的 JSON-RPC 进程——而不是让聊天模型在对话里硬写代码。粘合层在 `app/agent_computer/src/tools/codex/`，背后的执行引擎是 `CodexRunner`。本页是运维视角：Codex 在 Ankole 里干什么、它的配置和账户在哪、你调什么。

先把决定性的性质说清楚：Codex 是代码密集工作的执行引擎，它跑在你在 Console 里管的 Codex 账户上。聊天模型仍拥有对话；要碰代码的那个回合归 Codex。

## Codex 在 Ankole 里干什么

当工作是代码密集的——读文件、跨文件改、跑构建、迭代测试——worker 就找 Codex。让聊天模型在对话里硬写既差又贵，于是回合改走 Codex app-server。这些件都在 `app/agent_computer/src/tools/codex/`：

- **`app-server-client.ts`**——经 stdio 上的 JSON-RPC 与 Codex app-server 对话。
- **`config.ts`**——读写 `{codexHome}/config.toml`（第 23 行）这份 Codex 配置。
- **`protocol.ts`**——客户端与服务端交换的 JSON-RPC 消息形状。
- **`runtime-config.ts`**——推导一个回合需要的运行时参数。
- **`sandbox.ts`**——代码运行所在的沙箱边界。

`CodexRunner` 是驱动这些的执行引擎。[后台 agent 任务](../background-agent-jobs/)要在任务里碰代码时，就跑在它上面，与发起回合隔离。

## coding 模型档位

一份 Ankole profile 带若干具名模型档位，服务代码密集工作的是 `coding` 档。回合一旦走 Codex，runner 查的就是 `coding` profile 档。在主 profile 上，要紧的 Codex 订阅字段是：

- **`model`**——Codex 跑的模型。
- **`model_reasoning_effort`**——推理力度，取 `minimal`、`low`、`medium`、`high`、`xhigh`、`max`、`ultra` 之一。
- **`fast_mode`**——是否开启快速路径。

模型全貌和档位如何对应工作，读 [Providers and models](../providers-and-models/)。

## Codex 账户

一次 Codex 回合跑在一个 Codex 账户上，而这些账户在 Console 里管，不在 worker 里管。路由是 `GET`、`POST`、`PUT`、`DELETE /codex-accounts`，由控制面 router 暴露。建账户、把任务指向它、轮换或吊销、列出已有的——都从 Console 界面做。路由形状和 Console 的其余界面，读 [Console operations](../console-operations/) 与 [Console API](../console-api/) 参考。

## 后台 agent 任务与 Codex

一个后台 agent 任务跑在一个 Codex 账户上，账户就标在任务上。任务 schema 带 `codex_account_id`，默认 `"aigateway"`。两个后果：

1. **要执行代码的任务落在 `codex_account_id` 指定的账户上。** 该账户缺失或被吊销，任务就跑不了；失败经[后台任务运维界面](../background-jobs-ops/)可见。
2. **默认账户 `aigateway` 是兜底。** 没显式指名账户的任务就跑在它上面。在依赖碰代码的任务前，确认它存在且健康。

任务生命周期、重试、以及如何发现一个因 Codex 账户不可用而失败的任务，读 [Background jobs（运维视角）](../background-jobs-ops/) 和 [Background agent jobs](../background-agent-jobs/)。

## 运维配什么

你只碰四样，且只有四样：

- **Console 里的 Codex 账户**——建、指向任务、轮换、吊销。
- **主 profile 上的 `coding` 档**及其 `model`、`model_reasoning_effort`、`fast_mode` 字段。
- **后台任务上的 `codex_account_id`**——当你想让它跑在指定账户上时。
- **托管 `{codexHome}` 与它指向的 `config.toml` 的 worker 环境**。

JSON-RPC 协议、沙箱边界、runner 如何推导运行时配置，都不归你调。它们是 worker 内部。

## 运维不该碰的东西

app-server 客户端、JSON-RPC 消息形状、沙箱执行、runner 的内部调度，都不是运维可调项。如果一次 Codex 回合失败，看它跑在哪个账户上、查了哪个 profile 档——都在 Console 一侧——而不是 worker 镜像里的某个开关。Codex 路径坏了，持久的修在 `app/agent_computer/src/tools/codex/` 下的 runner 代码里，不在某个环境变量里。

## 下一步

- 模型档位，以及 `coding` 如何放进更广的 profile，读 [Providers and models](../providers-and-models/)。
- 建立和轮换 Codex 账户，读 [Console operations](../console-operations/) 与 [Console API](../console-api/) 参考。
- 任务生命周期与 `codex_account_id` 字段，读 [Background agent jobs](../background-agent-jobs/) 和 [Background jobs（运维视角）](../background-jobs-ops/)。
- runner 及其工具，读 [Agent Computer](../agent-computer/) 开发者页。
