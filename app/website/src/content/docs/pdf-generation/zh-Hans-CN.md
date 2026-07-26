---
title: PDF 生成
description: 如何设置一个创建、检查和编辑 PDF 文件的 agent——pdf skill、它用的工具、完整示例。
section: Guides
order: 327
---

PDF 生成是常见的交付物——报告、提案、必须以 PDF 发出的格式化文档。Ankole 的 `pdf` skill 通过 worker 安装的 PDF 工具链（Pandoc、两个 PDF 引擎、Poppler、QPDF）处理它，并作为后台任务运行。本指南是一个 PDF 生成 agent 的实际形态。

先把决定性的性质说清楚：`pdf` skill 是**文件系统+工具 skill，不是模型功能**。agent 用 shell 工具运行 Pandoc 和 PDF 引擎；skill 的 `SKILL.md` 告诉它怎么做。没有 `generate_pdf` API 调用——它是经 shell 的文档制备，由 skill 引导。

## 需要什么

- **`pdf` skill 已启用。** 它是 `default_enabled: true`，所以除非覆盖，对每个 agent 都开。见 [Skills](../skills/)。
- **worker 镜像。** Agent Computer 镜像安装了 Pandoc、两个 PDF 引擎（Typst 和 LaTeX）、Poppler 和 QPDF。这些是镜像的一部分——你不用装。
- **绑定 `primary` model profile。** agent 写源内容（Markdown 或文档结构），然后 skill 的工具渲染成 PDF。

## skill 做什么

`pdf` skill 的 `SKILL.md` 覆盖三个操作：

- **创建**——写源内容（通常 Markdown），通过 Pandoc 和 PDF 引擎渲染成 PDF。skill 知道引擎选择、字体设置、输出路径。
- **检查**——用 Poppler 和 QPDF 验证生成的 PDF（页数、文本提取、字体嵌入）。发出前用它确认 PDF 有效。
- **编辑**——不重新生成整个文档，对现有 PDF 做文本修正。

skill 作为后台任务运行（`ankole-runtime: background_job`），所以长 PDF 渲染不阻塞会话。

## 一个完整示例

设置一个每周产 PDF 报告的 agent：

1. 确认 `pdf` skill 已启用（默认是）。
2. 创建 agent，撰写 `MISSION.md`："产出每周状态报告 PDF。从频道历史收集本周指标，用 Markdown 写报告，用 Typst 渲染 PDF，用 Poppler 验证，把 PDF 发到频道。"
3. 加一条每周[调度](../cron-schedules-ops/)。
4. 每次触发，agent 收集上下文、写 Markdown、通过 shell 调 `pdf` skill 的工具、验证输出、发文件。

## `design-md` 伙伴

若 PDF 需要视觉打磨——品牌色板、特定布局——把 `pdf` skill 和 `design-md` skill 配对。`pdf` skill 的 `SKILL.md` 说："若人已提供品牌色板或模板，优先匹配它。否则用 `design-md` skill 作为设计参考。"

## 本指南不是什么

它不是 Pandoc 或 Typst 教程——skill 知道工具调用；运维者的工作是定范围。它不是布局设计指南——视觉决策用 `design-md` skill。它也不是读 `pdf` skill 的 `SKILL.md` 的替代——那个文件是工具命令的权威参考。

## 下一步

- skill 系统，读 [Skills](../skills/)和[编写 skill](../writing-a-skill/)。
- skill 用的 shell 工具，读[代码执行](../code-execution/)。
- 后台任务，读[后台任务（运维视角）](../background-jobs-ops/)。
- 调度，读 [Cron 调度](../cron-schedules-ops/)。
