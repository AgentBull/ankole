// A full in-memory fake of an IM platform (Lark/Slack-shaped), used as the
// outer world in External Gateway integration tests. It plays two roles at once:
//   1. The platform the bot talks TO — adapter outbound methods (post/edit/
//      delete/react/reconcile/streaming card) mutate its message store, so tests
//      can assert what the user would actually see.
//   2. The platform that pushes events IN — `MockImConversation` builds webhook
//      payloads and feeds them through the real adapter + runtime, the same path
//      a production webhook takes.
// The design choice that makes the tests meaningful: state is modeled FIRST
// (what the platform shows), then events are emitted from it. Failure injection
// runs before any outbound mutation, so a "provider rejected the send" test
// leaves the visible state untouched — exactly like the real provider. This lets
// a test compare the gateway's projected mirror (`external_messages`) against the
// platform's own visible latest-state and demand they match.
import type { BullXExternalGatewayGroupMessageMode } from '@agentbull/bullx-sdk/plugins'
import { parseMarkdown } from '../core/markdown'
import {
  type ExternalGatewayAdapter,
  type ExternalGatewayAdapterCapabilities,
  type ExternalGatewayAdapterContext,
  type ExternalGatewayBeginStreamingCardInput,
  type ExternalGatewayMessageInput,
  type ExternalGatewayMessageReconciliation,
  type ExternalGatewayOutboundOptions,
  type ExternalGatewayRawMessage,
  type ExternalGatewayReasoningTraceViewAuthInput,
  type ExternalGatewayStreamingCardHandle,
  type ExternalGatewayWebhookOptions
} from '../core'

export type MockImGroupMessageMode = BullXExternalGatewayGroupMessageMode

/** Whether a conversation is a direct message or a group room; drives admission. */
export type MockImSurface = 'dm' | 'group'

/** Identifies one conversation (room + thread) a test drives messages through. */
export interface MockImConversationOptions {
  adapterName: string
  agentUid: string
  channelName?: string
  channelId?: string
  deliver?: MockImDeliver
  mode?: MockImGroupMessageMode
  surface?: MockImSurface
  threadId?: string
}

// The seam that connects the fake platform to the system under test: a test
// passes `runtime.handleWebhook` (bound) here, so the fake "delivers" a webhook
// exactly as the HTTP route would, agent + channel included.
export type MockImDeliver = (agentUid: string, channelName: string, request: Request) => Promise<Response>

/** Knobs for a single inbound message a test sends from a user/actor. */
export interface MockImMessageOptions {
  attachments?: MockImAttachmentInput[]
  authorId?: string
  authorName?: string
  dateSent?: Date
  id?: string
  isMention?: boolean
  links?: unknown[]
  raw?: Record<string, unknown>
  replyToBot?: boolean
  text?: string
}

export interface MockImAttachmentInput {
  data: ArrayBuffer | ArrayBufferView | string
  fileKey?: string
  mimeType?: string
  name?: string
  type: 'image' | 'file' | 'video' | 'audio'
}

export interface MockImResourceDescriptor {
  fileKey: string
  fileName?: string
  mimeType?: string
  resourceType: 'image' | 'file' | 'video' | 'audio'
  size?: number
}

export interface MockImDeleteOptions {
  deletedAt?: Date
  id: string
}

export interface MockImReactionOptions {
  actorId?: string
  actorName?: string
  messageId: string
  rawEmoji: string
}

// The outbound operations a test can make the fake provider reject once, to
// exercise the outbox's retry/failure paths. Injected via `failNext` and burned
// by `consumeFailure` at the start of the matching outbound method.
export type MockImFailurePoint = 'post' | 'delete' | 'addReaction' | 'removeReaction'

export interface MockImAdapterOptions {
  capabilities?: ExternalGatewayAdapterCapabilities
  groupMessageMode?: MockImGroupMessageMode
  userName?: string
  /** Opt in to the streaming-card path; otherwise the adapter omits beginStreamingCard. */
  enableStreaming?: boolean
  authorizeReasoningTraceView?: (input: ExternalGatewayReasoningTraceViewAuthInput) => boolean | Promise<boolean>
}

export interface MockImStreamingCardRecord {
  cardId: string
  messageId: string
  threadId: string
  traceUrl?: string
  updates: string[]
  statusUpdates: string[]
  finalText?: string
  finalStatus?: 'completed' | 'cancelled' | 'failed'
}

export interface MockImRawMessage {
  attachments?: MockImResourceDescriptor[]
  authorId: string
  authorName: string
  channelId: string
  dateSent: string
  id: string
  isMention?: boolean
  links?: unknown[]
  raw?: Record<string, unknown>
  replyToBot?: boolean
  surface: MockImSurface
  text: string
  threadId: string
}

// The fake's wire format: the JSON body of a simulated webhook. One discriminated
// `event` covers every push the platform can make (new message, recall vs hard
// delete, reaction add/remove, button click). `handleWebhook` branches on it.
// Recall and delete are kept distinct because the gateway maps them to different
// canonical event types downstream.
export interface MockImWebhookPayload {
  event: 'receive' | 'recall' | 'delete' | 'reaction_add' | 'reaction_remove' | 'action'
  deletedAt?: string
  message?: MockImRawMessage
  messageId?: string
  rawEmoji?: string
  threadId?: string
  action?: {
    actionId: string
    value: string
  }
  user?: {
    userId: string
    userName: string
    fullName: string
  }
}

// The platform's externally visible latest-state for one message — what a human
// in the chat would see right now. This is the projection tests diff against the
// gateway's own `external_messages` mirror to prove the two stayed in sync.
// Deleted messages and unobserved inbound messages are filtered out before this
// shape is produced (see `visibleMessages`).
export interface MockImVisibleMessage {
  authorId: string
  channelId: string
  id: string
  isMention: boolean
  isBot: boolean
  reactions: Record<string, { actors: Record<string, unknown>; count: number; rawEmoji: string }>
  sentAt: Date | null
  text: string
  threadId: string
}

// The full internal record kept in the message store. Extends the visible shape
// with the bookkeeping the fake needs but never exposes: a soft-delete marker
// (`deletedAt`, so a recall/delete can be filtered out yet still win against a
// late out-of-order receive) and `revisionAt`, the per-message clock that makes
// redelivery and out-of-order delivery idempotent — an update with an older
// `revisionAt` is dropped.
type StoredMessage = MockImVisibleMessage & {
  deletedAt: Date | null
  raw: unknown
  revisionAt: Date
  surface: MockImSurface
}

