---
title: 客户支持 agent
description: 如何设置一个观察支持频道、回答常见问题、需要时升级给人、并记住所学的 agent。
section: Guides
order: 330
---

一个客户支持 agent 盯着共享支持频道、从其知识回答常见问题、无法帮助时升级给人、并为下次记住所学。这是 Ankole 最高价值的模式之一——它组合了 signal binding、Brain 记忆、群消息策略、和"升级还是回答"的判断。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：支持 agent **观察、有用、且知道自己的界限**。它观察频道（`may_intervene`）、能答时答、不能时升级、永远不假装知道它不知道的东西。判断住 在人设里；记忆住在 Brain 里；升级是一条消息，不是安静失败。

## 需要什么

- **一个可用的聊天 binding**（Lark、Slack、钉钉或 Teams）。见各 adapter 指南。
- **绑定 `primary`/`light`/`heavy` profile。** 支持回答需要一个能推理客户问题的模型。
- **绑定 `embedding` profile。** Brain 召回用 embedding 找相关知识。
- **`unaddressed_group_message_policy` 设为 `may_intervene`。** agent 必须看到非 @ 消息才能观察频道。见[环境干预](../ambient-intervention/)。
- **Brain 知识已策展。** 把你的 FAQ、产品文档、已知问题作为 Brain source 上传、运行学习、复核提取的知识。

## 三种行为

支持 agent 做三件事，人设必须全部命名：

1. **回答**——客户问了一个 agent 知道的问题（来自 Brain 知识或产品文档），简洁回答附来源链接。
2. **升级**——agent 不知道，或问题关于账单争议、安全事件、或客户情绪激动时，升级给人。升级是频道里的一条消息："我不确定这个——@on-call 能帮忙吗？"
3. **保持安静**——频道只是闲聊、已有人在回答、或问题在 agent 范围之外。安静是正确行为，不是失败。

## 记忆循环

Brain 让支持 agent 随时间改进：

- **策展知识**——产品文档、FAQ、已知问题，通过 [Brain 复核](../brain-review-ops/)策展。回合中召回读取这些。
- **源聊天召回**——agent 能召回这个频道之前说过什么，所以它知道"我们昨天讨论过这个"。
- **Dreaming 提案**——Brain 的 dreaming 过程读取频道历史并提出新知识条目。人复核它们；被批准的扩展 agent 所知。

设一条每周 dreaming 运行（`POST /brain/dreaming-runs`）并复核提案。这就是 agent 从它观察到的对话中学习的方式。

## 一个完整示例

为 Slack 上的 SaaS 产品设置支持 agent：

1. 创建 agent，绑 profile（`primary`/`light`/`heavy`/`embedding`）。
2. 把 Slack binding 的 `unaddressed_group_message_policy` 设为 `may_intervene`。
3. 撰写 `MISSION.md`："你是 #help 的支持 agent。从 Brain 知识回答产品问题。升级给 @support-team 当：你不知道、是账单或安全、或客户沮丧。有人已在帮时保持安静。永远别猜——不确定就升级。"
4. 把产品文档作为 Brain source 上传、运行学习、复核知识。
5. 加一条每周调度跑 dreaming 并复核提案。
6. 观察一周，调人设的"何时回答 vs 升级"边界。

## 升级纪律

支持 agent 最难的部分是升级边界。太急——什么 都升级、不增值。太不情愿——回答不该答的、侵蚀信任。人设是杠杆：

- 命名 agent 处理的**话题**（产品功能、设置、常见错误）。
- 命名它总是升级的**话题**（账单、安全、数据丢失、法律）。
- 命名升级的**信号**（客户沮丧、反复追问、agent 自己不确定）。

在一周观察中调人设，不是第一天。

## 本指南不是什么

它不是聊天机器人教程——agent 通过其模型和知识推理客户问题，不是关键词匹配。它不是工单集成——Ankole 不替代你的工单系统；agent 在频道里升级给人，人用工单系统。它也不是人工支持的替代——它处理常见情形；难的仍需要人。

## 下一步

- 群消息策略，读[环境干预](../ambient-intervention/)和[团队助理](../team-assistant/)。
- Brain 知识，读 [Brain](../brain/)和 [Brain 复核](../brain-review-ops/)。
- 首机器人设置，读[你的第一个 Slack 机器人](../slack-first-bot/)（或 Lark/钉钉/Teams 等价物）。
- memory 工具，读 [Memory](../memory/)。
