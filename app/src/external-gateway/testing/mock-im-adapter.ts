import {
  parseMarkdown,
  type ExternalGatewayAdapter,
  type ExternalGatewayAdapterCapabilities,
  type ExternalGatewayAdapterContext,
  type ExternalGatewayBeginStreamingCardInput,
  type ExternalGatewayMessageInput,
  type ExternalGatewayMessageReconciliation,
  type ExternalGatewayOutboundOptions,
  type ExternalGatewayRawMessage,
  type ExternalGatewayStreamingCardHandle,
  type ExternalGatewayWebhookOptions
} from '../core'

export type MockImGroupMessageMode = 'addressed_only' | 'observe_all' | 'may_intervene'

export type MockImSurface = 'dm' | 'group'

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

export type MockImDeliver = (agentUid: string, channelName: string, request: Request) => Promise<Response>

export interface MockImMessageOptions {
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

export type MockImFailurePoint = 'post' | 'delete' | 'addReaction' | 'removeReaction'

export interface MockImAdapterOptions {
  capabilities?: ExternalGatewayAdapterCapabilities
  groupMessageMode?: MockImGroupMessageMode
  userName?: string
  /** Opt in to the streaming-card path; otherwise the adapter omits beginStreamingCard. */
  enableStreaming?: boolean
}

export interface MockImStreamingCardRecord {
  cardId: string
  messageId: string
  threadId: string
  updates: string[]
  finalText?: string
  finalStatus?: 'completed' | 'cancelled' | 'failed'
}

export interface MockImRawMessage {
  attachments?: unknown[]
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

export const fullMockImCapabilities = {
  inbound: fullInboundCapabilities,
  outbound: fullOutboundCapabilities
} as const satisfies ExternalGatewayAdapterCapabilities

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
  readonly adapters = new Map<string, MockImAdapter>()
  readonly transcript: MockImWebhookPayload[] = []
  readonly outbound: Array<{
    messageId?: string
    op: string
    options?: ExternalGatewayOutboundOptions
    targetMessageId?: string
    text?: string
    threadId: string
  }> = []
  readonly streamingCards: MockImStreamingCardRecord[] = []

  private readonly messages = new Map<string, StoredMessage>()
  private readonly observedInboundKeys = new Set<string>()
  private readonly failures: Record<MockImFailurePoint, number> = {
    post: 0,
    delete: 0,
    addReaction: 0,
    removeReaction: 0
  }
  private postSeq = 0
  private userSeq = 0

  createAdapter(name: string, options: MockImAdapterOptions = {}): MockImAdapter {
    const adapter = new MockImAdapter(this, name, options)
    this.adapters.set(name, adapter)
    return adapter
  }

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

  group(options: Omit<MockImConversationOptions, 'surface'>): MockImConversation {
    const channelId = options.channelId ?? `${options.adapterName}:group-${crypto.randomUUID()}`
    return new MockImConversation(this, {
      ...options,
      channelId,
      surface: 'group',
      threadId: options.threadId ?? `${channelId}:thread-${crypto.randomUUID()}`
    })
  }

  failNext(point: MockImFailurePoint, count = 1): void {
    this.failures[point] += count
  }

