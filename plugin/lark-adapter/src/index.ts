import { createLarkAdapter, decodeThreadId, encodeThreadId, fromLarkEmojiType } from '@larksuite/vercel-chat-adapter'
import * as lark from '@larksuiteoapi/node-sdk'
import type {
  BullXAppConfigPatternDefinition,
  BullXChatGatewayAdapterFactoryContext,
  BullXPlatformSubjectProfile,
  BullXIdentityProviderAdapter,
  BullXIdentityProviderAdapterFactoryContext,
  BullXIdentityProviderFullSyncSnapshot,
  BullXIdentityProviderGroupRecord,
  BullXIdentityProviderUserRecord,
  BullXPlugin,
  BullXPluginJsonValue
} from '@agentbull/bullx-sdk/plugins'
import {
  bullxExternalIdentityProviderIdPattern as providerIdPattern,
  bullxExternalIdentityProviderIdPatternSource as providerIdPatternSource
} from '@agentbull/bullx-sdk/plugins'
import { z } from 'zod'

const larkChannelConfigSchema = z
  .object({
    appId: z.string().min(1),
    appSecret: z.string().min(1),
    /**
     * `principal_external_identities.provider` namespace for this Lark tenant.
     *
     * This is intentionally not named `identityProviderId`: the chat adapter is
     * not bound to an active identity-provider adapter. It merely emits the same
     * platform subject fact that a separate Lark directory/OIDC adapter may emit.
     */
    platformProviderId: z.string().regex(providerIdPattern),
    userName: z.string().min(1).optional()
  })
  .strict()

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
        pageSize: z.number().int().min(1).max(100).default(100)
      })
      .default({ users: true, departments: true, websocket: true, pageSize: 100 }),
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

