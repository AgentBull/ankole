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
import { isBullXInteractiveOutputCardPayload, isBullXLarkNativeCardPayload } from '@agentbull/bullx-sdk/plugins'
import { renderInteractiveOutputToLarkCard } from './interactive-output'
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
  isBotSenderFromNormalizedMessage,
  larkActorMetadata,
  larkChannelLoggerFromChat,
  larkDividerOriginalTextFromPayload,
  larkDividerPayloadFromMessage,
  normalizeLarkDividerText,
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
      logLarkChatWarning(this, { normalizedMessage }, 'Lark message event missing sender id')
      throw new LarkAdapterConfigError('Lark message event is missing sender id')
    }

    const content = normalizedMessage.content
    const senderName = optionalString(normalizedMessage.senderName) ?? platformUserId
    const botIdentity = this.connection?.botIdentity
    const actorId = actorIdFromNormalizedMessage(normalizedMessage)
    const botUserId = optionalString(botIdentity?.userId)
    const botOpenId = optionalString(botIdentity?.openId)
    const actorUserId = optionalString(actorId?.user_id)
    const isTypedBotSubject = platformUserId.startsWith('bot:')
    const isMe =
      !isTypedBotSubject &&
      ((botUserId !== undefined && (platformUserId === botUserId || actorUserId === botUserId)) ||
        (botOpenId !== undefined && platformUserId === botOpenId))
    const isBotSender = isMe || isBotSenderFromNormalizedMessage(normalizedMessage)
    const attachments = this.attachmentsFromResources(messageId, normalizedMessage.resources)
    if (attachments.length === 0) {
      attachments.push(...(await this.backfillRecentSiblingResourceAttachments(normalizedMessage, actorId)))
    }

    const message = {
      id: messageId,
      threadId,
      text: content,
      formatted: markdownAstFromText(content),
      author: {
        userId: platformUserId,
        userName: senderName,
        fullName: senderName,
        isBot: isBotSender,
        isMe
      },
      metadata: {
        dateSent: dateFromLarkMillis(normalizedMessage.createTime) ?? new Date(),
        platform_subject_provider: this.config.platformSubjectNamespace
      },
      raw: normalizedMessage,
      attachments,
      isMention: normalizedMessage.mentionedBot === true
    }

    await recordLarkPlatformSubject(this.context, this.config, platformUserId, {
      metadata: larkActorMetadata(this.config, actorId, 'message'),
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

    const files = outboundFileInputsFromMessage(message)
    if (files.length > 0) return this.postFiles(threadId, chatId, rootId, message, files, options)

    const targetMessageId = options?.targetMessageId ?? (rootId || undefined)
    const uuid = larkUuidFromOptions(options)
    if (targetMessageId) {
      const response = await this.requireConnection().rawClient.im.v1.message.reply({
        path: { message_id: targetMessageId },
        data: {
          msg_type: 'text',
          content: larkTextContent(this.messageToMarkdown(message)),
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
    if (metadata?.provider !== 'lark' || !metadata.messageId || !metadata.fileKey || !metadata.downloadType) {
      return attachment
    }

    return {
      ...attachment,
      fetchData: () =>
        this.requireConnection().downloadMessageResource(
          metadata.messageId,
          metadata.fileKey,
          metadata.downloadType as lark.ResourceType
        )
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
    const originalText = this.dividerOriginalText(divider)
    if (originalText) {
      const normalized = normalizeLarkDividerText(originalText)
      if (normalized.truncated) {
        this._getLogger()?.warn?.('Lark system divider text exceeded Feishu limits and was truncated', {
          originalLength: Array.from(originalText).length,
          normalizedText: normalized.text
        })
      }
    }

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

  private dividerOriginalText(divider: Record<string, unknown>): string | undefined {
    return larkDividerOriginalTextFromPayload(divider)
  }

  private renderOutboundCard(message: unknown): Record<string, unknown> | undefined {
    if (isBullXInteractiveOutputCardPayload(message)) return renderInteractiveOutputToLarkCard(message.output)
    if (isBullXLarkNativeCardPayload(message)) return message.card
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
        data: { msg_type: 'interactive', content, uuid }
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

  private async postFiles(
    threadId: string,
    chatId: string,
    rootId: string,
    message: unknown,
    files: readonly LarkOutboundFileInput[],
    options?: BullXExternalGatewayOutboundOptions
  ): Promise<BullXExternalGatewayRawMessage> {
    const targetMessageId = options?.targetMessageId ?? (rootId || undefined)
    const uuid = larkUuidFromOptions(options)
    const connection = this.requireConnection()
    let lastSent: BullXExternalGatewayRawMessage | undefined

    const leadingText = this.messageToMarkdown(message).trim()
    if (leadingText) {
      const textUuid = uuid ? `${uuid}-text` : undefined
      const response = targetMessageId
        ? await connection.rawClient.im.v1.message.reply({
            path: { message_id: targetMessageId },
            data: { msg_type: 'text', content: larkTextContent(leadingText), uuid: textUuid }
          })
        : await connection.rawClient.im.v1.message.create({
            params: { receive_id_type: 'chat_id' },
            data: { receive_id: chatId, msg_type: 'text', content: larkTextContent(leadingText), uuid: textUuid }
          })
      assertLarkSuccess(response, 'message text create before file')
      lastSent = { id: messageIdFromLarkResponse(response), threadId, raw: response }
    }

    for (const [index, file] of files.entries()) {
      const buffer = await bufferFromOutboundFileData(file.data)
      const upload = await connection.rawClient.im.v1.file.create({
        data: {
          file_type: larkUploadFileType(file.filename, file.mimeType),
          file_name: file.filename,
          file: buffer
        }
      })
      const fileKey =
        optionalString(asRecord(upload)?.file_key) ?? optionalString(asRecord(asRecord(upload)?.data)?.file_key)
      if (!fileKey) throw new LarkAdapterConfigError('Lark file upload response is missing file_key')

      const content = JSON.stringify({ file_key: fileKey })
      const fileUuid = uuid ? `${uuid}-file-${index}` : undefined
      const response = targetMessageId
        ? await connection.rawClient.im.v1.message.reply({
            path: { message_id: targetMessageId },
            data: { msg_type: 'file', content, uuid: fileUuid }
          })
        : await connection.rawClient.im.v1.message.create({
            params: { receive_id_type: 'chat_id' },
            data: { receive_id: chatId, msg_type: 'file', content, uuid: fileUuid }
          })
      assertLarkSuccess(response, 'message file create')
      lastSent = { id: messageIdFromLarkResponse(response), threadId, raw: response }
    }

    if (!lastSent) throw new LarkAdapterConfigError('No outbound files were sent')
    return lastSent
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

  private async backfillRecentSiblingResourceAttachments(
    normalizedMessage: lark.NormalizedMessage,
    actorId: Record<string, any> | undefined
  ): Promise<BullXAttachment[]> {
    if (normalizedMessage.mentionedBot !== true) return []
    if (normalizedMessage.chatType !== 'group') return []
    if (!shouldBackfillRecentAttachment(normalizedMessage.content)) return []

    const triggerTime = Number(normalizedMessage.createTime)
    if (!Number.isFinite(triggerTime)) return []

    const windowMs = 2 * 60 * 1000
    const startTime = Math.max(0, Math.floor((triggerTime - windowMs) / 1000))
    const endTime = Math.ceil(triggerTime / 1000)

    try {
      const response = await this.requireConnection().rawClient.im.v1.message.list({
        params: {
          container_id_type: 'chat',
          container_id: normalizedMessage.chatId,
          start_time: String(startTime),
          end_time: String(endTime),
          sort_type: 'ByCreateTimeDesc',
          page_size: 20
        }
      })
      assertLarkSuccess(response, 'message list for recent attachment backfill')

      const attachments: BullXAttachment[] = []
      const data = asRecord(response.data)
      const items = Array.isArray(data?.items)
        ? data.items.flatMap(item => (asRecord(item) ? [asRecord(item)!] : []))
        : []
      const skipped: Array<Record<string, unknown>> = []

      for (const item of items) {
        const candidateMessageId = optionalString(item.message_id)
        if (!candidateMessageId || candidateMessageId === normalizedMessage.messageId) continue

        const candidateTime = Number(optionalString(item.create_time))
        if (Number.isFinite(candidateTime) && candidateTime >= triggerTime) continue

        const senderMatch = recentAttachmentSenderMatch(actorId, asRecord(item.sender))
        if (!senderMatch.matched) {
          skipped.push({
            messageId: candidateMessageId,
            reason: senderMatch.reason,
            sender: item.sender
          })
          continue
        }

        const resources = larkResourcesFromApiMessage(item)
        for (const resource of resources) {
          const attachment = this.attachmentFromResource(candidateMessageId, resource)
          if (attachment) attachments.push(attachment)
          if (attachments.length >= 3) break
        }
        if (attachments.length > 0) {
          this._getLogger()?.debug?.('Lark recent attachment backfill matched prior message', {
            triggerMessageId: normalizedMessage.messageId,
            candidateMessageId,
            senderMatch: senderMatch.reason,
            resourceCount: resources.length,
            attachmentCount: attachments.length,
            windowMs
          })
          break
        }
      }

      if (attachments.length === 0) {
        this._getLogger()?.debug?.('Lark recent attachment backfill found no usable prior resources', {
          triggerMessageId: normalizedMessage.messageId,
          chatId: normalizedMessage.chatId,
          startTime,
          endTime,
          candidateCount: items.length,
          skipped: skipped.slice(0, 5)
        })
      }

      return attachments
    } catch (error) {
      this._getLogger()?.warn?.('Lark recent attachment backfill failed', {
        triggerMessageId: normalizedMessage.messageId,
        chatId: normalizedMessage.chatId,
        error
      })
      return []
    }
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
      fetchData: () => this.requireConnection().downloadMessageResource(messageId, fileKey, downloadType)
    }
  }

  private requireConnection(): SharedLarkConnection {
    if (!this.connection) throw new LarkAdapterConfigError('Lark shared connection is not initialized')
    return this.connection
  }
}

type LarkOutboundFileInput = {
  data: unknown
  filename: string
  mimeType?: string
}

function outboundFileInputsFromMessage(message: unknown): LarkOutboundFileInput[] {
  const record = asRecord(message)
  if (!record || !Array.isArray(record.files)) return []

  return record.files.flatMap(file => {
    const fileRecord = asRecord(file)
    const filename = optionalString(fileRecord?.filename)?.trim()
    if (!fileRecord || !filename) return []
    return [
      {
        data: fileRecord.data,
        filename,
        mimeType: optionalString(fileRecord.mimeType)
      }
    ]
  })
}

type RecentAttachmentSenderMatch = {
  matched: boolean
  reason: string
}

function recentAttachmentSenderMatch(
  triggerActor: Record<string, any> | undefined,
  candidateSender: Record<string, any> | undefined
): RecentAttachmentSenderMatch {
  if (!candidateSender) return { matched: false, reason: 'candidate_missing_sender' }

  const candidateId = optionalString(candidateSender.id)
  const candidateIdType = optionalString(candidateSender.id_type)
  const candidateSenderType = optionalString(candidateSender.sender_type)
  const triggerUserId = optionalString(triggerActor?.user_id)
  const triggerOpenId = optionalString(triggerActor?.open_id)
  const triggerSenderType = optionalString(triggerActor?.sender_type)

  if (candidateId && candidateIdType === 'user_id' && triggerUserId && candidateId === triggerUserId) {
    return { matched: true, reason: 'same_user_id' }
  }
  if (candidateId && candidateIdType === 'open_id' && triggerOpenId && candidateId === triggerOpenId) {
    return { matched: true, reason: 'same_open_id' }
  }
  if (isLarkBotLikeSenderType(triggerSenderType) && isLarkBotLikeSenderType(candidateSenderType)) {
    return { matched: true, reason: 'bot_sender_type_fallback' }
  }

  return { matched: false, reason: 'sender_mismatch' }
}

function isLarkBotLikeSenderType(senderType: string | undefined): boolean {
  return senderType === 'bot' || senderType === 'app'
}

function shouldBackfillRecentAttachment(text: string | undefined): boolean {
  if (!text) return false
  const normalized = text.toLowerCase()
  return /上一条|前一条|刚发|刚刚发|刚才|上面|附件|文件|图片|图像|照片|last message|previous message|previous file|previous image|attached|attachment/.test(
    normalized
  )
}

function larkResourcesFromApiMessage(item: Record<string, any>): lark.ResourceDescriptor[] {
  const msgType = optionalString(item.msg_type)
  const content = parseLarkApiMessageContent(optionalString(asRecord(item.body)?.content))
  if (!content) return []

  const resources: lark.ResourceDescriptor[] = []
  if (msgType === 'file') {
    const fileKey = optionalString(content.file_key)
    if (fileKey) resources.push({ type: 'file', fileKey, fileName: optionalString(content.file_name) })
  } else if (msgType === 'image') {
    const imageKey = optionalString(content.image_key)
    if (imageKey) resources.push({ type: 'image', fileKey: imageKey })
  } else if (msgType === 'audio') {
    const fileKey = optionalString(content.file_key)
    if (fileKey) resources.push({ type: 'audio', fileKey })
  } else if (msgType === 'media') {
    const fileKey = optionalString(content.file_key)
    if (fileKey) resources.push({ type: 'video', fileKey, fileName: optionalString(content.file_name) })
  } else if (msgType === 'post') {
    resources.push(...larkResourcesFromPostContent(content))
  }

  return resources
}

function parseLarkApiMessageContent(content: string | undefined): Record<string, any> | undefined {
  if (!content) return undefined
  try {
    return asRecord(JSON.parse(content))
  } catch {
    return undefined
  }
}

function larkResourcesFromPostContent(content: Record<string, any>): lark.ResourceDescriptor[] {
  const resources: lark.ResourceDescriptor[] = []
  const visit = (value: unknown) => {
    const record = asRecord(value)
    if (record) {
      const tag = optionalString(record.tag)
      const imageKey = optionalString(record.image_key)
      const fileKey = optionalString(record.file_key)
      if (tag === 'img' && imageKey) resources.push({ type: 'image', fileKey: imageKey })
      if (tag === 'file' && fileKey) {
        resources.push({ type: 'file', fileKey, fileName: optionalString(record.file_name) })
      }
      for (const child of Object.values(record)) visit(child)
      return
    }
    if (Array.isArray(value)) {
      for (const child of value) visit(child)
    }
  }

  visit(content)
  return resources
}

async function bufferFromOutboundFileData(data: unknown): Promise<Buffer> {
  if (Buffer.isBuffer(data)) return data
  if (data instanceof ArrayBuffer) return Buffer.from(data)
  if (ArrayBuffer.isView(data)) return Buffer.from(data.buffer, data.byteOffset, data.byteLength)
  if (data instanceof Blob) return Buffer.from(await data.arrayBuffer())
  throw new LarkAdapterConfigError('Outbound file data must be Buffer, ArrayBuffer, typed array, or Blob')
}

function larkUploadFileType(
  filename: string,
  mimeType: string | undefined
): 'opus' | 'mp4' | 'pdf' | 'doc' | 'xls' | 'ppt' | 'stream' {
  const lowerName = filename.toLowerCase()
  const lowerMime = mimeType?.toLowerCase() ?? ''
  if (lowerName.endsWith('.pdf') || lowerMime === 'application/pdf') return 'pdf'
  if (lowerName.endsWith('.doc') || lowerName.endsWith('.docx')) return 'doc'
  if (lowerName.endsWith('.xls') || lowerName.endsWith('.xlsx')) return 'xls'
  if (lowerName.endsWith('.ppt') || lowerName.endsWith('.pptx')) return 'ppt'
  if (lowerName.endsWith('.mp4') || lowerMime === 'video/mp4') return 'mp4'
  if (lowerName.endsWith('.opus') || lowerMime === 'audio/opus') return 'opus'
  return 'stream'
}
