---
title: 新人引导 agent
description: 如何设置一个帮助新团队成员上手的 agent——从 Brain 知识回答问题、指向文档、卡住时升级给 buddy。
section: Guides
order: 332
---

一个新人引导 agent 住在团队频道里，帮助新人找到方向——回答关于代码库、团队约定、设置流程、谁负责什么的问题。它是[客户支持 agent](../customer-support-agent/) 的向内特化版：客户是你的新队友。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：新人引导 agent 是**一个有知识、有耐心、永远不厌倦同一个问题的同事**。它从策展的 Brain 知识（你的 onboarding 手册、架构决策、团队约定）回答、指向正确的文档或人、新人卡住时升级给指定的 buddy。价值不在于聪明——在于始终可用。

## 需要什么

- **一个可用的聊天 binding** 到团队的 onboarding 频道（Slack、Lark、钉钉或 Teams）。
- **绑定 `primary`/`light`/`heavy` profile**，加 **`embedding`** 供 Brain 召回。
- **`unaddressed_group_message_policy: may_intervene`**——agent 应观察频道并在新人问它知道的东西时帮忙，不等 @。见[环境干预](../ambient-intervention/)。
- **Brain 知识已策展**——你的 onboarding 手册、设置指南、架构概览、团队约定，作为 source 上传并复核。见 [Brain source](../brain-sources/)和 [Brain 复核](../brain-review-ops/)。

## 三种行为

与支持 agent 相同的形态，为内部使用适配：

1. **回答**——新人问"如何设置开发环境？"或"谁负责支付服务？"时，从 Brain 知识回答并附文档链接。
2. **指向**——当答案是一个人不是文档（"我的第一个 PR 该给谁审？"），指向正确的人。在 Brain 里维护一条"谁负责什么"知识条目。
3. **升级给 buddy**——新人卡在 agent 不知道的东西上，或关于团队文化、薪酬、HR 时，升级给指定的 onboarding buddy。"我不确定这个——@buddy 能帮忙吗？"

## onboarding 与支持的区别

- **知识是内部的**——设置指南、架构决策、代码库约定、团队名册。这些是你上传和策展的 Brain source，不是面向客户的文档。
- **受众小且信任**——新人期望 agent 有用，不期望完美。升级是给同事，不是给工单。
- **问题重复**——每个新人都问同样的设置问题。Brain 召回让 agent 跨新人一致；dreaming 从它答不了的问题中提议新知识。

## 一个完整示例

在 Slack 上设置新人引导 agent：

1. 创建 agent，绑 profile（`primary`/`light`/`heavy`/`embedding`）。
2. 把 Slack binding 的策略设为 `may_intervene`。
3. 撰写 `MISSION.md`："你是 #new-hires 的 onboarding agent。从 Brain 知识回答设置、代码库、约定问题。当答案是人时指向正确的人。不知道或是 HR 问题时升级给 @buddy。要有耐心——不同人问同一问题仍是好问题。"
4. 把 onboarding 手册、设置指南、架构概览作为 Brain source 上传。运行学习。复核知识。
5. 策展一条"谁负责什么"知识条目——服务 owner、PR 审查轮值、on-call 日程。
6. 加一条月度 dreaming 运行，从 agent 答不了的问题中学习。

## "谁负责什么"条目

这是新人引导 agent 单一最有价值的 Brain 条目。作为策展知识维护：

- **服务 owner**——"支付服务由 @alice 负责。"
- **PR 审查**——"前端 PR 给 @bob，后端给 @carol。"
- **On-call**——"当前 on-call 轮值在日程文档里。"

新人问"X 的事该找谁？"时，agent 召回这条并指向正确的人。

## 本指南不是什么

它不是 HR 系统——agent 不管访问、配置或薪酬。它回答问题并指向人。它不是人工 buddy 的替代——agent 处理可重复的问题；buddy 处理上下文、文化、"我不确定该问谁"的时刻。它也不是静态 FAQ——Brain 知识通过 dreaming 和复核演进，所以 agent 的答案随它观察更多问题而改进。

## 下一步

- 它建立的支持 agent 模式，读[客户支持 agent](../customer-support-agent/)。
- Brain 知识策展，读 [Brain source](../brain-sources/)和 [Brain 复核](../brain-review-ops/)。
- 群消息策略，读[环境干预](../ambient-intervention/)。
- 首机器人设置，读[你的第一个 Slack 机器人](../slack-first-bot/)（或你平台的等价物）。
