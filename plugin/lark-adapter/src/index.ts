import * as lark from '@larksuiteoapi/node-sdk'
import QRCode from 'qrcode'
import type {
  BullXExternalGatewayAdapterContext,
  BullXExternalGatewayAdapterCapabilities,
  BullXExternalGatewayAdapterFactoryContext,
  BullXPlatformSubjectProfile,
  BullXIdentityProviderAdapter,
  BullXIdentityProviderAdapterFactoryContext,
  BullXIdentityProviderFullSyncSnapshot,
  BullXIdentityProviderGroupRecord,
  BullXIdentityProviderUserRecord,
  BullXPluginInteractiveConfig,
  BullXPlugin,
  BullXPluginJsonValue
} from '@agentbull/bullx-sdk/plugins'
import { bullxExternalIdentityNamespaceIdPattern } from '@agentbull/bullx-sdk/plugins'
import { z } from 'zod'

type BullXAttachment = {
  data?: Buffer | Blob
  fetchData?: () => Promise<Buffer>
  fetchMetadata?: Record<string, string>
  height?: number
  mimeType?: string
  name?: string
  size?: number
  type: 'image' | 'file' | 'video' | 'audio'
  url?: string
  width?: number
}

type LarkSdkLogger = {
  debug?: (...args: unknown[]) => void
  error?: (...args: unknown[]) => void
  fatal?: (...args: unknown[]) => void
  info?: (...args: unknown[]) => void
  trace?: (...args: unknown[]) => void
  warn?: (...args: unknown[]) => void
}

const larkChannelConfigSchema = z
  .object({
    appId: z.string().min(1),
    appSecret: z.string().min(1),
    /**
     * Connection realm for both API base URLs and the shared long connection.
     * Chat and identity realtime sync can share one app only when this matches.
     */
    domain: z.enum(['feishu', 'lark']).default('feishu'),
    group_message_mode: z.enum(['addressed_only', 'observe_all', 'may_intervene']).default('observe_all'),
    /**
     * Namespace used when this chat channel records Lark `user_id` subjects.
     * Channels installed in the same Lark tenant can use the same namespace so
     * BullX recognizes the same human across those chat channels.
     */
    platformSubjectNamespace: z.string().regex(bullxExternalIdentityNamespaceIdPattern).optional(),
    /**
     * @deprecated Old channel configs used this key before the Lark setup UI made
     * the platform-subject namespace explicit. Keep read compatibility so stored
     * encrypted configs do not have to be migrated immediately.
     */
    platformProviderId: z.string().regex(bullxExternalIdentityNamespaceIdPattern).optional(),
    userName: z.string().min(1).optional()
  })
  .strict()
  .superRefine((config, context) => {
    const namespace = config.platformSubjectNamespace ?? config.platformProviderId
    if (!namespace) {
      context.addIssue({
        code: 'custom',
        path: ['platformSubjectNamespace'],
        message: 'platformSubjectNamespace is required'
      })
      return
    }

    if (
      config.platformSubjectNamespace &&
      config.platformProviderId &&
      config.platformSubjectNamespace !== config.platformProviderId
    ) {
      context.addIssue({
        code: 'custom',
        path: ['platformProviderId'],
        message: 'legacy platformProviderId must match platformSubjectNamespace when both are provided'
      })
    }
  })
  .transform(config => ({
    appId: config.appId,
    appSecret: config.appSecret,
    domain: config.domain,
    group_message_mode: config.group_message_mode,
    platformSubjectNamespace: config.platformSubjectNamespace ?? config.platformProviderId!,
    userName: config.userName
  }))

const larkIdentityProviderConfigSchema = z
  .object({
    appId: z.string().min(1),
    appSecret: z.string().min(1),
    domain: z.enum(['feishu', 'lark']).default('feishu'),
    oidc: z
      .object({
        enabled: z.boolean().default(true),
        scopes: z.array(z.string().min(1)).default(['contact:user.employee_id:readonly'])
      })
      .default({ enabled: true, scopes: ['contact:user.employee_id:readonly'] }),
    sync: z
      .object({
        users: z.boolean().default(true),
        departments: z.boolean().default(true),
        websocket: z.boolean().default(true),
        pageSize: z.number().int().min(1).max(50).default(50)
      })
      .default({ users: true, departments: true, websocket: true, pageSize: 50 }),
    /*
     * Kept only so older saved configs can still parse. The current Lark/Feishu
     * long-connection API does not need event verification token or encrypt key.
     */
    event: z
      .object({
        verificationToken: z.string().min(1).optional(),
        encryptKey: z.string().min(1).optional()
      })
      .default({})
  })
  .strict()

export type LarkChannelConfig = z.infer<typeof larkChannelConfigSchema>
export type LarkIdentityProviderConfig = z.infer<typeof larkIdentityProviderConfigSchema>

export class LarkAdapterConfigError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'LarkAdapterConfigError'
  }
}

class LarkContactSyncUnavailableError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'LarkContactSyncUnavailableError'
  }
}

type LarkAppRegistrationResult = {
  client_id: string
  client_secret: string
  user_info?: {
    open_id?: string
    tenant_brand?: 'feishu' | 'lark'
  }
}

type LarkAppRegistration = (options: {
  onQRCodeReady(info: { url: string; expireIn?: number }): void
  onStatusChange?(info: { status: string; interval?: number }): void
  signal?: AbortSignal
  source?: string
}) => Promise<LarkAppRegistrationResult>

let larkAppRegistrationOverride: LarkAppRegistration | undefined

