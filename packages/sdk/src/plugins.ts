/**
 * Canonical syntax for `principal_external_identities.provider`.
 *
 * This value names an external platform namespace, usually one enterprise tenant
 * such as `lark-main`. It is not a plugin id, not a bot app id, and not a
 * reference to any running adapter. Chat, login, and directory integrations may
 * independently use the same namespace when the upstream platform exposes one
 * stable subject id, but no integration owns the others.
 */
export const bullxExternalIdentityNamespaceIdPatternSource = '[a-z][a-z0-9_-]*'
export const bullxExternalIdentityNamespaceIdPattern = new RegExp(`^${bullxExternalIdentityNamespaceIdPatternSource}$`)

export type BullXPluginJsonValue =
  | string
  | number
  | boolean
  | null
  | { [key: string]: BullXPluginJsonValue }
  | BullXPluginJsonValue[]

export interface BullXPluginJsonSchema<TValue extends BullXPluginJsonValue = BullXPluginJsonValue> {
  parse(value: unknown): TValue
}

export interface BullXAppConfigDefinition<TValue extends BullXPluginJsonValue = BullXPluginJsonValue> {
  key: string
  schema: BullXPluginJsonSchema<TValue>
  encrypted: boolean
  defaultValue?: TValue
  description?: string
}

export interface BullXAppConfigPatternDefinition<TValue extends BullXPluginJsonValue = BullXPluginJsonValue> {
  id: string
  keyPattern: RegExp
  schema: BullXPluginJsonSchema<TValue>
  encrypted: boolean
  defaultValue?: TValue
  description?: string
}

export const bullxExternalGatewayGroupMessageModes = ['addressed_only', 'observe_all', 'may_intervene'] as const
export type BullXExternalGatewayGroupMessageMode = (typeof bullxExternalGatewayGroupMessageModes)[number]

export function isBullXExternalGatewayGroupMessageMode(value: unknown): value is BullXExternalGatewayGroupMessageMode {
  return typeof value === 'string' && (bullxExternalGatewayGroupMessageModes as readonly string[]).includes(value)
}

export interface BullXAgentExternalBinding {
  adapter: string
  enabled: boolean
  groupMessageMode?: BullXExternalGatewayGroupMessageMode
  name: string
}

export interface BullXPlatformSubjectProfile {
  displayName?: string | null
  avatarUrl?: string | null
  email?: string | null
  phone?: string | null
}

export interface BullXPlatformSubjectInput extends BullXPlatformSubjectProfile {
  /**
   * External platform namespace stored in `principal_external_identities.provider`.
   *
   * For Lark self-built apps this should identify the tenant-level namespace that
   * uses Lark `user_id`, not an app-scoped `open_id` namespace.
   */
  provider: string
  /**
   * Subject id inside the provider namespace. For Lark this must be `user_id`.
   */
  externalId: string
  verifiedAt?: Date | null
  metadata?: { [key: string]: BullXPluginJsonValue }
}

export interface BullXPlatformSubjectResult {
  principalUid: string
  externalIdentityId: string
}

/**
 * Host-owned Principal bridge exposed to chat adapter plugins.
 *
 * A chat adapter can record a platform-subject fact from an inbound event. If
 * another integration later emits the same `provider + externalId`, both facts
 * land on the same `principal_external_identities` row without the integrations
 * depending on each other.
 */
export interface BullXExternalGatewayExternalIdentitySink {
  upsertPlatformSubject(input: BullXPlatformSubjectInput): Promise<BullXPlatformSubjectResult>
}

export type BullXExternalGatewayJsonObject = { [key: string]: BullXPluginJsonValue }

export const bullxInteractiveOutputVersion = 'bullx.interactive_output.v1' as const
export const bullxInteractiveOutputActionValueVersion = 'bullx.interactive_output.action.v1' as const

export type BullXInteractiveOutputFormat = 'plain' | 'markdown'
export type BullXInteractiveOutputSeverity = 'neutral' | 'info' | 'success' | 'warning' | 'danger'
export type BullXInteractiveOutputStateStatus = 'open' | 'answered' | 'expired' | 'cancelled' | 'superseded'
export type BullXInteractiveOutputChoiceSelection = 'single' | 'multi'
export type BullXInteractiveOutputChoiceStyle = 'primary' | 'danger' | 'default'
export type BullXInteractiveOutputResponderScope = 'any_room_member' | 'originator' | 'specified_users'