const fullInboundCapabilities = [
  'message_receive',
  'message_delete',
  'message_recall',
  'reaction_add',
  'reaction_remove',
  'action_event',
  'modal_event'
] as const

const fullOutboundCapabilities = [
  'post_message',
  'reply_message',
  'edit_message',
  'delete_message',
  'outbound_idempotency',
  'outbound_reconciliation',
  'add_reaction',
  'remove_reaction',
  'divider',
  'card',
  'modal',
  'streaming',
  'ephemeral'
] as const

// The "maximal" provider: a fake that supports every gateway capability. Tests
// start here and selectively remove capabilities (via `mockImCapabilitiesWithout`)
// to assert the gateway degrades correctly on platforms that lack, say, edit or
// idempotency support.
export const fullMockImCapabilities = {
  inbound: fullInboundCapabilities,
  outbound: fullOutboundCapabilities
} as const satisfies ExternalGatewayAdapterCapabilities

/**
 * Returns the full capability set with the named capabilities stripped from one
 * section, so a test can model a provider that does not support them.
 */
export function mockImCapabilitiesWithout(
  section: keyof ExternalGatewayAdapterCapabilities,
  ...capabilities: string[]
): ExternalGatewayAdapterCapabilities {
  const source = fullMockImCapabilities
  return {
    inbound: [...source.inbound],
    outbound: [...source.outbound],
    [section]: [...(source[section] ?? [])].filter(capability => !capabilities.includes(capability))
  } as ExternalGatewayAdapterCapabilities
}

/**
 * In-memory IM platform used by External Gateway integration tests.
 *
 * This is not a spy adapter. It models the externally visible platform state
 * first, then emits webhook events into the real runtime. Adapter outbound
 * methods mutate the same state only after failure injection has passed, so
 * tests can compare IM visible latest-state with `external_messages`.
 */
export class MockImPlatform {
  // Adapters registered against this platform, keyed by channel name. One
  // platform can host several bindings/agents at once (multi-binding tests).
  readonly adapters = new Map<string, MockImAdapter>()
  // Every webhook payload the fake pushed, in delivery order — a test inspection
  // log for "what events did the platform actually emit".
  readonly transcript: MockImWebhookPayload[] = []
  // Every outbound op the bot performed (post/reply/edit/delete/reconcile/
  // stream-card), in order. Tests assert on this to check what the bot sent and
  // how many times, independent of the resulting visible state.
  readonly outbound: Array<{
    messageId?: string
    op: string
    options?: ExternalGatewayOutboundOptions
    targetMessageId?: string
    text?: string
    threadId: string
  }> = []
  // Streaming-card lifecycles, one record per card, capturing each incremental
  // update and the final text/status so streaming tests can replay the sequence.
  readonly streamingCards: MockImStreamingCardRecord[] = []

  // The single source of truth for platform state, keyed by `channelId\0messageId`
  // (see `messageKey`). Holds both user and bot messages; soft-deleted rows stay
  // here so a recall can still beat a late receive.
  private readonly messages = new Map<string, StoredMessage>()
  // Inbound messages the adapter actually admitted (passed the group-mode filter).
  // `visibleMessages` only surfaces admitted inbound messages, so an ignored
  // ambient message never shows up in the mirror comparison.
  private readonly observedInboundKeys = new Set<string>()
  // Attachment bytes, keyed by fileKey, so `downloadResource` can serve what an
  // inbound message referenced — the fake's stand-in for provider file storage.
  private readonly resources = new Map<string, Uint8Array>()
  // Pending one-shot failures per outbound op, armed by `failNext`. A positive
  // count makes the next matching send throw, modeling a provider rejection.
  private readonly failures: Record<MockImFailurePoint, number> = {
    post: 0,
    delete: 0,
    addReaction: 0,
    removeReaction: 0
  }
  // Monotonic counters that make generated bot message / card ids and synthetic
  // user ids stable and unique within one platform instance.
  private postSeq = 0
  private userSeq = 0

  /** Registers a new adapter (one channel/binding) against this platform. */
  createAdapter(name: string, options: MockImAdapterOptions = {}): MockImAdapter {
    const adapter = new MockImAdapter(this, name, options)
    this.adapters.set(name, adapter)
    return adapter
  }

  /**
   * Opens a direct-message conversation. DMs are always `observe_all` and every
   * message in them is addressed, so the mode/surface are fixed here.
   */
  dm(options: Omit<MockImConversationOptions, 'surface' | 'mode'>): MockImConversation {
    const channelId = `${options.adapterName}:dm`
    return new MockImConversation(this, {
      ...options,
      channelId,
      surface: 'dm',
      mode: 'observe_all',
      threadId: options.threadId?.includes(':dm:')
        ? options.threadId
        : `${options.adapterName}:dm:${options.channelId ?? this.nextUserId()}`
    })
  }

  /**
   * Opens a group conversation. The caller chooses the group-message mode; the
   * room and thread ids default to fresh unique values when not supplied.
   */
  group(options: Omit<MockImConversationOptions, 'surface'>): MockImConversation {
    const channelId = options.channelId ?? `${options.adapterName}:group-${crypto.randomUUID()}`
    return new MockImConversation(this, {
      ...options,
      channelId,
      surface: 'group',
      threadId: options.threadId ?? `${channelId}:thread-${crypto.randomUUID()}`
    })
  }

  /** Arms the next `count` calls of one outbound op to fail (provider rejection). */
  failNext(point: MockImFailurePoint, count = 1): void {
    this.failures[point] += count
  }

  // Burns one armed failure for `point` and throws if one was pending. Outbound
  // methods call this FIRST, before mutating state, so a rejected send leaves the
  // visible platform exactly as the real provider would: unchanged.
  consumeFailure(point: MockImFailurePoint): void {
    if (this.failures[point] <= 0) return

    this.failures[point] -= 1
    throw new Error(`mock im ${point} failure`)
  }