export function setLarkAppRegistrationForTest(registration: LarkAppRegistration | undefined): void {
  larkAppRegistrationOverride = registration
}

export function createBullXLarkAdapter(context: BullXExternalGatewayAdapterFactoryContext) {
  const parsed = larkChannelConfigSchema.safeParse(context.config)
  if (!parsed.success) {
    throw new LarkAdapterConfigError(`Invalid Lark adapter config for channel ${context.channel.name}`, {
      cause: parsed.error
    })
  }

  return new BullXLarkChatAdapter(context, parsed.data)
}

export function createBullXLarkIdentityProvider(
  context: BullXIdentityProviderAdapterFactoryContext
): BullXIdentityProviderAdapter {
  const parsed = larkIdentityProviderConfigSchema.safeParse(context.config)
  if (!parsed.success) {
    throw new LarkAdapterConfigError(`Invalid Lark identity provider config for ${context.providerId}`, {
      cause: parsed.error
    })
  }

  if (parsed.data.oidc.enabled && context.isProduction && !context.publicBaseUrl) {
    throw new LarkAdapterConfigError(
      `admin_auth.public_base_url is required for Lark OIDC provider ${context.providerId}`
    )
  }

  return new BullXLarkIdentityProviderAdapter(context, parsed.data)
}

const larkInteractiveConfig: BullXPluginInteractiveConfig = {
  displayName: {
    'en-US': 'Scan to create app',
    'zh-Hans-CN': '扫码创建应用'
  },
  description: {
    'en-US': 'Use the official Lark / Feishu one-click app creation flow to fill App ID and App Secret.',
    'zh-Hans-CN': '使用飞书 / Lark 官方一键创建应用流程回填 App ID 和 App Secret。'
  },
  async start(context) {
    const register = await resolveLarkAppRegistration()
    const pendingUpdates: Promise<unknown>[] = []
    const result = await register({
      source: 'bullx-agent',
      signal: context.signal,
      onQRCodeReady: info => {
        /*
         * Feishu/Lark's one-click app creation URL is a mobile-app scan target,
         * not a normal browser authorization link. Render a QR code immediately
         * so the operator can scan with the Feishu/Lark mobile client while the
         * server-side registration promise continues to wait for completion.
         */
        const qrUpdate = larkQrCodeHtml(info.url)
          .then(html =>
            context.onUpdate({
              status: {
                'en-US': `Waiting for scan${info.expireIn ? `, expires in ${info.expireIn}s` : ''}`,
                'zh-Hans-CN': `等待扫码${info.expireIn ? `，${info.expireIn} 秒后过期` : ''}`
              },
              html
            })
          )
          .catch(() =>
            context.onUpdate({
              status: {
                'en-US': 'QR code rendering failed; use a QR generator with the registration URL below.',
                'zh-Hans-CN': '二维码渲染失败；请使用下方注册链接生成二维码后扫码。'
              },
              html: larkRegistrationLinkHtml(info.url)
            })
          )
        pendingUpdates.push(qrUpdate)
      },
      onStatusChange: info => {
        void context.onUpdate({
          status: {
            'en-US': `Authorization status: ${info.status}`,
            'zh-Hans-CN': `授权状态：${info.status}`
          }
        })
      }
    })
    /*
     * QR rendering is asynchronous. Wait for queued progress updates before
     * publishing the final credentials so polling clients do not briefly see a
     * completed session without the scan UI that explains what happened.
     */
    await Promise.allSettled(pendingUpdates)

    return {
      status: {
        'en-US': 'App credentials received',
        'zh-Hans-CN': '已获取应用凭据'
      },
      values: {
        appId: result.client_id,
        appSecret: result.client_secret,
        domain: result.user_info?.tenant_brand ?? 'feishu'
      },
      html: result.user_info?.tenant_brand
        ? `<p>Tenant brand: ${escapeHtml(result.user_info.tenant_brand)}</p>`
        : undefined
    }
  }
}

