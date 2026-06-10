import { genericHash } from '@agentbull/bullx-native-addons'
import type { Computer } from '@agentbull/bullx-computer'

/** Shared per-run state for the computer tools (lazy session + background ids). */
export interface ComputerToolContext {
  /** Current BullX Agent UID; the agent-level scope (worker binding, workspace, browser profile/cookies). */
  agentUid: string
  /**
   * Conversation-level execution scope. Persistent shells, tmux names, browser
   * execution sessions/captures/artifacts are namespaced by this so concurrent
   * conversations of one agent do not share execution state.
   */
  executionScopeId: string
  /** Resolve-or-create the agent's computer session (memoized for the run). */
  getComputer: (signal?: AbortSignal) => Promise<Computer>
  /** Command ids started via terminal(background=true), for the process tool. */
  backgroundIds: Set<string>
}

/** Short stable tag for namespacing worker-side names by execution scope. */
export function executionScopeTag(context: Pick<ComputerToolContext, 'executionScopeId'>): string {
  return genericHash(context.executionScopeId).slice(0, 8)
}
