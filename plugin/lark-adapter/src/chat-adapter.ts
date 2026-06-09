import * as lark from '@larksuiteoapi/node-sdk'
import type {
  BullXBeginStreamingCardInput,
  BullXExternalGatewayAdapterCapabilities,
  BullXExternalGatewayAdapterContext,
  BullXExternalGatewayAdapterFactoryContext,
  BullXExternalGatewayMessageReconciliation,
  BullXExternalGatewayOutboundCapability,
  BullXExternalGatewayOutboundOptions,
  BullXExternalGatewayRawMessage,
  BullXExternalGatewayRoomInput,
  BullXStreamingCardHandle
} from '@agentbull/bullx-sdk/plugins'
import { LarkAdapterConfigError, type LarkChannelConfig } from './config'
import { sharedLarkConnections, type LarkConnectionLease, type SharedLarkConnection } from './connection'
import {
  isBullXInteractiveOutputPayload,
  isLarkNativeCardPayload,
  renderInteractiveOutputToLarkCard
} from './interactive-output'
import { createLarkStreamingCardSession } from './streaming-card'
import {
  actorIdFromNormalizedMessage,
  asRecord,
  assertLarkSuccess,
  type BullXAttachment,
  compactStringRecord,
  dateFromLarkMillis,
  decodeLarkChannelId,
  decodeThreadId,
  deriveRootId,
  deriveRootIdFromApiMessage,
  encodeLarkChannelId,
  encodeThreadId,
  firstLarkMessageItem,
  fromLarkEmojiType,
  larkActorMetadata,
  larkChannelLoggerFromChat,
  larkDividerPayloadFromMessage,
  larkResourceAttachmentType,
  larkTextContent,
  larkUuidFromOptions,
  type LarkThreadId,
  logLarkChatWarning,
  markdownAstFromText,
  messageIdFromLarkResponse,
  optionalString,
  platformUserIdFromNormalizedMessage,
  profileFromMessage,
  recalledMessagePayload,
  recordLarkPlatformSubject,
  requiredString,
  stringifySimpleMarkdownContent,
  threadIdFromLarkApiMessage,
  toLarkEmojiType
} from './lark-helpers'

export class BullXLarkChatAdapter {
  readonly name = 'lark'
  readonly lockScope = 'thread'
  readonly capabilities: BullXExternalGatewayAdapterCapabilities
  readonly userName: string

  private chat!: BullXExternalGatewayAdapterContext
  private connection: SharedLarkConnection | undefined
  private connectionLease: LarkConnectionLease | undefined
  private readonly channelInfoCache = new Map<string, Promise<BullXExternalGatewayRoomInput>>()
  private readonly p2pChats = new Set<string>()

  constructor(
    private readonly context: BullXExternalGatewayAdapterFactoryContext,
    private readonly config: LarkChannelConfig
  ) {
    this.userName = config.userName ?? 'BullX'
    const outbound: BullXExternalGatewayOutboundCapability[] = [
      'post_message',
      'reply_message',
      'edit_message',
      'delete_message',
      'outbound_idempotency',
      'outbound_reconciliation',
      'add_reaction',
      'remove_reaction',
      'divider',
      'card'
    ]
    // 'streaming' is config-gated: the host only attempts CardKit streaming when
    // declared here, otherwise it falls back to a single final post.
    if (config.streamingEnabled) outbound.push('streaming')
    this.capabilities = {
      inbound: ['message_receive', 'message_recall', 'reaction_add', 'reaction_remove', 'action_event'],
      outbound
    }
  }

  async initialize(chat: BullXExternalGatewayAdapterContext): Promise<void> {
    this.chat = chat
    const lease = await sharedLarkConnections.acquireChat(this.config, this, larkChannelLoggerFromChat(chat))
    this.connection = lease.connection
    this.connectionLease = lease
  }

  async disconnect(): Promise<void> {
    this.connectionLease?.release()
    this.connectionLease = undefined
    this.connection = undefined
  }

  async handleWebhook(): Promise<Response> {
    return new Response('Lark chat adapter is configured for WebSocket transport', { status: 405 })
  }

  encodeThreadId(input: LarkThreadId): string {
    return encodeThreadId(input)
  }

  decodeThreadId(threadId: string): LarkThreadId {
    return decodeThreadId(threadId)
  }

  channelIdFromThreadId(threadId: string): string {
    const { chatId } = decodeThreadId(threadId)
    return encodeLarkChannelId(chatId)
  }

