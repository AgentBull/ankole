---
title: Automation Job
description: 让确定性脚本承接 Cron、Checkback 和 Webhook 触发：机械检查静默完成，需要判断时再唤醒 Agent。
section: User guide
order: 22
---

Cron、Checkback 和 webhook endpoint 这三种触发器默认唤醒一个 Agent 会话。Automation job 是第二种承接方式：一段由 Agent 编写、放在它自己 Agent Home 里的确定性脚本。触发器绑定到它之后，到点或到件时系统运行脚本，而不是启动一个 Agent 回合。

脚本自己决定什么值得打扰你：可以静默结束，也可以调用 `emitEvent` 把一个事件发回归属会话，让 Agent 带着脚本准备好的上下文醒来。机械检查由代码守夜，模型只留在需要判断的关节。

## 适合与不适合

处理过程只是确定性的获取、比较、解析或预定动作时，适合交给 automation job。典型例子：每 5 分钟查一次行情，价格在阈值之上就直接结束，跌破阈值才发射当前价格，唤醒 Agent 复核并提醒你。这样每次检查的成本只是一次脚本执行，而不是一轮模型调用。

每次触发都需要记忆、判断或对话时，让触发器保持直接唤醒 Agent。两种选择都不是永久的：可以先直接唤醒，处理被证明是机械的以后再移入脚本，也可以随时改回来。

## 直接让 Agent 创建

不必打开 Console。在聊天里说清检查什么、条件是什么、什么情况下要叫你：

```text
帮我盯住 7709 的价格：每 5 分钟查一次，跌破 3.5 再提醒我，
其余时间保持安静。收盘后汇报一次当天的检查是否正常。
```

Agent 会在自己的 Agent Home 里写脚本、先手工验证，再注册成 automation job，创建 Cron 并绑定给它，最后设置一个收盘对账 Checkback。脚本修改即生效，不需要重新注册：每次运行执行的都是磁盘上的当前文件。

## 运行记录与失败处理

每次触发都留下一条运行记录：开始与结束时间、状态、exit code、报错和有界日志。Agent 可以在会话里查询这份历史；Console 的 **Automation Jobs** 页面提供同样的只读视图。

- 默认情况下，失败只记入运行记录，不打扰任何人。
- 让 Agent 在创建时开启 `wake_on_failure`，每次失败运行都会唤醒归属会话。
- 长期值守建议搭配一个对账 Checkback：Agent 到点醒来查运行历史，「14:00 起检测中断」这类静默故障由它大声报告。

脚本抛错、非零退出或超时是脚本自己的结局，系统不重试，下一个周期自然到来。Worker 故障则会重新派发这次运行，因此运行可能重叠、投递可能重复；Agent 写脚本时会让重跑无害。

## 数据纪律

脚本经 `emitEvent` 发回的载荷被当作不可信输入呈现给 Agent，与 webhook 回执遵守同一纪律：有后果的事实要先向权威来源复核，Agent 才会据此行动或答复。

## 收尾

结束一项值守时，先取消指向脚本的 Cron、Checkback 或 webhook endpoint，再取消 automation job；触发器打进已取消的 job 会留下一条失败运行记录。没有触发器指向的 job 没有运行成本，留着只占一行列表。

触发器的配置见[计划任务](../schedules/)和 [Webhook 委托](../webhook-delegations/)，常见组合形态见[自动化蓝图](../automation-blueprints/)，脚本、SDK 与命令的完整合同见 [Worker CLI 能力](../cli-capabilities/)。
