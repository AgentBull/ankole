# 生命周期命名用 subagent，不用 codex

委托的工具、表、事件与配置在首版即命名为 subagent 族：工具 `subagent`、表 `subagent_delegations`（`runtime` 列记录抽象执行类别，当前唯一合法值 `task_worker`）、事件 `subagent.delegation.*`。Ankole 尚未发布公共兼容契约，此刻改名零成本；发布后再改是破坏性迁移。

边界规则：`task_worker` 是可替换的委托执行抽象，Codex 是当前实现。`agent_computer.subagent.*` 拥有生命周期语义，`agent_computer.codex.*` 只拥有 Codex 实现机制；领域契约不得用具体实现名代替 runtime 类别。

出处：`internals/docs/SubagentDelegation.zh.md` §1 决策 8。
