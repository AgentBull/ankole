---
title: QA 测试 agent
description: 如何设置一个推进测试积压、跑测试、收集证据、以足够上下文交接失败的 agent。
section: Guides
order: 336
---

一个 QA 测试 agent 推进测试积压——跑测试套件、识别失败、收集证据（日志、截图、堆栈跟踪）、并以足够上下文交接每个失败，让人无需复现即可复核。这是架构概览中点名的模式之一——"QA agent 推进测试积压，收集证据，并交接失败。"本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：agent **跑测试和收集证据，不修 bug**。它找到失败、捕获上下文、报告它。人决定修、推迟、还是关闭为预期行为。agent 的价值是证据收集的彻底性和速度，不是诊断权威。

## 需要什么

- **WorkerEnv 里的 git 凭证**（`GIT_TOKEN`）。agent 克隆 repo 跑测试。见 [Git 集成](../git-integration/)。
- **绑定 `primary` 和 `coding` profile。** 读测试输出和分类失败需要推理。
- **一个 signal binding** 到测试报告发帖的频道。
- **worker 镜像**——测试运行器（Bun、pytest、mix test 等）必须装在镜像里。多数标准运行器已装。

## 工作流

1. **agent 收到测试任务**——来自调度（"每晚跑全套"）、webhook（"一个 PR 合并了，跑测试"）、或人（"在分支 X 上跑集成测试"）。
2. **agent 克隆和 checkout**——`git clone`、`git checkout <branch>`。
3. **agent 跑测试**——`bun test`、`pytest`、`mix test`、或 repo 声明的任何命令。它捕获完整输出。
4. **agent 分类**——通过或失败。对失败，它读堆栈跟踪、测试名、失败的断言。
5. **agent 收集证据**——失败测试的输出、相关日志行、与上一个已知良好 commit 的 diff（若 git 历史允许）。对 UI 测试，若 browser skill 可用则附截图。
6. **agent 报告**——发结构化失败报告：测试名、什么失败了、证据、commit 链接。它不提议修复。

## 人设控制什么

- **范围**——"跑全套"vs"只跑集成测试"vs"只跑涉及支付模块的测试"。
- **证据深度**——"捕获堆栈跟踪和最后 50 行日志"vs"捕获完整日志和截图"。
- **分类**——"把失败分类为回归（之前通过的测试新失败）、flaky（间歇）、或已知（匹配 Brain 里的现有 issue）。"
- **报告**——"每个失败作为单独消息发证据，或批成一个摘要。"
- **不做什么**——"不尝试修失败。不改测试。报告并交接。"

## 失败报告

agent 发的一个好的失败报告：

```text
**FAIL: tests/payments/refund.test.ts > "should refund within 24h"**
- **类型**：回归（在 commit abc123 上通过）
- **错误**：AssertionError: expected status 200, got 500
- **堆栈**：server.ts:142 → refund handler 在 null customer_id 上抛出
- **日志**：[服务器输出最后 20 行]
- **Commit**：def456（PR #789 的合并）
- **Runbook**：Brain 条目"退款测试失败"（若匹配已知模式）
```

这给人复核者足够的上下文开始调试而无需复现——测试名、错误、堆栈、日志、引入它的 commit。

## 委派重运行

大型测试套件，把测试运行委派给后台任务（见[委派模式](../delegate-patterns/)）。任务跑套件；任务完成时 agent 分类和报告。一个跑 20 分钟的全套不应阻塞会话。

## 已知失败模式

为已知失败维护一条 Brain 知识条目——间歇失败的测试（flaky）或因已知未修 issue 而失败的测试。agent 遇到失败时查 Brain：若失败匹配已知模式，它分类为"已知"并指向 issue，而非报告为新回归。

## 一个完整示例

为 web app 设置每晚 QA agent：

1. 在 WorkerEnv 存 `GIT_TOKEN`。
2. 创建 agent，绑 `primary`/`light`/`heavy`/`coding` + `embedding`。
3. 撰写 `MISSION.md`："每晚在 main 分支跑完整测试套件。每个失败分类为回归/flaky/已知。收集堆栈跟踪和最后 50 行日志。每个失败作为单独报告发。不修。先查 Brain 的已知失败模式。"
4. 加一条每晚调度：`cron: "0 2 * * *"`。
5. 策展 Brain 知识：已知 flaky 测试、已知未修 issue。
6. 每天早上，团队复核 agent 隔夜发的失败报告。

## 本指南不是什么

它不是 CI/CD 替代——CI 在每次推送时跑并门控合并；agent 按调度或按需跑并报告到频道。它不是修 bug 的 agent——它找和报告；人修。它也不是写测试的工具——agent 跑已有测试；它不生成新的（尽管它可以建议缺覆盖的区域）。

## 下一步

- git 设置，读 [Git 集成](../git-integration/)。
- shell 工具，读[代码执行](../code-execution/)。
- 委派，读[委派模式](../delegate-patterns/)。
- Brain 知识（已知失败），读 [Brain](../brain/)和 [Brain 复核](../brain-review-ops/)。
