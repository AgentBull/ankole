import {
  Message,
  parseMarkdown,
  type Adapter,
  type AdapterPostableMessage,
  type ChannelAdapterCapabilities,
  type ChatElement,
  type ChatInstance,
  type FetchOptions,
  type FetchResult,
  type RawMessage,
  type WebhookOptions
} from '../core'
import { emoji as coreEmoji } from '../core/emoji'

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

export interface MockImEditOptions extends MockImMessageOptions {
  editedAt?: Date
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

export type MockImFailurePoint = 'post' | 'edit' | 'delete' | 'addReaction' | 'removeReaction'

export interface MockImAdapterOptions {
  capabilities?: ChannelAdapterCapabilities
  groupMessageMode?: MockImGroupMessageMode
  userName?: string
}

export interface MockImRawMessage {
  attachments?: unknown[]
  authorId: string
  authorName: string
  channelId: string
  dateSent: string
  editedAt?: string
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
  event: 'receive' | 'edit' | 'recall' | 'delete' | 'reaction_add' | 'reaction_remove' | 'action'
  deletedAt?: string
  editedAt?: string
  message?: MockImRawMessage
  messageId?: string
  rawEmoji?: string
  user?: {
    userId: string
    userName: string
    fullName: string
  }
}

export interface MockImVisibleMessage {
  authorId: string
  channelId: string
  editedAt: Date | null
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
  'message_edit',
  'message_delete',
  'message_recall',
  'reaction_add',
  'reaction_remove',
  'action_event',
  'modal_event'
] as const

const fullOutboundCapabilities = [
  'post_message',
  'edit_message',
  'delete_message',
  'add_reaction',
  'remove_reaction',
  'divider',
  'card',
  'modal',
  'streaming',
  'ephemeral'
] as const

const fullHistoryCapabilities = [
  'fetch_message',
  'fetch_thread_messages',
  'fetch_channel_messages',
  'backfill_history'
] as const

export const fullMockImCapabilities = {
  inbound: fullInboundCapabilities,
  outbound: fullOutboundCapabilities,
  history: fullHistoryCapabilities
} as const satisfies ChannelAdapterCapabilities

export function mockImCapabilitiesWithout(
  section: keyof ChannelAdapterCapabilities,
  ...capabilities: string[]
): ChannelAdapterCapabilities {
  const source = fullMockImCapabilities
  return {
    inbound: [...source.inbound],
    outbound: [...source.outbound],
    history: [...source.history],
    [section]: [...(source[section] ?? [])].filter(capability => !capabilities.includes(capability))
  } as ChannelAdapterCapabilities
}

/**
 * In-memory IM platform used by Chat Gateway integration tests.
 *
 * This is not a spy adapter. It models the externally visible platform state
 * first, then emits webhook events into the real runtime. Adapter outbound
 * methods mutate the same state only after failure injection has passed, so
 * tests can compare IM visible latest-state with `chat_messages`.
 */
export class MockImPlatform {
  readonly adapters = new Map<string, MockImAdapter>()
  readonly transcript: MockImWebhookPayload[] = []
  readonly outbound: Array<{ op: string; messageId?: string; text?: string; threadId: string }> = []

  private readonly messages = new Map<string, StoredMessage>()
  private readonly observedInboundKeys = new Set<string>()
  private readonly failures: Record<MockImFailurePoint, number> = {
    post: 0,
    edit: 0,
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
        editedAt: message.editedAt,
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
      editedAt: message.editedAt?.toISOString(),
      id: message.id,
      isMention: message.isMention,
      raw: typeof message.raw === 'object' && message.raw !== null ? (message.raw as Record<string, unknown>) : {},
      surface: message.surface,
      text: message.text,
      threadId: message.threadId
    }
  }

