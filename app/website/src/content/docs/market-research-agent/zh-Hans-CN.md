---
title: 市场研究 agent
description: 如何设置一个监控竞品、跟踪市场变化、在要紧时报告的 agent——结合 web 工具、调度、Brain 记忆、和没事时保持安静的纪律。
section: Guides
order: 334
---

一个市场研究 agent 监控竞品、跟踪行业变化、在某事要紧时报告——不是每次扫描都报，只在信号越过人设定义的阈值时。本指南是那个 agent 的实际形态，结合 web 工具、调度、Brain 记忆、和保持安静的纪律。

先把决定性的性质说清楚：研究 agent 的价值是**信号优于噪声**。它定期扫描但选择性地报告。每次扫描都发帖的 agent 是噪声；只在竞品改了定价、发了功能、或做了公告时发帖的 agent 是信号。人设定义阈值；web 工具收集原材料；Brain 持有上次报告了什么，让 agent 能 diff。

## 需要什么

- **绑定 `web_search` 和 `web_fetch` profile。** agent 搜竞品动态并读找到的来源。见 [Web 工具](../web-tools/)。
- **绑定 `primary` profile**——用于综合和"有没有真的变了？"的判断。
- **绑定 `embedding` profile**——Brain 召回把这次扫描找到的和上次找到的对比。
- **一个调度**每天或每周触发。见 [Cron 调度](../cron-schedules-ops/)。
- **一个 signal binding** 到报告发帖的频道。

## 工作流

1. **调度触发**——快变市场每天，慢变每周。
2. **agent 搜索**——对每个跟踪的竞品或话题 `web_search`（"Acme 公司定价"、"Beta 公司产品发布"、"行业监管变化"）。
3. **agent 抓取**——对最相关的结果 `web_fetch` 读实际内容。
4. **agent 对比**——Brain 召回调出上次报告了什么。agent diff：这是新的，还是已经报告过？
5. **agent 决定**——若无实质变化，保持安静（`[SILENT]` 模式）。若有变化，起草报告：变了什么、为何要紧、附链接。
6. **agent 发帖（或不发）**——报告到频道，或安静。

## 安静模式

这是研究 agent 最重要的人设规则：**安静是有效的结果**。agent 扫描后没发现新东西，不应发"未检测到变化"——那是噪声。它应保持安静。只在有东西要报告时发帖。

人设应显式命名："若自上次扫描以来无实质变化，不发帖。安静是正确的。"

## Brain 增加什么

Brain 让研究 agent 跨扫描改进：

- **上次扫描记忆**——Brain 召回调出 agent 上次报告了什么，让它 diff 而非重复自己。
- **策展上下文**——竞品清单、要跟踪的话题、"什么算实质"的阈值，作为知识条目维护。
- **Dreaming 提案**——Brain 的 dreaming 读取扫描历史、提议新的跟踪话题或阈值。人复核它们。

## 一个完整示例

设置一个每周竞品跟踪 agent：

1. 绑 `web_search`（Jina Search）、`web_fetch`（Jina Reader）、`primary`、`embedding`。
2. 创建 agent，撰写 `MISSION.md`："每周跟踪 Acme 公司和 Beta 公司。查他们的定价页、changelog、新闻稿。只在有实质变化时报告（定价、新产品、收购、重大招聘）。无变化时保持安静。始终附链接。"
3. 加一条每周调度：`cron: "0 9 * * 1"`（周一 9 点）。
4. 策展 Brain 知识：竞品清单、当前定价（作基线）、实质变化阈值。
5. 第一次运行，agent 报告基线。后续运行，它 diff、只报告变化。

## 委派重扫描

竞品多或搜索深时，把扫描委派给后台任务（见[委派模式](../delegate-patterns/)）。任务做搜索-抓取循环；任务完成时 agent 综合 diff。这保持调度的回合短。

## 本指南不是什么

它不是 web 爬虫——`web_search` 和 `web_fetch` 读公共页；不绕过鉴权或限速。它不是市场情报平台——agent 收集和综合；不预测。它也不是"什么要紧"的人工判断替代——人设编码阈值；人随时间调它。

## 下一步

- web 工具，读 [Web 工具](../web-tools/)和 [Web 研究](../web-research/)。
- 调度，读 [Cron 调度](../cron-schedules-ops/)。
- Brain 记忆，读 [Brain](../brain/)和 [Brain 复核](../brain-review-ops/)。
- 委派，读[委派模式](../delegate-patterns/)。
