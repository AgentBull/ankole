// Public surface for the Agent Computer text loop. Keep this intentionally small:
// the control plane owns transcript persistence and compaction, while this package
// only exposes the active provider/tool loop and the types needed to build tools.

export { runAgentLoop } from './agent-loop'
export type { AgentEventSink } from './agent-loop'
export * from './types'
