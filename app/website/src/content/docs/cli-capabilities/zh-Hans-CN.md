---
title: Worker CLI 能力
description: 将特定 Agent 能力封装为 Shell 命令行工具，由 --help 承载完整使用契约，并在关键决策点放置一句话指引。
section: Developer guide
order: 114
---

在 Ankole 中，有一部分平台能力并不是作为每轮必带的模型工具（Tool）暴露给大模型，而是直接封装为 Agent Computer Worker 内的 Shell 命令行程序（CLI）。Agent 就像日常调用 `gh` 或 `kubectl` 一样，直接在终端里运行它们——内置的 `ankole-pod`（涵盖 `pages.*`、`base.*`、`applet build|publish|pull`）、`ankole-files`、`ankole-browser`、Webhook 端点管理命令以及 Automation Job 管理命令，全部采用这种交付形态。

本页说明什么样的能力适合做成 CLI，以及如何在不注册模型工具、不塞入全局 Skill 索引、也不膨胀系统提示词的前提下，让 Agent 依然能够精准发现并正确调用这些命令。

## 什么时候 CLI 是正确形态

当一项能力同时符合以下三个特征时，做成 CLI 往往比做成模型工具更合适：

- **天然融入 Shell 工作流**：Agent 往往需要把它与其他终端命令串联组合使用，或者还需要在自动化脚本及后台 Agent 任务中直接调用它。
- **仅在特定决策分支上才用得到**：例如，一个从不需要配置外部事件接入的 Agent，压根不需要在日常每轮对话里都知道 `create-webhook-cli` 的存在。
- **参数结构简单直观**：无需让模型构造复杂的嵌套 JSON Schema，靠几个标准命令行参数（flag）就能清晰表达输入。

要知道，挂载在模型上下文里的可见工具在**每一个对话回合**都会消耗 Token 预算；而做成 CLI 的能力在 Agent 真正走到相关业务分支之前，上下文开销是零。

## 披露架构

为了让 Agent 无需全局工具表也能顺畅使用 CLI，我们用三条渐进式披露准则替代传统的工具注册与全局索引：

**1. `--help` 本身就是权威契约文档。**
CLI 输出的 `--help` 帮助信息直接承载 Agent 正确调用该能力所需的全部上下文：这项命令解决什么问题、背后的安全与信任模型、持久性与幂等保证，以及一次完整的端到端调用示例。由于帮助文本直接随二进制同库编译发布，始终与代码实际行为保持严格同版本，绝不会像外部独立文档那样逐渐脱节。编写 `--help` 时应面向零背景知识的读者，重点讲清目标与边界约束，而非罗列死板的机械步骤（可参考 `create-webhook-cli --help` 的写法）。

**2. 把一句话指针放在必经的决策面上。**
Agent 之所以能“想起来”有这个命令，靠的是埋在相邻决策节点上的一句话指针——它可以放在某个相邻工具的描述里、某个对接特定外部系统的 Skill 里，或是另一个关联 CLI 的 `--help` 末尾。每条指针只客观点明“在什么场景下需要用到该能力”以及“运行哪条 `--help` 查看详情”，绝不强行诱导模型调用。凡是做成 CLI 的能力，都必须在通往该场景的必经入口处至少留有一条指针：让这项能力派上用场的那条业务路径，天然就决定了应该把指针放在哪里。

**3. 通用平台契约写在 `--help`，外部系统差异留在插件 Skill。**
凡是对该能力所有使用场景普遍成立的平台级规则，一律收敛进 CLI 的 `--help`；对接具体第三方平台的 Skill 只需补充该外部系统特有的增量知识。例如，GitHub Webhook Skill 开篇第一句就引导 Agent 先运行 `create-webhook-cli --help` 了解通用的 Webhook 安全与投递契约，而 Skill 正文自己只写 GitHub 侧的 Hook 注册接口、Ping 握手校验、投递对账与仓库配额限制。这样一来，日后新增第二个平台的 Webhook 集成时，整套底层通用契约都能零成本直接复用。

## Automation job

Automation Job 是确定性脚本消费者：无论是 Checkback 延迟回查、Cron 定时计划还是 Webhook 端点，都可以配置 `automation_job_id` 将触发事件交由脚本消费，而不必每次都直接唤醒 Agent 会话（未配置该字段的触发器仍保持直接唤醒会话的默认行为）。