  async deliver(payload: MockImWebhookPayload, deliver: MockImDeliver, agentUid: string, channelName: string): Promise<Response> {
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

  applyInboundEdit(message: MockImRawMessage, editedAt: string): void {
    this.upsertInbound({ ...message, editedAt }, editedAt)
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
      editedAt: null,
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

  createBotMessage(threadId: string, text: string, raw: unknown): RawMessage<MockImRawMessage> {
    this.consumeFailure('post')
    const adapterName = threadId.split(':')[0] ?? 'mock'
    const channelId = threadId.split(':').slice(0, 2).join(':')
    const id = `${adapterName}-bot-${++this.postSeq}`
    const now = new Date()
    const stored: StoredMessage = {
      authorId: 'self',
      channelId,
      deletedAt: null,
      editedAt: null,
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
    this.outbound.push({ op: 'post', messageId: id, text, threadId })

    return {
      id,
      threadId,
      raw: this.toRawMessage(stored)
    }
  }

  editBotMessage(threadId: string, messageId: string, text: string, raw: unknown): RawMessage<MockImRawMessage> {
    this.consumeFailure('edit')
    const channelId = threadId.split(':').slice(0, 2).join(':')
    const key = messageKey(channelId, messageId)
    const existing = this.messages.get(key)
    const now = new Date()
    if (existing && !existing.deletedAt) {
      existing.text = text
      existing.editedAt = now
      existing.revisionAt = now
      existing.raw = raw
    }
    this.outbound.push({ op: 'edit', messageId, text, threadId })

    const message = existing ?? this.messages.get(key)
    return {
      id: messageId,
      threadId,
      raw: message ? this.toRawMessage(message) : ({ id: messageId, text } as MockImRawMessage)
    }
  }

  deleteBotMessage(threadId: string, messageId: string): void {
    this.consumeFailure('delete')
    const channelId = threadId.split(':').slice(0, 2).join(':')
    const existing = this.messages.get(messageKey(channelId, messageId))
    if (existing) {
      const now = new Date()
      existing.deletedAt = now
      existing.revisionAt = now
    }
    this.outbound.push({ op: 'delete', messageId, threadId })
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
      editedAt: message.editedAt ? new Date(message.editedAt) : null,
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
      editedAt: message.editedAt?.toISOString(),
      id: message.id,
      isMention: message.isMention,
      raw: typeof message.raw === 'object' && message.raw !== null ? (message.raw as Record<string, unknown>) : {},
      surface: message.surface,
      text: message.text,
      threadId: message.threadId
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
    this.channelId = options.channelId ?? options.threadId?.split(':').slice(0, 2).join(':') ?? `${options.adapterName}:channel`
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

  async edit(id: string, options: MockImEditOptions = {}): Promise<Response> {
    const base = this.platform.rawMessage(this.channelId, id)
    const editedAt = (options.editedAt ?? new Date()).toISOString()
    const message = this.message({
      ...options,
      authorId: options.authorId ?? base?.authorId,
      authorName: options.authorName ?? base?.authorName,
      dateSent: options.dateSent ?? (base?.dateSent ? new Date(base.dateSent) : undefined),
      id,
      isMention: options.isMention ?? base?.isMention,
      raw: { ...base?.raw, ...options.raw },
      text: options.text ?? base?.text ?? ''
    })
    this.platform.applyInboundEdit(message, editedAt)
    return this.deliverPayload({
      editedAt,
      event: 'edit',
      message
    })
  }

  async recall(id: string, options: Omit<MockImDeleteOptions, 'id'> = {}): Promise<Response> {
    return this.deleteOrRecall('recall', { ...options, id })
  }

  async delete(id: string, options: Omit<MockImDeleteOptions, 'id'> = {}): Promise<Response> {
    return this.deleteOrRecall('delete', { ...options, id })
  }

  async react(options: MockImReactionOptions): Promise<Response> {
    return this.reactOrUnreact(true, options)
  }

  async unreact(options: MockImReactionOptions): Promise<Response> {
    return this.reactOrUnreact(false, options)
  }

  async postDivider(): Promise<RawMessage<MockImRawMessage>> {
    const adapter = this.platform.adapters.get(this.adapterName)
    if (!adapter) throw new Error(`Mock IM adapter is not registered: ${this.adapterName}`)

    return adapter.postMessage(this.threadId, { type: 'divider' } as never)
  }

  payload(options: MockImMessageOptions = {}): MockImRawMessage {
    return this.message(options)
  }

  private async deleteOrRecall(
    event: 'delete' | 'recall',
    options: MockImDeleteOptions
  ): Promise<Response> {
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

export class MockImAdapter implements Adapter<string, MockImRawMessage> {
  readonly capabilities: ChannelAdapterCapabilities
  readonly userName: string
  chat: ChatInstance | undefined

  constructor(
    private readonly platform: MockImPlatform,
    readonly name: string,
    options: MockImAdapterOptions = {}
  ) {
    this.capabilities = options.capabilities ?? fullMockImCapabilities
    this.userName = options.userName ?? 'Agent'
    this.groupMessageMode = options.groupMessageMode ?? 'observe_all'
  }

  private readonly groupMessageMode: MockImGroupMessageMode

  async initialize(chat: ChatInstance): Promise<void> {
    this.chat = chat
  }

  async disconnect(): Promise<void> {}

  async handleWebhook(request: Request, options?: WebhookOptions): Promise<Response> {
    const payload = (await request.json()) as MockImWebhookPayload
    const message = payload.message

    if (payload.event === 'receive' && message) {
      if (!this.shouldAdmit(message)) return Response.json({ ok: true, ignored: true })

      this.platform.markObserved(message.channelId, message.id)
      await this.chat?.processMessage(this, message.threadId, this.parseMessage(message), options)
      return Response.json({ ok: true })
    }

    if (payload.event === 'edit' && message) {
      if (!this.shouldAdmit(message)) return Response.json({ ok: true, ignored: true })

      this.platform.markObserved(message.channelId, message.id)
      await this.chat?.processMessageEdited(
        {
          adapter: this,
          editedAt: payload.editedAt ? new Date(payload.editedAt) : undefined,
          message: this.parseMessage({ ...message, editedAt: payload.editedAt }),
          messageId: message.id,
          raw: payload,
          threadId: message.threadId
        },
        options
      )
      return Response.json({ ok: true })
    }

    if ((payload.event === 'delete' || payload.event === 'recall') && payload.messageId) {
      const threadId = message?.threadId ?? this.threadIdFromChannelAndMessage(payload.messageId)
      await this.chat?.processMessageDeleted(
        {
          adapter: this,
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

    if ((payload.event === 'reaction_add' || payload.event === 'reaction_remove') && payload.messageId) {
      const rawEmoji = payload.rawEmoji ?? 'thumbs_up'
      const messageSnapshot = this.findRawMessage(payload.messageId)
      await this.chat?.processReaction(
        {
          adapter: this,
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

  parseMessage(raw: MockImRawMessage): Message<MockImRawMessage> {
    const text = raw.text ?? ''
    const editedAt = raw.editedAt ? new Date(raw.editedAt) : undefined
    return new Message({
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
        dateSent: new Date(raw.dateSent),
        edited: editedAt !== undefined,
        editedAt
      },
      raw,
      text,
      threadId: raw.threadId
    })
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

  async fetchMessage(threadId: string, messageId: string): Promise<Message<MockImRawMessage> | null> {
    const raw = this.platform.rawMessage(this.channelIdFromThreadId(threadId), messageId)
    return raw ? this.parseMessage(raw) : null
  }

  async fetchMessages(threadId: string, _options?: FetchOptions): Promise<FetchResult<MockImRawMessage>> {
    const channelId = this.channelIdFromThreadId(threadId)
    return {
      messages: this.platform
        .visibleMessages(channelId)
        .filter(message => message.threadId === threadId)
        .map(message => this.parseMessage(this.visibleToRaw(message))),
      nextCursor: undefined
    }
  }

  async fetchChannelMessages(channelId: string, _options?: FetchOptions): Promise<FetchResult<MockImRawMessage>> {
    return {
      messages: this.platform.visibleMessages(channelId).map(message => this.parseMessage(this.visibleToRaw(message))),
      nextCursor: undefined
    }
  }

  async fetchThread(threadId: string) {
    return {
      channelId: this.channelIdFromThreadId(threadId),
      id: threadId,
      isDM: this.isDM(threadId),
      metadata: {}
    }
  }

  async postMessage(threadId: string, message: AdapterPostableMessage | ChatElement): Promise<RawMessage<MockImRawMessage>> {
    return this.platform.createBotMessage(threadId, postableText(message), { postable: message })
  }

  async editMessage(
    threadId: string,
    messageId: string,
    message: AdapterPostableMessage | ChatElement
  ): Promise<RawMessage<MockImRawMessage>> {
    return this.platform.editBotMessage(threadId, messageId, postableText(message), { postable: message })
  }

  async deleteMessage(threadId: string, messageId: string): Promise<void> {
    this.platform.deleteBotMessage(threadId, messageId)
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

  async startTyping(): Promise<void> {}

  renderFormatted(): string {
    return ''
  }

  private shouldAdmit(message: MockImRawMessage): boolean {
    if (message.surface === 'dm') return true
    if (this.groupMessageMode !== 'addressed_only') return true
    if (message.isMention || message.replyToBot) return true

    const key = messageKey(message.channelId, message.id)
    return this.platform.visibleMessages(message.channelId).some(visible => messageKey(visible.channelId, visible.id) === key)
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
      editedAt: message.editedAt?.toISOString(),
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
  if (typeof value === 'object' && value !== null && 'type' in value && value.type === 'divider') return '[divider]'

  return JSON.stringify(value)
}

function normalizedEmoji(rawEmoji: string) {
  if (rawEmoji === '+1' || rawEmoji === 'thumbsup' || rawEmoji === '👍') return coreEmoji.thumbs_up

  return rawEmoji as never
}
