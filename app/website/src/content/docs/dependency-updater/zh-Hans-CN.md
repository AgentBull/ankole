---
title: 依赖更新 agent
description: 如何设置一个检查过时依赖、更新、跑测试、开 PR 的 agent——保持最新的机械工作。
section: Guides
order: 350
---

一个依赖更新 agent 检查过时的包、更新到最新兼容版本、跑测试套件、测试通过则开 PR。这是保持最新的机械工作——对人乏味、对 agent 合适的工作。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：agent **更新和验证，不合并**。它升版本、跑测试、开 draft PR。人复核 changelog 并决定是否合并。价值在于移除机械障碍——"我该更新但没时间"——不在于替代判断。

## 需要什么

- **WorkerEnv 里的 git 凭证**（`GIT_TOKEN`）。见 [Git 集成](../git-integration/)。
- **绑定 `primary` 和 `coding` profile**——agent 读 changelog 并评估破坏性变更。
- **一个 signal binding** 到更新 PR 公告的频道。
- **repo 从 worker 可达**，带 lockfile 和测试套件。

## 工作流

1. **调度触发**（每周或按需）。
2. **agent 检查过时依赖**——`bun outdated`、`npm outdated`、`pip list --outdated`、`cargo outdated`。
3. **agent 读 changelog**——每个过时包检查最新版是否有破坏性变更（主版本升级、废弃）。
4. **agent 更新**——升到最新兼容版本（patch/minor 安全；主版本升级标记给人复核）。
5. **agent 跑测试**——`bun test`、`pytest` 等。全必须通过。
6. **agent 开 PR**——带更新的 lockfile、变更清单、和测试结果。

## 人设控制什么

- **更新策略**——"自动更新 patch 和 minor 版本。主版本升级标记给人复核——不更新它们。"
- **批处理**——"每周一个 PR，所有安全更新批在一起"vs"每个包一个 PR。"
- **Changelog 阅读**——"读每个更新包的 changelog。即便 minor 升级提到破坏性变更也标记。"
- **证明**——"始终跑完整测试套件。任何测试失败则还原那个包并报告。"

## 主版本规则

最重要的安全规则：**不自动更新主版本**。主版本升级（1.x → 2.x）可能以测试套件抓不到的方式破坏构建（API 移除、行为变化）。agent 更新 patch 和 minor 版本（semver 安全）；主版本报告"包 X 有新主版本可用——手动复核"且不碰 lockfile。

## 一个完整示例

为 Bun repo 设置每周依赖更新 agent：

1. 在 WorkerEnv 存 `GIT_TOKEN`。
2. 创建 agent，绑 `primary`/`coding`。
3. 撰写 `MISSION.md`："每周一，检查过时依赖。更新 patch 和 minor 版本。读 changelog 找破坏性变更。跑 `bun test`。测试通过则开带更新 lockfile 的 PR。主版本升级标记为手动复核——不更新它们。每周一个 PR，所有安全更新批在一起。"
4. 加一条每周调度：`cron: "0 7 * * 1"`。
5. agent 检查、读、更新、测试、开 PR。

## 本指南不是什么

它不是破坏性变更迁移工具——agent 更新到兼容版本；迁移到新主版本是人的任务。它不是安全修补——漏洞驱动的更新用[安全审计 agent](../security-audit-agent/)。它也不是复核 changelog 的替代——agent 读它并标记风险；人做决定。

## 下一步

- git 设置，读 [Git 集成](../git-integration/)。
- shell 工具（`bun outdated`、`bun test`），读[代码执行](../code-execution/)。
- 安全审计模式（漏洞驱动更新），读[安全审计 agent](../security-audit-agent/)。
- 调度，读 [Cron 调度](../cron-schedules-ops/)。
