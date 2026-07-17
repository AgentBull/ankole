# BackgroundAgentJob 使用专属 actor session

状态：有效。

每个 BackgroundAgentJob 使用专属 actor identity：

```text
{agent_uid, "job:<job_id>"}
```

现有 ActorRuntime 已经提供同一 session 串行投递、执行租约、失活重投、
fence 和运行中打断。复用这条轨道即可满足 Job 的 durable 执行要求；worker
不再拥有第二套本地 JobQueue、调度器或生命周期状态。

owner session 只负责创建、控制和接收 Job wakeup。Job session 不继承 owner
对话历史，也不承担面向用户的对话身份。完整任务通过 PostgreSQL Job 的
`task` 字段交给 runner。

## Consequences

- PostgreSQL Job 与 ActorEvent 是 durable truth，worker 只持有当前执行。
- 只有取得真实执行租约才增加 `attempts`；placement 失败不消耗机会。
- worker 丢失后，同一个 Job 可以在另一 worker 上恢复，不会并发双跑。
- 任何未来 runner 也必须复用这一生命周期边界，不能在 worker 内另造队列。

详细契约见 `docs/design-docs/BackgroundAgentJob.md`。