  /**
   * The platform's current visible state for a room (or all rooms).
   *
   * This is the gold the gateway's projection mirror is checked against, so its
   * filter has to match what the gateway would ever record: deleted messages are
   * gone, and an inbound message only counts once the adapter ADMITTED it
   * (`observedInboundKeys`) — an ignored ambient message exists in the store for
   * lookup but is not part of visible state. Bot messages are always visible.
   * Sorted by send time then id so the comparison is order-stable.
   */
  visibleMessages(channelId?: string): MockImVisibleMessage[] {
    return [...this.messages.values()]
      .filter(message => !message.deletedAt)
      .filter(message => !channelId || message.channelId === channelId)
      .filter(message => message.isBot || this.observedInboundKeys.has(messageKey(message.channelId, message.id)))
      .sort((a, b) => (a.sentAt?.getTime() ?? 0) - (b.sentAt?.getTime() ?? 0) || a.id.localeCompare(b.id))
      .map(message => ({
        authorId: message.authorId,
        channelId: message.channelId,
        id: message.id,
        isMention: message.isMention,
        isBot: message.isBot,
        reactions: structuredClone(message.reactions),
        sentAt: message.sentAt,
        text: message.text,
        threadId: message.threadId
      }))
  }

  // Returns the wire-shaped snapshot of a live (non-deleted) message, or
  // undefined. Used to fetch a message back the way an adapter's fetchMessage
  // would, and to recover the original body when building a delete/recall payload.
  rawMessage(channelId: string, messageId: string): MockImRawMessage | undefined {
    const message = this.messages.get(messageKey(channelId, messageId))
    if (!message || message.deletedAt) return undefined

    return {
      authorId: message.authorId,
      authorName: message.authorId,
      channelId: message.channelId,
      dateSent: (message.sentAt ?? new Date()).toISOString(),
      id: message.id,
      isMention: message.isMention,
      attachments: mockResourceDescriptorsFromRaw(message.raw),
      raw: typeof message.raw === 'object' && message.raw !== null ? (message.raw as Record<string, unknown>) : {},
      surface: message.surface,
      text: message.text,
      threadId: message.threadId
    }
  }

