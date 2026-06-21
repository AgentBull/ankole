/**
 * In-memory bookkeeping for the latest unanswered clarify question, keyed by
 * conversation id.
 *
 * A clarify ask ends its IM turn: the question goes out, the generation commits
 * and releases its lease, and the user's reply arrives as a normal inbound
 * message that starts the next turn. Nothing waits in-process, so this registry
 * holds no resolvers, timers or lease state tied to a run — only what the
 * inbound side needs to dress the answer: lock the question card with the
 * chosen option, and upgrade the next non-@mention group reply to addressed
 * (room gate). Entries expire after a TTL so the gate cannot capture unrelated
 * chatter forever; an expired or restart-dropped entry only costs the niceties,
 * the answer itself still works as a plain message.
 */

export interface ClarifyEntry {
  conversationId: string
  toolCallId: string
  question: string
  choices: string[]
  /** Outbound key of the question post, so the answer side can target that exact card to lock it. */
  askedOutboundKey: string
  providerRoomId: string
  providerThreadId: string
  /** Whether the question was sent as an interactive card (vs. plain text); decides if there is a card to lock on answer. */
  cardCapable: boolean
}

interface StoredClarifyEntry extends ClarifyEntry {
  expireTimer: ReturnType<typeof setTimeout> | null
}

export class AiAgentClarifyRegistry {
  private readonly entries = new Map<string, StoredClarifyEntry>()
  // Reverse index by provider room so the external-gateway handler can route a
  // group reply (even non-@mention) to the pending question. A room has at most
  // one active conversation, hence one pending clarify.
  private readonly roomGate = new Map<string, string>()

  /**
   * Register the pending question for a conversation, replacing any earlier
   * unanswered one (the newest ask wins; a stale card simply stays unlocked and
   * later clicks on it find no entry).
   */
  set(entry: ClarifyEntry, ttlMs?: number): void {
    this.clear(entry.conversationId)
    const expireTimer =
      ttlMs && ttlMs > 0 && Number.isFinite(ttlMs) ? setTimeout(() => this.clear(entry.conversationId), ttlMs) : null
    // The expiry timer must not keep the process alive on shutdown — it only
    // drops a nicety, so it is unref'd. Optional-chained because the test/runtime
    // timer handle does not always expose `unref`.
    expireTimer?.unref?.()
    this.entries.set(entry.conversationId, { ...entry, expireTimer })
    if (entry.providerRoomId) this.roomGate.set(entry.providerRoomId, entry.conversationId)
  }

  has(conversationId: string): boolean {
    return this.entries.has(conversationId)
  }

  get(conversationId: string): ClarifyEntry | undefined {
    return this.entries.get(conversationId)
  }

  /** Conversation with a pending clarify in this provider room, if any (group reply gate). */
  pendingConversationForRoom(providerRoomId: string): string | undefined {
    return this.roomGate.get(providerRoomId)
  }

  /** Remove and return the pending question — the answer arrived. First caller wins. */
  take(conversationId: string): ClarifyEntry | undefined {
    const entry = this.entries.get(conversationId)
    if (!entry) return undefined
    this.clear(conversationId)
    // clear() already disposed the timer; strip the handle so callers get the
    // public ClarifyEntry shape without the internal field.
    const { expireTimer: _expireTimer, ...publicEntry } = entry
    return publicEntry
  }

  /** Drop the pending question (answered, expired, /new, /stop, or takeover). */
  clear(conversationId: string): boolean {
    const entry = this.entries.get(conversationId)
    if (!entry) return false
    if (entry.expireTimer) clearTimeout(entry.expireTimer)
    this.entries.delete(conversationId)
    if (entry.providerRoomId && this.roomGate.get(entry.providerRoomId) === conversationId) {
      this.roomGate.delete(entry.providerRoomId)
    }
    return true
  }
}

export const aiAgentClarifyRegistry = new AiAgentClarifyRegistry()
