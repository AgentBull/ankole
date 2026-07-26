---
title: Changelog 生成器
description: 如何设置一个从 commit 历史生成结构化 changelog 的 agent——按变更类型分组、过滤噪声、准备好写入 CHANGELOG.md。
section: Guides
order: 357
---

一个 changelog 生成器 agent 读自上次发布以来的 commit 历史、按类型分类每次变更（功能、修复、破坏性、内部）、过滤噪声（重构、纯测试、CI）、起草一条结构化 changelog 条目，准备好写入项目的 `CHANGELOG.md`。本指南是那个 agent 的实际形态。

先把决定性的性质说清楚：agent **从证据生成，不发明**。生成的 changelog 里的每一条追溯到一个具体 commit。agent 不加 commit 不支持的叙事，也不遗漏实质影响用户的变更。价值在于分类和过滤，不在于创意写作。

## 需要什么

- **WorkerEnv 里的 git 凭证**（`GIT_TOKEN`）。见 [Git 集成](../git-integration/)。
- **绑定 `primary` profile**——分类 commit 和过滤噪声需要推理。
- **一个 signal binding** 到 changelog 草稿发帖的频道。
- **了解项目的 changelog 格式**——是否遵循 Keep a Changelog、conventional commits、或自定义格式。

## 工作流

1. **changelog 请求到达**——"生成 v2.3.0 的 changelog"、或每次发布前触发的调度。
2. **agent 读 commit 历史**——`git log v2.2.0..HEAD --format="%h %s%n%b"` 获取自上次发布的每个 commit 及完整消息。
3. **agent 分类**——每个 commit：feature（新能力）、fix（bug 修复）、breaking（破坏性变更）、internal（重构、测试、CI、文档——非用户面向）、或 skip（merge commit、版本升级）。
4. **agent 过滤**——从用户面向的 changelog 中移除 internal 和 skip。
5. **agent 起草**——按类型分组剩余条目，用项目的 changelog 格式，准备好粘贴进 `CHANGELOG.md`。

## changelog 格式

若项目遵循 Keep a Changelog：

```markdown
## [2.3.0] - 2026-07-26

### Added
- Webhook 重试加指数退避 (#142)
- 设置页暗色模式 (#145)

### Fixed
- 零金额订单退款失败 (#138)
- Session 超时不清 auth token (#143)

### Changed
- API 限速从 100 提到 200 请求/分钟 (#147)

### Removed
- 废弃的 `/v1/users` 端点 (#140)
```

人设命名格式和分组约定。

## 人设控制什么

- **分类规则**——"commit 加了新端点、UI 元素或配置选项时是 feature。解决 issue 或 bug 时是 fix。移除、重命名或改公共 API 时是 breaking。"
- **过滤**——"排除标记为 `internal`、`chore`、`ci`、`test`、或 `refactor` 的 commit，除非它们影响用户可见行为。"
- **格式**——"遵循 Keep a Changelog 格式。链到 PR，不链到单个 commit。"
- **请求**——"发草稿请求复核。不直接提交到 CHANGELOG.md。"

## 一个完整示例

为基于发布的 repo 设置 changelog 生成器：

1. 在 WorkerEnv 存 `GIT_TOKEN`。
2. 创建 agent，绑 `primary`。
3. 撰写 `MISSION.md`："收到请求时，读自上次 tag 以来的 commit。分类：Added、Fixed、Changed、Removed、internal（排除）。过滤掉 internal 和 merge commit。用 Keep a Changelog 格式加 PR 链接起草。发草稿请求复核。不提交到 CHANGELOG.md。"
4. 在频道里："生成 v2.3.0（自 v2.2.0）的 changelog。"
5. agent 读、分类、过滤、起草、发帖。

## 与发布说明 agent 的关系

[发布说明 agent](../release-notes-agent/) 从同样的 commit 历史起草面向客户的说明（博客、通讯）。这个 agent 起草面向开发者的 `CHANGELOG.md` 条目。它们读相同的源材料；为不同受众产出不同产物。

## 本指南不是什么

它不是 commit 消息执行器——agent 用已有的 commit 消息工作；它不拒绝或重写它们。它不是版本升级器——agent 生成条目；人决定版本号。它也不是项目的 `CHANGELOG.md` 编辑器——agent 起草；人提交。

## 下一步

- git 设置，读 [Git 集成](../git-integration/)。
- 发布说明模式（面向客户），读[发布说明 agent](../release-notes-agent/)。
- shell 工具（git log），读[代码执行](../code-execution/)。
- Ankole 自身的 changelog 规则，读 [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md)。
