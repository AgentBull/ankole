---
title: FAQ 机器人
description: 如何设置一个从策展的 Brain 知识回答常见问题的聚焦 agent——最简单有用的 agent，许多团队的正确起点。
section: Guides
order: 344
---

一个 FAQ 机器人是最简单有用的 Ankole agent：从策展知识回答问题、不知道时指向正确文档、在范围外保持安静。它是精简版[客户支持 agent](../customer-support-agent/)——不观察频道、不升级给多个人、不做 dreaming。就是：问题进来、从 Brain 回答。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：FAQ 机器人**仅 @ 唤醒、知识有界、对自身界限诚实**。被 @ 时回答、从 Brain 知识、答案不在那就说"我不知道"。它不猜、不搜网、不观察频道。

## 需要什么

- **绑定 `primary` profile**——回答问题需要推理。
- **绑定 `embedding` profile**——Brain 召回用 embedding 找相关知识条目。
- **一个 signal binding**，`unaddressed_group_message_policy: addressed_only`（或 `ignore`）——agent 在 @ 时醒来，不在每条消息上。
- **Brain 知识已策展**——你的 FAQ 条目、产品文档、常见问题答案，经复核和批准。

## 工作流

1. **有人 @ agent** 问一个问题。
2. **agent 召回 Brain 知识**——`memory_search` 找相关条目。
3. **agent 回答**——从知识，附来源文档链接。
4. **若答案不在 Brain**——agent 说"我没有这个的答案。试试问 @team 或查 <文档链接>。"

## 与支持 agent 的区别

| | FAQ 机器人 | 支持 agent |
|---|---|---|
| 在何时醒来 | 仅 @（`addressed_only`） | 任何消息（`may_intervene`） |
| 知识来源 | 仅 Brain 策展知识 | Brain + web 搜索 + session 上下文 |
| 升级 | "问 @team" | 按话题升级给特定的人 |
| 复杂度 | 最小——正确的起点 | 完整——观察、判断、升级 |

FAQ 机器人是你先建的。支持 agent 是在 FAQ 机器人回答得好、你想要它更主动时把它演化成的。

## 人设控制什么

- **范围**——"回答关于产品设置、定价、常见错误的问题。其他一律说不知道。"
- **格式**——"简洁回答（2-3 句）附完整文档链接。"
- **诚实**——"答案不在 Brain 时说'我没有这个的答案'。不猜。不搜网。"
- **语气**——"有用、直接、不废话。"

## 一个完整示例

为产品团队设置 FAQ 机器人：

1. 创建 agent，绑 `primary`/`light`/`embedding`。
2. 把 binding 的策略设为 `addressed_only`。
3. 撰写 `MISSION.md`："从 Brain 知识回答 @ 的问题。范围：产品设置、定价、常见错误。简洁回答附文档链接。不在 Brain 的说不知道。不猜。"
4. 策展 Brain 知识：前 20 条 FAQ、设置指南、定价页内容、错误参考文档。
5. 测试：@ agent 问"如何重置密码？"——它应从 Brain 回答并链到设置文档。

## 扩展知识

FAQ 机器人随知识增长而改进：

- **加新 FAQ**——当机器人答不了的问题揭示了缺口。把答案作为 Brain source 上传、运行学习、复核。
- **每周跑 dreaming**——从机器人收到的问题中提议新知识。
- **复核审计日志**——看问了什么问题、答案是否正确。

## 本指南不是什么

它不是搜索引擎——它从 Brain 知识回答，不从 web。它不是聊天机器人——它不做闲聊；它回答范围化的问题。它也不是完成品——它随知识增长改进，且应在团队准备好主动帮助时演化成支持 agent。

## 下一步

- Brain 知识策展，读 [Brain](../brain/)和 [Brain 复核](../brain-review-ops/)。
- 支持 agent（演化方向），读[客户支持 agent](../customer-support-agent/)。
- 首机器人设置，读[你的第一个 Lark 机器人](../lark-first-bot/)或 Slack/钉钉/Teams 等价物。
- binding 策略，读 [Signal binding](../signal-bindings/)。