export interface BullXInteractiveOutputFact {
  label: string
  value: string
}

export interface BullXInteractiveOutputContent {
  title?: string
  body: string
  format?: BullXInteractiveOutputFormat
  facts?: readonly BullXInteractiveOutputFact[]
  severity?: BullXInteractiveOutputSeverity
}

export interface BullXInteractiveOutputChoiceOption {
  id: string
  label: string
  value: string
  description?: string
  style?: BullXInteractiveOutputChoiceStyle
}

export interface BullXInteractiveOutputCustomText {
  enabled: boolean
  hint?: string
}

export interface BullXInteractiveOutputResponsePolicy {
  firstResponseWins?: boolean
  responderScope?: BullXInteractiveOutputResponderScope
}

export interface BullXInteractiveOutputChoiceResponse {
  type: 'choice'
  interactionId: string
  controlId: string
  selection: BullXInteractiveOutputChoiceSelection
  options: readonly BullXInteractiveOutputChoiceOption[]
  customText?: BullXInteractiveOutputCustomText
  policy?: BullXInteractiveOutputResponsePolicy
}

export type BullXInteractiveOutputResponse = BullXInteractiveOutputChoiceResponse

export interface BullXInteractiveOutputState {
  status: BullXInteractiveOutputStateStatus
  selectedOptionId?: string
  responseText?: string
}

/**
 * Platform-neutral interaction protocol between the BullX host and chat adapters.
 *
 * This is intentionally not a UI tree. It describes the interaction the host
 * needs the platform to offer: visible content, optional response controls,
 * response policy, current state, and fallback text for projection/degraded
 * adapters. Business concepts such as "clarify" stay in the agent runtime.
 */
export interface BullXInteractiveOutput {
  version: typeof bullxInteractiveOutputVersion
  content: BullXInteractiveOutputContent
  response?: BullXInteractiveOutputResponse
  state?: BullXInteractiveOutputState
  fallbackText: string
}

export interface BullXInteractiveOutputActionValue {
  version: typeof bullxInteractiveOutputActionValueVersion
  interactionId: string
  controlId: string
  optionId?: string
  value?: string
}

export interface BullXInteractiveOutputCardPayload {
  kind: 'interactive_output'
  output: BullXInteractiveOutput
}

export interface BullXLarkNativeCardPayload {
  kind: 'lark_native_card'
  card: BullXExternalGatewayJsonObject
  fallbackText: string
}

export type BullXExternalGatewayCardPayload = BullXInteractiveOutputCardPayload | BullXLarkNativeCardPayload

function bullxJsonRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined
}

/** Validates a cross-boundary interactive-output value (host and adapters share this). */
export function isBullXInteractiveOutput(value: unknown): value is BullXInteractiveOutput {
  const record = bullxJsonRecord(value)
  if (!record || record.version !== bullxInteractiveOutputVersion) return false
  if (typeof record.fallbackText !== 'string' || record.fallbackText.length === 0) return false
  const content = bullxJsonRecord(record.content)
  if (!content || typeof content.body !== 'string') return false
  if (record.response !== undefined && !isBullXInteractiveOutputResponse(record.response)) return false
  if (record.state !== undefined && !isBullXInteractiveOutputState(record.state)) return false
  return true
}

function isBullXInteractiveOutputResponse(value: unknown): value is BullXInteractiveOutputResponse {
  const record = bullxJsonRecord(value)
  if (!record || record.type !== 'choice') return false
  if (typeof record.interactionId !== 'string' || !record.interactionId) return false
  if (typeof record.controlId !== 'string' || !record.controlId) return false
  if (record.selection !== 'single' && record.selection !== 'multi') return false
  if (!Array.isArray(record.options)) return false
  return record.options.every(isBullXInteractiveOutputChoiceOption)
}

function isBullXInteractiveOutputChoiceOption(value: unknown): value is BullXInteractiveOutputChoiceOption {
  const record = bullxJsonRecord(value)
  return (
    record !== undefined &&
    typeof record.id === 'string' &&
    record.id.length > 0 &&
    typeof record.label === 'string' &&
    typeof record.value === 'string'
  )
}

