---
title: 自动化蓝图
description: 将触发器与 Agent 会话、Automation Job、后台任务和信号路由规则组合成自动化流程，并理清与 Workflow 的边界。
section: Guides
order: 309
---

先选择触发源，再选择消费者。定时、Checkback、普通回调端点和连接器事件提供 CloudEvents 输入；Agent 负责判断和对话，Applet Action 负责确定性处理。一个来源可以通过多个绑定投递给不同消费者。

## 常见组合

| 目标 | 配置 | 结果 |
| --- | --- | --- |
| 每日简报 | Agent 定时，加上任务和投递目标 | Agent 收集信息并发送摘要 |
| 高频机械检查 | Applet 任务及其持有的定时 | Action 检查条件并记录结果，不启动模型回合 |
| 延后跟进一次 | Agent Checkback | 到时恢复原会话 |
| 响应外部变化 | 连接器订阅或普通回调端点 | 绑定触发选定的任务或 Agent |
| 长时间研究 | Agent 定时加后台 Agent 任务 | 独立研究，完成后回报原会话 |
| 安静观察频道 | 安静的聊天绑定加 Agent 定时 | 持续记录消息，定时汇总 |

## 实现确定性监控

将检查逻辑发布为 Applet Action，在 Applet「自动化」面板创建任务、填写配置，再添加定时或外部事件源。通过 `ctx.signal.data` 读取事件，通过 `ctx.state` 保存游标或上次观测值。使用 `AnkoleRuntime.mcp` 调用平台工具；有多个连接时明确选择连接。

分别测试正常、条件变化和上游失败的情况，检查真实运行记录的输入、结果和日志。需要通知用户时，在 Action 中明确调用对应平台的消息工具；静默运行成功不会自动发送聊天消息。

## 选择执行方式

每次事件都需要记忆、解释或文字答复时，直接交给 Agent。规则能够用代码表达时，使用 Applet 任务。[Workflow](../workflows/) 适合在一个 Agent 回合内并行调用有限个子 Agent；[后台 Agent 任务](../background-jobs/) 适合较长的智能体工作，与 Applet Action 是不同的执行方式。

设置与恢复见[自动化任务](../automation-jobs/)，时间规则见[定时任务](../schedules/)，回调见[Webhook 委托](../webhook-delegations/)。
