---
title: 多 agent 模式
description: 一套 Ankole 部署上多个 agent 如何协作——独立 Principal、共享频道、共享记忆、人在环中的协调模型。没有 agent 间 RPC。
section: Guides
order: 317
---

一套部署上有不止一个 agent 时，问题是它们如何协作。本页命名 Ankole 实际支持的模式——并明确说出它不支持的那一种，因为那是最容易假设、也最容易搞错的。

先把决定性的性质说清楚：**没有 agent 间 RPC。** agent 不把彼此当工具调用。它们是独立的 Principal，有独立的 session、独立的记忆、独立的权限，通过共享面协作——人中介的频道、刻意共享的记忆、一个 agent 委派给它自己拥有的后台任务。如果你的设计需要一个 agent 同步调用另一个，重新设计；那条路径不存在。

## "不止一个 agent"实际意味着什么

每个 agent 是一个 Principal。各自有：

- **signal binding**——binding 以 `{agent_uid, binding_name}` 针对一个 agent，所以同一聊天平台里的两个 agent 是两个 binding、两个身份、两种回复形态。
- **session**——actor 是 `{agent_uid, session_id}`；一个 agent 的回合看不到另一个 agent 的 session。
- **记忆**——Brain scope 按 agent 派生，从会话声明来。一个 agent 知道的，另一个不知道，除非记忆被显式共享。
- **权限**——AuthZ 授予按 Principal。两个 agent 恰好拥有各自被授予的权限，不多。

这种分离是重点。客户成功 agent 和代码 agent 是不同的人，并保持那样。

## 模式 1：共享频道，人中介

两个 agent 绑到同一频道，各按 @ 唤醒。频道里的人决定跟谁说话；agent 之间不互相对话。

- **形态**：agent A 绑该频道，agent B 绑同一频道（不同 adapter 应用或不同 bot 身份）。人 @ A 或 B；被 @ 的 agent 醒。
- **协调**：人。"A，总结这个；B，拿总结开个 PR"是人发的两个 @，不是 agent 间的交接。
- **适合**：一个有通用助理和专家（代码、研究）的团队频道——人选对的那个。

这是最简单、通常也最对的多 agent 模式。它保持每个 agent 的身份和记忆干净，并让人对"哪个 agent 做什么"负责。

## 模式 2：共享记忆，独立 agent

两个 agent 需要知道同样的持久事实——团队的栈、已做的决定、术语表——但用途不同。用 Brain 共享存储。

- **形态**：Brain 知识范围限定到 `brain-shared` owner，两个 agent 通过各自的 scope 声明可读。每个 agent 仍各有自己的会话记忆；共享行是两者都能看到的策展事实。
- **协调**：共享的知识行。人复核进共享 Brain 知识的变更，对两个 agent 在下次召回时可见。
- **适合**：一个研究 agent 和一个代码 agent，都需要知道"这些是我们用的库"。

共享存储用于*经策展、经复核*的事实——不是让一个 agent 写进另一个的工作记忆。写入权限模型仍适用：dreaming 提案是 dreaming 写入，如此标注。

## 模式 3：委派工作，单一 owner

一个 agent 把长工作交给后台任务，任务作为同一个 agent 运行——不是作为另一个。这是[委派模式](../delegate-patterns/)的形态；是单 agent 委派，不是多 agent 协作，但它是人们想象"agent 协作"时伸手拿的模式。

- **形态**：agent A 调 `create_background_job`；任务的 `agent_uid` 和 `owner_session_id` 属于 A；任务完成时唤醒 A 的 session。
- **不是多 agent**：任务是 A 的工作、在 A 的工作空间、在 A 的权限下。若想让结果到达 agent B，人读 A 的结果并 @ B——模式 1 的人中介形态。

这值得直说，因为"委派给另一个 agent"是人们假设存在的设计。它不存在；委派是给任务，不是给对等 agent。

## 模式 4：调度扇出

一个 schedule 触发一个 agent，后者产出若干 agent 消费的东西——一份每日简报，人再路由到多个频道，每个由不同 agent 服务。

- **形态**：agent A session 上的 cron schedule 产出摘要；A 发帖；其他频道里的人或 schedule 接住。每个下游 agent 是自己的 binding、自己的 session。
- **协调**：发出来的产物（摘要），不是 agent 间消息。
- **适合**：一个研究者，几个按频道的呈现者。

这是带一个调度生产者的模式 1。协调产物是发出来的文本，不是 agent 间调用。

## 何时会想要真正的 agent 间

当一个 agent 的输出是另一个 agent 的输入、同步、中间无人时，你会想要它。Ankole 按设计不支持：人在环中是模型的属性，不是要绕开的限制。如果你确实需要一串 agent 调 agent 的流水线，你要的是单个 agent，其人设和工具覆盖整条流水线——一个 Principal、一个权限面、一套记忆——而不是一张互相说话的 agent 网。

## 运维多个 agent

- **按 agent 最小权限。** 每个 agent 只得所需授予。见[安全加固](../security-hardening/)。
- **按 agent model profile。** 专家可以跑比通用助理更重的 `primary`。见[成本管理](../cost-management/)。
- **按 agent 人设。** 每个 agent 的 `MISSION`/`SOUL`/`DESIGN` 点名其范围，包括何时交给人而非作答。
- **按 agent 观察。** [可观测性](../observability/)界面按 agent（`/agents/:agent_uid/...`），你能看到各自在做什么而不混淆。

## 本指南不是什么

它不是 agent 间协议目录——没有，添加它们不是受支持的扩展。它不是让 agent 共享 session 或权限的方式；那些按设计按 Principal 限定。它也不是单 agent 指南的替代；几乎每个多 agent 部署是几个恰好共享频道或记忆存储的单 agent 部署，单 agent 模式才是活所在。

## 下一步

- 单 agent 基础，读 [Agent](../agents/)和[你的第一个 Lark 机器人](../lark-first-bot/)。
- 共享记忆，读 [Brain](../brain/)（`brain-shared` owner）。
- 委派（单 agent），读[委派模式](../delegate-patterns/)。
- 按 agent 权限，读 [Principal 与 AuthZ](../principal-authz/)。