function isBullXInteractiveOutputState(value: unknown): value is BullXInteractiveOutputState {
  const record = bullxJsonRecord(value)
  if (!record) return false
  return (
    record.status === 'open' ||
    record.status === 'answered' ||
    record.status === 'expired' ||
    record.status === 'cancelled' ||
    record.status === 'superseded'
  )
}

export function isBullXInteractiveOutputCardPayload(value: unknown): value is BullXInteractiveOutputCardPayload {
  const record = bullxJsonRecord(value)
  return record?.kind === 'interactive_output' && isBullXInteractiveOutput(record.output)
}

export function isBullXLarkNativeCardPayload(value: unknown): value is BullXLarkNativeCardPayload {
  const record = bullxJsonRecord(value)
  return (
    record?.kind === 'lark_native_card' &&
    bullxJsonRecord(record.card) !== undefined &&
    typeof record.fallbackText === 'string'
  )
}

export function isBullXExternalGatewayCardPayload(value: unknown): value is BullXExternalGatewayCardPayload {
  return isBullXInteractiveOutputCardPayload(value) || isBullXLarkNativeCardPayload(value)
}

export function bullxCardPayloadFallbackText(payload: BullXExternalGatewayCardPayload): string {
  return payload.kind === 'interactive_output' ? payload.output.fallbackText : payload.fallbackText
}

/** Parses an adapter action callback value (JSON string or object) into the typed action value. */
export function parseBullXInteractiveOutputActionValue(value: unknown): BullXInteractiveOutputActionValue | undefined {
  const record = bullxJsonRecord(typeof value === 'string' ? bullxSafeJsonParse(value) : value)
  if (!record) return undefined
  if (record.version !== bullxInteractiveOutputActionValueVersion) return undefined
  if (typeof record.interactionId !== 'string' || !record.interactionId) return undefined
  if (typeof record.controlId !== 'string' || !record.controlId) return undefined
  return {
    version: bullxInteractiveOutputActionValueVersion,
    interactionId: record.interactionId,
    controlId: record.controlId,
    optionId: typeof record.optionId === 'string' ? record.optionId : undefined,
    value: typeof record.value === 'string' ? record.value : undefined
  }
}

function bullxSafeJsonParse(value: string): unknown {
  try {
    return JSON.parse(value)
  } catch {
    return undefined
  }
}

/**
 * Normalized External Gateway facts emitted by chat adapters.
 *
 * Provider raw payloads stay generic because every adapter has a different API
 * shape. The normalized room/message/lifecycle fields are typed so plugins and
 * the host cannot silently drift on required Gateway semantics.
 */
export interface BullXExternalGatewayAuthor {
  fullName: string
  isBot: boolean | 'unknown'
  isMe: boolean
  userId: string
  userName: string
}

export interface BullXExternalGatewayAttachment {
  data?: unknown
  fetchData?: () => Promise<unknown>
  fetchMetadata?: Record<string, string>
  height?: number
  mimeType?: string
  name?: string
  size?: number
  type: 'image' | 'file' | 'video' | 'audio'
  url?: string
  width?: number
}

export interface BullXExternalGatewayLinkPreview {
  description?: string
  fetchMessage?: () => Promise<unknown>
  imageUrl?: string
  siteName?: string
  title?: string
  url: string
}

export interface BullXExternalGatewayRawMessage<TRawMessage = unknown> {
  id: string
  raw: TRawMessage
  threadId: string
}

export interface BullXExternalGatewayRoomInput {
  id?: string
  isDM?: boolean
  metadata?: unknown
  name?: string | null
  raw?: unknown
  roomVisibility?: string
}

export interface BullXExternalGatewayMessageMetadata {
  dateSent?: Date
  [key: string]: unknown
}

export interface BullXExternalGatewayMessageInput<TRawMessage = unknown> {
  attachments?: BullXExternalGatewayAttachment[]
  author: BullXExternalGatewayAuthor
  formatted?: unknown
  id: string
  isMention?: boolean
  links?: BullXExternalGatewayLinkPreview[]
  mentions?: unknown[]
  metadata?: BullXExternalGatewayMessageMetadata
  raw?: TRawMessage
  room?: BullXExternalGatewayRoomInput
  text?: string
  threadId: string
  userKey?: string
}

