---
title: 发布说明 agent
description: 如何设置一个盯着已合并 PR、起草发布说明、发出来供复核的 agent——结合 git、调度、团队频道。
section: Guides
order: 331
---

一个发布说明 agent 盯着什么合并了、从 commit 历史和 PR 标题起草说明、发一份草稿供团队在发布前复核。本指南是那个 agent 的实际形态——结合 git 访问、调度、频道发帖。

先把决定性的性质说清楚：agent **起草，不发布**。发布说明是人面向的产物，有语气、框架、对客户敏感的过滤。agent 收集原材料并写草稿；人复核并发出。自动化收集是收益；自动化判断不是。

## 需要什么

- **WorkerEnv 里的 git 凭证**（`GIT_TOKEN`）。见 [Git 集成](../git-integration/)。
- **绑定 `primary` 和 `light` profile。** 起草是综合工作——`primary` 为质量，`light` 若想要更快更便宜的内部复核草稿。
- **一个 signal binding** 到团队发草稿的频道。
- **一个调度**每周触发（或按发布节奏）。见 [Cron 调度](../cron-schedules-ops/)。

## 工作流

1. **调度触发**——每周，或按你的发布节奏。
2. **agent 克隆或 fetch repo**——`git log --oneline --since="1 week ago"` 列出合并了什么。
3. **agent 读 PR 标题和 commit 消息**——`git log --format="%s%n%b" --since="1 week ago"` 看详情。
4. **agent 起草发布说明**——按类别分组（功能、修复、破坏性变更），附 PR 链接。
5. **agent 发草稿**到绑定的频道，请求复核。

团队复核、编辑、发布。agent 的草稿是起点，不是最终产物。

## 人设控制什么

人设（`MISSION.md`）决定草稿的质量：

- **分类**——你的项目里什么算功能 vs 修复 vs 破坏性变更。
- **语气**——工程博客偏技术，客户通讯偏易懂。
- **过滤**——"排除内部重构、纯测试改动、依赖升级，除非影响行为。"
- **链接**——链到 PR，不链到单个 commit。
- **请求**——"发草稿并请求复核；不经人批准不发布。"

## 一个完整示例

为 GitHub repo 设置每周发布说明 agent：

1. 在 WorkerEnv 存 `GIT_TOKEN`。
2. 创建 agent，绑 `primary`/`light`/`heavy`。
3. 撰写 `MISSION.md`："每周从 your-repo 获取上周已合并的 PR。按功能、修复、破坏性变更起草发布说明。排除重构和纯测试改动。链到 PR。发草稿到频道请求复核。不发布。"
4. 加一条每周调度（周五下午）：`cron: "0 17 * * 5"`。
5. agent 获取、起草、发帖。团队周末复核、周一发布。

## 委派 git 工作

合并多的 repo，`git log` 和 PR 详情获取可能慢。委派给后台任务（见[委派模式](../delegate-patterns/)）——任务收集原材料，任务完成时 agent 综合草稿。

## 本指南不是什么

它不是发布管线——agent 起草；人通过团队用的任何渠道发布（GitHub Releases、博客、通讯）。它不是 changelog 生成器——项目的 `CHANGELOG.md` 由贡献者维护；agent 读它但不编辑。它也不是人工判断该突出什么的替代——agent 收集和分类；人决定叙事。

## 下一步

- git 设置，读 [Git 集成](../git-integration/)。
- 调度，读 [Cron 调度](../cron-schedules-ops/)。
- 委派，读[委派模式](../delegate-patterns/)。
- 相关的调度 agent 模式，读[一个每日简报机器人](../daily-briefing-bot/)。
