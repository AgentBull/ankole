---
title: 数据管线 agent
description: 如何设置一个运行数据转换管线的 agent——获取、转换、验证、交付——通过 shell 工具和 Jupyter kernel，作为后台任务。
section: Guides
order: 338
---

一个数据管线 agent 运行多步数据转换——获取源数据、清洗和转换、验证输出、交付结果。这种工作形态组合了 shell 工具（获取和运行脚本）与 Jupyter kernel（迭代数据检查），全在后台任务里。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：数据管线是**一个按序运行 shell 和 Python 步骤的后台任务，不是实时流式系统**。agent 获取、转换、验证、交付——任务完成时报告成功或失败。价值是 agent 能在某步失败时适应（重试、调整、升级），而非盲目运行固定脚本。

## 需要什么

- **绑定 `web_fetch` profile**——若数据源是公共 URL。数据库源则在 WorkerEnv 存连接串。
- **绑定 `primary` 和 `coding` profile**——agent 写或调整转换脚本。
- **启用 `jupyter-live-kernel` skill**——管线需要探索时（schema 检查、异常检测）用于迭代数据检查。
- **一个 signal binding** 到结果或失败报告的频道。
- **已配置 Codex account**——管线作为后台任务跑在 Codex account 上。

## 管线步骤

1. **获取**——agent 获取源数据：URL 用 `web_fetch`、数据库查询用 `command`（通过 `psql` 等 CLI）、或从 Agent Home 读文件。
2. **转换**——agent 运行 Python 脚本（通过 `command` 或 Jupyter kernel）清洗、过滤、聚合或重塑数据。
3. **验证**——agent 检查输出：行数、schema、汇总统计、空值检查。验证失败则 agent 报告且不交付。
4. **交付**——agent 把输出写成文件、发到频道、或通过 worker-file 路由上传。

## 使其成为 agent 的适应性

固定脚本做步骤 1-4，要么成功要么失败。agent 做步骤 1-4，且当某步失败时适应：

- **获取失败**——用不同 URL 重试，或报告"源不可用"。
- **转换失败**——检查数据形态（通过 Jupyter kernel），识别异常（新列、类型变化），调整脚本，重试。
- **验证失败**——报告什么失败了（行数降了 50%、schema 变了）并请求决定。

这种适应性是为什么这是 agent 任务而非 cron 脚本。agent 处理常见变化；它升级不常见的。

## 一个完整示例

设置一个每周数据管线，获取 CSV、清洗、交付摘要：

1. 绑 `web_fetch`（CSV URL）、`primary`/`coding`，启用 `jupyter-live-kernel`。
2. 创建 agent，撰写 `MISSION.md`："每周一，从 <url> 获取周指标 CSV。在 Jupyter kernel 中加载。清洗：删除 ID 为空的行、归一化日期列。验证：行数 > 100、关键列无空值。交付：把清洗后的摘要作为 Markdown 表格发到频道。验证失败时报告什么失败了且不交付。"
3. 加一条每周调度：`cron: "0 8 * * 1"`。
4. agent 把管线委派给后台任务。任务获取、加载、清洗、验证、交付。某步失败时 agent 适应或升级。

## 本指南不是什么

它不是流式数据平台——agent 跑批量转换，非实时管线。它不是 ETL 框架——agent 通过 shell 和 Jupyter kernel 运行脚本；它不替代 Airflow 或 dbt。它也不是数据质量监控系统——它验证自己管线的输出；它不跨系统监控数据质量。

## 下一步

- Jupyter kernel skill，读 [Jupyter 数据分析](../jupyter-data-analysis/)。
- shell 工具，读[代码执行](../code-execution/)。
- 后台任务，读[后台任务（运维视角）](../background-jobs-ops/)和[委派模式](../delegate-patterns/)。
- 调度，读 [Cron 调度](../cron-schedules-ops/)。
