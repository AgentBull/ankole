---
title: 代码格式化器
description: 如何设置一个跑项目格式化器、应用它、报告变更的 agent——代码风格的机械面。
section: Guides
order: 360
---

一个代码格式化器 agent 跑项目的格式化器（Prettier、oxfmt、gofmt、mix format）、应用格式化、报告变更。这是最简单的代码质量 agent——它机械地做一件事并报告。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：agent **格式化，不重新设计风格**。它逐字应用项目配置的格式化器——无观点、无调整、无"我觉得这样更好看"。格式化器是权威；agent 是手。若格式化错了，修格式化器配置，不是 agent。

## 需要什么

- **WorkerEnv 里的 git 凭证**（`GIT_TOKEN`）。见 [Git 集成](../git-integration/)。
- **绑定 `primary` profile**——最小；agent 主要跑命令和读 diff。
- **一个 signal binding** 到格式报告发帖的频道。
- **项目的格式化器装在 worker 镜像里。**

## 工作流

1. **格式任务到达**——定时或 commit 前。
2. **agent 跑格式化器**——`bun run fmt`、`npx prettier --write .`、`gofmt -w .`、`mix format`。
3. **agent 读 diff**——`git diff` 看格式化器改了什么。
4. **agent 报告**——文件数、行数、和是否有手工格式被格式化器覆盖。

## 与 lint 运行器的区别

| | 格式化器 | Lint 运行器 |
|---|---|---|
| 做什么 | 应用风格（空格、行宽、引号） | 找代码问题（未用变量、复杂度） |
| 权威 | 格式化器配置——无观点 | linter 规则——部分需判断 |
| 自动修复 | 总是（格式化是确定性的） | 有时（`--fix` 处理部分，非全部） |
| 需人复核 | 很少（格式化安全） | 经常（部分发现需判断） |

格式化器是确定性的——同样输入总产出同样输出。linter 有判断。格式化 agent 更简单更安全；lint 运行器更有价值但需更紧的人设控制。

## 人设控制什么

- **格式化命令**——"跑 `bun run fmt`（它跑 `oxfmt`）。"
- **范围**——"格式化所有文件"vs"只格式化自上次 commit 以来修改的文件"。
- **报告**——"报告文件数和行数。不发完整 diff——那是噪声。"
- **提交行为**——"不提交格式化变更。留在工作树里让开发者提交。"

## 一个完整示例

为 Bun repo 设置格式化 agent：

1. 在 WorkerEnv 存 `GIT_TOKEN`。
2. 创建 agent，绑 `primary`。
3. 撰写 `MISSION.md`："跑 `bun run fmt`。读 `git diff --stat` 获取摘要。报告：变更的文件、变更的行。不提交。不发完整 diff。无变更则说'已格式化。'"
4. 加一条调度：`cron: "0 6 * * 1-5"`（工作日早上 6 点）。
5. agent 格式化、读 diff stat、发摘要。

## 本指南不是什么

它不是风格执行器——格式化器执行风格；agent 跑它。它不是 lint 运行器——格式化是空格和行形态；lint 是代码正确性。它也不是项目格式 CI 门控的替代——CI 在未格式化代码上挡；agent 格式化和报告。

## 下一步

- git 设置，读 [Git 集成](../git-integration/)。
- shell 工具，读[代码执行](../code-execution/)。
- lint 运行器（相关的、更复杂的模式），读[代码 lint 运行器](../code-lint-runner/)。
- 调度，读 [Cron 调度](../cron-schedules-ops/)。
