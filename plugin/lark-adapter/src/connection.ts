import * as lark from '@larksuiteoapi/node-sdk'
import { LarkAdapterConfigError, type LarkChannelConfig, type LarkIdentityProviderConfig } from './config'
import { sdkDomain, type LarkSdkLogger } from './lark-helpers'
import type { BullXLarkChatAdapter } from './chat-adapter'
import type { BullXLarkIdentityProviderAdapter } from './identity-adapter'

type LarkConnectionConfig = {
  appId: string
  appSecret: string
  domain: 'feishu' | 'lark'
}

export type LarkConnectionLease = {
  connection: SharedLarkConnection
  release(): void
}

class SharedLarkConnectionRegistry {
  private readonly connections = new Map<string, SharedLarkConnection>()

  async acquireChat(
    config: LarkChannelConfig,
    adapter: BullXLarkChatAdapter,
    logger: LarkSdkLogger | undefined
  ): Promise<LarkConnectionLease> {
    const connection = this.connectionFor(channelConnectionConfig(config), logger)
    connection.addChatAdapter(adapter)
    await connection.start()

    return {
      connection,
      release: () => this.releaseChat(connection, adapter)
    }
  }

  async acquireIdentity(
    config: LarkIdentityProviderConfig,
    adapter: BullXLarkIdentityProviderAdapter,
    logger: LarkSdkLogger | undefined
  ): Promise<LarkConnectionLease | undefined> {
    if (!config.sync.websocket) return undefined

    const connection = this.connectionFor(identityConnectionConfig(config), logger)
    connection.addIdentityProvider(adapter)
    await connection.start()

    return {
      connection,
      release: () => this.releaseIdentity(connection, adapter)
    }
  }

  resetForTest(): void {
    for (const connection of this.connections.values()) connection.close()
    this.connections.clear()
  }

  private connectionFor(config: LarkConnectionConfig, logger: LarkSdkLogger | undefined): SharedLarkConnection {
    const key = larkConnectionKey(config)
    const existing = this.connections.get(key)
    if (existing) {
      existing.assertSameSecret(config)
      existing.setLogger(logger)
      return existing
    }

    const connection = new SharedLarkConnection(config, logger, () => {
      if (connection.isUnused()) this.connections.delete(key)
    })
    this.connections.set(key, connection)
    return connection
  }

  private releaseChat(connection: SharedLarkConnection, adapter: BullXLarkChatAdapter): void {
    connection.removeChatAdapter(adapter)
    if (connection.isUnused()) connection.close()
  }

  private releaseIdentity(connection: SharedLarkConnection, adapter: BullXLarkIdentityProviderAdapter): void {
    connection.removeIdentityProvider(adapter)
    if (connection.isUnused()) connection.close()
  }
}

export class SharedLarkConnection {
  private channel: lark.LarkChannel | undefined
  private readonly chatAdapters = new Set<BullXLarkChatAdapter>()
  private readonly identityProviders = new Set<BullXLarkIdentityProviderAdapter>()
  private startPromise: Promise<void> | undefined

  constructor(
    private readonly config: LarkConnectionConfig,
    private logger: LarkSdkLogger | undefined,
    private readonly onClose: () => void
  ) {}

  get rawClient(): lark.Client {
    return this.requireChannel().rawClient
  }

  get botIdentity(): lark.BotIdentity | undefined {
    return this.channel?.botIdentity
  }

  addChatAdapter(adapter: BullXLarkChatAdapter): void {
    this.chatAdapters.add(adapter)
  }

  removeChatAdapter(adapter: BullXLarkChatAdapter): void {
    this.chatAdapters.delete(adapter)
  }

  addIdentityProvider(adapter: BullXLarkIdentityProviderAdapter): void {
    this.identityProviders.add(adapter)
  }

  removeIdentityProvider(adapter: BullXLarkIdentityProviderAdapter): void {
    this.identityProviders.delete(adapter)
  }

  setLogger(logger: LarkSdkLogger | undefined): void {
    if (logger) this.logger = logger
  }

  assertSameSecret(config: LarkConnectionConfig): void {
    if (this.config.appSecret !== config.appSecret) {
      throw new LarkAdapterConfigError(`Lark app ${config.appId} is configured with multiple app secrets`)
    }
  }

  async start(): Promise<void> {
    if (this.channel) return
    if (!this.startPromise) this.startPromise = this.doStart()

    return this.startPromise
  }

  close(): void {
    const channel = this.channel
    this.channel = undefined
    this.startPromise = undefined
    void channel?.disconnect()
    this.onClose()
  }

  isUnused(): boolean {
    return this.chatAdapters.size === 0 && this.identityProviders.size === 0
  }

  requireChannel(): lark.LarkChannel {
    if (!this.channel) throw new LarkAdapterConfigError(`Lark app ${this.config.appId} connection is not initialized`)
    return this.channel
  }

  async downloadResource(fileKey: string, type: lark.ResourceType): Promise<Buffer> {
    return this.requireChannel().downloadResource(fileKey, type)
  }

  async recallMessage(messageId: string): Promise<void> {
    await this.requireChannel().recallMessage(messageId)
  }

  async addReaction(messageId: string, emojiType: string): Promise<void> {
    await this.requireChannel().addReaction(messageId, emojiType)
  }

  async removeReactionByEmoji(messageId: string, emojiType: string): Promise<void> {
    await this.requireChannel().removeReactionByEmoji(messageId, emojiType)
  }

  async getChatInfo(chatId: string): Promise<lark.ChatInfo> {
    return this.requireChannel().getChatInfo(chatId)
  }

