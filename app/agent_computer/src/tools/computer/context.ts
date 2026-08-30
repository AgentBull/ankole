import type { ContainerComputer } from './computer'

/** Shared per-run state for the computer tools (workspace roots + computer factory). */
export interface ComputerToolContext {
  /** Agent-scoped filesystem home. */
  agentHome: string
  /** Session or Job workspace for the active turn. */
  workspaceRoot: string
  userFilesRoot: string
  /** Resolve-or-create the agent's container computer facade (memoized for the run). */
  getComputer: (signal?: AbortSignal) => Promise<ContainerComputer>
}
