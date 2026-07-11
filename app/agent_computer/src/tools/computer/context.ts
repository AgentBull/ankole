import { createHash } from 'node:crypto'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { ContainerComputer } from './computer'

/** Shared per-run state for the computer tools (workspace root + execution scope). */
export interface ComputerToolContext {
  /** Current Ankole Agent UID; used to namespace browser/session artifacts. */
  agentUID: string
  /** Session-local /workspace root for the active turn. */
  workspaceRoot: string
  /**
   * Conversation-level execution scope. Persistent shells, tmux names, browser
   * execution sessions/captures/artifacts are namespaced by this so concurrent
   * conversations of one agent do not share execution state.
   */
  executionScopeID: string
  /** Decrypted remote browser CDP config for this turn, resolved by control-plane RPC. */
  browserRemoteCDPConfig?: JSONObject | null
  /** Local browser idle release TTL in milliseconds, resolved by AppConfigure. */
  localBrowserIdleTtlMs?: number
  /** Resolve-or-create the agent's container computer facade (memoized for the run). */
  getComputer: (signal?: AbortSignal) => Promise<ContainerComputer>
}

/**
 * Derives a short, stable tag used to namespace worker-side names (shell names,
 * tmux sessions, artifact dirs) by execution scope.
 *
 * The raw `executionScopeId` is an arbitrary conversation id, too long and not
 * guaranteed safe for shell/tmux identifiers. Hashing makes it deterministic
 * across turns and process restarts; 8 chars is sufficient because this is only
 * a namespace, not a security boundary.
 */
export function executionScopeTag(context: Pick<ComputerToolContext, 'executionScopeID'>): string {
  return createHash('sha256').update(context.executionScopeID).digest('hex').slice(0, 8)
}