export const larkAdapterPlugin = {
  metadata: {
    id: 'lark-adapter',
    apiVersion: 1,
    displayName: 'Lark / Feishu Chat Adapter',
    description: 'First-party Lark and Feishu adapters for chat ingress, login, and directory sync.'
  },
  externalGatewayAdapters: [
    {
      id: 'lark',
      setup: {
        displayName: {
          'en-US': 'Lark / Feishu',
          'zh-Hans-CN': '飞书 / Lark'
        },
        description: {
          'en-US': 'Connect one BullX Agent channel to a Lark or Feishu self-built app.',
          'zh-Hans-CN': '将一个 BullX Agent 的聊天入口连接到飞书或 Lark 自建应用。'
        },
        defaultChannelName: 'lark',
        defaultConfig: {
          appId: '',
          appSecret: '',
          domain: 'feishu',
          group_message_mode: 'observe_all',
          platformSubjectNamespace: 'lark-main',
          userName: 'BullX'
        },
        fields: [
          {
            path: ['appId'],
            type: 'text',
            label: {
              'en-US': 'App ID',
              'zh-Hans-CN': 'App ID'
            }
          },
          {
            path: ['appSecret'],
            type: 'password',
            secret: true,
            label: {
              'en-US': 'App Secret',
              'zh-Hans-CN': 'App Secret'
            }
          },
          {
            path: ['domain'],
            type: 'select',
            label: {
              'en-US': 'Domain',
              'zh-Hans-CN': '域'
            },
            defaultValue: 'feishu',
            options: [
              {
                value: 'feishu',
                label: 'Feishu'
              },
              {
                value: 'lark',
                label: 'Lark'
              }
            ]
          },
          {
            path: ['platformSubjectNamespace'],
            type: 'text',
            label: {
              'en-US': 'Platform namespace',
              'zh-Hans-CN': '平台用户命名空间'
            },
            description: {
              'en-US':
                'Namespace used when this chat channel records Lark user_id subjects, for example lark-main. Use the same value for channels in the same Lark tenant.',
              'zh-Hans-CN':
                '此 chat channel 记录 Lark user_id 时使用的平台用户命名空间，例如 lark-main。同一个飞书租户下的多个 channel 可以使用同一个值。'
            },
            defaultValue: 'lark-main'
          },
          {
            path: ['group_message_mode'],
            type: 'select',
            label: {
              'en-US': 'Group message mode',
              'zh-Hans-CN': '群消息模式'
            },
            description: {
              'en-US':
                'addressed_only only accepts @ mentions. observe_all mirrors non-@ group messages only. may_intervene mirrors them and delivers ambient events to the agent.',
              'zh-Hans-CN':
                'addressed_only 只接收 @ 消息。observe_all 只镜像群内非 @ 消息；may_intervene 会镜像并把它们作为 ambient 事件投递给 agent。'
            },
            defaultValue: 'observe_all',
            options: [
              {
                value: 'observe_all',
                label: {
                  'en-US': 'Observe all',
                  'zh-Hans-CN': '观测全部'
                }
              },
              {
                value: 'addressed_only',
                label: {
                  'en-US': 'Addressed only',
                  'zh-Hans-CN': '只处理被点名'
                }
              },
              {
                value: 'may_intervene',
                label: {
                  'en-US': 'May intervene',
                  'zh-Hans-CN': '可介入'
                }
              }
            ]
          },
          {
            path: ['userName'],
            type: 'text',
            label: {
              'en-US': 'Bot display name',
              'zh-Hans-CN': '机器人显示名'
            },
            defaultValue: 'BullX'
          }
        ],
        interactiveConfig: larkInteractiveConfig
      },
      create: createBullXLarkAdapter
    }
  ],
  identityProviderAdapters: [
    {
      id: 'lark',
      setup: {
        displayName: {
          'en-US': 'Lark / Feishu',
          'zh-Hans-CN': '飞书 / Lark'
        },
        description: {
          'en-US': 'OIDC login and contact sync for a Lark or Feishu self-built app.',
          'zh-Hans-CN': '使用飞书或 Lark 自建应用完成 OIDC 登录和通讯录同步。'
        },
        defaultProviderId: 'lark-main',
        defaultConfig: {
          appId: '',
          appSecret: '',
          domain: 'feishu',
          oidc: {
            enabled: true,
            scopes: ['contact:user.employee_id:readonly']
          },
          sync: {
            users: true,
            departments: true,
            websocket: true,
            pageSize: 50
          },
          event: {}
        },
        fields: [
          {
            path: ['appId'],
            type: 'text',
            label: {
              'en-US': 'App ID',
              'zh-Hans-CN': 'App ID'
            }
          },
          {
            path: ['appSecret'],
            type: 'password',
            secret: true,
            label: {
              'en-US': 'App Secret',
              'zh-Hans-CN': 'App Secret'
            }
          },
          {
            path: ['domain'],
            type: 'select',
            label: {
              'en-US': 'Domain',
              'zh-Hans-CN': '域'
            },
            defaultValue: 'feishu',
            options: [
              {
                value: 'feishu',
                label: 'Feishu'
              },
              {
                value: 'lark',
                label: 'Lark'
              }
            ]
          },
          {
            path: ['oidc', 'enabled'],
            type: 'checkbox',
            label: {
              'en-US': 'Enable OIDC login',
              'zh-Hans-CN': '启用 OIDC 登录'
            },
            defaultValue: true
          },
          {
            path: ['sync', 'users'],
            type: 'checkbox',
            label: {
              'en-US': 'Sync users',
              'zh-Hans-CN': '同步用户'
            },
            defaultValue: true
          },
          {
            path: ['sync', 'departments'],
            type: 'checkbox',
            label: {
              'en-US': 'Sync departments',
              'zh-Hans-CN': '同步部门'
            },
            defaultValue: true
          },
          {
            path: ['sync', 'websocket'],
            type: 'checkbox',
            label: {
              'en-US': 'Sync contact changes in realtime',
              'zh-Hans-CN': '实时同步通讯录变更'
            },
            defaultValue: true
          },
          {
            path: ['sync', 'pageSize'],
            type: 'number',
            label: {
              'en-US': 'Page size',
              'zh-Hans-CN': '分页大小'
            },
            defaultValue: 50
          }
        ]
      },
      create: createBullXLarkIdentityProvider
    }
  ]
} satisfies BullXPlugin

export default larkAdapterPlugin

async function resolveLarkAppRegistration(): Promise<LarkAppRegistration> {
  if (larkAppRegistrationOverride) return larkAppRegistrationOverride

  const registerApp = (lark as Record<string, unknown>).registerApp
  if (typeof registerApp === 'function') return registerApp as LarkAppRegistration

  throw new LarkAdapterConfigError('Lark one-click app registration is not available in installed SDK packages')
}

type LarkConnectionConfig = {
  appId: string
  appSecret: string
  domain: 'feishu' | 'lark'
}