export interface BullXExternalGatewayMessageDeletedEvent<TRawEvent = unknown> {
  deletedAt?: Date
  kind: 'deleted' | 'recalled'
  message?: BullXExternalGatewayMessageInput
  messageId: string
  raw?: TRawEvent
  room?: BullXExternalGatewayRoomInput
  threadId: string
}

export interface BullXExternalGatewayReactionEvent<TRawEvent = unknown> {
  added: boolean
  emoji: unknown
  message?: BullXExternalGatewayMessageInput
  messageId: string
  raw?: TRawEvent
  rawEmoji?: string
  room?: BullXExternalGatewayRoomInput
  threadId: string
  user: BullXExternalGatewayAuthor
}

export interface BullXExternalGatewayActionEvent<TRawEvent = unknown> {
  actionId: string
  messageId?: string
  raw?: TRawEvent
  room?: BullXExternalGatewayRoomInput
  threadId: string
  user: BullXExternalGatewayAuthor
  value?: string
}

export interface BullXExternalGatewayOutboundOptions {
  idempotencyKey?: string
  operationKey?: string
  reconciliationHint?: {
    providerMessageId?: string
    sentAt?: Date
  }
  targetMessageId?: string
}

export interface BullXExternalGatewayMessageReconciliation<TRawMessage = unknown> {
  deleted?: boolean
  exists: boolean
  message?: BullXExternalGatewayRawMessage<TRawMessage> | BullXExternalGatewayMessageInput<TRawMessage>
  providerMessageId: string
  raw?: unknown
}

export type BullXStreamingCardStatus = 'completed' | 'cancelled' | 'failed'

export interface BullXStreamingCardFinishResult {
  /**
   * True when the provider-visible card message exists. A delivered preview is not
   * enough to suppress the final post unless `finalTextConfirmed` is also true.
   */
  delivered: boolean
  /**
   * True only when the provider confirmed the final text requested by `finish`.
   * Adapters should return false when the card is stuck on an older preview.
   */
  finalTextConfirmed: boolean
  fallbackReason?: string
}

export interface BullXBeginStreamingCardInput {
  threadId: string
  rootId?: string
  idempotencyKey?: string
  initialText?: string
  traceUrl?: string
}

export interface BullXReasoningTraceViewAuthInput {
  agentUid: string
  bindingName: string
  providerRoomId?: string
  providerThreadId?: string
  request: Request
  traceId: string
}

/**
 * Live streaming-card session handle (Lark CardKit parity).
 *
 * `update` is fed the full answer text so far (the adapter throttles and
 * diff-applies provider-side); `updateStatus` is fed transient run/tool status
 * that belongs inside the same card but outside the final answer text; `finish`
 * closes the stream. Implementations must never throw from `update`/`finish` —
 * streaming is decorative and must not fail the agent generation that drives it.
 */
export interface BullXStreamingCardHandle {
  cardId: string
  messageId: string
  update(fullText: string): Promise<void>
  updateStatus?(statusText: string): Promise<void>
  finish(finalText: string, status: BullXStreamingCardStatus): Promise<BullXStreamingCardFinishResult | void>
}

export type BullXExternalGatewayInboundCapability =
  | 'message_receive'
  | 'message_delete'
  | 'message_recall'
  | 'reaction_add'
  | 'reaction_remove'
  | 'action_event'
  | 'modal_event'

export type BullXExternalGatewayOutboundCapability =
  | 'post_message'
  | 'reply_message'
  | 'edit_message'
  | 'delete_message'
  | 'add_reaction'
  | 'remove_reaction'
  | 'divider'
  | 'card'
  | 'modal'
  | 'streaming'
  | 'ephemeral'
  | 'outbound_idempotency'
  | 'outbound_reconciliation'

/**
 * Capability declaration for a concrete chat adapter instance.
 *
 * This is a positive contract, not a feature wishlist. The host uses it before
 * attempting side effects so a GitHub-style webhook adapter can truthfully
 * expose receive/delete while a Lark adapter can expose richer lifecycle and
 * outbound primitives.
 */
