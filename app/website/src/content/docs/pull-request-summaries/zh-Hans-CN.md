---
title: Pull request 摘要
description: 如何设置一个读 PR diff 并发结构化摘要的 agent——改了什么、为什么、影响区域、复核重点——让审查者快速开始。
section: Guides
order: 361
---

一个 Pull request 摘要 agent 读每个新或更新 PR 的 diff、理解改了什么和为什么、发结构化摘要让审查者无需先读完整 diff 就能开始复核。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：agent **为审查者摘要，不审查**。它告诉你改了什么和看哪里；它不告诉你变更是否正确。价值在于缩短审查者的上手时间——"这个 PR 到底在做什么"的那 5 分钟——不在于替代审查。

## 需要什么

- **WorkerEnv 里的 git 凭证**（`GIT_TOKEN`）。见 [Git 集成](../git-integration/)。
- **绑定 `primary` 和 `coding` profile**——读 diff 和摘要其意图需要代码理解能力。
- **一个 signal binding** 到 PR 摘要发帖的频道，或在 PR open/update 时触发的 webhook。
- **repo 从 worker 可达。**

## 工作流

1. **PR 事件到达**——webhook、调度、或人请求。
2. **agent 获取 diff**——`git diff base...head` 或 PR API。
3. **agent 读 diff**——识别改动的文件、修改的函数、新增或删除的逻辑。
4. **agent 读 PR 描述和 commit 消息**——了解意图（为什么做这个变更）。
5. **agent 发结构化摘要**——改了什么、为什么、影响区域、和建议的复核重点。

## 摘要格式

```text
**PR #142 — 加 webhook 重试带退避**

**改了什么**：
- 在 `src/webhooks/send.ts` 加了重试逻辑（指数退避、最多 3 次）
- 在 `src/types.ts` 加了 `RetryConfig` 类型
- 更新了 `test/webhooks.test.ts` 的测试

**为什么**：到 provider X 的 webhook 间歇失败；无重试信号就丢了。

**影响区域**：webhook 投递、信号可靠性

**复核重点**：退避公式（第 45 行）、最大重试上限、以及 3 次对 provider X 是否够。
```

"复核重点"是关键价值——它告诉审查者注意力花在哪，不只是改了什么。

## 人设控制什么

- **摘要深度**——"一段"vs"逐文件分解带建议复核重点"。
- **包含什么**——"始终包含：改了什么、为什么、影响区域、和 1-3 个复核重点。"
- **不做什么**——"不批准或拒绝 PR。不跑测试（那是 QA agent）。只摘要。"
- **链接**——"链接到需要注意的具体文件和行，不只是 PR URL。"

## 一个完整示例

设置一个 webhook 触发的 PR 摘要 agent：

1. 在 WorkerEnv 存 `GIT_TOKEN`。
2. 创建 agent，绑 `primary`/`coding`。
3. 设置一个在 PR open 时触发的 webhook binding（通过 `signals_gateway.webhook_handler` plugin 或监控频道）。
4. 撰写 `MISSION.md`："PR open 时获取 diff。读变更和 PR 描述。发结构化摘要：改了什么、为什么、影响区域、1-3 个带 file:line 链接的复核重点。不审查或批准。"
5. agent 在 webhook 上醒来、获取、读、摘要、发帖。

## 本指南不是什么

它不是代码审查——agent 摘要不判断。判断见[代码审查工作流](../code-review-workflow/)。它不是 CI 报告——它读 diff 不读测试结果。它也不是 changelog 条目——它为审查者摘要一个 PR，不为用户摘要发布。

## 下一步

- 代码审查模式（判断而非仅摘要），读[代码审查工作流](../code-review-workflow/)。
- webhook 触发，读[自动化蓝图](../automation-blueprints/)。
- git 设置，读 [Git 集成](../git-integration/)。
- 发布说明模式（面向用户而非面向审查者），读[发布说明 agent](../release-notes-agent/)。
