# 后台 Agent 工作统一命名为 BackgroundAgentJob

状态：有效。

由模型或确定性 ingress 创建、在 owner turn 之外 durable 执行的工作项统一
命名为 **Background Agent Job**：

- 领域实体：`BackgroundAgentJob`；
- 模型工具与 RuntimeFabric RPC：`background_agent_job`；
- PostgreSQL：`background_agent_jobs`、`background_agent_job_turns`；
- Actor event：`background_agent_job.*`；
- 专属 actor session：`job:<job_id>`。

这个名称明确区分三层事实：tool call 是创建或控制请求，BackgroundAgentJob
是 PostgreSQL 持有的 durable 工作项，Codex thread 是当前唯一 runner 的可
恢复执行状态。Ankole 领域中不再使用 delegation、task worker、Codex Job 或
subagent 指代这条生命周期；`subagent` 只保留为 Codex 自身的原生执行概念。

Agent Plugin 只是普通 Job 的能力选择。Job 保存 Plugin ID，runner 每次 prepare
解析当前 enabled 包与成员。Plugin 使用标准 Codex Plugin 包，并可带 Ankole 约定的
`workspace-template/` 目录；它不能定义新的 Job 类型、生命周期或字段。编译进
Elixir/OTP release 的扩展统一称为 Control Plane Plugin。

详细契约见 `docs/design-docs/BackgroundAgentJob.md`。
