---
title: PDF 生成
description: 配置 Agent 创建、校验与编辑 PDF 文档——涵盖 pdf Skill、底层工具链与完整示例。
section: Guides
order: 306
---

报告、提案以及各类正式对外文稿，往往都需要以排版规范的 PDF 格式交付。Ankole 的 `pdf` Skill 调用 Worker 内预装的 PDF 工具链（Pandoc、两套 PDF 排版引擎、Poppler 与 QPDF），并以常驻后台任务的方式完成文档渲染。本文将介绍这类 PDF 生成 Agent 的实际配置与工作方式。

首先要明确一点：`pdf` Skill 属于**基于文件系统与命令行工具的 Skill，而非模型内置接口**。平台上并不存在名为 `generate_pdf` 的专用 API——Agent 会按照 `SKILL.md` 中的作业指引，通过 Shell 工具调用 Pandoc 与排版引擎完成文档制作。

## 需要什么

- **启用 `pdf` Skill。** 该 Skill 默认开启（`default_enabled: true`），只要未手动关闭，所有 Agent 均可直接使用。详见 [Skills](../skills/)。
- **准备 Worker 镜像。** 官方 Agent Computer Worker 镜像已预装 Pandoc、两套 PDF 引擎（Typst 与 LaTeX）、Poppler 以及 QPDF，开箱即用，无需另行安装。
- **绑定 `primary` 模型档案。** 由主模型负责撰写源文稿（Markdown 或结构化源文件），再交由工具链渲染为 PDF。

## skill 做什么

`pdf` Skill 的 `SKILL.md` 定义了三类核心操作：

- **创建文档**：先编写源内容（通常为 Markdown），再调用 Pandoc 与 PDF 引擎渲染输出，涵盖引擎选型、字体配置与输出路径管理。
- **质量检查**：使用 Poppler 与 QPDF 校验生成的 PDF（核对总页数、文本可提取性及字体嵌入情况），确保正式发出前文件完整可用。
- **局部编辑**：在无需重头渲染整份文档的前提下，对已有 PDF 执行局部文本修正。

由于该 Skill 以常驻后台任务运行（`ankole-runtime: background_job`），即便渲染长篇复杂文档也不会阻塞当前对话会话。

## 一个完整示例

下面配置一个每周自动生成 PDF 状态周报的 Agent：

1. 确认 `pdf` Skill 已启用（默认开启）。
2. 创建 Agent 并编写 `MISSION.md`：“每周生成一份 PDF 格式的状态报告：从频道历史记录中汇总本周指标，以 Markdown 撰写正文，使用 Typst 渲染为 PDF，通过 Poppler 校验无误后将文件发送至频道。”
3. 添加一条每周定时触发的 [计划任务](../schedules/)。
4. 每次计划任务触发时，Agent 都会自动汇总上下文、撰写 Markdown 源稿、在 Shell 中调用 `pdf` Skill 工具链渲染并校验成品，最后将 PDF 附件发到指定频道。

## `design-md` 伙伴

如果生成的 PDF 需要更讲究的视觉呈现（例如贴合品牌色板或采用特定版式），可以将 `pdf` Skill 与 `design-md` Skill 搭配使用。正如 `pdf` Skill 的 `SKILL.md` 所约定的：“若用户已提供品牌色板或现成模板，优先严格对齐；否则参考 `design-md` Skill 完成版面设计。”

## 本指南不是什么

- **不是 Pandoc 或 Typst 语法教程**：具体命令行调用方式已内置在 Skill 指引中，运维人员只需界定业务需求与交付标准。
- **不是版式设计指南**：涉及视觉风格与排版规范时，请配合 `design-md` Skill 使用。
- **不替代阅读 `SKILL.md`**：关于底层工具命令的完整权威说明，仍以 `pdf` Skill 自带的 `SKILL.md` 为准。

## 下一步

- 深入了解 Skill 机制，请参阅 [Skills](../skills/) 与 [编写 skill](../writing-a-skill/)。
- 了解 Skill 底层依赖的 Shell 工具，请参阅 [代码执行](../code-execution/)。
- 了解后台执行机制，请参阅 [后台 Agent 任务](../background-jobs/)。
- 了解如何配置定时触发，请参阅 [计划任务](../schedules/)。