  async send(chatId: string, input: lark.SendInput, options?: lark.SendOptions): Promise<lark.SendResult> {
    return this.requireChannel().send(chatId, input, options)
  }

  private async doStart(): Promise<void> {
    const channel = lark.createLarkChannel({
      appId: this.config.appId,
      appSecret: this.config.appSecret,
      domain: sdkDomain(this.config.domain),
      transport: 'websocket',
      source: 'bullx-agent',
      includeRawEvent: true,
      logger: this.logger as any,
      policy: {
        requireMention: false
      },
      safety: {
        staleMessageWindowMs: Number.MAX_SAFE_INTEGER,
        chatQueue: { enabled: false },
        dedup: {
          ttl: 1,
          maxEntries: 1,
          sweepIntervalMs: 60_000
        },
        batch: {
          text: { delayMs: 0 },
          media: { delayMs: 0 }
        }
      }
    })

    try {
      this.channel = channel
      channel.on('message', message => this.dispatchMessage(message))
      channel.on('cardAction', event => this.dispatchCardAction(event))
      channel.on('reaction', event => this.dispatchReaction(event))
      this.registerAdditionalDispatcherHandlers(channel)
      await channel.connect()
    } catch (error) {
      this.channel = undefined
      this.startPromise = undefined
      throw error
    }
  }

  private registerAdditionalDispatcherHandlers(channel: lark.LarkChannel): void {
    const dispatcher = (channel as any).dispatcher
    if (typeof dispatcher?.register !== 'function') {
      throw new LarkAdapterConfigError(
        'LarkChannel dispatcher internals are unavailable; shared lifecycle events cannot be registered'
      )
    }

    dispatcher.register({
      'im.message.recalled_v1': async (raw: unknown) => this.dispatchRecall(raw),
      'contact.user.created_v3': async (event: any) => this.dispatchUserUpsert(event.object),
      'contact.user.updated_v3': async (event: any) => this.dispatchUserUpsert(event.object),
      'contact.user.deleted_v3': async (event: any) => this.dispatchUserDeleted(event.object),
      'contact.department.created_v3': async (event: any) => this.dispatchDepartmentUpsert(event.object),
      'contact.department.updated_v3': async (event: any) => this.dispatchDepartmentUpsert(event.object),
      'contact.department.deleted_v3': async (event: any) => this.dispatchDepartmentDeleted(event.object),
      'contact.scope.updated_v3': async () => this.dispatchContactScopeUpdated()
    })
    this.logger?.debug?.('Lark shared dispatcher handlers registered', {
      appId: this.config.appId,
      domain: this.config.domain,
      handlers: [
        'im.message.recalled_v1',
        'contact.user.created_v3',
        'contact.user.updated_v3',
        'contact.user.deleted_v3',
        'contact.department.created_v3',
        'contact.department.updated_v3',
        'contact.department.deleted_v3',
        'contact.scope.updated_v3'
      ]
    })
  }

  private async dispatchMessage(message: lark.NormalizedMessage): Promise<void> {
    await Promise.all([...this.chatAdapters].map(adapter => adapter.handleSharedMessage(message)))
  }

  private async dispatchCardAction(event: lark.CardActionEvent): Promise<void> {
    await Promise.all([...this.chatAdapters].map(adapter => adapter.handleCardAction(event)))
  }

  private async dispatchReaction(event: lark.ReactionEvent): Promise<void> {
    await Promise.all([...this.chatAdapters].map(adapter => adapter.handleReaction(event)))
  }

  private async dispatchRecall(raw: unknown): Promise<void> {
    this.logger?.debug?.('Lark recall raw event received by shared dispatcher', {
      appId: this.config.appId,
      domain: this.config.domain,
      chatAdapterCount: this.chatAdapters.size,
      raw
    })
    await Promise.all([...this.chatAdapters].map(adapter => adapter.handleRecall(raw)))
  }

  private async dispatchUserUpsert(input: unknown): Promise<void> {
    await Promise.all([...this.identityProviders].map(provider => provider.handleUserUpsertEvent(input)))
  }

  private async dispatchUserDeleted(input: unknown): Promise<void> {
    await Promise.all([...this.identityProviders].map(provider => provider.handleUserDeletedEvent(input)))
  }

  private async dispatchDepartmentUpsert(input: unknown): Promise<void> {
    await Promise.all([...this.identityProviders].map(provider => provider.handleDepartmentUpsertEvent(input)))
  }

  private async dispatchDepartmentDeleted(input: unknown): Promise<void> {
    await Promise.all([...this.identityProviders].map(provider => provider.handleDepartmentDeletedEvent(input)))
  }

  private async dispatchContactScopeUpdated(): Promise<void> {
    await Promise.all([...this.identityProviders].map(provider => provider.handleContactScopeUpdated()))
  }
}

function channelConnectionConfig(config: LarkChannelConfig): LarkConnectionConfig {
  return {
    appId: config.appId,
    appSecret: config.appSecret,
    domain: config.domain
  }
}

function identityConnectionConfig(config: LarkIdentityProviderConfig): LarkConnectionConfig {
  return {
    appId: config.appId,
    appSecret: config.appSecret,
    domain: config.domain
  }
}

function larkConnectionKey(config: LarkConnectionConfig): string {
  return `${config.domain}:${config.appId}`
}

export const sharedLarkConnections = new SharedLarkConnectionRegistry()

export function resetLarkSharedConnectionsForTest(): void {
  sharedLarkConnections.resetForTest()
}
