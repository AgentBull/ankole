import type { Agent } from './core'

/** The process-local handle for one in-flight run: its {@link Agent} and the {@link AbortController} a stop signal pulls, tagged with the lease that owns it. */
export interface ActiveAiAgentRun {
  abortController: AbortController
  agent: Agent
  conversationId: string
  leaseId: string
  startedAt: Date
  triggerMessageId: string
}

/**
 * In-process index of the live run per conversation, keyed by conversation id so
 * there is at most one entry per conversation. The durable single-writer
 * guarantee is the database lease (only one acquirer wins), not this map; the
 * registry exists so an out-of-band signal that arrives on this same process —
 * `/stop`, `/new`, daily reset, an expired-lease takeover, a recalled trigger —
 * can reach into the running attempt and abort it. A run on another worker is
 * unreachable here and is stopped by lease fencing instead.
 *
 * It is also what lets a fresh delivery recognize that a run is already going for
 * its conversation rather than starting a duplicate: the would-be second run
 * fails to acquire the lease, parks its input as a pending follow-up, and the
 * registered run drains it at a turn boundary.
 */
export class AiAgentRunRegistry {
  private readonly runs = new Map<string, ActiveAiAgentRun>()

  /** Registers the run as the live one for its conversation. A later run for the same conversation overwrites the entry (the prior lease has already lost ownership by then). */
  set(run: ActiveAiAgentRun): void {
    this.runs.set(run.conversationId, run)
  }

  /**
   * Removes the entry when a run finishes. The optional `leaseId` scopes the
   * delete to the caller's own run: if a newer lease has already registered its
   * run under this conversation, the stale finisher must not evict the successor.
   */
  delete(conversationId: string, leaseId?: string): void {
    const existing = this.runs.get(conversationId)
    if (!existing) return
    if (leaseId && existing.leaseId !== leaseId) return
    this.runs.delete(conversationId)
  }

  /** Unconditional removal, ignoring the lease guard. Used by {@link abortAndWait} once it has already settled the specific run it aborted. */
  forceDelete(conversationId: string): void {
    this.runs.delete(conversationId)
  }

  /**
   * Fire-and-forget abort of the live run for a conversation: signals both the
   * agent loop and its {@link AbortController}, then returns without waiting for
   * the run to unwind. Callers that must not race a still-finishing run use
   * {@link abortAndWait} instead.
   */
  abort(conversationId: string, reason: string): void {
    const run = this.runs.get(conversationId)
    if (!run) return
    run.agent.abort()
    run.abortController.abort(reason)
  }

  /**
   * Abort the active run and wait for it to settle (ported from AgentHarness.abort's settlement contract).
   * Returns once the agent's run promise resolves or `timeoutMs` elapses, so callers like `/stop` and `/new`
   * don't race a still-finishing background generation. Lease fencing remains the authoritative guard.
   */
  async abortAndWait(conversationId: string, reason: string, timeoutMs = 5000): Promise<void> {
    const run = this.runs.get(conversationId)
    if (!run) return
    run.agent.abort()
    run.abortController.abort(reason)
    let timer: ReturnType<typeof setTimeout> | undefined
    const timeout = new Promise<void>(resolve => {
      timer = setTimeout(resolve, timeoutMs)
    })
    try {
      await Promise.race([run.agent.waitForIdle(), timeout])
    } finally {
      if (timer) clearTimeout(timer)
      if (this.runs.get(conversationId)?.leaseId === run.leaseId) this.forceDelete(conversationId)
    }
  }
}

/** Process-wide singleton; the runtime and its collaborators all share this one live-run index. */
export const aiAgentRunRegistry = new AiAgentRunRegistry()