export interface BullXExternalGatewayAdapterCapabilities {
  inbound?: readonly BullXExternalGatewayInboundCapability[]
  outbound?: readonly BullXExternalGatewayOutboundCapability[]
}

export interface BullXExternalGatewayWebhookOptions {
  onOpenModal?: (modal: unknown, contextId: string) => Promise<{ viewId: string } | undefined>
  runInBackground?: (task: Promise<unknown>) => void
}

export interface BullXExternalGatewayLogger {
  debug?(...args: unknown[]): void
  error?(...args: unknown[]): void
  info?(...args: unknown[]): void
  warn?(...args: unknown[]): void
}

export interface BullXExternalGatewayAdapterContext {
  emitAction(event: BullXExternalGatewayActionEvent, options?: BullXExternalGatewayWebhookOptions): Promise<void>
  emitMessage(message: BullXExternalGatewayMessageInput, options?: BullXExternalGatewayWebhookOptions): Promise<void>
  emitMessageDeleted(
    event: BullXExternalGatewayMessageDeletedEvent,
    options?: BullXExternalGatewayWebhookOptions
  ): Promise<void>
  emitReaction(event: BullXExternalGatewayReactionEvent, options?: BullXExternalGatewayWebhookOptions): Promise<void>
  getLogger?(prefix?: string): BullXExternalGatewayLogger
  getUserName(): string
}

/**
 * Structural External Gateway adapter contract exposed to plugins.
 *
 * Plugins cannot import app-local core types. Keep this surface aligned with
 * the methods the host runtime invokes so incomplete adapters fail during plugin
 * development instead of at first webhook delivery.
 */
export interface BullXExternalGatewayAdapter<TRawMessage = unknown> {
  readonly capabilities?: BullXExternalGatewayAdapterCapabilities
  addReaction?(threadId: string, messageId: string, emoji: unknown): Promise<void>
  /**
   * Begin a live streaming-card session for the agent's incremental answer.
   * Declared only by adapters that advertise the `streaming` outbound capability;
   * the host falls back to a single post when absent.
   */
  beginStreamingCard?(input: BullXBeginStreamingCardInput): Promise<BullXStreamingCardHandle>
  authorizeReasoningTraceView?(input: BullXReasoningTraceViewAuthInput): boolean | Promise<boolean>
  channelIdFromThreadId(threadId: string): string
  decodeThreadId(threadId: string): unknown
  deleteMessage?(threadId: string, messageId: string, options?: BullXExternalGatewayOutboundOptions): Promise<void>
  disconnect?(): Promise<void>
  encodeThreadId(platformData: unknown): string
  fetchChannelInfo?(channelId: string): Promise<BullXExternalGatewayRoomInput>
  fetchThread?(threadId: string): Promise<BullXExternalGatewayRoomInput>
  getChannelVisibility?(threadId: string): string
  handleWebhook(request: Request, options?: BullXExternalGatewayWebhookOptions): Promise<Response>
  initialize(context: BullXExternalGatewayAdapterContext): void | Promise<void>
  isDM?(threadId: string): boolean
  name: string
  openDM?(userId: string): Promise<string>
  parseMessage(
    raw: TRawMessage
  ): BullXExternalGatewayMessageInput<TRawMessage> | Promise<BullXExternalGatewayMessageInput<TRawMessage>>
  editMessage?(
    threadId: string,
    messageId: string,
    message: unknown,
    options?: BullXExternalGatewayOutboundOptions
  ): Promise<BullXExternalGatewayRawMessage<TRawMessage>>
  postChannelMessage?(
    channelId: string,
    message: unknown,
    options?: BullXExternalGatewayOutboundOptions
  ): Promise<BullXExternalGatewayRawMessage<TRawMessage>>
  postMessage?(
    threadId: string,
    message: unknown,
    options?: BullXExternalGatewayOutboundOptions
  ): Promise<BullXExternalGatewayRawMessage<TRawMessage>>
  reconcileMessage?(
    threadId: string,
    messageId: string,
    options?: BullXExternalGatewayOutboundOptions
  ): Promise<BullXExternalGatewayMessageReconciliation<TRawMessage>>
  removeReaction?(threadId: string, messageId: string, emoji: unknown): Promise<void>
  renderFormatted(content: unknown): string
  userName: string
}

