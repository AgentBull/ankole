---
title: 贡献
description: 一次 Ankole 贡献合并的路径——规则住在哪里、如何设置、如何跑对的检查、项目要求的 changelog 与 PR 纪律。
section: Guides
order: 321
---

为 Ankole 做贡献意味着在第一次编辑前读两份文档，并遵循它们定义的路径。本页是地图：指向权威来源、标出穿过它们的路径、并刻意不复制任一份。若本页与源文档冲突，源文档正确。

先说明最关键的一点：Ankole 的贡献规则不是可选约定——它们由项目的评审流程和门控每次提交的 changelog 规则强制。跳过 [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md) 或 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) 的贡献会被要求回去读。先读。

## 拥有规则的两份文档

- **[`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md)**——项目范围规则：范围与授权、changelog 作为版本单元的规则、核心纪律（最小正确改动、worse is better）、设计优先级（简洁 > 正确 > 一致 > 完整）、目标保真、子系统边界。这份文档决定*如何*做一次改动。
- **[`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)**——贡献路径：六步本地设置、飞书端到端验收、故障排查顺序、仓库地图、质量门、changelog 与 PR 步骤。这份文档决定*做什么*来落地一次改动。

两者各自是自己领域的权威来源。本指南与其余文档链接到它们；这里的一切不凌驾于它们。

## 设置路径（六步）

`CONTRIBUTING.md` 分六步走设置，它是权威版本。形态如下，让你知道将面对什么：

1. **获取仓库并选择环境**——克隆，并选 macOS/Linux/WSL2 或 GitHub Codespaces。
2. **安装并验证系统工具**——`bash tools/devkit/scripts/env-setup.sh`，然后验证 `bun`、`elixir`、`rustc`、`cargo clippy`、`docker` 都可用。每条 `kit` 命令做什么见 [kit CLI 参考](../kit-cli/)。
3. **安装依赖并初始化 PostgreSQL**——`bun install`、`bun run services:start`、`bun run control-plane:setup`。
4. **启动完整开发环境**——`bun dev`。
5. **完成首次产品设置**——激活、创建飞书测试应用、配置 OIDC、在 Console 配置运行时。
6. **证明端到端路径**——一条真实飞书消息到达 agent 并收到预期回复。

页面能打开不算设置完成。一条真实消息往返完成才算。短路径见 [快速开始](../quickstart/)，完整验收见 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)。

## 如何做改动

第一次编辑前读 `AGENTS.md`。最常出现的规则：

- **范围与授权。** 回答或规划的请求授权只读检查；实现的请求授权编辑。未经批准不扩大范围。
- **changelog 是版本单元。** 每次提交恰好加一个 `CHANGELOG.md` 版本，该版本描述该提交中每一项保留改动。一个版本不跨提交；一次提交不含多个版本。见下面一节。
- **最小正确改动。** 偏好遵循所选方向、保持系统能守契约、并保持可理解的最小改动。一点重复好过增加复杂度的抽象。
- **Worse is better。** 简洁胜过接口统一或理论完整。简洁赢时，收窄契约或显式拒绝不支持的情形，而非悄悄产出错的结果。
- **目标保真。** 做要求的任务，不做更便宜的替代。绿测试不是目标；穿过拥有抽象的真实路径才是。
- **子系统边界。** PostgreSQL 拥有持久事实；Elixir 控制面拥有持久状态与监督；Rust kernel 拥有共享原生原语；Bun Agent Computer Worker 拥有执行。跨边界的改动应尊重它，而非掩盖。

## changelog 规则

这是门控每次提交的规则，也是大多数贡献第一次搞错的那一条。来自 `AGENTS.md`：

- 每次提交恰好加一个根 `CHANGELOG.md` 版本。
- 该版本描述该提交中每一项保留的源码、测试、文档、配置、schema、migration、manifest、lockfile 和必需生成文件改动。
- 一个版本不跨多次提交；一次提交不含多个版本。
- 版本使用无前导零的 `MAJOR.MINOR.PATCH`。默认增加 `PATCH`。只有当这次提交让用户或运维人员能做到产品此前做不到的事，或者破坏了既有行为、必须有人改配置、改已存数据或改外部调用方时，才增加 `MINOR` 并将 `PATCH` 重置为 `0`。其他变动一律增加 `PATCH`，即使用户立刻能察觉：无论多显眼的 bug 修复、既有能力内的速度或可靠性改进、内部重写、依赖升级、工具链和文档。一次提交同时包含两类变动时增加 `MINOR`，但前提是其中某一项变动自身就够 `MINOR`。只有维护者明确决定时才改变 `MAJOR`。
- 提交前立即从确切的暂存 diff 准备条目。

changelog 是*唯一*的 changelog 和版本单元——没有单独的 release notes 文件。`main` 的运行时镜像构建通过镜像对验证后，工作流会用最新版本标记 control-plane 和 Worker 镜像，并用该版本的 changelog 段落创建不可变的 GitHub Release。把 changelog 当作改动的一部分，不是事后的文书。

## 跑对的检查

`CONTRIBUTING.md` 命名检查，[kit CLI 参考](../kit-cli/) 文档命令。形态：

- **针对你改的包的目标测试和正常静态检查**——跑受影响包的测试，不是整套。
- **受影响的集成或端到端套件**——当改动跨进程、provider、持久化重启或用户流程边界时——且不要跳过。
- **`bun run analyze`**（`kit analyze all`）——仓库范围的异味、未使用代码、结构、依赖循环。
- **`bun run lint`** 和 **`bun run fmt:check`**——提交前。

若某条必需命令在你的环境跑不了，报告确切的命令和阻碍——不要把那个保证当作已验证。

## 提交 pull request

`CONTRIBUTING.md` 覆盖 PR 步骤。简短形态：PR 的提交遵循 changelog 规则（每次提交一个版本）、改动尊重 `AGENTS.md` 的边界、PR 描述用文档使用的术语说明改了什么和为什么。评审会检查同样的东西。

## 本指南不是什么

它不是两份文档的替代——它是通往它们的门。它不是不读就编辑的许可；`AGENTS.md` 刻意很短，读它是贡献者成本最低的一步。它也不是争论规则的地方；规则是已定的权衡，本地偏好不是发现——改为评估实现是否在所选方向内一致。

## 下一步

- 第一次编辑前读 [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md)。
- 设置与验收按 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)。
- devkit 命令用 [kit CLI 参考](../kit-cli/)。
- 改动跨的子系统边界，读 [架构概览](../architecture/)。
