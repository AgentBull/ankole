---
title: 贡献
description: 向 Ankole 贡献代码的完整路径：工程准则出处、本地开发环境搭建、必跑检查项，以及项目强制执行的 Changelog 与 PR 规范。
section: Guides
order: 321
---

向 Ankole 提交第一行代码改动前，需要先通读仓库根目录下的两份核心规范文档，并严格按照它们定义的流程推进。本页作为快速导览，负责为你指明权威文档位置、勾勒完整的开发验收主线，而刻意不在此重复抄录细则——倘若本页概述与源码仓库中的规范文档存在任何出入，一律以仓库源文档为准。

先强调最重要的一条前提：**Ankole 的贡献规范不是可有可无的软性建议，而是由代码评审流程与覆盖每一次产品提交的 Changelog 校验共同强制执行的硬性要求。**任何跳过 [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md) 或 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md) 直接发出的改动都会在评审阶段被打回补课，因此请务必先读完这两份文档再动手。

## 拥有规则的两份文档

- **[`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md)**：定义全仓库通用的工程与架构准则，包括操作授权边界、以 Changelog 为版本发布单元的铁律、核心设计取向（最小正确改动、Worse is Better）、设计优先级（简洁 > 正确 > 一致 > 完整）、目标保真原则以及各子系统的职责边界。它决定了你应当**如何设计并实现**一项改动。
- **[`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)**：定义一步步落地的实操流程，涵盖六步本地环境搭建、飞书端到端真实链路验收、排障先后顺序、代码目录地图、质量门禁命令以及 Changelog 与 PR 提交清单。它决定了你需要**完成哪些具体步骤**才能让改动合入主干。

这两份文件分别掌管各自领域的唯一权威规范；本站所有开发者文档均指向它们，且不覆盖其中的任何条款。

## 设置路径（六步）

本地开发环境的权威搭建步骤以 `CONTRIBUTING.md` 为准，整体分为环环相扣的六步：

1. **克隆仓库并准备宿主环境**：拉取代码，准备 macOS、Linux、WSL2 或 GitHub Codespaces 开发环境。
2. **安装并校验系统级工具链**：执行 `bash tools/devkit/scripts/env-setup.sh`，随后确认 `bun`、`elixir`、`rustc`、`cargo clippy` 与 `docker` 均已就绪可用（各 `kit` 子命令的详细说明见 [kit CLI 参考](../kit-cli/)）。
3. **安装项目依赖并初始化本地基础服务**：依次执行 `bun install`、`bun run services:start`（拉起 PostgreSQL 18 与 `Function Runtime` / `ankole-function-runtime`）以及 `bun run control-plane:setup`。
4. **启动完整本地开发环境**：执行 `bun dev`。
5. **走完产品首次初始化向导**：在浏览器打开 `/setup` 激活站点，通过免密 SMTP 邮箱验证码（Email OTP）或飞书应用 OAuth 完成首位管理员登录（如需跑通完整的飞书端到端验收，请按指南创建飞书测试应用），随后进入 `/site-admin-console` 站点管理控制台配好运行时参数。
6. **跑通真实端到端消息闭环**：从飞书真实发出一句消息送达 Agent，并在聊天窗口收到符合预期的回复。

请注意，光能让前端页面打开并不算环境就绪，只有真实跑通一轮端到端消息收发才算搭建完成。极简体验路径可参阅 [快速开始](../quickstart/)，完整的开发验收细则请查阅 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)。

## 如何做改动

动笔修改代码前请先细读 `AGENTS.md`，以下是代码评审中最常触及的六条准则：

- **严守范围与操作授权**：面对答疑、诊断或方案设计类请求时保持只读分析；面对明确的功能实现请求时才修改代码，未经确认绝不私自扩大改动范围。
- **面向用户与运维撰写 Changelog**：凡是改变产品实际行为的提交，都必须在 `CHANGELOG.md` 中新增一个版本号记录升级后可感知的变化；仅修改文档的提交则不增加版本号（详见下一节）。
- **追求最小正确改动**：在符合既定架构方向、守住系统契约且易于理解的前提下，始终优先选择改动面最小的方案。宁可容忍少量直观的代码重复，也不要为了消除重复而引入晦涩的过度抽象。
- **坚持 Worse is Better**：实现简洁性优先于表面接口整齐划一或理论上的面面俱到。当为了保持简洁需要取舍时，宁可收窄契约边界或直接明确报错拒绝不支持的场景，也绝不悄悄返回看似正常实则失真的结果。
- **保证目标保真**：正面交付需求所要求的真实结果，不拿取巧的缩水替代品交差。单测变绿本身不是目的，让生产代码真正走通所属领域模块与真实协议边界才是目的。
- **尊重子系统职责边界**：PostgreSQL 掌管权威持久化事实；Elixir 控制面掌管持久状态、并发协调与监督恢复；Rust 内核掌管共享原生原语与网络传输；Bun Agent Computer Worker 掌管单 Agent 隔离执行；`Function Runtime`（`app/function_runtime/`）掌管无状态 Applet 后端与确定性程序隔离运行。跨层改动必须顺应这套边界，而非强行穿透或模糊职责。