export interface BullXExternalGatewayAdapterFactoryContext {
  agent: unknown
  channel: BullXAgentExternalBinding
  config: BullXPluginJsonValue | undefined
  externalIdentities?: BullXExternalGatewayExternalIdentitySink
}

export interface BullXExternalGatewayAdapterFactory {
  id: string
  setup?: BullXExternalGatewayAdapterSetup
  create(
    context: BullXExternalGatewayAdapterFactoryContext
  ): BullXExternalGatewayAdapter | Promise<BullXExternalGatewayAdapter>
}

/**
 * Canonical user fact emitted by an enterprise identity source.
 *
 * `externalId` is intentionally provider-scoped, not channel-scoped. For Lark
 * self-built apps this is `user_id`, so OIDC login, directory sync, inbound IM
 * authors, and future proactive DM all converge on the same human binding.
 */
export interface BullXIdentityProviderUserRecord {
  externalId: string
  status: 'active' | 'disabled'
  displayName?: string | null
  avatarUrl?: string | null
  email?: string | null
  phone?: string | null
  departmentExternalIds?: readonly string[]
  metadata?: { [key: string]: BullXPluginJsonValue }
}

/**
 * Canonical group fact emitted by an enterprise identity source.
 *
 * V1 uses this for departments. Parent links are external IDs from the same
 * provider; the host expands direct membership into ancestor membership so
 * authorization can grant against either a leaf department or a parent org.
 */
export interface BullXIdentityProviderGroupRecord {
  externalId: string
  name: string
  parentExternalId?: string | null
  status?: 'active' | 'disabled'
  description?: string | null
  metadata?: { [key: string]: BullXPluginJsonValue }
}

export interface BullXIdentityProviderFullSyncSnapshot {
  users: readonly BullXIdentityProviderUserRecord[]
  groups: readonly BullXIdentityProviderGroupRecord[]
}

/**
 * Host-owned write surface handed to identity-provider adapters.
 *
 * Plugins do not write BullX tables directly. This keeps provider API code
 * thin while the app owns Principal, group, membership, and external-identity
 * persistence semantics.
 */
export interface BullXIdentityProviderSyncSink {
  applyFullSync(snapshot: BullXIdentityProviderFullSyncSnapshot): Promise<void>
  upsertUser(user: BullXIdentityProviderUserRecord): Promise<void>
  disableUser(externalId: string, metadata?: { [key: string]: BullXPluginJsonValue }): Promise<void>
  upsertGroup(group: BullXIdentityProviderGroupRecord): Promise<void>
  deleteGroup(externalId: string): Promise<void>
  requestFullSync(reason: string): Promise<void>
}

export interface BullXIdentityProviderAdapterFactoryContext {
  providerId: string
  config: BullXPluginJsonValue | undefined
  /**
   * Public URL used to build OIDC redirect URIs. It can be absent in dev/test
   * until an operator actually starts an OIDC login, but production adapters
   * should reject enabled OIDC without it.
   */
  publicBaseUrl?: string
  /**
   * Host environment signal for config validation. Plugins should not import
   * app internals such as `AppEnv`; this is the small piece they need.
   */
  isProduction: boolean
  syncSink: BullXIdentityProviderSyncSink
  logger?: {
    debug?(data: unknown, message: string): void
    info?(data: unknown, message: string): void
    warn?(data: unknown, message: string): void
    error?(data: unknown, message: string): void
  }
}

export interface BullXIdentityProviderOidcStartInput {
  redirectUri: string
  state: string
  nonce?: string
  returnTo?: string
}

export interface BullXIdentityProviderOidcCallbackInput {
  code: string
  redirectUri: string
  state: string
  nonce?: string
}

export interface BullXIdentityProviderLoginResult {
  user: BullXIdentityProviderUserRecord
}

