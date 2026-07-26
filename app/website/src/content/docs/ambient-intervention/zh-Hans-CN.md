---
title: 环境介入
description: Ankole agent 如何在一个没被 @ 的群聊里决定要不要开口——may_intervene 策略、轻量级环境回合、与 addressed_only、record_only、ignore 的对比，以及让该静默时静默的 durable-context 指引。
section: User guide
order: 38
---

`may_intervene` 是让 agent 在不被点名时也能开口的群聊策略。在[信号绑定](../signal-bindings/)上设它，一条没 @ 到 agent 的群消息就会产生一个 `may_intervene` 事件。agent 在该事件上醒来，读上下文，自己做决定——它不会自动回复。本页是运维视角：这策略做什么、agent 如何决策、它与其余选项有何不同。

先把决定性的性质说清楚：`may_intervene` 给 agent 的是选择，不是反射。它把 agent 叫醒，但 agent 有权保持沉默。决策由一个轻量级回合做出，该回合的全部职责就是权衡开口是否有益。

## 这策略做什么

在信号绑定上设 `unaddressed_group_message_policy: may_intervene`，会改变一条非点名群消息的去向。它不再被无视，而是产生一个 `may_intervene` 事件。agent 在该事件上醒来，跑一个回合，然后或开口、或按住。处理代码在 `core/turns/ambient_turn.ts` 与 `core/turns/ambient_recognizer.ts`。

与一次正常的点名回合的关键区分：agent 接到的指令不是"回复"，而是"决定要不要回复"。点名回合默认用户要答案；环境回合什么都不默认，开口的权利是它判断开口有益后才挣来的。

## agent 如何决策

环境回合比点名回合更轻。它读上下文、掂量对话是否需要它、然后可以选择沉默。它跑的指引也不同于点名回合。在 `core/turns/durable_context.ts` 里，`formatAmbientDurableContext` 函数为这次决策塑造上下文：

> Use this saved context only to decide whether to speak. You cannot retrieve memory; stay silent if missing or newer context could change the decision.

两个子句要紧。其一，agent 拿这份留存上下文只为决定是否开口——不为回答问题、不为采取行动。其二，若缺失的或更新的上下文可能改变决策，agent 就沉默。整体偏静：拿不准就不开口。

## 四种策略对比

`unaddressed_group_message_policy` 有四个取值，最清楚的理解方式是看一条非点名群消息在每种取值下的遭遇：

- **`may_intervene`**——产生一个 `may_intervene` 事件。agent 醒来并决定是否开口。这是唯一让 agent 拥有介入选择的策略。
- **`addressed_only`**——只有 @ 点名才唤醒 agent。非点名群消息什么也不做。
- **`record_only`**——agent 把消息镜像进自己的上下文，但从不醒来。它看得见频道，不对频道采取行动。
- **`ignore`**——agent 什么都看不见。消息根本不进 agent 的上下文。

按 agent 的角色挑策略。共享支持频道里的客户成功 agent 也许该用 `may_intervene`——它得能发现一个自己答得了的问题。发布说明 bot 该用 `addressed_only`——只有被叫到才说话。被动观察、攒上下文的 agent 该用 `record_only`。绝不该看见某频道的 agent 该用 `ignore`。

## 策略住在哪

策略设在信号绑定上，与 adapter、filters、`enabled` 开关并列。它是按绑定的，所以一个 agent 能在一个频道介入、在另一个频道只答点名。绑定模型、字段、如何创建或替换绑定，读 [Signal bindings](../signal-bindings/)。agent 的角色，以及它如何映射到一种策略，读 [Agents](../agents/) 和 [team assistant](../team-assistant/) 模式。

## 运维不该碰的东西

环境回合的处理、把消息判为 `may_intervene` 的 recognizer、durable-context 的格式化，都是 worker 内部。如果 agent 在 `may_intervene` 下说得太勤，修在 agent 的人设和策略选择里——见 [Agents](../agents/)——而不在某个 worker 开关上。让 agent 偏向沉默的那条 durable-context 指引，是 runner 的一部分，不是 Console 设置。

## 下一步

- 承载该策略的绑定、以及如何设置，读 [Signal bindings](../signal-bindings/)。
- agent 角色如何映射到群聊策略，读 [Agents](../agents/) 和 [team assistant](../team-assistant/) 模式。
- 跑环境回合、塑造其上下文的 worker，读 [Agent Computer](../agent-computer/) 开发者页。