export function createBullXLarkAdapter(context: BullXChatGatewayAdapterFactoryContext) {
  const parsed = larkChannelConfigSchema.safeParse(context.config)
  if (!parsed.success) {
    throw new LarkAdapterConfigError(`Invalid Lark adapter config for channel ${context.channel.name}`, {
      cause: parsed.error
    })
  }

  const adapter = createLarkAdapter({
    appId: parsed.data.appId,
    appSecret: parsed.data.appSecret,
    userName: parsed.data.userName
  })

  return patchLarkChatAdapterForUserId(adapter, context, parsed.data)
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

export const larkIdentityProviderConfigPattern = {
  id: 'identity_providers.lark',
  keyPattern: new RegExp(`^identity_providers\\.lark\\.${providerIdPatternSource}$`),
  encrypted: true,
  schema: larkIdentityProviderConfigSchema,
  description: 'Encrypted Lark identity provider configuration'
} satisfies BullXAppConfigPatternDefinition

export const larkAdapterPlugin = {
  metadata: {
    id: 'lark-adapter',
    apiVersion: 1,
    displayName: 'Lark / Feishu Chat Adapter',
    description: 'First-party Chat SDK and identity provider plugin for Lark and Feishu.'
  },
  appConfigPatterns: [larkIdentityProviderConfigPattern],
  chatGatewayAdapters: [
    {
      id: 'lark',
      create: createBullXLarkAdapter
    }
  ],
  identityProviderAdapters: [
    {
      id: 'lark',
      create: createBullXLarkIdentityProvider
    }
  ]
} satisfies BullXPlugin

export default larkAdapterPlugin

class BullXLarkIdentityProviderAdapter implements BullXIdentityProviderAdapter {
  private readonly client: lark.Client
  private wsClient: lark.WSClient | undefined

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

  async fullSync(): Promise<BullXIdentityProviderFullSyncSnapshot> {
    const groups = this.config.sync.departments ? await this.listDepartments() : []
    const users = this.config.sync.users ? await this.listUsers(groups) : []

    return { groups, users }
  }

  /**
   * Opens Lark's long-connection event stream for contact changes.
   *
   * Event payloads are treated as hints: if an event lacks enough identity data
   * to produce a provider-scoped `user_id` or department id, the adapter asks
   * the host to run a full reconciliation instead of inventing an open_id-based
   * binding.
   */
  async start(): Promise<void> {
    if (!this.config.sync.websocket) return

    const dispatcher = new lark.EventDispatcher({
      verificationToken: this.config.event.verificationToken,
      encryptKey: this.config.event.encryptKey
    }).register({
      'contact.user.created_v3': event => this.handleUserUpsertEvent(event.object),
      'contact.user.updated_v3': event => this.handleUserUpsertEvent(event.object),
      'contact.user.deleted_v3': event => this.handleUserDeletedEvent(event.object),
      'contact.department.created_v3': event => this.handleDepartmentUpsertEvent(event.object),
      'contact.department.updated_v3': event => this.handleDepartmentUpsertEvent(event.object),
      'contact.department.deleted_v3': event => this.handleDepartmentDeletedEvent(event.object),
      'contact.scope.updated_v3': () => this.context.syncSink.requestFullSync('contact.scope.updated_v3')
    })

    this.wsClient = new lark.WSClient({
      appId: this.config.appId,
      appSecret: this.config.appSecret,
      domain: sdkDomain(this.config.domain),
      autoReconnect: true,
      onError: error =>
        this.context.logger?.warn?.({ error, providerId: this.context.providerId }, 'Lark identity WS error'),
      onReconnecting: () =>
        this.context.logger?.warn?.({ providerId: this.context.providerId }, 'Lark identity WS reconnecting'),
      onReconnected: () =>
        this.context.logger?.info?.({ providerId: this.context.providerId }, 'Lark identity WS reconnected')
    })

    await this.wsClient.start({ eventDispatcher: dispatcher })
  }

  async stop(): Promise<void> {
    this.wsClient?.close({ force: true })
    this.wsClient = undefined
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
      for (const department of page?.items ?? []) {
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
        for (const rawUser of page?.items ?? []) {
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

  private async handleUserUpsertEvent(input: unknown): Promise<void> {
    const user = await this.hydrateUser(input)
    if (!user) {
      this.context.logger?.warn?.({ providerId: this.context.providerId, input }, 'Lark user event missing user_id')
      await this.context.syncSink.requestFullSync('lark.user_event_missing_user_id')
      return
    }

    await this.context.syncSink.upsertUser(user)
  }

  private async handleUserDeletedEvent(input: unknown): Promise<void> {
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

  private async handleDepartmentUpsertEvent(input: unknown): Promise<void> {
    const group = mapDepartmentRecord(input)
    if (!group) {
      await this.context.syncSink.requestFullSync('lark.department_event_missing_department_id')
      return
    }

    await this.context.syncSink.upsertGroup(group)
  }

  private async handleDepartmentDeletedEvent(input: unknown): Promise<void> {
    const group = mapDepartmentRecord(input)
    if (!group) {
      await this.context.syncSink.requestFullSync('lark.department_deleted_event_missing_department_id')
      return
    }

    await this.context.syncSink.deleteGroup(group.externalId)
  }
}

/**
 * Keeps the upstream Lark chat adapter as the transport/formatting layer while
 * overriding the parts where BullX has a stricter identity contract.
 *
 * `@larksuite/vercel-chat-adapter` currently normalizes incoming users around
 * app-scoped `open_id`. BullX uses Lark `user_id` for both identity-provider
 * sync and chat-observed platform subject facts, so this wrapper fails closed
 * when a live message/action/reaction cannot provide `user_id`.
 */
function patchLarkChatAdapterForUserId<TAdapter extends ReturnType<typeof createLarkAdapter>>(
  adapter: TAdapter,
  context: BullXChatGatewayAdapterFactoryContext,
  config: LarkChannelConfig
): TAdapter {
  const mutable = adapter as any
  const originalParseMessage = adapter.parseMessage.bind(adapter)
  mutable.parseMessage = async (normalizedMessage: unknown) => {
    const message = originalParseMessage(normalizedMessage as never)
    const platformUserId = platformUserIdFromNormalizedMessage(normalizedMessage)
    if (!platformUserId) {
      logLarkChatWarning(mutable, { normalizedMessage }, 'Lark message event missing sender user_id')
      throw new LarkAdapterConfigError('Lark message event is missing sender user_id')
    }

    const botIdentity = mutable._getChannel?.()?.botIdentity
    const isMe = platformUserId === botIdentity?.userId || platformUserId === botIdentity?.openId
    message.author = {
      ...message.author,
      userId: platformUserId,
      userName: message.author.userName === message.author.userId ? platformUserId : message.author.userName,
      fullName: message.author.fullName === message.author.userId ? platformUserId : message.author.fullName,
      isBot: isMe ? true : message.author.isBot,
      isMe
    }
    await recordLarkPlatformSubject(context, config, platformUserId, {
      metadata: larkActorMetadata(config, actorIdFromNormalizedMessage(normalizedMessage), 'message'),
      profile: profileFromMessage(message, normalizedMessage)
    })
    return message
  }

  // DM placeholders intentionally use `user_id` as the chatId component. The
  // upstream adapter uses the same placeholder shape, but historically expected
  // `open_id`; BullX callers pass provider-scoped user ids.
  mutable.openDM = async (userId: string) => encodeThreadId({ chatId: userId, rootId: '' })
  const originalIsDM = adapter.isDM.bind(adapter)
  mutable.isDM = (threadId: string) => {
    const decoded = decodeThreadId(threadId)
    if (decoded.rootId === '' && !decoded.chatId.startsWith('oc_')) return true
    return originalIsDM(threadId)
  }

  mutable.handleCardAction = async (event: any) => {
    if (!mutable.chat) return

    const rootId = await mutable.fetchRootIdFor(event.messageId)
    const threadId = encodeThreadId({ chatId: event.chatId, rootId })
    const actionId = event.action.name ?? event.action.tag
    const value = typeof event.action.value === 'string' ? event.action.value : JSON.stringify(event.action.value)
    const userId = optionalString(event.operator?.userId)
    if (!userId) {
      logLarkChatWarning(mutable, { event }, 'Lark card action event missing operator user_id')
      return
    }
    await recordLarkPlatformSubject(context, config, userId, {
      metadata: larkActorMetadata(config, event.operator, 'card_action'),
      profile: { displayName: optionalString(event.operator.name) }
    })

    await mutable.chat.processAction(
      {
        adapter,
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

  mutable.handleReaction = async (event: any) => {
    if (!mutable.chat) return

    const { chatId, rootId } = await mutable.fetchChatAndRootFor(event.messageId)
    const threadId = chatId ? encodeThreadId({ chatId, rootId }) : ''
    const userId = optionalString(event.operator?.userId)
    if (!userId) {
      logLarkChatWarning(mutable, { event }, 'Lark reaction event missing operator user_id')
      return
    }
    await recordLarkPlatformSubject(context, config, userId, {
      metadata: larkActorMetadata(config, event.operator, 'reaction')
    })

    mutable.chat.processReaction({
      adapter,
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

  return adapter
}

async function recordLarkPlatformSubject(
  context: BullXChatGatewayAdapterFactoryContext,
  config: LarkChannelConfig,
  externalId: string,
  input: { metadata: { [key: string]: BullXPluginJsonValue }; profile?: BullXPlatformSubjectProfile }
): Promise<void> {
  await context.externalIdentities?.upsertPlatformSubject({
    provider: config.platformProviderId,
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
  return optionalString(actorIdFromNormalizedMessage(input)?.user_id)
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
