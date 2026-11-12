---
title: Automation Job
description: 通过定时、回调和外部事件运行 Applet Action，并检查持久化的执行结果。
section: User guide
order: 22
---

自动化任务（Automation Job）在 Function Runtime 中运行已发布的 Applet Action，用确定性代码处理工作，无须启动 Agent 回合。任务保存配置和持久状态，Applet 发布的代码定义处理逻辑、并发策略和续执行上限。

## 创建任务并连接触发源

1. 发布 Applet，并在服务端模块中导出 `actions` 表。
2. 打开 Applet 的「自动化」面板，选择 Action，创建个人或团队任务。
3. 添加定时计划、创建回调端点，或关联外部事件源。定时支持 Cron 表达式和固定间隔；外部事件源来自租户已配置的连接。
4. 手动运行一次定时计划，或发送测试回调，再打开对应的运行记录，检查输入和结果。

Agent 可通过 `ankole-pod` (`jobs.*`) 完成相同操作，具体命令以 `ankole-pod --help` 为准。Applet 界面可使用 `@ankole/applet-sdk` 的 `useAppletJobs()` 和 `useJobSources(jobID)`。

## 个人与团队执行名义

个人任务以所属员工的身份执行，员工本人及其个人助理可管理触发源。团队任务使用 Applet 所有者的服务权限，管理任务需要页面编辑权限。Applet 移入回收站后不再接受新的执行。删除任务会清理其持有的定时和回调端点，并解除外部事件关联；其他消费者仍在使用的共享订阅不会被删除。

## 输入、状态与外部工具

Action 通过 `ctx.signal` 读取 CloudEvents 输入，通过 `ctx.job.config` 读取任务配置，通过 `ctx.state` 保存持久状态。长任务使用 `remainingMs()` 和 `continueSlice()` 分段执行。通过 `AnkoleRuntime.mcp` 调用连接器工具；团队任务使用对应的 `AnkoleRuntime.admin` 能力。应用凭据和个人授权在 Pod「外部连接」页面管理。

发布新的 Applet 版本即可更新后续执行的代码。不要用本地文件保存跨运行的业务状态。

## 查看结果与处理失败

「自动化」面板显示运行状态、开始和结束时间、触发来源、结果、错误及有长度上限的日志。排查时可展开输入和日志。投递回执会关联运行记录，并标明输入是否合并到了另一次待执行任务。

Action 声明自身的并发和重放策略，外部写操作应符合所选策略。缺少个人授权时，错误中会提供授权链接；完成授权后再重试目标操作。若上游只完成了部分写入，错误会携带已创建资源的 ID，便于只补做剩余步骤。

继续阅读[定时任务](../schedules/)、[Webhook 委托](../webhook-delegations/)和[自动化蓝图](../automation-blueprints/)。