  /**
   * Pushes one webhook payload into the system under test.
   *
   * Records it in `transcript`, then serializes it to JSON and hands it to the
   * caller-supplied `deliver` (typically the runtime's HTTP webhook entrypoint)
   * as a real `Request` — so the body crosses the same JSON boundary a live
   * provider webhook would, not an in-process object shortcut.
   */
  async deliver(
    payload: MockImWebhookPayload,
    deliver: MockImDeliver,
    agentUid: string,
    channelName: string
  ): Promise<Response> {
    this.transcript.push(payload)
    return deliver(
      agentUid,
      channelName,
      new Request('http://mock-im.local/webhook', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(payload)
      })
    )
  }

  // Fires a set of webhook deliveries together. The two helpers below are
  // intentionally identical in body and differ only in name: the name documents
  // the scenario a test is exercising (deliberately reordered vs concurrent
  // arrival). The fake makes no real ordering guarantee — Promise.all races them
  // — which is the point: it surfaces ordering bugs in the gateway, not the fake.
  async deliverOutOfOrder(events: Array<() => Promise<Response>>): Promise<Response[]> {
    return Promise.all(events.map(event => event()))
  }

  async deliverConcurrently(events: Array<() => Promise<Response>>): Promise<Response[]> {
    return Promise.all(events.map(event => event()))
  }

  // Applies an inbound user message to platform state (no webhook emitted). The
  // conversation calls this before delivering the `receive` payload so the
  // platform's visible state already reflects the new message.
  applyInboundReceive(message: MockImRawMessage): void {
    this.upsertInbound(message, message.dateSent)
  }

  /** Serves stored attachment bytes; throws on an unknown fileKey. */
  downloadResource(fileKey: string): Buffer {
    const data = this.resources.get(fileKey)
    if (!data) throw new Error(`mock im resource not found: ${fileKey}`)
    return Buffer.from(data)
  }

  /**
   * Stores raw attachment bytes and returns provider-style descriptors.
   *
   * Splits the test-facing input (inline bytes) from the wire shape: bytes go
   * into resource storage under a generated fileKey, and the message only carries
   * the descriptor — mirroring real platforms, where a webhook references a file
   * the bot must download separately.
   */
  registerInboundAttachments(
    messageId: string,
    attachments: readonly MockImAttachmentInput[] | undefined
  ): MockImResourceDescriptor[] {
    const descriptors: MockImResourceDescriptor[] = []
    for (const [index, attachment] of (attachments ?? []).entries()) {
      const data = mockAttachmentBytes(attachment.data)
      const fileKey = attachment.fileKey ?? `mock-resource-${messageId}-${index}-${crypto.randomUUID()}`
      this.resources.set(fileKey, data)
      descriptors.push({
        fileKey,
        fileName: attachment.name,
        mimeType: attachment.mimeType,
        resourceType: attachment.type,
        size: data.byteLength
      })
    }
    return descriptors
  }

  /**
   * Records a recall/delete in platform state, idempotently and order-safely.
   *
   * Three cases: a newer revision already won → ignore (a recall must not undo a
   * later edit). The message exists → soft-delete it. The message has not been
   * seen yet → insert a tombstone row, so when its out-of-order `receive` later
   * lands, `upsertInbound` sees the deleted marker and refuses to resurrect it.
   * That tombstone path is what defends "recall arrives before receive".
   */
  applyInboundDelete(channelId: string, messageId: string, deletedAt: Date): void {
    const key = messageKey(channelId, messageId)
    const existing = this.messages.get(key)
    if (existing && existing.revisionAt > deletedAt) return

    if (existing) {
      existing.deletedAt = deletedAt
      existing.revisionAt = deletedAt
      return
    }

    this.messages.set(key, {
      authorId: 'unknown',
      channelId,
      deletedAt,
      id: messageId,
      isBot: false,
      isMention: false,
      raw: null,
      reactions: {},
      revisionAt: deletedAt,
      sentAt: null,
      surface: 'group',
      text: '',
      threadId: channelId
    })
  }

  // Marks an inbound message as admitted by the adapter, so it counts toward
  // visible state. Called by `handleWebhook` only after the group-mode filter
  // passes, which is why an ignored ambient message never enters the mirror.
  markObserved(channelId: string, messageId: string): void {
    this.observedInboundKeys.add(messageKey(channelId, messageId))
  }

  /**
   * Sends a bot message: the outbound side of `postMessage`/`replyMessage`.
   *
   * Honors an armed `post` failure first (so a rejected send writes nothing),
   * then stores the new bot message and appends an `outbound` record. The
   * reply-vs-post distinction is recovered from `raw` so tests can tell the two
   * apart in the outbound log.
   */
  createBotMessage(
    threadId: string,
    text: string,
    raw: unknown,
    options?: ExternalGatewayOutboundOptions
  ): ExternalGatewayRawMessage<MockImRawMessage> {
    this.consumeFailure('post')
    const adapterName = threadId.split(':')[0] ?? 'mock'
    const channelId = threadId.split(':').slice(0, 2).join(':')
    const id = `${adapterName}-bot-${++this.postSeq}`
    const now = new Date()
    const stored: StoredMessage = {
      authorId: 'self',
      channelId,
      deletedAt: null,
      id,
      isBot: true,
      isMention: false,
      raw,
      reactions: {},
      revisionAt: now,
      sentAt: now,
      surface: threadId.includes(':dm:') ? 'dm' : 'group',
      text,
      threadId
    }
    this.messages.set(messageKey(channelId, id), stored)
    this.outbound.push({ op: rawHasReply(raw) ? 'reply' : 'post', messageId: id, options, text, threadId })

    return {
      id,
      threadId,
      raw: this.toRawMessage(stored)
    }
  }

  /**
   * Opens a streaming card and returns a live handle the runtime drives.
   *
   * Models a provider that shows one editable card whose visible text is
   * recomputed on every `update`/`updateStatus`: the rendered body is the latest
   * status line plus the latest content (see `render`), so a test sees the card
   * mutate in place, not a stream of separate messages. `finish` collapses to the
   * final text, clears the status, and records one `stream-card` outbound op. The
   * `record` accumulates every increment for tests that assert the full sequence.
   */
  createStreamingCard(threadId: string, traceUrl?: string): ExternalGatewayStreamingCardHandle {
    const n = ++this.postSeq
    const adapterName = threadId.split(':')[0] ?? 'mock'
    const channelId = threadId.split(':').slice(0, 2).join(':')
    const cardId = `${adapterName}-card-${n}`
    const messageId = `${adapterName}-card-msg-${n}`
    const record: MockImStreamingCardRecord = { cardId, messageId, threadId, traceUrl, updates: [], statusUpdates: [] }
    this.streamingCards.push(record)
    const now = new Date()
    this.messages.set(messageKey(channelId, messageId), {
      authorId: 'self',
      channelId,
      deletedAt: null,
      id: messageId,
      isBot: true,
      isMention: false,
      raw: { streamingCard: true },
      reactions: {},
      revisionAt: now,
      sentAt: now,
      surface: threadId.includes(':dm:') ? 'dm' : 'group',
      text: '',
      threadId
    })
    const setText = (text: string) => {
      const stored = this.messages.get(messageKey(channelId, messageId))
      if (stored) stored.text = text
    }
    let latestStatusText = ''
    let latestText = ''
    const render = () => [latestStatusText, latestText].filter(Boolean).join('\n\n')
    return {
      cardId,
      messageId,
      update: async (fullText: string) => {
        record.updates.push(fullText)
        latestText = fullText
        setText(render())
      },
      updateStatus: async (statusText: string) => {
        record.statusUpdates.push(statusText)
        latestStatusText = statusText
        setText(render())
      },
      finish: async (finalText, status) => {
        record.finalText = finalText
        record.finalStatus = status
        latestStatusText = ''
        latestText = finalText
        setText(finalText)
        this.outbound.push({ op: 'stream-card', messageId, text: finalText, threadId })
        return { delivered: true, finalTextConfirmed: true }
      }
    }
  }

  /** Deletes a bot message (outbound side of `deleteMessage`); honors a `delete` failure. */
  deleteBotMessage(threadId: string, messageId: string, options?: ExternalGatewayOutboundOptions): void {
    this.consumeFailure('delete')
    const channelId = threadId.split(':').slice(0, 2).join(':')
    const existing = this.messages.get(messageKey(channelId, messageId))
    if (existing) {
      const now = new Date()
      existing.deletedAt = now
      existing.revisionAt = now
    }
    this.outbound.push({ op: 'delete', messageId, options, threadId })
  }

  /**
   * Edits a bot message in place (outbound side of `editMessage`).
   *
   * Updates text and bumps `revisionAt` only when the target still exists and is
   * live. When the target is gone, it still records the `edit` op and returns a
   * synthesized raw shape rather than throwing — the outbox owns edit-failure
   * policy (e.g. fall back to a new post), so this fake just reflects the attempt.
   */
  editBotMessage(
    threadId: string,
    messageId: string,
    text: string,
    options?: ExternalGatewayOutboundOptions
  ): ExternalGatewayRawMessage<MockImRawMessage> {
    const channelId = threadId.split(':').slice(0, 2).join(':')
    const existing = this.messages.get(messageKey(channelId, messageId))
    if (existing && !existing.deletedAt) {
      const now = new Date()
      existing.text = text
      existing.revisionAt = now
      existing.raw = { edit: { text } }
    }
    this.outbound.push({ op: 'edit', options, targetMessageId: messageId, text, threadId })
    const raw = existing
      ? this.toRawMessage(existing)
      : {
          authorId: 'self',
          authorName: 'self',
          channelId,
          dateSent: new Date().toISOString(),
          id: messageId,
          surface: threadId.includes(':dm:') ? ('dm' as const) : ('group' as const),
          text,
          threadId
        }
    return {
      id: messageId,
      raw,
      threadId
    }
  }

  /**
   * Adds or removes one actor's reaction on a message.
   *
   * Reactions are modeled as a set of actors per emoji (not a raw counter), so
   * `count` is always derived from the actor map and redelivery stays idempotent.
   * When the last actor leaves, the emoji bucket is dropped entirely. This mirrors
   * the gateway's own reaction-folding so the two latest-states can be compared.
   */
  applyReaction(input: {
    added: boolean
    actorId: string
    actorName: string
    channelId: string
    messageId: string
    rawEmoji: string
  }): void {
    this.consumeFailure(input.added ? 'addReaction' : 'removeReaction')
    const message = this.messages.get(messageKey(input.channelId, input.messageId))
    if (!message || message.deletedAt) return

    const current = message.reactions[input.rawEmoji] ?? {
      actors: {},
      count: 0,
      rawEmoji: input.rawEmoji
    }
    if (input.added) {
      current.actors[input.actorId] = {
        fullName: input.actorName,
        isBot: false,
        isMe: false,
        userId: input.actorId,
        userName: input.actorName
      }
    } else {
      delete current.actors[input.actorId]
    }

    current.count = Object.keys(current.actors).length
    if (current.count === 0) delete message.reactions[input.rawEmoji]
    else message.reactions[input.rawEmoji] = current
  }

  // Inserts/updates one inbound message with the same guards a real platform's
  // latest-state would enforce: a soft-deleted row is never resurrected (defends
  // recall-before-receive), and an update older than the stored revision is
  // dropped (defends redelivery and out-of-order delivery). Existing reactions
  // are carried forward so a re-received message keeps its reaction map.
  private upsertInbound(message: MockImRawMessage, revisionAtValue: string): void {
    const key = messageKey(message.channelId, message.id)
    const revisionAt = new Date(revisionAtValue)
    const existing = this.messages.get(key)
    if (existing?.deletedAt) return
    if (existing && existing.revisionAt > revisionAt) return

    this.messages.set(key, {
      authorId: message.authorId,
      channelId: message.channelId,
      deletedAt: null,
      id: message.id,
      isBot: false,
      isMention: message.isMention ?? false,
      raw: message.raw ? { ...message.raw, attachments: message.attachments } : message,
      reactions: existing?.reactions ?? {},
      revisionAt,
      sentAt: new Date(message.dateSent),
      surface: message.surface,
      text: message.text,
      threadId: message.threadId
    })
  }

  private toRawMessage(message: StoredMessage): MockImRawMessage {
    return {
      authorId: message.authorId,
      authorName: message.authorId,
      channelId: message.channelId,
      dateSent: (message.sentAt ?? new Date()).toISOString(),
      id: message.id,
      isMention: message.isMention,
      raw: typeof message.raw === 'object' && message.raw !== null ? (message.raw as Record<string, unknown>) : {},
      surface: message.surface,
      text: message.text,
      threadId: message.threadId
    }
  }

  /**
   * Answers "does this bot message still exist on the platform?" — the outbound
   * side of `reconcileMessage`.
   *
   * The outbox uses this during recovery to decide whether a send that may have
   * landed actually did, so a crash mid-send does not produce a duplicate. The
   * fake reports existence plus the current snapshot, and always logs a
   * `reconcile` op.
   */
  reconcileBotMessage(
    threadId: string,
    messageId: string,
    options?: ExternalGatewayOutboundOptions
  ): ExternalGatewayMessageReconciliation<MockImRawMessage> {
    const channelId = threadId.split(':').slice(0, 2).join(':')
    const existing = this.messages.get(messageKey(channelId, messageId))
    const exists = Boolean(existing && !existing.deletedAt)
    this.outbound.push({ op: 'reconcile', messageId, options, threadId })
    if (!exists || !existing) return { exists, providerMessageId: messageId }
    return {
      exists: true,
      message: { id: existing.id, raw: this.toRawMessage(existing), threadId: existing.threadId },
      providerMessageId: existing.id
    }
  }

  private nextUserId(): string {
    this.userSeq += 1
    return `user-${this.userSeq}`
  }
}

