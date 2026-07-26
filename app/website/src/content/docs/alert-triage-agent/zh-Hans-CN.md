---
title: 告警分诊 agent
description: 如何设置一个盯着告警、分类严重度、起草 runbook、在采取高风险动作前升级给人的 agent——结合 webhook、Brain 知识、升级纪律。
section: Guides
order: 333
---

一个告警分诊 agent 盯着到来的告警、分类严重度、起草初步评估、准备 runbook、在任何高风险动作前升级给人。本指南是那个 agent 的实际形态——结合事件驱动触发、Brain 知识、先升级纪律。

先把决定性的性质说清楚：agent **分诊，不在无批准下修复**。它读告警、分类、收集上下文、提议动作。任何高风险动作前人批准。agent 的价值是评估速度，不是行动自主。

## 需要什么

- **一个 webhook binding**——告警作为 webhook 事件通过 `signals_gateway.webhook_handler` plugin 到达，或作为监控频道里的消息。见[自动化蓝图](../automation-blueprints/)。
- **绑定 `primary` profile**——分诊需要推理告警的上下文和严重度。
- **`web_search`/`web_fetch` profile（可选）**——查错误消息或公开文档中的已知问题。
- **Brain 知识已策展**——你的 runbook、已知问题模式、服务依赖图、on-call 名册。

## 分诊工作流

1. **告警到达**——通过 webhook 或频道消息（PagerDuty、Datadog、Grafana、自定义监控）。
2. **agent 分类**——严重度（critical/warning/info）、受影响服务、影响范围。Brain 知识提供服务依赖图和已知问题模式。
3. **agent 收集上下文**——读近期日志（若可访问）、查 Brain 找类似过往事故、搜错误消息（若不熟悉）。
4. **agent 起草 runbook**——查什么、试什么、不碰什么。来自 Brain 知识和告警细节。
5. **agent 升级**——把分类和 runbook 发到 on-call 频道，请求批准后再行动。"这看起来像数据库连接池耗尽。Runbook：查 `pg_stat_activity`、考虑重启 worker。要我继续，还是你来处理？"

## 人设控制什么

人设（`MISSION.md`）是安全边界：

- **严重度阈值**——"影响用户可用性的告警分类为 critical；内部指标为 warning；容量通知为 info。"
- **提议什么、做什么**——"提议诊断和非破坏性检查。不经明确人批准，永远不提议重启、migration 或配置变更。"
- **升级目标**——"critical 升级给 @on-call；warning 发到 #ops；info 静默记录。"
- **已知问题快捷路径**——"若告警匹配 Brain 里的已知问题模式，指向已知修复，跳过完整分诊。"

## 已知问题模式

分诊最有价值的 Brain 知识是**已知问题模式**：从症状（错误消息、指标阈值）到诊断和修复的映射。在 agent 遇到事故时策展这些：

- "若错误是端口 5432 上的 `ECONNREFUSED`，检查 PostgreSQL 是否在运行——见数据库 runbook。"
- "若 `memory_usage` 指标超过 90%，检查 worker 内存泄漏——重启 worker pod。"

每条已知问题条目让 agent 跳过完整分诊、直接指向修复，在重复事故上省分钟。

## 一个完整示例

为 Kubernetes 部署设置告警分诊 agent：

1. 创建 webhook handler plugin（或绑到监控频道），把告警作为 actor 事件投递。
2. 创建 agent，绑 `primary`/`light`/`heavy` + `web_search`（查错误）+ `embedding`（Brain 召回）。
3. 撰写 `MISSION.md`："在 #on-call 分诊告警。分类严重度、从 Brain 收集上下文、起草 runbook。任何行动前升级给 @on-call。已知问题快捷路径：先查 Brain。"
4. 策展 Brain 知识：服务依赖图、前 5 类事故的 runbook、on-call 名册。
5. 发一条测试告警；观察 agent 分类、起草、升级。
6. 每次事故后，把模式作为已知问题条目加进 Brain。

## 本指南不是什么

它不是自动修复系统——agent 提议；人批准。它不是监控替代——你的监控栈（Prometheus、Datadog、CloudWatch）检测问题；agent 分诊检测到的东西。它也不是人工 on-call 的替代——agent 处理评估的前五分钟；人处理决策和行动。

## 下一步

- webhook 触发，读[自动化蓝图](../automation-blueprints/)。
- Brain 知识策展，读 [Brain source](../brain-sources/)和 [Brain 复核](../brain-review-ops/)。
- 事故响应（分诊后发生什么），读[事故响应](../incident-response/)。
- 升级纪律，读[客户支持 agent](../customer-support-agent/)（同形态、不同领域）。
