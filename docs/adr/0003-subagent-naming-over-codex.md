# 生命周期命名用 subagent，不用 codex

委托的工具、表、事件与配置在首版即命名为 subagent 族：工具 `subagent`、表 `subagent_delegations`（`runtime` 列记录具体实现，当前唯一合法值 `codex`）、事件 `subagent.delegation.*`。Ankole 尚未发布公共兼容契约，此刻改名零成本；发布后再改是破坏性迁移。

边界规则：`agent_computer.subagent.*` 拥有生命周期语义，`agent_computer.codex.*` 只拥有 Codex 运行时机制；工具与文档描述中注明由 Codex 实现，但领域语言不以 runtime 命名概念。

出处：`internals/docs/SubagentDelegation.zh.md` §1 决策 8。