创建流程上，Agent 会先在本地工作区新建独立目录并编写 `main.ts`，手动运行验证基础环境与不依赖平台 SDK 的纯逻辑分支，随后调用 `create-automation-job-cli` 完成注册。注册时，整个脚本目录会被上传至控制面云盘的 `automation/<目录名>-<随机后缀>` 路径下，并在返回结果中给出对应的 `drive_prefix`。此后每次触发执行，Worker 都会将触发当刻云盘该路径下的文件复制到一个全新的临时运行目录，再用 Bun 执行其中的 `main.ts`——因此脚本在当前工作目录下临时生成的文件不会留存到下一次运行。后续如需更新代码，Agent 直接执行 `ankole-files put <dir> <drive_prefix>` 覆盖云盘目录即可，无需重新注册。

每次触发运行（attempt）都会获取最新的 Agent `WorkerEnv` 环境变量，并根据当前已启用的 Skill 动态生成当次专属的 `MCPORTER_CONFIG`。Worker 不会预先猜测脚本会用到哪个 MCP 服务；脚本可通过 `mcporter` 配合标准输入（stdin）JSON 直接调用任一已启用 Skill 暴露的 MCP 工具。注意：Automation Job 运行时不加载 Skill 的 Markdown 文本指令，也不读取 Agent Home 下持久保存的本地 `mcporter` 配置。

运行时 SDK 向脚本暴露两个核心函数：`context()` 与 `emitEvent(payload)`。其中 `context().event` 返回的正是该触发器在直接唤醒模式下写入 Signal 的同款 CloudEvents 事件信封。若脚本执行完毕未调用 `emitEvent`，当次运行即视为静默成功；若调用了一次或多次 `emitEvent`，则会向归属会话持久化写入 `automation_job.emitted` 信号。

需要注意，`context()` 与 `emitEvent` 仅在平台受管运行（platform run）上下文中注入。在工作区直接裸跑 `bun main.ts` 只能验证语法环境与纯本地逻辑分支；完成注册后，必须用真实的测试触发器把每个调用了 SDK 的分支实际跑通一遍，并核查生成的持久化运行记录。此外，`emitEvent` 绝不会降级退化为往标准输出打印日志——只有当对应的 Signal 已在控制面数据库持久化落盘后，它返回的 Promise 才会正式 resolve。

每一次触发消费都会在同一个 PostgreSQL 事务内原子写入持久化运行记录（即 Checkback 认领、Cron 游标推进或 Webhook 接收动作，与脚本 `run` 记录同时提交）。脚本自身抛错、返回非零退出码或执行超时均属于确定的运行终态，系统不会自动重跑；而若因底层 Worker 容器失联导致中断，则属于基础设施故障，现有的 Oban 唤醒链路会发起一次带新栅栏标识的重试（fenced attempt）。由于基础设施重派可能导致脚本逻辑再次执行，编写脚本时必须保证外部副作用具备幂等安全性。

以下管理命令仅在活跃的 Agent 回合（turn）内可用：

- `create-automation-job-cli --dir <path> --label <text> [--wake-on-failure]`
- `list-automation-jobs-cli [--limit <1-500>]`
- `show-automation-job-cli --id <automation-job-id> [--runs <1-100>]`
- `cancel-automation-job-cli --id <automation-job-id>`

在运维侧，Console 的“自动化任务”页面会展示每个 Job 及其近期运行状态、尝试次数、报错详情、退出码与有界 `stdout`/`stderr` 日志尾部；而面向模型侧的完整使用规范，则始终由 `create-automation-job-cli --help` 单点维护。

## 新增 CLI 能力的要求

向代码库新增一项 Worker CLI 能力时，请遵循以下工程规范：

- 实现代码统一放在 `app/agent_computer/src/cli/` 下，每个命令族单独建一个子目录。
- 无论传入 `--help` 还是 `-h`，都必须向标准输出打印完整的使用契约并以退出码 `0` 正常结束，且帮助输出不得依赖活跃回合上下文或网络连接。由于外层命令包装器可能会在参数前前置子命令名，请遍历整个参数列表在任意位置识别帮助标志。
- 参数校验失败时仅输出简短的 `usage` 用法提示，不要把简短报错提示当作完整契约文档。
- 在 Agent 可能用到该能力的每一个上游决策点补充一句话指针；措辞保持客观中立，只讲清适用条件并引导查阅 `--help`。
- 当编写插件 Skill 将该 CLI 能力与某个外部系统结合时，在 Skill 开篇直接指向 `--help`，正文只写该外部系统特有的领域规则。
