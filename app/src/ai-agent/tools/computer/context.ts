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

/**
 * Derives a short, stable tag used to namespace worker-side names (shell names,
 * tmux sessions, artifact dirs) by execution scope.
 *
 * The raw `executionScopeId` is an arbitrary conversation id — too long and not
 * guaranteed safe for shell/tmux identifiers. Hashing makes it deterministic
 * (the same scope yields the same tag across turns and process restarts, so a
 * reconnecting worker re-targets the same shell), and clipping to 8 hex chars
 * keeps it short. 8 chars is enough because this only namespaces state, it is
 * not a security boundary: a collision would merely let two scopes share a
 * shell, which is acceptable and vanishingly unlikely here.
 */
export function executionScopeTag(context: Pick<ComputerToolContext, 'executionScopeId'>): string {
  return genericHash(context.executionScopeId).slice(0, 8)
}
