---
title: 代码 lint 运行器
description: 如何设置一个跑项目 linter、读输出、分类发现、提议修复简单项的 agent——其余的留给人复核。
section: Guides
order: 358
---

一个代码 lint 运行器 agent 跑项目的 linter、读发现、分类（可自动修复、需人判断、误报）、提议修复可自动修复的、报告其余的供人复核。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：agent **修机械的、报告需判断的**。像"未使用的 import"这样的 lint 发现是机械的——agent 移除它。像"函数参数太多"这样的发现是需判断的——agent 报告它让人决定。价值在于清理机械噪声，让人的复核时间花在需要思考的发现上。

## 需要什么

- **WorkerEnv 里的 git 凭证**（`GIT_TOKEN`）。见 [Git 集成](../git-integration/)。
- **绑定 `primary` 和 `coding` profile**——读 lint 输出和分类发现需要代码理解能力。
- **一个 signal binding** 到 lint 报告发帖的频道。
- **项目的 linter 装在 worker 镜像里**——ESLint、oxlint、RuboCop、Dialyzer、或 repo 声明的任何工具。

## 工作流

1. **lint 任务到达**——定时或 PR 后。
2. **agent 跑 linter**——`bun run lint`、`npx eslint .`、`rubocop`、或 repo 的 lint 命令。
3. **agent 读输出**——解析每个发现：文件、行、规则、严重度、消息。
4. **agent 分类**——可自动修复（linter 有 `--fix` 或修复很简单如移除未使用 import）、需判断（linter 标记的设计问题）、或误报（linter 在此上下文中错了）。
5. **agent 修复可自动修复的**——跑 linter 的 `--fix`、或通过 `patch`/`apply-patch` 应用修复。
6. **agent 报告**——修复计数、和需人判断的发现，每个附文件/行/规则/消息。

## 人设控制什么

- **自动修复策略**——"只自动修复 linter 的 `--fix` 处理的东西。不为 lint 发现手写修复。"
- **需判断的发现**——"报告但不修：复杂度警告、命名约定违规、和 linter 自身不自动修复的任何发现。"
- **误报**——"若发现明显是误报（linter 的规则在此上下文不适用），用项目的抑制注释抑制并说明原因。"
- **证明**——"自动修复后再跑一次 linter。所有自动修复的发现必须解决。报告任何剩余的。"

## linter 的 --fix

多数现代 linter 有 `--fix` 模式，机械地处理一大类发现：

```bash
npx eslint . --fix        # ESLint
bunx oxlint . --fix       # oxlint
rubocop -A                # RuboCop（全部自动纠正）
```

agent 跑带 `--fix` 的 linter、再跑不带 `--fix` 的看剩余什么。剩余的要么需判断、要么是误报。

## 一个完整示例

为 TypeScript repo 设置 lint 运行器：

1. 在 WorkerEnv 存 `GIT_TOKEN`。
2. 创建 agent，绑 `primary`/`coding`。
3. 撰写 `MISSION.md`："在 repo 上跑 `bun run lint`。自动修复 linter fix 模式处理的。再跑一次确认修复。报告剩余发现：文件、行、规则、消息、和是需人判断还是可能误报。不为需判断的发现手写修复。"
4. 加一条调度：`cron: "0 6 * * 1-5"`（工作日早上 6 点，团队开始前）。
5. agent lint、修复、再 lint、发报告。

## 本指南不是什么

它不是风格执行器——linter 执行风格；agent 跑它。它不是代码审查员——lint 发现是机械的；代码审查是语义的。它也不是项目 lint CI 门控的替代——CI 在 lint 上挡；agent 修复和报告。两者都用。

## 下一步

- git 设置，读 [Git 集成](../git-integration/)。
- shell 工具，读[代码执行](../code-execution/)。
- 代码审查模式（语义而非机械），读[代码审查工作流](../code-review-workflow/)。
- 重构模式（结构性变更），读[重构助手](../refactoring-assistant/)。
