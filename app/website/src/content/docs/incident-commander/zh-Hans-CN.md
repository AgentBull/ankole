---
title: 事故指挥 agent
description: 如何设置一个在事故期间协调的 agent——跟踪时间线、汇总状态、保持频道对齐，自身不采取高风险动作。
section: Guides
order: 335
---

一个事故指挥 agent 在活跃事故期间住在事故频道里。它不修问题——它协调：跟踪时间线、为后来者汇总当前状态、指向 runbook、问"谁在做什么？"让人类响应者保持对齐。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：事故指挥 **协调，不修复**。它读频道、维护时间线、发状态摘要。人诊断和行动。agent 的价值是在混乱中保持每个人对齐，不是替代人类指挥。

## 需要什么

- **一个 signal binding** 到事故频道（Slack、Lark、Teams——团队在事故期间协调的地方）。
- **`unaddressed_group_message_policy: may_intervene`**——agent 必须看到事故频道的所有消息以跟踪时间线。见[环境干预](../ambient-intervention/)。
- **绑定 `primary` profile**——从快速移动的频道综合状态更新需要推理。
- **Brain 知识已策展**——你的事故响应 runbook、服务依赖图、升级树、通讯模板。

## 事故期间的三种行为

1. **跟踪**——agent 观察事故频道的每条消息、构建时间线：谁报告了什么、试了什么、什么有效、什么失败。
2. **汇总**——定期（或按需），agent 发状态摘要：当前状态、已知什么、在试什么、谁在做什么、下一个决策点。这是为后来者和指挥。
3. **指向**——agent 指向相关 runbook 条目、Brain 里的已知问题模式、或受影响服务的负责人。它不提议 runbook 之外的动作。

## 状态摘要

agent 最有价值的产出是**状态摘要**——一个结构化、简洁的事故进展快照。一个好模板：

```text
**事故状态 — <时间戳>**
- **影响**：<用户看到什么>
- **已知**：<已识别的根因，否则"调查中">
- **进行中**：<在试什么，由谁>
- **下一个决策**：<团队在等什么>
- **Runbook**：<指向相关 Brain 条目>
```

agent 按节奏发（critical 每 15 分钟、warning 每 30 分钟），或有人问"状态？"时发。它不在更新之间发——事故中的噪声代价高。

## 人设控制什么

- **节奏**——"critical 事故每 15 分钟发状态摘要，warning 每 30 分钟。"
- **升级**——"若 5 分钟内无人确认事故，page @on-call。"
- **边界**——"不提议重启、回滚或配置变更。指向 runbook；指挥决定。"
- **语气**——冷静、结构化、事实。无戏剧。

## 与告警分诊 agent 的关系

[告警分诊 agent](../alert-triage-agent/) 处理前五分钟——分类告警和起草 runbook。事故指挥 agent 处理后两小时——在事故确认后协调响应。它们是不同阶段的不同 agent，或同一 agent 带一个从分诊切换到协调的人设。

## 一个完整示例

在 Slack 上设置事故指挥 agent：

1. 创建 agent，绑 `primary`/`light`/`heavy`/`embedding`。
2. 把 Slack binding 的策略设为 `may_intervene`。
3. 撰写 `MISSION.md`："你是 #incidents 的事故指挥。从频道消息跟踪时间线。critical 每 15 分钟发状态摘要，warning 每 30 分钟。从 Brain 指向 runbook 和服务 owner。不提议动作——人类指挥决定。5 分钟未确认则升级给 @on-call。"
4. 策展 Brain 知识：事故 runbook、服务依赖图、升级树、通讯模板。
5. 事故开始时，团队 @ agent 或它从告警 webhook 醒来。它跟踪、汇总、指向，直到事故解决。

## 本指南不是什么

它不是自动修复系统——agent 协调；人行动。它不是人类事故指挥的替代——它通过跟踪和汇总辅助指挥；指挥仍做决定。它也不是复盘生成器——事故后团队写复盘；agent 的时间线是原材料，不是最终文档。

## 下一步

- 告警分诊阶段，读[告警分诊 agent](../alert-triage-agent/)。
- 事故响应（运维纪律），读[事故响应](../incident-response/)。
- 群消息策略，读[环境干预](../ambient-intervention/)。
- Brain 知识（runbook、依赖图），读 [Brain](../brain/)和 [Brain 复核](../brain-review-ops/)。
