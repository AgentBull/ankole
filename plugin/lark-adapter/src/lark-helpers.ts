import * as lark from '@larksuiteoapi/node-sdk'
import type {
  BullXExternalGatewayAdapterFactoryContext,
  BullXExternalGatewayOutboundOptions,
  BullXIdentityProviderAdapterFactoryContext,
  BullXIdentityProviderGroupRecord,
  BullXIdentityProviderUserRecord,
  BullXPlatformSubjectProfile,
  BullXPluginJsonValue
} from '@agentbull/bullx-sdk/plugins'
import {
  LarkAdapterConfigError,
  LarkContactSyncUnavailableError,
  type LarkChannelConfig,
  type LarkIdentityProviderConfig
} from './config'

export type BullXAttachment = {
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

export type LarkSdkLogger = {
  debug?: (...args: unknown[]) => void
  error?: (...args: unknown[]) => void
  fatal?: (...args: unknown[]) => void
  info?: (...args: unknown[]) => void
  trace?: (...args: unknown[]) => void
  warn?: (...args: unknown[]) => void
}

export function larkChannelLoggerFromChat(chat: any) {
  const logger = chat?.getLogger?.('lark')
  return {
    debug: (...args: unknown[]) => logger?.debug?.(String(args[0] ?? ''), ...args.slice(1)),
    info: (...args: unknown[]) => logger?.info?.(String(args[0] ?? ''), ...args.slice(1)),
    warn: (...args: unknown[]) => logger?.warn?.(String(args[0] ?? ''), ...args.slice(1)),
    error: (...args: unknown[]) => logger?.error?.(String(args[0] ?? ''), ...args.slice(1)),
    trace: (...args: unknown[]) => logger?.debug?.(String(args[0] ?? ''), ...args.slice(1))
  }
}

export function larkLoggerFromRuntimeLogger(
  logger: BullXIdentityProviderAdapterFactoryContext['logger']
): LarkSdkLogger {
  return {
    debug: (...args: unknown[]) => logger?.info?.(larkSdkLogData(args), larkSdkLogMessage(args)),
    info: (...args: unknown[]) => logger?.info?.(larkSdkLogData(args), larkSdkLogMessage(args)),
    warn: (...args: unknown[]) => logger?.warn?.(larkSdkLogData(args), larkSdkLogMessage(args)),
    error: (...args: unknown[]) => logger?.error?.(larkSdkLogData(args), larkSdkLogMessage(args)),
    fatal: (...args: unknown[]) => logger?.error?.(larkSdkLogData(args), larkSdkLogMessage(args)),
    trace: (...args: unknown[]) => logger?.info?.(larkSdkLogData(args), larkSdkLogMessage(args))
  }
}

export function larkSdkLogMessage(args: readonly unknown[]): string {
  return String(args[0] ?? 'Lark SDK')
}

export function larkSdkLogData(args: readonly unknown[]): Record<string, unknown> {
  return args.length > 1 ? { args: args.slice(1) } : {}
}

export interface LarkThreadId {
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

export function larkUuidFromOptions(options: BullXExternalGatewayOutboundOptions | undefined): string | undefined {
  return optionalString(options?.idempotencyKey) ?? optionalString(options?.operationKey)
}

export function larkTextContent(text: string): string {
  return JSON.stringify({ text })
}

export function messageIdFromLarkResponse(response: unknown, fallback?: string): string {
  const data = asRecord(asRecord(response)?.data)
  const messageId =
    optionalString(data?.message_id) ??
    optionalString(asRecord(data?.message)?.message_id) ??
    optionalString(asRecord(response)?.message_id) ??
    fallback
  if (!messageId) throw new LarkAdapterConfigError('Lark message response is missing message_id')
  return messageId
}

export function firstLarkMessageItem(response: unknown): Record<string, any> | undefined {
  const data = asRecord(asRecord(response)?.data)
  const first = Array.isArray(data?.items) ? asRecord(data.items[0]) : undefined
  return first ?? asRecord(data?.message)
}

export function threadIdFromLarkApiMessage(item: Record<string, any>, fallback: string): string {
  const chatId = optionalString(item.chat_id)
  if (!chatId) return fallback
  return encodeThreadId({ chatId, rootId: deriveRootIdFromApiMessage(item) ?? optionalString(item.message_id) ?? '' })
}

export function encodeLarkChannelId(chatId: string): string {
  return `lark:${encodeURIComponent(chatId)}`
}

export function decodeLarkChannelId(channelId: string): string {
  if (channelId.startsWith('lark:')) return decodeURIComponent(channelId.slice('lark:'.length))
  return channelId
}

export function deriveRootId(input: unknown): string {
  const normalized = asRecord(input)
  return optionalString(normalized?.rootId) ?? optionalString(normalized?.messageId) ?? ''
}

export function deriveRootIdFromApiMessage(input: unknown): string | undefined {
  const message = asRecord(input)
  return optionalString(message?.root_id) ?? optionalString(message?.message_id)
}

export function dateFromLarkMillis(value: unknown): Date | undefined {
  const numeric = typeof value === 'number' ? value : typeof value === 'string' ? Number(value) : Number.NaN
  if (!Number.isFinite(numeric) || numeric <= 0) return undefined

  return new Date(numeric)
}

export function larkDividerPayloadFromMessage(message: unknown): Record<string, unknown> | undefined {
  const record = asRecord(message)
  const candidate = asRecord(record?.raw) ?? record
  // Only the 'divider' outbound operation marks its postable with type:'divider'
  // (postableFromFinalPayload). control_notice card payloads keep kind only and
  // fall through to the interactive-card path in postMessage.
  if (candidate?.type !== 'divider') return undefined

  const text =
    optionalString(candidate.text) ??
    optionalString(candidate.fallbackText) ??
    optionalString(asRecord(asRecord(candidate.params)?.divider_text)?.text) ??
    ''
  return larkDividerPayload(text)
}

/** Feishu system-divider message content (content_mapper.ex render_control_notice_system parity). */
export function larkDividerPayload(text: string): Record<string, unknown> {
  return {
    type: 'divider',
    params: { divider_text: { text } },
    options: { need_rollup: true }
  }
}

/** Feishu compact notice card (content_mapper.ex compact_notice_card parity): grey notation text, optional hr. */
export function larkCompactNoticeCard(text: string, options?: { divider?: boolean }): Record<string, unknown> {
  const elements: Record<string, unknown>[] = []
  if (options?.divider) elements.push({ tag: 'hr', margin: '0px 0px 0px 0px' })
  elements.push({
    tag: 'div',
    text: { tag: 'plain_text', content: text, text_size: 'notation', text_align: 'left', text_color: 'grey' },
    margin: '0px 0px 0px 0px'
  })
  return {
    schema: '2.0',
    config: { update_multi: true },
    body: {
      direction: 'vertical',
      horizontal_spacing: '8px',
      vertical_spacing: '8px',
      horizontal_align: 'left',
      vertical_align: 'top',
      padding: '12px 12px 12px 12px',
      elements
    }
  }
}

export function recalledMessagePayload(raw: unknown): Record<string, any> | undefined {
  const event = asRecord(raw)
  return asRecord(asRecord(event?.event)?.message) ?? asRecord(event?.message) ?? asRecord(event?.event) ?? event
}

export function requiredString(value: unknown, message: string): string {
  const parsed = optionalString(value)
  if (!parsed) throw new LarkAdapterConfigError(message)

  return parsed
}

export function markdownAstFromText(text: string): Record<string, unknown> {
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

export function larkResourceAttachmentType(type: lark.ResourceDescriptor['type']): BullXAttachment['type'] | undefined {
  if (type === 'image' || type === 'file' || type === 'audio' || type === 'video') return type
  return undefined
}

export function stringifySimpleMarkdownContent(content: unknown): string {
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

export function toLarkEmojiType(emoji: unknown): string {
  const name = typeof emoji === 'string' ? emoji : (optionalString(asRecord(emoji)?.name) ?? String(emoji))
  return reverseLarkEmojiMap[name] ?? name.toUpperCase()
}

export const larkEmojiMap: Record<string, string> = {
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

export const reverseLarkEmojiMap: Record<string, string> = Object.fromEntries(
  Object.entries(larkEmojiMap).map(([larkName, normalized]) => [normalized, larkName])
)

export async function recordLarkPlatformSubject(
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

export function platformUserIdFromNormalizedMessage(input: unknown): string | undefined {
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

export function actorIdFromNormalizedMessage(input: unknown): Record<string, any> | undefined {
  const normalized = asRecord(input)
  const raw = asRecord(normalized?.raw)
  const sender = asRecord(raw?.sender)
  return asRecord(sender?.sender_id)
}

export function profileFromMessage(
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

export function larkActorMetadata(
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

export function logLarkChatWarning(adapter: any, data: unknown, message: string): void {
  const logger = adapter._getLogger?.()
  try {
    logger?.warn?.(message, data)
  } catch {
    // Logging must never make event parsing fail differently from the missing
    // user_id condition that callers need to see.
  }
}

export function mapDepartmentRecord(input: unknown): BullXIdentityProviderGroupRecord | undefined {
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

export function mapUserRecord(input: unknown): BullXIdentityProviderUserRecord | undefined {
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

export function mergeUserRecord(
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

export function sdkDomain(domain: LarkIdentityProviderConfig['domain']): lark.Domain {
  return domain === 'lark' ? lark.Domain.Lark : lark.Domain.Feishu
}

export function accountsBaseUrl(domain: LarkIdentityProviderConfig['domain']): string {
  return domain === 'lark' ? 'https://accounts.larksuite.com' : 'https://accounts.feishu.cn'
}

export function assertLarkSuccess(response: { code?: number; msg?: string }, label: string): void {
  if (response.code !== undefined && response.code !== 0) {
    throw new LarkAdapterConfigError(`Lark ${label} failed: ${response.msg ?? response.code}`)
  }
}

export function requireNonEmptyContactPage<T>(items: readonly T[] | undefined, label: string): readonly T[] {
  if (!items || items.length === 0) {
    throw new LarkContactSyncUnavailableError(`Lark ${label} returned an empty page`)
  }

  return items
}

export function isIgnorableContactSyncError(error: unknown): boolean {
  if (error instanceof LarkContactSyncUnavailableError) return true

  const summary = larkErrorSummary(error)
  const text = [summary.message, summary.providerMessage].filter(Boolean).join(' ').toLowerCase()
  if (text.includes('permission') || text.includes('forbidden') || text.includes('scope')) return true

  return summary.providerCode === 99992402 && text.includes('field validation failed')
}

export function larkErrorSummary(error: unknown): {
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

export function normalizePhone(value: string | undefined): string | null {
  if (!value) return null
  const trimmed = value.trim()
  return /^\+[1-9]\d{1,14}$/.test(trimmed) ? trimmed : null
}

export function stringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string' && item.length > 0) : []
}

export function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : undefined
}

export function asRecord(value: unknown): Record<string, any> | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, any>)
    : undefined
}

export function compactJsonObject(input: Record<string, BullXPluginJsonValue | undefined>): {
  [key: string]: BullXPluginJsonValue
} {
  return Object.fromEntries(
    Object.entries(input).filter((entry): entry is [string, BullXPluginJsonValue] => entry[1] !== undefined)
  )
}

export function compactStringRecord(input: Record<string, string | undefined>): Record<string, string> {
  return Object.fromEntries(Object.entries(input).filter((entry): entry is [string, string] => entry[1] !== undefined))
}