  getChannelVisibility(): 'private' {
    return 'private'
  }

  isDM(threadId: string): boolean {
    const { chatId, rootId } = decodeThreadId(threadId)
    return this.p2pChats.has(chatId) || (rootId === '' && !chatId.startsWith('oc_'))
  }

  async openDM(userId: string): Promise<string> {
    return encodeThreadId({ chatId: userId, rootId: '' })
  }

  async handleSharedMessage(normalizedMessage: lark.NormalizedMessage): Promise<void> {
    if (!this.chat) return
    if (normalizedMessage.chatType === 'p2p') this.p2pChats.add(normalizedMessage.chatId)

    await this.chat.emitMessage(await this.parseMessage(normalizedMessage))
  }

  async parseMessage(normalizedMessage: lark.NormalizedMessage): Promise<any> {
    const messageId = requiredString(normalizedMessage.messageId, 'Lark message event missing messageId')
    const threadId = this.threadIdOf(normalizedMessage)
    const platformUserId = platformUserIdFromNormalizedMessage(normalizedMessage)
    if (!platformUserId) {
      logLarkChatWarning(this, { normalizedMessage }, 'Lark message event missing sender user_id')
      throw new LarkAdapterConfigError('Lark message event is missing sender user_id')
    }

    const content = normalizedMessage.content
    const senderName = optionalString(normalizedMessage.senderName) ?? platformUserId
    const botIdentity = this.connection?.botIdentity
    const isMe = platformUserId === botIdentity?.userId || platformUserId === botIdentity?.openId
    const message = {
      id: messageId,
      threadId,
      text: content,
      formatted: markdownAstFromText(content),
      author: {
        userId: platformUserId,
        userName: senderName,
        fullName: senderName,
        isBot: isMe,
        isMe
      },
      metadata: {
        dateSent: dateFromLarkMillis(normalizedMessage.createTime) ?? new Date()
      },
      raw: normalizedMessage,
      attachments: this.attachmentsFromResources(messageId, normalizedMessage.resources),
      isMention: normalizedMessage.mentionedBot === true
    }

    await recordLarkPlatformSubject(this.context, this.config, platformUserId, {
      metadata: larkActorMetadata(this.config, actorIdFromNormalizedMessage(normalizedMessage), 'message'),
      profile: profileFromMessage(message, normalizedMessage)
    })
    return message
  }

  threadIdOf(normalizedMessage: unknown): string {
    const normalized = asRecord(normalizedMessage)
    const chatId = requiredString(normalized?.chatId, 'Lark message event missing chatId')
    return encodeThreadId({
      chatId,
      rootId: deriveRootId(normalizedMessage)
    })
  }

  async postMessage(
    threadId: string,
    message: unknown,
    options?: BullXExternalGatewayOutboundOptions
  ): Promise<BullXExternalGatewayRawMessage> {
    const { chatId, rootId } = decodeThreadId(threadId)
    const divider = larkDividerPayloadFromMessage(message)
    if (divider) return this.postSystemDivider(threadId, chatId, divider, options)

    const card = this.renderOutboundCard(message)
    if (card) return this.postCard(threadId, chatId, rootId, card, options)

    const targetMessageId = options?.targetMessageId ?? (rootId || undefined)
    const uuid = larkUuidFromOptions(options)
    if (targetMessageId) {
      const response = await this.requireConnection().rawClient.im.v1.message.reply({
        path: { message_id: targetMessageId },
        data: {
          msg_type: 'text',
          content: larkTextContent(this.messageToMarkdown(message)),
          reply_in_thread: Boolean(rootId),
          uuid
        }
      })
      assertLarkSuccess(response, 'message reply')
      const messageId = messageIdFromLarkResponse(response)
      return { id: messageId, threadId, raw: response }
    }

    const response = await this.requireConnection().rawClient.im.v1.message.create({
      params: { receive_id_type: 'chat_id' },
      data: {
        receive_id: chatId,
        msg_type: 'text',
        content: larkTextContent(this.messageToMarkdown(message)),
        uuid
      }
    })
    assertLarkSuccess(response, 'message create')
    const messageId = messageIdFromLarkResponse(response)
    return { id: messageId, threadId, raw: response }
  }

