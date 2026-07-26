---
title: 代码文档 agent
description: 如何设置一个读代码库并生成或更新文档的 agent——函数文档、API 参考、README 章节。
section: Guides
order: 346
---

一个代码文档 agent 读代码库、理解函数及其契约、生成或更新文档——函数级文档注释、API 参考、README 章节、或架构概览。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：agent **文档化代码做了什么，不是代码应该做什么**。它读实际实现、提取契约（参数、返回类型、副作用、错误情况）、写与代码匹配的文档。它不发明代码没有的功能，不文档化未实现的计划 API。文档是代码的投影，不是规格。

## 需要什么

- **WorkerEnv 里的 git 凭证**（`GIT_TOKEN`）。见 [Git 集成](../git-integration/)。
- **绑定 `primary` 和 `coding` profile**——读代码和写文档需要代码理解能力。
- **一个 signal binding** 到文档草稿发帖的频道。
- **repo 从 worker 可达。**

## 工作流

1. **文档任务到达**——"文档化支付模块的公共 API"、"为新 auth 流程更新 README"、或一条检查未文档化函数的调度。
2. **agent 克隆并读取**——`git clone`，然后通过 shell 工具（`read-file`、`command` 用 `grep` 或 `rg`）读相关文件。
3. **agent 提取契约**——每个函数或模块：参数、返回类型、副作用、错误情况、依赖。
4. **agent 写文档**——文档注释、Markdown 参考页或 README 章节，匹配项目现有文档风格。
5. **agent 发草稿**——或开一个带文档变更的 PR。

## 人设控制什么

- **范围**——"只文档化公共函数"vs"文档化每个函数包括私有辅助"。
- **风格**——"匹配 repo 里已有的 JSDoc/TSDoc 风格。用项目现有文档的语气。"
- **深度**——"每个函数一行摘要"vs"完整参数描述、示例、错误情况。"
- **格式**——"内联文档注释"vs"单独 Markdown 参考页。"
- **不做什么**——"不文档化计划功能。不加未测试的示例。不改代码。"

## "匹配现有"纪律

文档 agent 最重要的人设规则：**匹配现有风格**。若 repo 用带 `@param` 和 `@returns` 的 TSDoc，agent 写带 `@param` 和 `@returns` 的 TSDoc。若 README 用特定标题结构，agent 用那个结构。发明新文档风格比没有文档更糟——它碎片化代码库的语气。

## 一个完整示例

设置一个文档化 TypeScript 库公共 API 的 agent：

1. 在 WorkerEnv 存 `GIT_TOKEN`。
2. 创建 agent，绑 `primary`/`heavy`/`coding`。
3. 撰写 `MISSION.md`："克隆 repo。读 `src/` 里所有导出函数。每个提取契约：参数、返回类型、抛出错误、副作用。写匹配现有风格的 TSDoc 注释。把 diff 作为草稿发出来供复核。不改代码。不文档化未导出的函数。"
4. 在频道里："文档化 `docs/payments` 分支上支付模块的公共 API。"
5. agent 克隆、读、提取、写 TSDoc、发 diff。

## 委派大型代码库

大量未文档化函数的大型代码库，把读取和文档化委派给后台任务（见[委派模式](../delegate-patterns/)）。任务处理一批文件；任务完成时 agent 发完成的 diff。

## 本指南不是什么

它不是代码生成器——agent 写文档；它不写或改代码本身。它不是架构决策记录器——agent 文档化存在的东西；架构决策由人在 ADR 中写。它也不是代码审查的替代——文档是草稿；人验证它匹配代码的意图。

## 下一步

- git 设置，读 [Git 集成](../git-integration/)。
- shell 工具（读代码），读[代码执行](../code-execution/)。
- coding profile，读 [Provider 与模型](../providers-and-models/)。
- 委派，读[委派模式](../delegate-patterns/)。