/**
 * A test-facing handle for one room/thread that drives user actions.
 *
 * Each method (`say`, `recall`, `delete`, `react`, `clickButton`, …) mutates the
 * platform's state to reflect what the user did, then delivers the matching
 * webhook payload through `deliver`. Tests script a conversation by calling these
 * in sequence; the heavy lifting lives on `MockImPlatform`.
 */
export class MockImConversation {
  readonly adapterName: string
  readonly agentUid: string
  readonly channelName: string
  readonly channelId: string
  readonly mode: MockImGroupMessageMode
  readonly surface: MockImSurface
  readonly threadId: string

  constructor(
    private readonly platform: MockImPlatform,
    options: MockImConversationOptions
  ) {
    this.adapterName = options.adapterName
    this.agentUid = options.agentUid
    this.channelName = options.channelName ?? options.adapterName
    this.channelId =
      options.channelId ?? options.threadId?.split(':').slice(0, 2).join(':') ?? `${options.adapterName}:channel`
    this.mode = options.mode ?? 'observe_all'
    this.surface = options.surface ?? 'group'
    this.threadId = options.threadId ?? `${this.channelId}:thread`
    this.deliver = options.deliver
  }

  private readonly deliver?: MockImDeliver

  /** Sends a user message: applies it to platform state, then delivers a `receive`. */
  async say(options: MockImMessageOptions = {}): Promise<Response> {
    const message = this.message(options)
    this.platform.applyInboundReceive(message)
    return this.deliverPayload({
      event: 'receive',
      message
    })
  }

  // Recall vs delete differ only in the event name; both soft-delete the message
  // and deliver the payload. The gateway maps `recalled` and `deleted` to
  // different canonical event types, which is why the distinction is preserved.
  async recall(id: string, options: Omit<MockImDeleteOptions, 'id'> = {}): Promise<Response> {
    return this.deleteOrRecall('recall', { ...options, id })
  }

  async delete(id: string, options: Omit<MockImDeleteOptions, 'id'> = {}): Promise<Response> {
    return this.deleteOrRecall('delete', { ...options, id })
  }

  /** Simulates a user pressing a card button, delivering an `action` event. */
  async clickButton(options: {
    messageId: string
    value: string
    actionId?: string
    actorId?: string
    actorName?: string
  }): Promise<Response> {
    const actorId = options.actorId ?? 'user-1'
    const actorName = options.actorName ?? actorId
    return this.deliverPayload({
      event: 'action',
      messageId: options.messageId,
      threadId: this.threadId,
      action: { actionId: options.actionId ?? 'clarify_answer', value: options.value },
      user: { userId: actorId, userName: actorName, fullName: actorName }
    })
  }