  async postChannelMessage(
    channelId: string,
    message: unknown,
    options?: BullXExternalGatewayOutboundOptions
  ): Promise<BullXExternalGatewayRawMessage> {
    const chatId = decodeLarkChannelId(channelId)
    return this.postMessage(encodeThreadId({ chatId, rootId: '' }), message, options)
  }

  async deleteMessage(
    _threadId: string,
    messageId: string,
    _options?: BullXExternalGatewayOutboundOptions
  ): Promise<void> {
    await this.requireConnection().recallMessage(messageId)
  }

  async editMessage(
    threadId: string,
    messageId: string,
    message: unknown,
    _options?: BullXExternalGatewayOutboundOptions
  ): Promise<BullXExternalGatewayRawMessage> {
    const card = this.renderOutboundCard(message)
    if (card) {
      // Update an already-sent interactive card via the typed message.patch resource.
      const response = await this.requireConnection().rawClient.im.v1.message.patch({
        path: { message_id: messageId },
        data: { content: JSON.stringify(card) }
      })
      assertLarkSuccess(response, 'message card patch')
      return { id: messageId, threadId, raw: response }
    }

    const response = await this.requireConnection().rawClient.im.v1.message.update({
      path: { message_id: messageId },
      data: {
        msg_type: 'text',
        content: larkTextContent(this.messageToMarkdown(message))
      }
    })
    assertLarkSuccess(response, 'message update')
    return { id: messageIdFromLarkResponse(response, messageId), threadId, raw: response }
  }

  async reconcileMessage(
    threadId: string,
    messageId: string,
    _options?: BullXExternalGatewayOutboundOptions
  ): Promise<BullXExternalGatewayMessageReconciliation> {
    const response = await this.requireConnection().rawClient.im.v1.message.get({
      path: { message_id: messageId }
    })
    assertLarkSuccess(response, 'message get')
    const item = firstLarkMessageItem(response)
    const providerMessageId = optionalString(item?.message_id) ?? messageId
    return {
      deleted: Boolean(item?.deleted),
      exists: Boolean(item) && item?.deleted !== true,
      message: item
        ? {
            id: providerMessageId,
            raw: item,
            threadId: threadIdFromLarkApiMessage(item, threadId)
          }
        : undefined,
      providerMessageId,
      raw: response
    }
  }

  async addReaction(_threadId: string, messageId: string, emoji: unknown): Promise<void> {
    await this.requireConnection().addReaction(messageId, toLarkEmojiType(emoji))
  }

  async removeReaction(_threadId: string, messageId: string, emoji: unknown): Promise<void> {
    await this.requireConnection().removeReactionByEmoji(messageId, toLarkEmojiType(emoji))
  }

  rehydrateAttachment(attachment: BullXAttachment): BullXAttachment {
    const metadata = attachment.fetchMetadata
    if (metadata?.provider !== 'lark' || !metadata.fileKey || !metadata.downloadType) return attachment

    return {
      ...attachment,
      fetchData: () =>
        this.requireConnection().downloadResource(metadata.fileKey, metadata.downloadType as lark.ResourceType)
    }
  }

  renderFormatted(content: unknown): string {
    return stringifySimpleMarkdownContent(content)
  }

  async fetchThread(threadId: string) {
    return {
      id: threadId,
      channelId: this.channelIdFromThreadId(threadId),
      isDM: this.isDM(threadId),
      roomVisibility: 'private',
      metadata: decodeThreadId(threadId)
    }
  }

  async fetchChannelInfo(channelId: string) {
    const cached = this.channelInfoCache.get(channelId)
    if (cached) return cached

    const promise = this.fetchChannelInfoUncached(channelId)
    this.channelInfoCache.set(channelId, promise)
    try {
      return await promise
    } catch (error) {
      this.channelInfoCache.delete(channelId)
      throw error
    }
  }

  private async fetchChannelInfoUncached(channelId: string) {
    const chatId = decodeLarkChannelId(channelId)
    try {
      const info = await this.requireConnection().getChatInfo(chatId)
      return {
        id: channelId,
        name: info.name,
        isDM: info.chatType === 'p2p',
        metadata: info
      }
    } catch {
      return {
        id: channelId,
        isDM: this.p2pChats.has(chatId),
        metadata: { chatId }
      }
    }
  }