type LarkConnectionLease = {
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

class SharedLarkConnection {
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

const sharedLarkConnections = new SharedLarkConnectionRegistry()

export function resetLarkSharedConnectionsForTest(): void {
  sharedLarkConnections.resetForTest()
}

class BullXLarkIdentityProviderAdapter implements BullXIdentityProviderAdapter {
  private readonly client: lark.Client
  private connectionLease: LarkConnectionLease | undefined

  constructor(
    private readonly context: BullXIdentityProviderAdapterFactoryContext,
    private readonly config: LarkIdentityProviderConfig
  ) {
    this.client = new lark.Client({
      appId: config.appId,
      appSecret: config.appSecret,
      domain: sdkDomain(config.domain)
    })
  }

  buildOidcAuthorizationUrl(input: { redirectUri: string; state: string }): string {
    if (!this.config.oidc.enabled) throw new LarkAdapterConfigError('Lark OIDC is disabled')

    const params = new URLSearchParams({
      client_id: this.config.appId,
      redirect_uri: input.redirectUri,
      response_type: 'code',
      scope: this.config.oidc.scopes.join(' '),
      state: input.state
    })

    return `${accountsBaseUrl(this.config.domain)}/open-apis/authen/v1/authorize?${params.toString()}`
  }

  async completeOidcLogin(input: { code: string }): Promise<{ user: BullXIdentityProviderUserRecord }> {
    if (!this.config.oidc.enabled) throw new LarkAdapterConfigError('Lark OIDC is disabled')

    const token = await this.client.authen.oidcAccessToken.create({
      data: {
        grant_type: 'authorization_code',
        code: input.code
      }
    })
    assertLarkSuccess(token, 'oidc access token')

    const accessToken = token.data?.access_token
    if (!accessToken) throw new LarkAdapterConfigError('Lark OIDC access token response is missing access_token')

    const userInfo = await this.client.authen.userInfo.get({}, lark.withUserAccessToken(accessToken))
    assertLarkSuccess(userInfo, 'oidc user info')
    const user = await this.hydrateUser(userInfo.data)
    if (!user) throw new LarkAdapterConfigError('Lark OIDC user info is missing user_id')

    return { user }
  }

  async fullSync(): Promise<BullXIdentityProviderFullSyncSnapshot | undefined> {
    try {
      const groups = this.config.sync.departments ? await this.listDepartments() : []
      const users = this.config.sync.users ? await this.listUsers(groups) : []

      return { groups, users }
    } catch (error) {
      if (!isIgnorableContactSyncError(error)) throw error

      this.context.logger?.warn?.(
        { providerId: this.context.providerId, error: larkErrorSummary(error) },
        'Lark identity contact full sync skipped'
      )
      return undefined
    }
  }

  async start(): Promise<void> {
    this.connectionLease = await sharedLarkConnections.acquireIdentity(
      this.config,
      this,
      larkLoggerFromRuntimeLogger(this.context.logger)
    )
  }

  async stop(): Promise<void> {
    this.connectionLease?.release()
    this.connectionLease = undefined
  }

  private async listDepartments(): Promise<BullXIdentityProviderGroupRecord[]> {
    const groups: BullXIdentityProviderGroupRecord[] = []
    const iterator = await this.client.contact.department.childrenWithIterator({
      path: {
        department_id: '0'
      },
      params: {
        department_id_type: 'department_id',
        user_id_type: 'user_id',
        fetch_child: true,
        page_size: this.config.sync.pageSize
      }
    })

    for await (const page of iterator) {
      const departments = requireNonEmptyContactPage(page?.items, 'contact department children')
      for (const department of departments) {
        const group = mapDepartmentRecord(department)
        if (group) groups.push(group)
      }
    }

    return groups
  }

  private async listUsers(
    groups: readonly BullXIdentityProviderGroupRecord[]
  ): Promise<BullXIdentityProviderUserRecord[]> {
    const users = new Map<string, BullXIdentityProviderUserRecord>()
    const departmentIds = ['0', ...groups.map(group => group.externalId)]

    for (const departmentId of departmentIds) {
      const iterator = await this.client.contact.user.findByDepartmentWithIterator({
        params: {
          user_id_type: 'user_id',
          department_id_type: 'department_id',
          department_id: departmentId,
          page_size: this.config.sync.pageSize
        }
      })

      for await (const page of iterator) {
        const pageUsers = requireNonEmptyContactPage(page?.items, 'contact user find by department')
        for (const rawUser of pageUsers) {
          const user = mapUserRecord(rawUser)
          if (!user) continue

          users.set(user.externalId, mergeUserRecord(users.get(user.externalId), user))
        }
      }
    }

    return [...users.values()]
  }

  private async hydrateUser(input: unknown): Promise<BullXIdentityProviderUserRecord | undefined> {
    const direct = mapUserRecord(input)
    if (direct?.externalId) {
      const contact = await this.fetchContactUser(direct.externalId)
      return mergeUserRecord(direct, contact ?? direct)
    }

    const object = asRecord(input)
    const email = optionalString(object?.enterprise_email) ?? optionalString(object?.email)
    const mobile = optionalString(object?.mobile)
    if (!email && !mobile) return undefined

    const ids = await this.client.contact.user.batchGetId({
      data: {
        emails: email ? [email] : undefined,
        mobiles: mobile ? [mobile] : undefined,
        include_resigned: true
      },
      params: {
        user_id_type: 'user_id'
      }
    })
    assertLarkSuccess(ids, 'contact user batchGetId')
    const userId = ids.data?.user_list?.find(item => item.user_id)?.user_id
    if (!userId) return undefined

    const contact = await this.fetchContactUser(userId)
    return (
      contact ?? {
        externalId: userId,
        status: 'active',
        email,
        phone: normalizePhone(mobile),
        metadata: compactJsonObject({ source: 'oidc_user_info' })
      }
    )
  }

  private async fetchContactUser(userId: string): Promise<BullXIdentityProviderUserRecord | undefined> {
    const response = await this.client.contact.user.get({
      path: {
        user_id: userId
      },
      params: {
        user_id_type: 'user_id',
        department_id_type: 'department_id'
      }
    })
    assertLarkSuccess(response, 'contact user get')

    return mapUserRecord(response.data?.user)
  }

  async handleUserUpsertEvent(input: unknown): Promise<void> {
    const user = await this.hydrateUser(input)
    if (!user) {
      this.context.logger?.warn?.({ providerId: this.context.providerId, input }, 'Lark user event missing user_id')
      await this.context.syncSink.requestFullSync('lark.user_event_missing_user_id')
      return
    }

    await this.context.syncSink.upsertUser(user)
  }

  async handleUserDeletedEvent(input: unknown): Promise<void> {
    const user = await this.hydrateUser(input)
    if (!user) {
      this.context.logger?.warn?.(
        { providerId: this.context.providerId, input },
        'Lark deleted user event missing user_id'
      )
      await this.context.syncSink.requestFullSync('lark.deleted_user_event_missing_user_id')
      return
    }

    await this.context.syncSink.disableUser(user.externalId, user.metadata)
  }

  async handleDepartmentUpsertEvent(input: unknown): Promise<void> {
    const group = mapDepartmentRecord(input)
    if (!group) {
      await this.context.syncSink.requestFullSync('lark.department_event_missing_department_id')
      return
    }

    await this.context.syncSink.upsertGroup(group)
  }

  async handleDepartmentDeletedEvent(input: unknown): Promise<void> {
    const group = mapDepartmentRecord(input)
    if (!group) {
      await this.context.syncSink.requestFullSync('lark.department_deleted_event_missing_department_id')
      return
    }

    await this.context.syncSink.deleteGroup(group.externalId)
  }

  async handleContactScopeUpdated(): Promise<void> {
    await this.context.syncSink.requestFullSync('contact.scope.updated_v3')
  }
}

class BullXLarkChatAdapter {
  readonly name = 'lark'
  readonly lockScope = 'thread'
  readonly capabilities = {
    inbound: ['message_receive', 'message_recall', 'reaction_add', 'reaction_remove', 'action_event'],
    outbound: ['post_message', 'delete_message', 'add_reaction', 'remove_reaction', 'divider', 'card'],
    history: ['fetch_thread_messages', 'fetch_channel_messages']
  } satisfies BullXExternalGatewayAdapterCapabilities
  readonly userName: string

  private chat!: BullXExternalGatewayAdapterContext
  private connection: SharedLarkConnection | undefined
  private connectionLease: LarkConnectionLease | undefined
  private readonly p2pChats = new Set<string>()

  constructor(
    private readonly context: BullXExternalGatewayAdapterFactoryContext,
    private readonly config: LarkChannelConfig
  ) {
    this.userName = config.userName ?? 'BullX'
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

  async postMessage(threadId: string, message: unknown): Promise<{ id: string; raw: unknown; threadId: string }> {
    const connection = this.requireConnection()
    const { chatId, rootId } = decodeThreadId(threadId)
    const divider = larkDividerPayloadFromMessage(message)
    if (divider) return this.postSystemDivider(threadId, chatId, divider)

    const result = await connection.send(
      chatId,
      { markdown: this.messageToMarkdown(message) },
      rootId ? { replyTo: rootId } : undefined
    )
    return { id: result.messageId, threadId, raw: result }
  }

  async postChannelMessage(
    channelId: string,
    message: unknown
  ): Promise<{ id: string; raw: unknown; threadId: string }> {
    const chatId = decodeLarkChannelId(channelId)
    return this.postMessage(encodeThreadId({ chatId, rootId: '' }), message)
  }

  async deleteMessage(_threadId: string, messageId: string): Promise<void> {
    await this.requireConnection().recallMessage(messageId)
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

  async fetchMessages(): Promise<{ messages: any[] }> {
    return { messages: [] }
  }

  async fetchChannelInfo(channelId: string) {
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

  async startTyping(): Promise<void> {}

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
    divider: Record<string, unknown>
  ): Promise<{ id: string; raw: unknown; threadId: string }> {
    const response = await this.requireConnection().rawClient.im.v1.message.create({
      params: { receive_id_type: 'chat_id' },
      data: {
        receive_id: chatId,
        msg_type: 'system',
        content: JSON.stringify(divider)
      }
    })
    assertLarkSuccess(response, 'system divider message create')
    const messageId =
      optionalString(asRecord(response.data)?.message_id) ??
      optionalString(asRecord(asRecord(response.data)?.message)?.message_id) ??
      optionalString((response as any).message_id)
    if (!messageId) throw new LarkAdapterConfigError('Lark system divider response is missing message_id')

    return { id: messageId, threadId, raw: response }
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

function larkChannelLoggerFromChat(chat: any) {
  const logger = chat?.getLogger?.('lark')
  return {
    debug: (...args: unknown[]) => logger?.debug?.(String(args[0] ?? ''), ...args.slice(1)),
    info: (...args: unknown[]) => logger?.info?.(String(args[0] ?? ''), ...args.slice(1)),
    warn: (...args: unknown[]) => logger?.warn?.(String(args[0] ?? ''), ...args.slice(1)),
    error: (...args: unknown[]) => logger?.error?.(String(args[0] ?? ''), ...args.slice(1)),
    trace: (...args: unknown[]) => logger?.debug?.(String(args[0] ?? ''), ...args.slice(1))
  }
}

function larkLoggerFromRuntimeLogger(logger: BullXIdentityProviderAdapterFactoryContext['logger']): LarkSdkLogger {
  return {
    debug: (...args: unknown[]) => logger?.info?.(larkSdkLogData(args), larkSdkLogMessage(args)),
    info: (...args: unknown[]) => logger?.info?.(larkSdkLogData(args), larkSdkLogMessage(args)),
    warn: (...args: unknown[]) => logger?.warn?.(larkSdkLogData(args), larkSdkLogMessage(args)),
    error: (...args: unknown[]) => logger?.error?.(larkSdkLogData(args), larkSdkLogMessage(args)),
    fatal: (...args: unknown[]) => logger?.error?.(larkSdkLogData(args), larkSdkLogMessage(args)),
    trace: (...args: unknown[]) => logger?.info?.(larkSdkLogData(args), larkSdkLogMessage(args))
  }
}

function larkSdkLogMessage(args: readonly unknown[]): string {
  return String(args[0] ?? 'Lark SDK')
}

function larkSdkLogData(args: readonly unknown[]): Record<string, unknown> {
  return args.length > 1 ? { args: args.slice(1) } : {}
}

interface LarkThreadId {
  chatId: string
  rootId: string
}

export function encodeThreadId(input: LarkThreadId): string {
  return `lark:${encodeURIComponent(input.chatId)}:${encodeURIComponent(input.rootId)}`
}

export function decodeThreadId(threadId: string): LarkThreadId {
  const [prefix, chatId, ...rootParts] = threadId.split(':')
  if (prefix !== 'lark' || !chatId) throw new LarkAdapterConfigError(`Invalid Lark thread id: ${threadId}`)

  return {
    chatId: decodeURIComponent(chatId),
    rootId: decodeURIComponent(rootParts.join(':'))
  }
}

function encodeLarkChannelId(chatId: string): string {
  return `lark:${encodeURIComponent(chatId)}`
}

function decodeLarkChannelId(channelId: string): string {
  if (channelId.startsWith('lark:')) return decodeURIComponent(channelId.slice('lark:'.length))
  return channelId
}

function deriveRootId(input: unknown): string {
  const normalized = asRecord(input)
  return optionalString(normalized?.rootId) ?? optionalString(normalized?.messageId) ?? ''
}

function deriveRootIdFromApiMessage(input: unknown): string | undefined {
  const message = asRecord(input)
  return optionalString(message?.root_id) ?? optionalString(message?.message_id)
}

function dateFromLarkMillis(value: unknown): Date | undefined {
  const numeric = typeof value === 'number' ? value : typeof value === 'string' ? Number(value) : Number.NaN
  if (!Number.isFinite(numeric) || numeric <= 0) return undefined

  return new Date(numeric)
}

function larkDividerPayloadFromMessage(message: unknown): Record<string, unknown> | undefined {
  const record = asRecord(message)
  const candidate = asRecord(record?.raw) ?? record
  if (candidate?.type !== 'divider') return undefined

  return candidate
}

function recalledMessagePayload(raw: unknown): Record<string, any> | undefined {
  const event = asRecord(raw)
  return asRecord(asRecord(event?.event)?.message) ?? asRecord(event?.message) ?? asRecord(event?.event) ?? event
}

function requiredString(value: unknown, message: string): string {
  const parsed = optionalString(value)
  if (!parsed) throw new LarkAdapterConfigError(message)

  return parsed
}

function markdownAstFromText(text: string): Record<string, unknown> {
  return {
    type: 'root',
    children: [
      {
        type: 'paragraph',
        children: [{ type: 'text', value: text }]
      }
    ]
  }
}

function larkResourceAttachmentType(type: lark.ResourceDescriptor['type']): BullXAttachment['type'] | undefined {
  if (type === 'image' || type === 'file' || type === 'audio' || type === 'video') return type
  return undefined
}

function stringifySimpleMarkdownContent(content: unknown): string {
  if (typeof content === 'string') return content

  /*
   * Plugin adapters should not depend on the app-local mdast serializer from
   * External Gateway core. This small renderer intentionally covers the normalized
   * facts this adapter emits itself; richer BullX outbound objects are handled
   * before formatted content reaches this fallback.
   */
  const record = asRecord(content)
  if (!record) return ''

  if (typeof record.value === 'string') return record.value
  const children = Array.isArray(record.children) ? record.children : []
  const separator = record.type === 'root' ? '\n\n' : ''
  return children.map(child => stringifySimpleMarkdownContent(child)).join(separator)
}

export function fromLarkEmojiType(
  contextOrEmojiType: BullXExternalGatewayAdapterFactoryContext | string,
  maybeEmojiType?: string
): unknown {
  const emojiType = maybeEmojiType ?? String(contextOrEmojiType)
  const normalized = larkEmojiMap[emojiType] ?? larkEmojiMap[emojiType.toUpperCase()] ?? emojiType.toLowerCase()
  return {
    name: normalized,
    toJSON: () => `:${normalized}:`,
    toString: () => `:${normalized}:`
  }
}

function toLarkEmojiType(emoji: unknown): string {
  const name = typeof emoji === 'string' ? emoji : (optionalString(asRecord(emoji)?.name) ?? String(emoji))
  return reverseLarkEmojiMap[name] ?? name.toUpperCase()
}

const larkEmojiMap: Record<string, string> = {
  THUMBSUP: 'thumbs_up',
  THUMBSDOWN: 'thumbs_down',
  HEART: 'heart',
  SMILE: 'smile',
  LAUGH: 'laugh',
  CLAP: 'clap',
  FIRE: 'fire',
  EYES: 'eyes',
  OK: 'ok_hand',
  CHECK: 'check',
  CROSS: 'x',
  QUESTION: 'question',
  EXCLAMATION: 'exclamation'
}

const reverseLarkEmojiMap: Record<string, string> = Object.fromEntries(
  Object.entries(larkEmojiMap).map(([larkName, normalized]) => [normalized, larkName])
)

async function recordLarkPlatformSubject(
  context: BullXExternalGatewayAdapterFactoryContext,
  config: LarkChannelConfig,
  externalId: string,
  input: { metadata: { [key: string]: BullXPluginJsonValue }; profile?: BullXPlatformSubjectProfile }
): Promise<void> {
  /*
   * This records a Lark `user_id` fact observed through a chat channel. It does
   * not call, require, or configure any identity-provider adapter; External
   * Gateway channels and login identity providers are independent plugin
   * capabilities.
   */
  await context.externalIdentities?.upsertPlatformSubject({
    provider: config.platformSubjectNamespace,
    externalId,
    displayName: input.profile?.displayName,
    avatarUrl: input.profile?.avatarUrl,
    email: input.profile?.email,
    phone: input.profile?.phone,
    verifiedAt: new Date(),
    metadata: input.metadata
  })
}

function platformUserIdFromNormalizedMessage(input: unknown): string | undefined {
  const normalized = asRecord(input)
  const rawActor = actorIdFromNormalizedMessage(input)
  const rawUserId = optionalString(rawActor?.user_id)
  if (rawUserId) return rawUserId

  /*
   * Future LarkChannel versions may normalize `senderId` to `user_id` directly.
   * Trust it only when raw `open_id` is absent or different; otherwise the event
   * is the known open_id shape and must fail closed instead of recording the
   * wrong identifier as a BullX platform subject.
   */
  const normalizedSenderId = optionalString(normalized?.senderId)
  const rawOpenId = optionalString(rawActor?.open_id)
  return normalizedSenderId && normalizedSenderId !== rawOpenId ? normalizedSenderId : undefined
}

function actorIdFromNormalizedMessage(input: unknown): Record<string, any> | undefined {
  const normalized = asRecord(input)
  const raw = asRecord(normalized?.raw)
  const sender = asRecord(raw?.sender)
  return asRecord(sender?.sender_id)
}

function profileFromMessage(
  message: { author: { fullName?: string | null; userName?: string | null } },
  input: unknown
): BullXPlatformSubjectProfile {
  const normalized = asRecord(input)
  const sender = asRecord(asRecord(normalized?.raw)?.sender)
  const avatar = asRecord(sender?.avatar)
  return {
    displayName:
      optionalString(message.author.fullName) ??
      optionalString(message.author.userName) ??
      optionalString(sender?.name),
    avatarUrl:
      optionalString(sender?.avatar_url) ??
      optionalString(avatar?.avatar_240) ??
      optionalString(avatar?.avatar_72) ??
      optionalString(avatar?.avatar_origin)
  }
}

function larkActorMetadata(
  config: LarkChannelConfig,
  input: Record<string, any> | undefined,
  source: 'message' | 'card_action' | 'reaction'
): { [key: string]: BullXPluginJsonValue } {
  return compactJsonObject({
    app_id: config.appId,
    source,
    open_id: optionalString(input?.open_id) ?? optionalString(input?.openId),
    union_id: optionalString(input?.union_id) ?? optionalString(input?.unionId),
    tenant_key: optionalString(input?.tenant_key) ?? optionalString(input?.tenantKey)
  })
}

function logLarkChatWarning(adapter: any, data: unknown, message: string): void {
  const logger = adapter._getLogger?.()
  try {
    logger?.warn?.(message, data)
  } catch {
    // Logging must never make event parsing fail differently from the missing
    // user_id condition that callers need to see.
  }
}

function mapDepartmentRecord(input: unknown): BullXIdentityProviderGroupRecord | undefined {
  const department = asRecord(input)
  const departmentId = optionalString(department?.department_id)
  if (!departmentId) return undefined

  const parentDepartmentId = optionalString(department?.parent_department_id)
  return {
    externalId: departmentId,
    name: optionalString(department?.name) ?? departmentId,
    parentExternalId: parentDepartmentId && parentDepartmentId !== '0' ? parentDepartmentId : null,
    status: asRecord(department?.status)?.is_deleted === true ? 'disabled' : 'active',
    description: optionalString(department?.name) ?? departmentId,
    metadata: compactJsonObject({
      open_department_id: optionalString(department?.open_department_id),
      leader_user_id: optionalString(department?.leader_user_id),
      chat_id: optionalString(department?.chat_id)
    })
  }
}

function mapUserRecord(input: unknown): BullXIdentityProviderUserRecord | undefined {
  const user = asRecord(input)
  const userId = optionalString(user?.user_id)
  if (!userId) return undefined

  const status = asRecord(user?.status)
  const disabled =
    status?.is_frozen === true ||
    status?.is_resigned === true ||
    status?.is_exited === true ||
    status?.is_unjoin === true ||
    status?.is_activated === false ||
    user?.is_frozen === true
  const avatar = asRecord(user?.avatar)

  return {
    externalId: userId,
    status: disabled ? 'disabled' : 'active',
    displayName:
      optionalString(user?.name) ?? optionalString(user?.en_name) ?? optionalString(user?.nickname) ?? userId,
    avatarUrl:
      optionalString(user?.avatar_url) ??
      optionalString(avatar?.avatar_240) ??
      optionalString(avatar?.avatar_72) ??
      optionalString(avatar?.avatar_origin),
    email: optionalString(user?.enterprise_email) ?? optionalString(user?.email),
    phone: normalizePhone(optionalString(user?.mobile)),
    departmentExternalIds: stringArray(user?.department_ids),
    metadata: compactJsonObject({
      open_id: optionalString(user?.open_id),
      union_id: optionalString(user?.union_id),
      tenant_key: optionalString(user?.tenant_key),
      employee_no: optionalString(user?.employee_no),
      job_title: optionalString(user?.job_title)
    })
  }
}

function mergeUserRecord(
  existing: BullXIdentityProviderUserRecord | undefined,
  next: BullXIdentityProviderUserRecord
): BullXIdentityProviderUserRecord {
  if (!existing) return next

  return {
    ...existing,
    ...next,
    displayName: next.displayName ?? existing.displayName,
    avatarUrl: next.avatarUrl ?? existing.avatarUrl,
    email: next.email ?? existing.email,
    phone: next.phone ?? existing.phone,
    departmentExternalIds: [
      ...new Set([...(existing.departmentExternalIds ?? []), ...(next.departmentExternalIds ?? [])])
    ],
    metadata: {
      ...existing.metadata,
      ...next.metadata
    }
  }
}

function sdkDomain(domain: LarkIdentityProviderConfig['domain']): lark.Domain {
  return domain === 'lark' ? lark.Domain.Lark : lark.Domain.Feishu
}

function accountsBaseUrl(domain: LarkIdentityProviderConfig['domain']): string {
  return domain === 'lark' ? 'https://accounts.larksuite.com' : 'https://accounts.feishu.cn'
}

function assertLarkSuccess(response: { code?: number; msg?: string }, label: string): void {
  if (response.code !== undefined && response.code !== 0) {
    throw new LarkAdapterConfigError(`Lark ${label} failed: ${response.msg ?? response.code}`)
  }
}

function requireNonEmptyContactPage<T>(items: readonly T[] | undefined, label: string): readonly T[] {
  if (!items || items.length === 0) {
    throw new LarkContactSyncUnavailableError(`Lark ${label} returned an empty page`)
  }

  return items
}

function isIgnorableContactSyncError(error: unknown): boolean {
  if (error instanceof LarkContactSyncUnavailableError) return true

  const summary = larkErrorSummary(error)
  const text = [summary.message, summary.providerMessage].filter(Boolean).join(' ').toLowerCase()
  if (text.includes('permission') || text.includes('forbidden') || text.includes('scope')) return true

  return summary.providerCode === 99992402 && text.includes('field validation failed')
}

function larkErrorSummary(error: unknown): {
  name?: string
  message?: string
  status?: number
  providerCode?: number
  providerMessage?: string
} {
  const response = asRecord(asRecord(error)?.response)
  const data = asRecord(response?.data)
  return {
    name: error instanceof Error ? error.name : optionalString(asRecord(error)?.name),
    message: error instanceof Error ? error.message : optionalString(asRecord(error)?.message),
    status: typeof response?.status === 'number' ? response.status : undefined,
    providerCode: typeof data?.code === 'number' ? data.code : undefined,
    providerMessage: optionalString(data?.msg) ?? optionalString(data?.message)
  }
}

function normalizePhone(value: string | undefined): string | null {
  if (!value) return null
  const trimmed = value.trim()
  return /^\+[1-9]\d{1,14}$/.test(trimmed) ? trimmed : null
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string' && item.length > 0) : []
}

function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : undefined
}

function asRecord(value: unknown): Record<string, any> | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, any>)
    : undefined
}

function compactJsonObject(input: Record<string, BullXPluginJsonValue | undefined>): {
  [key: string]: BullXPluginJsonValue
} {
  return Object.fromEntries(
    Object.entries(input).filter((entry): entry is [string, BullXPluginJsonValue] => entry[1] !== undefined)
  )
}

function compactStringRecord(input: Record<string, string | undefined>): Record<string, string> {
  return Object.fromEntries(Object.entries(input).filter((entry): entry is [string, string] => entry[1] !== undefined))
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, character => htmlEntities[character] ?? character)
}

function escapeHtmlAttribute(value: string): string {
  return escapeHtml(value)
}

const htmlEntities: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;'
}

async function larkQrCodeHtml(url: string): Promise<string> {
  /*
   * Keep this HTML small and self-contained. Console renders trusted plugin HTML
   * for interactive setup, but the registration URL is still escaped before it is
   * repeated as a fallback link below the QR code.
   */
  const svg = await QRCode.toString(url, {
    type: 'svg',
    width: 220,
    margin: 1,
    errorCorrectionLevel: 'M'
  })

  return `<div class="grid gap-3"><div class="inline-flex rounded-md border border-border bg-white p-3 text-black">${svg}</div><p>Use the Lark / Feishu mobile app to scan this QR code.</p>${larkRegistrationLinkHtml(url)}</div>`
}

function larkRegistrationLinkHtml(url: string): string {
  return `<a href="${escapeHtmlAttribute(url)}" target="_blank" rel="noreferrer">${escapeHtml(url)}</a>`
}