  /** A user adds a reaction, delivering a `reaction_add` event. */
  async react(options: MockImReactionOptions): Promise<Response> {
    return this.reactOrUnreact(true, options)
  }

  /** A user removes a reaction, delivering a `reaction_remove` event. */
  async unreact(options: MockImReactionOptions): Promise<Response> {
    return this.reactOrUnreact(false, options)
  }

  // Posts a divider as the bot by routing through the registered adapter's real
  // `postMessage`, rather than poking platform state directly — so the divider
  // travels the full outbound rendering path under test.
  async postDivider(): Promise<ExternalGatewayRawMessage<MockImRawMessage>> {
    const adapter = this.platform.adapters.get(this.adapterName)
    if (!adapter) throw new Error(`Mock IM adapter is not registered: ${this.adapterName}`)

    return adapter.postMessage(this.threadId, { type: 'divider' } as never)
  }

  // Builds the wire-shaped message a `say` would send, WITHOUT delivering it, so
  // a test can inspect the raw payload or hand it to `parseMessage` directly.
  payload(options: MockImMessageOptions = {}): MockImRawMessage {
    return this.message(options)
  }

  // Shared recall/delete path. Captures the original body first (so the payload
  // carries the recalled message's content), soft-deletes it, then delivers the
  // event. Falls back to a synthetic empty message when the original is already
  // gone — modeling a provider that recalls a message BullX never received.
  private async deleteOrRecall(event: 'delete' | 'recall', options: MockImDeleteOptions): Promise<Response> {
    const deletedAt = options.deletedAt ?? new Date()
    const base = this.platform.rawMessage(this.channelId, options.id)
    this.platform.applyInboundDelete(this.channelId, options.id, deletedAt)
    return this.deliverPayload({
      deletedAt: deletedAt.toISOString(),
      event,
      message:
        base ??
        this.message({
          dateSent: deletedAt,
          id: options.id,
          text: ''
        }),
      messageId: options.id
    })
  }

  private async reactOrUnreact(added: boolean, options: MockImReactionOptions): Promise<Response> {
    const actorId = options.actorId ?? 'reactor-1'
    const actorName = options.actorName ?? actorId
    this.platform.applyReaction({
      added,
      actorId,
      actorName,
      channelId: this.channelId,
      messageId: options.messageId,
      rawEmoji: options.rawEmoji
    })
    return this.deliverPayload({
      event: added ? 'reaction_add' : 'reaction_remove',
      messageId: options.messageId,
      rawEmoji: options.rawEmoji,
      user: {
        userId: actorId,
        userName: actorName,
        fullName: actorName
      }
    })
  }

  private async deliverPayload(payload: MockImWebhookPayload): Promise<Response> {
    if (!this.deliver) throw new Error('Mock IM conversation has no deliver function')

    return this.platform.deliver(payload, this.deliver, this.agentUid, this.channelName)
  }

  private message(options: MockImMessageOptions): MockImRawMessage {
    const id = options.id ?? crypto.randomUUID()
    const text = options.text ?? ''
    const dateSent = options.dateSent ?? new Date()
    const authorId = options.authorId ?? 'user-1'
    const authorName = options.authorName ?? authorId

    return {
      attachments: this.platform.registerInboundAttachments(id, options.attachments),
      authorId,
      authorName,
      channelId: this.channelId,
      dateSent: dateSent.toISOString(),
      id,
      isMention: options.isMention,
      links: options.links,
      raw: options.raw,
      replyToBot: options.replyToBot,
      surface: this.surface,
      text,
      threadId: this.threadId
    }
  }
}

/**
 * The fake's `ExternalGatewayAdapter` implementation — the real code under test.
 *
 * It is a genuine adapter (the runtime cannot tell it apart from a Lark/Slack
 * one): inbound, it parses the fake's webhook payloads and calls the context's
 * `emit*` doors; outbound, it forwards post/edit/delete/react to the platform's
 * state model. The platform holds the state; this class holds the protocol
 * translation. Capabilities are configurable so one fake can stand in for
 * platforms of differing power.
 */
export class MockImAdapter implements ExternalGatewayAdapter<MockImRawMessage> {
  readonly capabilities: ExternalGatewayAdapterCapabilities
  readonly userName: string
  context: ExternalGatewayAdapterContext | undefined
  // Present only when enableStreaming is set, so the runtime's streaming guard
  // (capability + method) stays false for the default post path.
  beginStreamingCard?: (input: ExternalGatewayBeginStreamingCardInput) => Promise<ExternalGatewayStreamingCardHandle>
  authorizeReasoningTraceView?: (input: ExternalGatewayReasoningTraceViewAuthInput) => boolean | Promise<boolean>

  constructor(
    private readonly platform: MockImPlatform,
    readonly name: string,
    options: MockImAdapterOptions = {}
  ) {
    this.capabilities = options.capabilities ?? fullMockImCapabilities
    this.userName = options.userName ?? 'Agent'
    this.groupMessageMode = options.groupMessageMode ?? 'observe_all'
    if (options.enableStreaming) {
      this.beginStreamingCard = async input => this.platform.createStreamingCard(input.threadId, input.traceUrl)
    }
    this.authorizeReasoningTraceView = options.authorizeReasoningTraceView
  }

  private readonly groupMessageMode: MockImGroupMessageMode

  async initialize(context: ExternalGatewayAdapterContext): Promise<void> {
    this.context = context
  }

  async disconnect(): Promise<void> {}

