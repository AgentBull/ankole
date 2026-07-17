import type { ContainerComputer } from './computer'

/** Shared per-run state for the computer tools (workspace root + execution scope). */
export interface ComputerToolContext {
  /** Session-local /workspace root for the active turn. */
  workspaceRoot: string
  /** Conversation-level scope used for per-turn tool diagnostics. */
  executionScopeID: string
  /** Resolve-or-create the agent's container computer facade (memoized for the run). */
  getComputer: (signal?: AbortSignal) => Promise<ContainerComputer>
}
