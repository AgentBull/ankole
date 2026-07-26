---
title: 代码审查工作流
description: 如何设置一个审查 pull request 的 agent——克隆、跑测试、检查 diff、以恰当的人工升级级别报告发现。
section: Guides
order: 329
---

一个代码审查 agent 盯着 PR，克隆分支、跑测试、检查 diff、报告发现——变更有风险或测试失败时升级给人。本指南是那个工作流的实际形态，从设置到审查循环。

先把决定性的性质说清楚：agent 通过**与开发者相同的 shell 工具**审查代码——git、测试运行器、文件读取——由其人设和 skill 引导。没有特殊的"代码审查 API"；agent 克隆、diff、测试，然后把审查写成消息。人决定合并什么。

## 需要什么

- **WorkerEnv 里的 git 凭证。** 存 PAT 或 SSH key（`PUT /worker-envs/GIT_TOKEN`）。见 [Git 集成](../git-integration/)。
- **绑定 `coding` model profile。** 代码审查受益于为代码调优的模型。
- **一个 signal binding** 到 PR 通知到达的频道（webhook、定期检查、或人 @）。
- **repo 从 worker 可达。**

## 工作流形态

1. **PR 事件到达**——通过 webhook（见[自动化蓝图](../automation-blueprints/)）、检查开放 PR 的调度、或人问"审查 PR #42"。
2. **agent 克隆分支**——`git clone`、`git fetch origin pull/42/head:pr-42`、`git checkout pr-42`。
3. **agent 跑测试**——`npm test`、`bun test`、`mix test`、或 repo 声明的任何命令。测试失败是证据，不是意见。
4. **agent 检查 diff**——`git diff main...pr-42`，读改过的文件，检查常见问题（缺错误处理、未测的边界、风格违规）。
5. **agent 报告**——把结构化审查发到频道：改了什么、测试是否通过、发现了什么、建议（合并、请求修改、或升级给人）。

## 人设控制什么

人设（`MISSION.md`）决定审查的质量和语气：

- **查什么**——命名约定、错误处理模式、测试覆盖阈值、安全敏感区域。
- **何时升级**——"若 diff 触及认证、支付、或数据库 migration，总是请求人工审查。"
- **如何报告**——结构化格式（摘要、测试状态、按严重度排列的发现、建议），不是一堵文字墙。

没有范围化人设的代码审查 agent 给通用建议；人设点名你代码库约定的那个给有用的审查。

## 一个完整示例

为一个 Bun + TypeScript repo 设置 PR 审查 agent：

1. 在 WorkerEnv 存 `GIT_TOKEN`。
2. 创建 agent，绑 `primary`/`light`/`heavy`/`coding`。
3. 撰写 `MISSION.md`："审查 your-repo 上的 PR。克隆分支，跑 `bun test`，检查 diff。报告：测试状态、发现（critical/warning/nit）、建议。diff 触及 `auth/` 或 `migrations/` 时总是升级给人。"
4. 把 agent 连到 GitHub PR 通知到达的频道（通过 webhook binding 或人 @ 它时带 PR 号）。
5. agent 克隆、测试、审查、发结构化审查。

## 委派重活

大型 PR，agent 可把测试运行或 diff 检查委派给后台任务（见[委派模式](../delegate-patterns/)）。审查作为 `background_agent_job.completed` 事件触发；任务完成时 agent 发摘要。这保持会话响应，重活在后台跑。

## 本指南不是什么

它不是 CI/CD 替代——agent 跑测试和审查代码，但不门控合并。人仍决定。它不是 lint 工具——repo 的 linter 管风格；agent 查 linter 查不了的（逻辑错误、缺边界、设计问题）。它也不是高风险变更人工审查的替代——人设应升级，不自动批准。

## 下一步

- git 设置，读 [Git 集成](../git-integration/)。
- shell 工具，读[代码执行](../code-execution/)。
- 委派，读[委派模式](../delegate-patterns/)。
- 自动化触发，读[自动化蓝图](../automation-blueprints/)。
