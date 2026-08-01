---
title: Worker CLI 能力
description: 把 Agent 能力做成 shell 命令,由 --help 承载契约,并把一句话指针放在 Agent 做相关决策的位置。
section: Developer guide
order: 114
---

Ankole 的一部分能力是 Agent Computer 里的 shell 命令,而不是模型可见的工具。Agent 像使用 `gh` 或 `kubectl` 一样经 shell 调用它们。Webhook 凭据命令与 automation job 命令都采用这种形态。

本页说明什么时候用这种形态交付能力,以及让它无需工具注册、无需技能索引条目、无需 system prompt 段落也能被发现并正确使用的披露架构。

## 什么时候 CLI 是正确形态

同时满足下列条件时,能力适合 CLI 形态:

- Agent 在更大的 shell 工作流里、与其他命令并肩使用它,脚本或 background agent job 也可能需要调用它。
- 它只在一条决策路径上有意义。从不创建 webhook 的 Agent 不需要知道 `create-webhook-cli` 存在。
- 它不需要让模型填写 JSON schema,几个 flag 就能承载输入。

模型可见工具在每个 turn 都消耗上下文;CLI 在 Agent 走到相关路径之前零成本。

## 披露架构

三条规则取代工具注册与技能索引:

**`--help` 就是契约文档。**CLI 的 `--help` 输出承载 Agent 正确使用该能力所需的知识:它是什么、信任模型、保证、以及一次完整使用长什么样。它随二进制发布,与其描述的行为同版本,不会像独立文档那样漂移。为零上下文的读者书写,陈述目标与约束而非程序步骤。`create-webhook-cli --help` 是参考样例。

**指针放在决策面上。**发现性来自一句话指针,放在 Agent 恰好在做相邻决策的位置:某个工具描述、某个集成特定外部系统的 Skill、或另一个 CLI 的 `--help`。每条指针陈述能力何时相关、去哪里读全文,不引导选择。这种形态的每个能力必须在相关路径的必经面上至少有一条指针——让能力有意义的那条路径,同时给出披露它的位置。

**通用知识住 `--help`,领域知识住插件 Skill。**对该能力的一切使用都成立的契约归 `--help`;集成某个外部系统的 Skill 只保留该系统的增量。例如 GitHub webhook Skill 开篇即指引 Agent 阅读 `create-webhook-cli --help` 获取通用 webhook 契约,自身只覆盖 hook 注册、ping 验证、delivery 对账与 GitHub hook 配额。第二个集成免费复用整个通用层。

## Automation job

Automation job 是确定性脚本消费者。Checkback、cron schedule 或 webhook endpoint 可以设置 `automation_job_id`,让脚本消费触发,而不是每次都直接唤醒 Agent 会话。未设置该字段的触发器保持原有直接唤醒行为。

Agent 在自己的 Agent Home 内创建独立目录,写入 `main.ts`,手工验证运行环境与不调用 SDK 的分支,再用 `create-automation-job-cli` 注册。Worker 在注册时和每次运行时都解析 realpath,确认目录和入口仍位于 Agent Home 内。运行时直接执行磁盘上的当前文件,所以修改脚本无需重新注册。

每个 attempt 都会获得最新 Agent WorkerEnv,以及从当前 enabled Skills 和全部发布内置 Direct MCP server 按次生成的 `MCPORTER_CONFIG`。这是同一份静态能力集;Worker 不预测脚本会使用哪个 server。脚本可以通过 mcporter 和 stdin JSON 调用一个已选 MCP 工具。Automation 不读 Skill instructions,也不使用 Agent Home 持久 mcporter 配置。

运行 SDK 提供 `context()` 与 `emitEvent(payload)`。`context().event` 是该触发器直接投递时会写入 ActorEvent 的同一 CloudEvents 信封。脚本不调用 `emitEvent` 即静默成功;调用一次或多次则向归属会话持久写入 `automation_job.emitted`。

`context()` 与 `emitEvent` 只存在于平台 run 内。直接执行 `bun main.ts` 只能验证运行环境和不调用这两个函数的分支。注册后,必须为每个 SDK 分支使用一次测试触发器,再检查对应的持久 run。`emitEvent` 不会降级为 stdout;只有 ActorEvent 已持久化后,它返回的 Promise 才会 resolve。

每次触发消费都会在同一个 PostgreSQL 事务里创建持久运行记录:checkback claim、cron advance 或 webhook accept 与 run 行同时提交。脚本异常、非零退出和超时是终态,不重试。Worker 丢失属于基础设施故障,现有 Oban wake edge 会用新的 fenced attempt 重派。重派可能重复脚本副作用,因此脚本必须让重复执行无害。

这些命令只在活跃 Agent turn 内可用:

- `create-automation-job-cli --dir <path> --label <text> [--wake-on-failure]`
- `list-automation-jobs-cli [--limit <1-500>]`
- `show-automation-job-cli --id <automation-job-id> [--runs <1-100>]`
- `cancel-automation-job-cli --id <automation-job-id>`

Console 的“自动化任务”页展示 job 及其最近运行状态、attempt 次数、错误、exit code 与有界 stdout/stderr 尾部。模型侧规范说明仍由 `create-automation-job-cli --help` 单点拥有。

## 新增 CLI 能力的要求

- 实现放在 `app/agent_computer/src/cli/` 下,每个命令族一个目录。
- `--help` 与 `-h` 输出完整契约,stdout、exit 0,不依赖 turn 或网络。命令包装器会前置子命令,所以在参数列表任意位置检测 help flag。
- 保留简短 usage 字符串用于参数错误;它不是契约文档。
- 在 Agent 需要该能力的每个决策面加一句指针,指针不带倾向:陈述条件,指出 `--help`。
- 插件 Skill 集成该能力与外部系统时,开篇放 `--help` 指针,Skill 只写领域增量。