  /**
   * Translates one fake webhook into the matching context `emit*` call.
   *
   * Each `event` maps to a single canonical ingress door. The `receive` branch
   * applies the group-mode admission filter first: a message that is not admitted
   * is acked but dropped (no `emitMessage`, never marked observed), which is how
   * ambient/unaddressed group chatter is kept out of the agent's input while
   * still returning a successful webhook response.
   */
  async handleWebhook(request: Request, options?: ExternalGatewayWebhookOptions): Promise<Response> {
    const payload = (await request.json()) as MockImWebhookPayload
    const message = payload.message

    if (payload.event === 'receive' && message) {
      if (!this.shouldAdmit(message)) return Response.json({ ok: true, ignored: true })

      this.platform.markObserved(message.channelId, message.id)
      await this.context?.emitMessage(this.parseMessage(message), options)
      return Response.json({ ok: true })
    }

    if ((payload.event === 'delete' || payload.event === 'recall') && payload.messageId) {
      const threadId = message?.threadId ?? this.threadIdFromChannelAndMessage(payload.messageId)
      await this.context?.emitMessageDeleted(
        {
          deletedAt: payload.deletedAt ? new Date(payload.deletedAt) : undefined,
          kind: payload.event === 'recall' ? 'recalled' : 'deleted',
          message: message ? this.parseMessage(message) : undefined,
          messageId: payload.messageId,
          raw: payload,
          threadId
        },
        options
      )
      return Response.json({ ok: true })
    }

    if (payload.event === 'action' && payload.action && payload.messageId) {
      await this.context?.emitAction(
        {
          actionId: payload.action.actionId,
          messageId: payload.messageId,
          threadId: payload.threadId ?? this.threadIdFromChannelAndMessage(payload.messageId),
          user: {
            fullName: payload.user?.fullName ?? 'clicker',
            isBot: false,
            isMe: false,
            userId: payload.user?.userId ?? 'user-1',
            userName: payload.user?.userName ?? 'clicker'
          },
          value: payload.action.value,
          raw: payload
        },
        options
      )
      return Response.json({ ok: true })
    }

    if ((payload.event === 'reaction_add' || payload.event === 'reaction_remove') && payload.messageId) {
      const rawEmoji = payload.rawEmoji ?? 'thumbs_up'
      const messageSnapshot = this.findRawMessage(payload.messageId)
      await this.context?.emitReaction(
        {
          added: payload.event === 'reaction_add',
          emoji: normalizedEmoji(rawEmoji),
          message: messageSnapshot ? this.parseMessage(messageSnapshot) : undefined,
          messageId: payload.messageId,
          raw: payload,
          rawEmoji,
          threadId: messageSnapshot?.threadId ?? this.threadIdFromChannelAndMessage(payload.messageId),
          user: {
            fullName: payload.user?.fullName ?? 'reactor',
            isBot: false,
            isMe: false,
            userId: payload.user?.userId ?? 'reactor-1',
            userName: payload.user?.userName ?? 'reactor'
          }
        },
        options
      )
      return Response.json({ ok: true })
    }

    return Response.json({ ok: true })
  }

  /**
   * Normalizes a fake raw message into the gateway's `ExternalGatewayMessageInput`.
   *
   * The attachment mapping is the interesting part: each descriptor becomes a
   * lazy `fetchData` that pulls bytes from the platform's resource store on
   * demand, exactly like a real adapter deferring a file download — so the
   * gateway's materialization path is exercised, not short-circuited.
   */
  parseMessage(raw: MockImRawMessage): ExternalGatewayMessageInput<MockImRawMessage> {
    const text = raw.text ?? ''
    return {
      attachments: (raw.attachments ?? []).map(resource => ({
        fetchData: async () => this.platform.downloadResource(resource.fileKey),
        fetchMetadata: {
          provider: 'mock-im',
          fileKey: resource.fileKey,
          resourceType: resource.resourceType,
          downloadType: resource.resourceType === 'image' ? 'image' : 'file',
          messageId: raw.id
        },
        mimeType: resource.mimeType,
        name: resource.fileName,
        size: resource.size,
        type: resource.resourceType
      })),
      author: {
        fullName: raw.authorName,
        isBot: false,
        isMe: false,
        userId: raw.authorId,
        userName: raw.authorName
      },
      formatted: parseMarkdown(text),
      id: raw.id,
      isMention: raw.isMention ?? raw.replyToBot,
      links: [],
      metadata: {
        dateSent: new Date(raw.dateSent)
      },
      raw,
      text,
      threadId: raw.threadId
    }
  }

  // The fake's id convention: a thread id is `adapter:room[:dm:...|:thread-...]`,
  // and the room id is its first two colon segments. The whole fake (and several
  // tests) rely on this shape, so changing it ripples widely.
  channelIdFromThreadId(threadId: string): string {
    return threadId.split(':').slice(0, 2).join(':')
  }

  decodeThreadId(threadId: string): string {
    return threadId
  }

  encodeThreadId(threadId: string): string {
    return threadId
  }

  // A DM thread is marked by a `:dm:` segment (set by `MockImPlatform.dm`).
  isDM(threadId: string): boolean {
    return threadId.includes(':dm:')
  }

  async fetchMessage(
    threadId: string,
    messageId: string
  ): Promise<ExternalGatewayMessageInput<MockImRawMessage> | null> {
    const raw = this.platform.rawMessage(this.channelIdFromThreadId(threadId), messageId)
    return raw ? this.parseMessage(raw) : null
  }

  async fetchThread(threadId: string) {
    return {
      channelId: this.channelIdFromThreadId(threadId),
      id: threadId,
      isDM: this.isDM(threadId),
      metadata: {}
    }
  }

  // The outbound methods below forward to the platform's state model. They flatten
  // the rich postable into plain text via `postableText`, because the fake stores
  // only the visible text the user would see; the structured payload is kept in
  // `raw` for tests that need it. A `targetMessageId` marks the post as a reply.
  async postMessage(
    threadId: string,
    message: unknown,
    options?: ExternalGatewayOutboundOptions
  ): Promise<ExternalGatewayRawMessage<MockImRawMessage>> {
    return this.platform.createBotMessage(
      threadId,
      postableText(message),
      { postable: message, reply: Boolean(options?.targetMessageId) },
      options
    )
  }

  async deleteMessage(threadId: string, messageId: string, options?: ExternalGatewayOutboundOptions): Promise<void> {
    this.platform.deleteBotMessage(threadId, messageId, options)
  }

  async editMessage(
    threadId: string,
    messageId: string,
    message: unknown,
    options?: ExternalGatewayOutboundOptions
  ): Promise<ExternalGatewayRawMessage<MockImRawMessage>> {
    return this.platform.editBotMessage(threadId, messageId, postableText(message), options)
  }

  async reconcileMessage(
    threadId: string,
    messageId: string,
    options?: ExternalGatewayOutboundOptions
  ): Promise<ExternalGatewayMessageReconciliation<MockImRawMessage>> {
    return this.platform.reconcileBotMessage(threadId, messageId, options)
  }