  consumeFailure(point: MockImFailurePoint): void {
    if (this.failures[point] <= 0) return

    this.failures[point] -= 1
    throw new Error(`mock im ${point} failure`)
  }

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
      raw: typeof message.raw === 'object' && message.raw !== null ? (message.raw as Record<string, unknown>) : {},
      surface: message.surface,
      text: message.text,
      threadId: message.threadId
    }
  }

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

  async deliverOutOfOrder(events: Array<() => Promise<Response>>): Promise<Response[]> {
    return Promise.all(events.map(event => event()))
  }

  async deliverConcurrently(events: Array<() => Promise<Response>>): Promise<Response[]> {
    return Promise.all(events.map(event => event()))
  }

  applyInboundReceive(message: MockImRawMessage): void {
    this.upsertInbound(message, message.dateSent)
  }

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

  markObserved(channelId: string, messageId: string): void {
    this.observedInboundKeys.add(messageKey(channelId, messageId))
  }

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

  createStreamingCard(threadId: string): ExternalGatewayStreamingCardHandle {
    const n = ++this.postSeq
    const adapterName = threadId.split(':')[0] ?? 'mock'
    const channelId = threadId.split(':').slice(0, 2).join(':')
    const cardId = `${adapterName}-card-${n}`
    const messageId = `${adapterName}-card-msg-${n}`
    const record: MockImStreamingCardRecord = { cardId, messageId, threadId, updates: [] }
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
    return {
      cardId,
      messageId,
      update: async (fullText: string) => {
        record.updates.push(fullText)
        setText(fullText)
      },
      finish: async (finalText, status) => {
        record.finalText = finalText
        record.finalStatus = status
        setText(finalText)
        this.outbound.push({ op: 'stream-card', messageId, text: finalText, threadId })
      }
    }
  }

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
      raw: message.raw ?? message,
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

  async say(options: MockImMessageOptions = {}): Promise<Response> {
    const message = this.message(options)
    this.platform.applyInboundReceive(message)
    return this.deliverPayload({
      event: 'receive',
      message
    })
  }

  async recall(id: string, options: Omit<MockImDeleteOptions, 'id'> = {}): Promise<Response> {
    return this.deleteOrRecall('recall', { ...options, id })
  }

  async delete(id: string, options: Omit<MockImDeleteOptions, 'id'> = {}): Promise<Response> {
    return this.deleteOrRecall('delete', { ...options, id })
  }

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

  async react(options: MockImReactionOptions): Promise<Response> {
    return this.reactOrUnreact(true, options)
  }

  async unreact(options: MockImReactionOptions): Promise<Response> {
    return this.reactOrUnreact(false, options)
  }

  async postDivider(): Promise<ExternalGatewayRawMessage<MockImRawMessage>> {
    const adapter = this.platform.adapters.get(this.adapterName)
    if (!adapter) throw new Error(`Mock IM adapter is not registered: ${this.adapterName}`)

    return adapter.postMessage(this.threadId, { type: 'divider' } as never)
  }

  payload(options: MockImMessageOptions = {}): MockImRawMessage {
    return this.message(options)
  }

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

export class MockImAdapter implements ExternalGatewayAdapter<MockImRawMessage> {
  readonly capabilities: ExternalGatewayAdapterCapabilities
  readonly userName: string
  context: ExternalGatewayAdapterContext | undefined
  // Present only when enableStreaming is set, so the runtime's streaming guard
  // (capability + method) stays false for the default post path.
  beginStreamingCard?: (input: ExternalGatewayBeginStreamingCardInput) => Promise<ExternalGatewayStreamingCardHandle>

  constructor(
    private readonly platform: MockImPlatform,
    readonly name: string,
    options: MockImAdapterOptions = {}
  ) {
    this.capabilities = options.capabilities ?? fullMockImCapabilities
    this.userName = options.userName ?? 'Agent'
    this.groupMessageMode = options.groupMessageMode ?? 'observe_all'
    if (options.enableStreaming) {
      this.beginStreamingCard = async input => this.platform.createStreamingCard(input.threadId)
    }
  }

  private readonly groupMessageMode: MockImGroupMessageMode

  async initialize(context: ExternalGatewayAdapterContext): Promise<void> {
    this.context = context
  }

  async disconnect(): Promise<void> {}

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

  parseMessage(raw: MockImRawMessage): ExternalGatewayMessageInput<MockImRawMessage> {
    const text = raw.text ?? ''
    return {
      attachments: [],
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

  channelIdFromThreadId(threadId: string): string {
    return threadId.split(':').slice(0, 2).join(':')
  }

  decodeThreadId(threadId: string): string {
    return threadId
  }

  encodeThreadId(threadId: string): string {
    return threadId
  }

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

function messageKey(channelId: string, messageId: string): string {
  return `${channelId}\u0000${messageId}`
}

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

function normalizedEmoji(rawEmoji: string) {
  if (rawEmoji === '+1' || rawEmoji === 'thumbsup' || rawEmoji === '👍') return thumbsUpEmoji

  return rawEmoji as never
}

const thumbsUpEmoji = Object.freeze({
  name: 'thumbs_up',
  toJSON: () => ':thumbs_up:',
  toString: () => ':thumbs_up:'
})