export interface BullXIdentityProviderAdapter {
  /**
   * Optional OIDC entry point for admin-console login. Adapters that only sync
   * users/groups can omit this without disabling their directory behavior.
   */
  buildOidcAuthorizationUrl?(input: BullXIdentityProviderOidcStartInput): string | Promise<string>
  completeOidcLogin?(input: BullXIdentityProviderOidcCallbackInput): Promise<BullXIdentityProviderLoginResult>
  /**
   * Startup reconciliation pass. External API failures should be surfaced to
   * the host runtime so it can enter degraded mode and retry in the background.
   */
  fullSync?(): Promise<BullXIdentityProviderFullSyncSnapshot | undefined>
  start?(): Promise<void>
  stop?(): Promise<void>
}

export interface BullXIdentityProviderAdapterFactory {
  id: string
  setup?: BullXIdentityProviderAdapterSetup
  create(
    context: BullXIdentityProviderAdapterFactoryContext
  ): BullXIdentityProviderAdapter | Promise<BullXIdentityProviderAdapter>
}

/**
 * Text owned by a plugin but rendered by the host UI.
 *
 * Plugins may keep a simple string for internal/private adapters. Public setup
 * metadata should prefer locale maps so console and setup can render the same
 * adapter contract without hard-coded host-side copy.
 */
export type BullXPluginLocalizedText = string | { [locale: string]: string }

export interface BullXPluginSetupField {
  /**
   * JSON path inside the adapter config object.
   *
   * The path is the persistence contract, not just a form name. Renaming a path
   * changes stored encrypted config unless the adapter keeps a compatibility
   * reader for the old key.
   */
  path: readonly string[]
  type: 'text' | 'password' | 'select' | 'checkbox' | 'number'
  label: BullXPluginLocalizedText
  description?: BullXPluginLocalizedText
  options?: readonly {
    value: string
    label: BullXPluginLocalizedText
  }[]
  defaultValue?: BullXPluginJsonValue
  /**
   * Marks values that must never be echoed back to the browser as plaintext.
   *
   * Host UIs expose these as presence markers during edit. Empty submissions
   * mean "keep the existing secret"; deleting the owning config is the explicit
   * erase operation.
   */
  secret?: boolean
}

export type BullXIdentityProviderSetupField = BullXPluginSetupField

export interface BullXPluginInteractiveConfigUpdate {
  /**
   * Human-readable progress for the current interactive step.
   */
  status?: BullXPluginLocalizedText
  /**
   * Trusted plugin-provided HTML rendered by the host for the active session.
   *
   * This is intentionally generic. QR codes, OAuth links, embedded widgets, and
   * future plugin-specific flows can all fit without forcing every plugin into a
   * host-defined shape. Hosts should only run interactive config for trusted,
   * locally registered plugins.
   */
  html?: string
  /**
   * Partial config patch to merge into the visible form.
   *
   * Returning values does not persist anything by itself; the operator still
   * reviews the form and saves the channel/provider explicitly.
   */
  values?: { [key: string]: BullXPluginJsonValue }
}

export interface BullXPluginInteractiveConfigContext {
  locale?: string
  currentConfig?: BullXPluginJsonValue
  /**
   * Aborted when the operator cancels the session or leaves the form.
   */
  signal?: AbortSignal
  /**
   * Publishes intermediate UI state while the plugin waits for external input.
   */
  onUpdate(update: BullXPluginInteractiveConfigUpdate): void | Promise<void>
}

export interface BullXPluginInteractiveConfig {
  displayName?: BullXPluginLocalizedText
  description?: BullXPluginLocalizedText
  /**
   * Starts a server-side interactive configuration flow.
   *
   * The function may stream progress with `onUpdate` and returns a final update
   * when complete. It runs outside the browser so plugins can call provider SDKs
   * without exposing temporary secrets or polling credentials to client code.
   */
  start(
    context: BullXPluginInteractiveConfigContext
  ): BullXPluginInteractiveConfigUpdate | Promise<BullXPluginInteractiveConfigUpdate>
}

export interface BullXExternalGatewayAdapterSetup {
  displayName?: BullXPluginLocalizedText
  description?: BullXPluginLocalizedText
  /**
   * Suggested instance name for a new Agent channel, for example `lark`.
   *
   * Operators can create multiple channels for one Agent, so this is only a
   * default and must not be treated as the adapter id.
   */
  defaultChannelName?: string
  /**
   * Initial config object for a new channel instance.
   */
  defaultConfig?: BullXPluginJsonValue
  /**
   * Editable config fields shown by setup/console. Runtime validation remains
   * the adapter's responsibility because the host only understands generic JSON.
   */
  fields: readonly BullXPluginSetupField[]
  interactiveConfig?: BullXPluginInteractiveConfig
}