  async handleCardAction(event: any): Promise<void> {
    if (!this.chat) return

    const rootId = await this.fetchRootIdFor(event.messageId)
    const threadId = encodeThreadId({ chatId: event.chatId, rootId })
    const actionId = event.action.name ?? event.action.tag
    const value = typeof event.action.value === 'string' ? event.action.value : JSON.stringify(event.action.value)
    const userId = optionalString(event.operator?.userId)
    if (!userId) {
      logLarkChatWarning(this, { event }, 'Lark card action event missing operator user_id')
      return
    }
    await recordLarkPlatformSubject(this.context, this.config, userId, {
      metadata: larkActorMetadata(this.config, event.operator, 'card_action'),
      profile: { displayName: optionalString(event.operator.name) }
    })

    await this.chat.emitAction(
      {
        actionId,
        messageId: event.messageId,
        threadId,
        user: {
          userId,
          userName: event.operator.name ?? userId,
          fullName: event.operator.name ?? userId,
          isBot: false,
          isMe: false
        },
        value,
        raw: event
      },
      undefined
    )
  }

  async handleReaction(event: any): Promise<void> {
    if (!this.chat) return

    const { chatId, rootId } = await this.fetchChatAndRootFor(event.messageId)
    if (!chatId) {
      logLarkChatWarning(this, { event }, 'Lark reaction event missing chat_id and message lookup failed')
      return
    }
    const threadId = encodeThreadId({ chatId, rootId })
    const userId = optionalString(event.operator?.userId)
    if (!userId) {
      logLarkChatWarning(this, { event }, 'Lark reaction event missing operator user_id')
      return
    }
    await recordLarkPlatformSubject(this.context, this.config, userId, {
      metadata: larkActorMetadata(this.config, event.operator, 'reaction')
    })

    await this.chat.emitReaction({
      added: event.action === 'added',
      emoji: fromLarkEmojiType(event.emojiType),
      messageId: event.messageId,
      threadId,
      rawEmoji: event.emojiType,
      user: {
        userId,
        userName: userId,
        fullName: userId,
        isBot: false,
        isMe: false
      },
      raw: event
    })
  }

  async fetchRootIdFor(messageId: string): Promise<string> {
    const { rootId } = await this.fetchChatAndRootFor(messageId)
    return rootId || messageId
  }

  async fetchChatAndRootFor(messageId: string): Promise<LarkThreadId> {
    try {
      const response = await this.requireConnection().rawClient.im.v1.message.get({
        path: { message_id: messageId }
      })
      const item = asRecord(asRecord(response.data)?.items?.[0]) ?? asRecord(asRecord(response.data)?.message)
      const chatId = optionalString(item?.chat_id)
      if (chatId) return { chatId, rootId: deriveRootIdFromApiMessage(item) ?? messageId }
    } catch {
      // Fall through to the least-wrong thread identity below. Reaction events do
      // not carry chat_id in the normalized node-sdk shape.
    }

    return { chatId: '', rootId: messageId }
  }

  _getLogger() {
    return this.chat?.getLogger?.('lark')
  }

  async handleRecall(raw: unknown): Promise<void> {
    if (!this.chat) return

    const logger = this._getLogger()
    logger?.debug?.('Lark recall event entered chat adapter', { raw })
    const message = recalledMessagePayload(raw)
    const messageId = requiredString(message?.message_id, 'Lark recall event missing message_id')
    const chatId = requiredString(message?.chat_id, 'Lark recall event missing chat_id')
    const threadId = encodeThreadId({ chatId, rootId: optionalString(message?.root_id) ?? messageId })
    const room = {
      id: encodeLarkChannelId(chatId),
      metadata: { chatId },
      roomVisibility: 'private' as const
    }
    logger?.debug?.('Lark recall event parsed', {
      chatId,
      messageId,
      roomId: room.id,
      threadId,
      recallTime: message?.recall_time,
      recallType: message?.recall_type,
      raw
    })
    await this.chat.emitMessageDeleted(
      {
        threadId,
        messageId,
        deletedAt: dateFromLarkMillis(message?.recall_time ?? message?.update_time ?? message?.create_time),
        kind: 'recalled',
        room,
        raw
      },
      undefined
    )
    logger?.debug?.('Lark recall event emitted to External Gateway', {
      chatId,
      messageId,
      roomId: room.id,
      threadId
    })
  }

