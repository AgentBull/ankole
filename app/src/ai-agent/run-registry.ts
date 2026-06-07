import type { Agent } from './core'

export interface ActiveAiAgentRun {
  abortController: AbortController
  agent: Agent
  conversationId: string
  leaseId: string
  startedAt: Date
  triggerMessageId: string
}

export class AiAgentRunRegistry {
  private readonly runs = new Map<string, ActiveAiAgentRun>()

  set(run: ActiveAiAgentRun): void {
    this.runs.set(run.conversationId, run)
  }

  delete(conversationId: string, leaseId?: string): void {
    const existing = this.runs.get(conversationId)
    if (!existing) return
    if (leaseId && existing.leaseId !== leaseId) return
    this.runs.delete(conversationId)
  }

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
    }
  }
}

export const aiAgentRunRegistry = new AiAgentRunRegistry()
