/**
 * In-memory resolver registry for pending clarify waits, keyed by conversation
 * id (a conversation has at most one active run, hence one pending clarify).
 *
 * Mirrors the module-singleton style of `run-registry.ts` and the in-memory
 * `_entries` map of hermes' clarify_gateway: process restart drops pending
 * waits (recovery re-asks). This is the bridge between the clarify tool's parked
 * `execute` and the inbound message that answers it.
 */

export type ClarifyResolution =
  | { kind: 'answer'; text: string; choiceIndex?: number }
  | { kind: 'timeout' }
  | { kind: 'aborted' }
  | { kind: 'superseded' }

export interface ClarifyEntry {
  conversationId: string
  toolCallId: string
  leaseId: string
  question: string
  choices: string[]
  /** When true, the next inbound message is taken as the answer (text-intercept). */
  awaitingText: boolean
  askedOutboundKey: string
  resolve: (resolution: ClarifyResolution) => void
  timeoutTimer: ReturnType<typeof setTimeout>
  heartbeatTimer: ReturnType<typeof setInterval>
  signal?: AbortSignal
  onAbort?: () => void
}

export class AiAgentClarifyRegistry {
  private readonly entries = new Map<string, ClarifyEntry>()
  private readonly reserved = new Set<string>()

  /**
   * Synchronously claim the conversation slot before the async send, so a second
   * concurrent clarify in the same batch fails immediately without sending a
   * duplicate question. Returns false if a clarify is pending or reserved.
   */
  tryReserve(conversationId: string): boolean {
    if (this.entries.has(conversationId) || this.reserved.has(conversationId)) return false
    this.reserved.add(conversationId)
    return true
  }

  /** Release a reservation taken by `tryReserve` when the send fails before `register`. */
  releaseReservation(conversationId: string): void {
    this.reserved.delete(conversationId)
  }

  /** Register a pending clarify. Throws if one already exists for the conversation. */
  register(entry: ClarifyEntry): void {
    this.reserved.delete(entry.conversationId)
    if (this.entries.has(entry.conversationId)) {
      throw new Error(`clarify already pending for conversation ${entry.conversationId}`)
    }
    this.entries.set(entry.conversationId, entry)
  }

  has(conversationId: string): boolean {
    return this.entries.has(conversationId)
  }

  get(conversationId: string): ClarifyEntry | undefined {
    return this.entries.get(conversationId)
  }

  /**
   * Single exit funnel: clears timers, detaches the abort listener, removes the
   * entry, and resolves the parked promise exactly once. Idempotent — returns
   * false if there was nothing pending.
   */
  resolveByConversation(conversationId: string, resolution: ClarifyResolution): boolean {
    const entry = this.entries.get(conversationId)
    if (!entry) return false
    clearTimeout(entry.timeoutTimer)
    clearInterval(entry.heartbeatTimer)
    if (entry.signal && entry.onAbort) entry.signal.removeEventListener('abort', entry.onAbort)
    this.entries.delete(conversationId)
    entry.resolve(resolution)
    return true
  }

  /** Cancel a pending clarify (e.g. /stop -> 'aborted', /new -> 'superseded'). */
  abort(conversationId: string, reason: 'aborted' | 'superseded'): boolean {
    return this.resolveByConversation(conversationId, { kind: reason })
  }
}

export const aiAgentClarifyRegistry = new AiAgentClarifyRegistry()