  async addReaction(threadId: string, messageId: string, emoji: string): Promise<void> {
    this.platform.applyReaction({
      added: true,
      actorId: 'self',
      actorName: this.userName,
      channelId: this.channelIdFromThreadId(threadId),
      messageId,
      rawEmoji: emoji
    })
  }

  async removeReaction(threadId: string, messageId: string, emoji: string): Promise<void> {
    this.platform.applyReaction({
      added: false,
      actorId: 'self',
      actorName: this.userName,
      channelId: this.channelIdFromThreadId(threadId),
      messageId,
      rawEmoji: emoji
    })
  }

  renderFormatted(): string {
    return ''
  }

  // The platform-side admission gate (distinct from the gateway's own delivery
  // decision). DMs and any non-`addressed_only` mode always reach the runtime; an
  // explicit mention/reply does too. Under `addressed_only`, an unaddressed
  // message is admitted only if it is ALREADY visible — i.e. a redelivery of a
  // message the bot was previously told about — so redelivered events still flow
  // while genuinely new ambient chatter is dropped before it leaves the platform.
  private shouldAdmit(message: MockImRawMessage): boolean {
    if (message.surface === 'dm') return true
    if (this.groupMessageMode !== 'addressed_only') return true
    if (message.isMention || message.replyToBot) return true

    const key = messageKey(message.channelId, message.id)
    return this.platform
      .visibleMessages(message.channelId)
      .some(visible => messageKey(visible.channelId, visible.id) === key)
  }

  private findRawMessage(messageId: string): MockImRawMessage | undefined {
    for (const message of this.platform.visibleMessages()) {
      if (message.id === messageId) return this.visibleToRaw(message)
    }

    return undefined
  }

  private threadIdFromChannelAndMessage(messageId: string): string {
    const message = this.findRawMessage(messageId)
    return message?.threadId ?? `${this.name}:channel:thread`
  }

  private visibleToRaw(message: MockImVisibleMessage): MockImRawMessage {
    return {
      authorId: message.authorId,
      authorName: message.authorId,
      channelId: message.channelId,
      dateSent: (message.sentAt ?? new Date()).toISOString(),
      id: message.id,
      isMention: message.isMention,
      surface: message.threadId.includes(':dm:') ? 'dm' : 'group',
      text: message.text,
      threadId: message.threadId
    }
  }
}

// Composite key for the message store. A NUL byte joins the parts because it
// cannot appear in a channel or message id, so distinct (channel, message) pairs
// can never collide into the same key.
function messageKey(channelId: string, messageId: string): string {
  return `${channelId}\u0000${messageId}`
}

function mockAttachmentBytes(data: ArrayBuffer | ArrayBufferView | string): Uint8Array {
  if (typeof data === 'string') return Buffer.from(data)
  if (data instanceof ArrayBuffer) return new Uint8Array(data)
  return new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
}

function mockResourceDescriptorsFromRaw(raw: unknown): MockImResourceDescriptor[] | undefined {
  if (typeof raw !== 'object' || raw === null || !('attachments' in raw)) return undefined
  const attachments = (raw as { attachments?: unknown }).attachments
  if (!Array.isArray(attachments)) return undefined

  const descriptors = attachments.filter(isMockResourceDescriptor)
  return descriptors.length > 0 ? descriptors : undefined
}

function isMockResourceDescriptor(value: unknown): value is MockImResourceDescriptor {
  if (typeof value !== 'object' || value === null) return false
  const descriptor = value as Partial<MockImResourceDescriptor>
  return (
    typeof descriptor.fileKey === 'string' &&
    ['image', 'file', 'video', 'audio'].includes(String(descriptor.resourceType))
  )
}

// Flattens any outbound postable (string, markdown, card, divider, interactive
// output, …) to the single line of text the fake stores as visible state. A real
// adapter renders the rich object and shows a text fallback on plain surfaces;
// the fake keeps only that fallback. The branch order matters and is noted inline
// at the divider case.
function postableText(value: unknown): string {
  if (typeof value === 'string') return value
  if (typeof value === 'object' && value !== null && 'markdown' in value && typeof value.markdown === 'string') {
    return value.markdown
  }
  if (typeof value === 'object' && value !== null && 'raw' in value && typeof value.raw === 'string') return value.raw
  // Card / control-notice / divider payloads carry a fallback text for non-card
  // surfaces; a real adapter renders the card/divider and projects this text. This
  // precedes the bare-divider sentinel so a text-bearing divider keeps its text.
  if (
    typeof value === 'object' &&
    value !== null &&
    'fallbackText' in value &&
    typeof value.fallbackText === 'string'
  ) {
    return value.fallbackText
  }
  if (typeof value === 'object' && value !== null && 'kind' in value && value.kind === 'interactive_output') {
    const output =
      'output' in value && typeof value.output === 'object' && value.output !== null ? value.output : undefined
    if (output && 'fallbackText' in output && typeof output.fallbackText === 'string') return output.fallbackText
  }
  if (typeof value === 'object' && value !== null && 'kind' in value && value.kind === 'lark_native_card') {
    if ('fallbackText' in value && typeof value.fallbackText === 'string') return value.fallbackText
  }
  if (typeof value === 'object' && value !== null && 'text' in value && typeof value.text === 'string') {
    return value.text
  }
  if (typeof value === 'object' && value !== null && 'type' in value && value.type === 'divider') return '[divider]'

  return JSON.stringify(value)
}

function rawHasReply(raw: unknown): boolean {
  if (typeof raw !== 'object' || raw === null || !('reply' in raw)) return false
  return Boolean((raw as { reply?: unknown }).reply)
}

// Maps the several aliases a platform might use for a thumbs-up onto one
// normalized emoji object, so reaction tests do not depend on which alias the
// payload happened to carry. Any other emoji passes through as its raw string.
function normalizedEmoji(rawEmoji: string) {
  if (rawEmoji === '+1' || rawEmoji === 'thumbsup' || rawEmoji === '👍') return thumbsUpEmoji

  return rawEmoji as never
}

// A normalized thumbs-up that serializes to `:thumbs_up:` in both JSON and string
// contexts, modeling an adapter emoji value that is an object, not a bare string.
const thumbsUpEmoji = Object.freeze({
  name: 'thumbs_up',
  toJSON: () => ':thumbs_up:',
  toString: () => ':thumbs_up:'
})