export interface BullXIdentityProviderAdapterSetup {
  displayName?: BullXPluginLocalizedText
  description?: BullXPluginLocalizedText
  /**
   * Suggested external platform namespace for login/directory configuration.
   *
   * This is the provider id used by identity-provider runtime config, not a chat
   * channel reference. Chat integrations may independently use the same platform
   * namespace when the upstream platform subject is globally stable.
   */
  defaultProviderId?: string
  defaultConfig?: BullXPluginJsonValue
  fields: readonly BullXIdentityProviderSetupField[]
}

export interface BullXPluginMetadata {
  id: string
  apiVersion: 1
  displayName?: string
  description?: string
}

export type BullXWebProviderKind = 'search' | 'extract'

export interface BullXWebSearchResult {
  title: string
  url: string
  snippet: string
}

export interface BullXWebExtractResult {
  url: string
  title: string
  text: string
  error?: string
}

export interface BullXWebProviderFactoryContext {
  /** Resolve a registered (plugin-declared) app-config value by key, with its declared JSON type. */
  getConfig(key: string): Promise<BullXPluginJsonValue | undefined>
  /** Resolve a registered (plugin-declared) app-config secret by key. Use for credentials only. */
  getSecret(key: string): Promise<string | undefined>
  isProduction: boolean
  logger?: {
    debug?(data: unknown, message: string): void
    info?(data: unknown, message: string): void
    warn?(data: unknown, message: string): void
    error?(data: unknown, message: string): void
  }
}

/**
 * A web search/extract provider contributed by a plugin. Mirrors the host's
 * built-in provider contract; the host adapts it into the web provider registry
 * consumed by the web_search / web_extract tools.
 */
export interface BullXWebProvider {
  id: string
  supports: readonly BullXWebProviderKind[]
  available(kind: BullXWebProviderKind): boolean | Promise<boolean>
  search?(args: { query: string; limit?: number }, signal?: AbortSignal): Promise<BullXWebSearchResult[]>
  extract?(args: { urls: string[] }, signal?: AbortSignal): Promise<BullXWebExtractResult[]>
}

export interface BullXWebProviderFactory {
  id: string
  create(context: BullXWebProviderFactoryContext): BullXWebProvider | Promise<BullXWebProvider>
}

export interface BullXPlugin {
  metadata: BullXPluginMetadata
  appConfigDefinitions?: readonly BullXAppConfigDefinition[]
  appConfigPatterns?: readonly BullXAppConfigPatternDefinition[]
  externalGatewayAdapters?: readonly BullXExternalGatewayAdapterFactory[]
  identityProviderAdapters?: readonly BullXIdentityProviderAdapterFactory[]
  webProviders?: readonly BullXWebProviderFactory[]
}

export function defineBullXPlugin<const TPlugin extends BullXPlugin>(plugin: TPlugin): TPlugin {
  return plugin
}

/**
 * Resolves plugin-owned localized text with one host-wide fallback order.
 *
 * Console and setup both call this helper so an adapter label does not change
 * just because it is rendered in a different app surface. The order is exact
 * locale, language prefix, English, first available plugin value, then caller
 * fallback.
 */
export function resolveBullXPluginLocalizedText(
  value: BullXPluginLocalizedText | undefined,
  locale: string | undefined,
  fallback?: string
): string | undefined {
  if (typeof value === 'string') return value
  if (!value) return fallback

  const normalizedLocale = locale?.trim()
  const candidates = [normalizedLocale, normalizedLocale?.split('-')[0], 'en-US', 'en'].filter(
    (candidate): candidate is string => Boolean(candidate)
  )

  for (const candidate of candidates) {
    const exact = value[candidate]
    if (exact) return exact

    const prefixed = Object.entries(value).find(([key]) => key === candidate || key.startsWith(`${candidate}-`))
    if (prefixed?.[1]) return prefixed[1]
  }

  return Object.values(value)[0] ?? fallback
}
