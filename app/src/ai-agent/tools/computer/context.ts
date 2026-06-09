import type { Computer } from '@agentbull/bullx-computer'

/** Shared per-run state for the computer tools (lazy session + background ids). */
export interface ComputerToolContext {
  /** Current BullX Agent UID; used as the default browser session/profile id. */
  agentUid: string
  /** Resolve-or-create the agent's computer session (memoized for the run). */
  getComputer: (signal?: AbortSignal) => Promise<Computer>
  /** Command ids started via terminal(background=true), for the process tool. */
  backgroundIds: Set<string>
}