  private async postSystemDivider(
    threadId: string,
    chatId: string,
    divider: Record<string, unknown>,
    options?: BullXExternalGatewayOutboundOptions
  ): Promise<{ id: string; raw: unknown; threadId: string }> {
    const response = await this.requireConnection().rawClient.im.v1.message.create({
      params: { receive_id_type: 'chat_id' },
      data: {
        receive_id: chatId,
        msg_type: 'system',
        content: JSON.stringify(divider),
        uuid: larkUuidFromOptions(options)
      }
    })
    assertLarkSuccess(response, 'system divider message create')
    const messageId = messageIdFromLarkResponse(response)
    return { id: messageId, threadId, raw: response }
  }

  private renderOutboundCard(message: unknown): Record<string, unknown> | undefined {
    if (isBullXInteractiveOutputPayload(message)) return renderInteractiveOutputToLarkCard(message.output)
    if (isLarkNativeCardPayload(message)) return message.card
    return undefined
  }

  async beginStreamingCard(input: BullXBeginStreamingCardInput): Promise<BullXStreamingCardHandle> {
    const { chatId, rootId } = decodeThreadId(input.threadId)
    return createLarkStreamingCardSession(this.requireConnection(), {
      chatId,
      rootId: input.rootId ?? (rootId || undefined),
      idempotencyKey: input.idempotencyKey,
      initialText: input.initialText,
      intervalMs: this.config.streamUpdateIntervalMs,
      bufferThreshold: this.config.streamBufferThreshold,
      logger: { warn: (...args) => this._getLogger()?.warn?.(String(args[0] ?? ''), ...args.slice(1)) }
    })
  }

  private async postCard(
    threadId: string,
    chatId: string,
    rootId: string,
    card: Record<string, unknown>,
    options?: BullXExternalGatewayOutboundOptions
  ): Promise<BullXExternalGatewayRawMessage> {
    const targetMessageId = options?.targetMessageId ?? (rootId || undefined)
    const uuid = larkUuidFromOptions(options)
    const content = JSON.stringify(card)
    if (targetMessageId) {
      const response = await this.requireConnection().rawClient.im.v1.message.reply({
        path: { message_id: targetMessageId },
        data: { msg_type: 'interactive', content, reply_in_thread: Boolean(rootId), uuid }
      })
      assertLarkSuccess(response, 'card reply')
      return { id: messageIdFromLarkResponse(response), threadId, raw: response }
    }

    const response = await this.requireConnection().rawClient.im.v1.message.create({
      params: { receive_id_type: 'chat_id' },
      data: { receive_id: chatId, msg_type: 'interactive', content, uuid }
    })
    assertLarkSuccess(response, 'card create')
    return { id: messageIdFromLarkResponse(response), threadId, raw: response }
  }

  private messageToMarkdown(message: unknown): string {
    if (typeof message === 'string') return message
    const record = asRecord(message)
    if (!record) return ''

    const raw = record.raw
    if (typeof raw === 'string') return raw
    if (typeof record.markdown === 'string') return record.markdown
    if (record.ast) return stringifySimpleMarkdownContent(record.ast)
    if (record.card) return JSON.stringify(record.card)

    return JSON.stringify(record)
  }

  private attachmentsFromResources(
    messageId: string,
    resources: readonly lark.ResourceDescriptor[] | undefined
  ): BullXAttachment[] {
    const attachments: BullXAttachment[] = []

    for (const resource of resources ?? []) {
      const attachment = this.attachmentFromResource(messageId, resource)
      if (attachment) attachments.push(attachment)
    }

    return attachments
  }

  private attachmentFromResource(messageId: string, resource: lark.ResourceDescriptor): BullXAttachment | undefined {
    const fileKey = optionalString(resource.fileKey)
    if (!fileKey) return undefined

    const type = larkResourceAttachmentType(resource.type)
    if (!type) return undefined

    const downloadType: lark.ResourceType = resource.type === 'image' ? 'image' : 'file'
    const fetchMetadata = compactStringRecord({
      provider: 'lark',
      messageId,
      fileKey,
      downloadType,
      resourceType: resource.type,
      coverImageKey: optionalString(resource.coverImageKey),
      durationMs: resource.durationMs === undefined ? undefined : String(resource.durationMs)
    })

    return {
      type,
      name: optionalString(resource.fileName),
      fetchMetadata,
      fetchData: () => this.requireConnection().downloadResource(fileKey, downloadType)
    }
  }

  private requireConnection(): SharedLarkConnection {
    if (!this.connection) throw new LarkAdapterConfigError('Lark shared connection is not initialized')
    return this.connection
  }
}