## changelog 规则

这是每次产品代码提交都会触发的硬性门禁，也是初次贡献者最容易踩坑的地方。核心规则摘录自 `CONTRIBUTING.md`：

- 仅修改文档或 `CHANGELOG.md` 自身的提交**不新增**版本号；其余每一次提交都必须在根目录 `CHANGELOG.md` 中**恰好新增一个版本号**，且同一个版本号绝不横跨多次提交。
- 更新日志面向终端用户与系统管理员编写，如实记录升级后会感知到的变化：新增功能、行为变更、能力移除、用户可能遇到过的线上缺陷修复，以及升级时必须配合执行的手工操作。纯文档润色、测试用例、开发工具链、依赖升级与内部重构一律不写进条目；若当次提交纯粹属于此类内部改动，在新增版本号下仅写一行 `Internal changes only.` 即可。
- 版本号采用标准的 `MAJOR.MINOR.PATCH` 语义化格式：常规修复与内部演进默认递增 `PATCH`；新增产品此前没有的能力，或引入需要人工介入处理的破坏性变更时递增 `MINOR`；`MAJOR` 大版本跃迁与预发布后缀由项目维护者统一决定。

在 Ankole 中，根目录的 `CHANGELOG.md` 是**唯一**的版本记录与发布单元，不另设单独的 Release Notes 文件。每当 `main` 分支合入新提交并顺利通过全部三个同版本运行时镜像（`ankole-control-plane`、`ankole-agent-computer` 与 `ankole-function-runtime`）的构建校验后，自动化流水线便会用最新版本号为这三个镜像打标，并直接截取该版本的 Changelog 段落生成不可变的 GitHub Release。因此，请把撰写 Changelog 视作代码改动不可分割的一环，而非事后补交的文书手续。

## 跑对的检查

具体检查项的定义以 `CONTRIBUTING.md` 为准，底层命令参数详见 [kit CLI 参考](../kit-cli/)，日常提交前需按改动范围跑通以下验证：

- **受影响包的目标单测与常规静态检查**：针对本次修改波及的子包精准运行测试与类型检查，不必盲目全量空跑无关模块。
- **跨边界集成测试或端到端测试**：一旦改动跨越进程边界、外部 Provider、持久化重启恢复或核心用户交互主线，必须跑通对应的集成或端到端套件，严禁跳过。
- **仓库级架构与代码异味分析**：运行 `bun run analyze`（即 `kit analyze all`），排查未使用死代码、目录结构违规及模块循环依赖。
- **代码规范与格式校验**：提交前运行 `bun run lint` 与 `bun run fmt:check`。

如果某条必跑验证因当前本地环境限制确实无法执行，请在汇报或 PR 说明中如实列出**确切命令与具体受阻原因**，切勿在未实际跑通的情况下声称该项保障已验证通过。

## 提交 pull request

完整的 PR 提交流程见 `CONTRIBUTING.md`。简言之，一份合格的 PR 应当做到：每次产品代码提交严格遵守“一提交一版本”的 Changelog 规范、代码设计严守 `AGENTS.md` 划定的领域边界、PR 描述采用与项目设计文档一致的准确术语讲清“改了什么”以及“为什么这样改”——代码评审同样会对照这几条逐项核验。

## 本指南不是什么

本页只是引导你进入两份权威规范文档的入口，绝不能替代直接阅读原文档，更不是允许“不看规范直接改代码”的通行证——`AGENTS.md` 本身篇幅非常精炼，花几分钟读完它是返工成本最低的投入。同时，也请避免在功能 PR 中就既定工程准则展开纯个人偏好的拉锯：这些规则都是团队深思熟虑后的架构取舍，评审关注的重点是具体实现是否在既定设计方向内保持自洽。

## 下一步

- 动手改代码前，先通读 [`AGENTS.md`](https://github.com/AgentBull/ankole/blob/main/AGENTS.md)。
- 按步骤搭建本地环境并完成端到端验收，请参阅 [`CONTRIBUTING.md`](https://github.com/AgentBull/ankole/blob/main/CONTRIBUTING.md)。
- 查阅本地开发与检查工具链命令，请参阅 [kit CLI 参考](../kit-cli/)。
- 理解跨模块改动涉及的子系统职责边界，请参阅 [架构概览](../architecture/)。
