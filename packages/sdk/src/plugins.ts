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

/**
 * @deprecated Use {@link bullxExternalIdentityNamespaceIdPatternSource}. This
 * legacy name predates the explicit split between login identity providers and
 * Chat Gateway platform-subject attribution.
 */
export const bullxExternalIdentityProviderIdPatternSource = bullxExternalIdentityNamespaceIdPatternSource

/**
 * @deprecated Use {@link bullxExternalIdentityNamespaceIdPattern}. This is kept
 * only so older plugins keep compiling while host code migrates terminology.
 */
export const bullxExternalIdentityProviderIdPattern = bullxExternalIdentityNamespaceIdPattern

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

export interface BullXAgentChannelBinding {
  adapter: string
  enabled: boolean
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
export interface BullXChatGatewayExternalIdentitySink {
  upsertPlatformSubject(input: BullXPlatformSubjectInput): Promise<BullXPlatformSubjectResult>
}

export type BullXChatGatewayMessageLifecycleReplyAction =
  | {
      /**
       * Create the BullX-authored reply that should exist for the current inbound
       * latest-state. This is returned when the inbound message is already
       * projected as addressed but no reply link exists yet, typically because an
       * earlier outbound post failed before the link could be recorded.
       */
      kind: 'create'
      /**
       * Chat SDK thread id where the BullX-authored reply should be posted.
       */
      threadId: string
      /**
       * Text the adapter should render for the new reply.
       */
      text: string
    }
  | {
      /**
       * Edit an existing BullX-authored reply to match the current inbound
       * latest-state.
       */
      kind: 'edit'
      /**
       * Chat SDK thread id that contains the BullX-authored reply.
       */
      threadId: string
      /**
       * Platform message id of the BullX-authored reply.
       */
      messageId: string
      /**
       * Replacement text the adapter should render when mirroring an inbound edit.
       */
      text: string
    }
  | {
      /**
       * Delete an existing BullX-authored reply because the inbound latest-state is
       * no longer addressed or the inbound message was recalled/deleted.
       */
      kind: 'delete'
      /**
       * Chat SDK thread id that contains the BullX-authored reply.
       */
      threadId: string
      /**
       * Platform message id of the BullX-authored reply.
       */
      messageId: string
    }

export type BullXChatGatewayMessageLifecycleReplyTarget = BullXChatGatewayMessageLifecycleReplyAction

export interface BullXChatGatewayMessageLifecycleReplyLink {
  /**
   * Chat SDK thread id that contains the BullX-authored reply.
   */
  threadId: string
  /**
   * Platform message id of the BullX-authored reply.
   */
  messageId: string
}

export interface BullXChatGatewayInboundMessageMutationResult {
  /**
   * `true` means the host consumed this inbound mutation through the canonical
   * latest-state path. BullX core uses the same path for ordinary receives and
   * edit lifecycle events so stale receives, edits, and recalls cannot diverge
   * from the IM mirror.
   *
   * `chat_messages` is updated before reply side effects. Reply retry is driven
   * by reconciliation state, not by delaying the long-term IM mirror.
   */
  handled: boolean
  /**
   * Reply side effect still needed for the latest projected inbound state.
   */
  reply?: BullXChatGatewayMessageLifecycleReplyAction
  /**
   * Previous latest-state facts, when the host recognized the inbound message.
   *
   * Adapters normally do not need this. The host echo/runtime layer uses it to
   * distinguish an ambient message edited into an addressed message from an edit
   * that only changes text.
   */
  previous?: {
    isMention?: boolean | null
    text?: string | null
  }
}

export interface BullXChatGatewayMessageLifecycleRecordReplyResult {
  recorded: boolean
}

/**
 * Host-owned lifecycle bridge for chat adapters that can observe platform
 * message edits/deletes.
 *
 * The sink is intentionally keyed by Chat SDK channel/message ids, not by
 * identity-provider config or login provider ids. Chat adapters use it only to
 * keep BullX's own reply and latest-state projection aligned with the external
 * chat platform.
 */
export interface BullXChatGatewayMessageLifecycleSink {
  isDeleted(input: { agentUid: string; channelId: string; messageId: string }): Promise<boolean>
  recordReply(input: {
    agentUid: string
    inboundChannelId: string
    inboundThreadId: string
    inboundMessageId: string
    replyThreadId: string
    replyMessageId: string
  }): Promise<BullXChatGatewayMessageLifecycleRecordReplyResult>
  /**
   * Projects an inbound receive/edit latest-state into `chat_messages` and
   * returns any BullX reply action still needed for the current IM state.
   */
  updateInboundMessage(input: {
    agentUid: string
    channelId: string
    messageId: string
    thread: unknown
    message: unknown
  }): Promise<BullXChatGatewayInboundMessageMutationResult>
  /**
   * Records that the BullX-authored reply is now consistent with the currently
   * projected inbound visible state.
   */
  markReplyReconciled(input: {
    agentUid: string
    inboundChannelId: string
    inboundThreadId: string
    inboundMessageId: string
    replyThreadId: string
    replyMessageId: string
  }): Promise<BullXChatGatewayMessageLifecycleRecordReplyResult>
  deleteInboundMessage(input: {
    agentUid: string
    channelId: string
    messageId: string
  }): Promise<BullXChatGatewayInboundMessageMutationResult>
  forgetReply(input: { agentUid: string; channelId: string; messageId: string }): Promise<void>
}

export interface BullXChatGatewayRawMessage<TRawMessage = unknown> {
  id: string
  raw: TRawMessage
  threadId: string
}

export interface BullXChatGatewayFetchMessagesResult {
  messages: readonly unknown[]
  nextCursor?: string
  hasMore?: boolean
}

export type BullXChatGatewayInboundCapability =
  | 'message_receive'
  | 'message_edit'
  | 'message_delete'
  | 'message_recall'
  | 'reaction_add'
  | 'reaction_remove'
  | 'action_event'
  | 'modal_event'

export type BullXChatGatewayOutboundCapability =
  | 'post_message'
  | 'edit_message'
  | 'delete_message'
  | 'add_reaction'
  | 'remove_reaction'
  | 'divider'
  | 'card'
  | 'modal'
  | 'streaming'
  | 'ephemeral'

export type BullXChatGatewayHistoryCapability =
  | 'fetch_message'
  | 'fetch_thread_messages'
  | 'fetch_channel_messages'
  | 'backfill_history'

/**
 * Capability declaration for a concrete chat adapter instance.
 *
 * This is a positive contract, not a feature wishlist. The host uses it before
 * attempting side effects so a GitHub-style webhook adapter can truthfully
 * expose receive/edit/delete while a Lark adapter can expose richer lifecycle
 * and outbound primitives.
 */
export interface BullXChatGatewayAdapterCapabilities {
  history?: readonly BullXChatGatewayHistoryCapability[]
  inbound?: readonly BullXChatGatewayInboundCapability[]
  outbound?: readonly BullXChatGatewayOutboundCapability[]
}

/**
 * Structural Chat SDK adapter contract exposed to plugins.
 *
 * Plugins cannot import app-local vendored core types, but Chat Gateway still
 * calls returned objects as Chat SDK adapters. Keep this surface aligned with
 * the methods the host runtime invokes so incomplete adapters fail during
 * plugin development instead of at first webhook delivery.
 */
export interface BullXChatGatewayAdapter {
  readonly capabilities?: BullXChatGatewayAdapterCapabilities
  addReaction?(threadId: string, messageId: string, emoji: unknown): Promise<void>
  channelIdFromThreadId(threadId: string): string
  decodeThreadId(threadId: string): unknown
  deleteMessage?(threadId: string, messageId: string): Promise<void>
  disconnect?(): Promise<void>
  editMessage?(threadId: string, messageId: string, message: unknown): Promise<BullXChatGatewayRawMessage>
  encodeThreadId(platformData: unknown): string
  fetchChannelInfo?(channelId: string): Promise<unknown>
  fetchChannelMessages?(channelId: string, options?: unknown): Promise<BullXChatGatewayFetchMessagesResult>
  fetchMessages?(threadId: string, options?: unknown): Promise<BullXChatGatewayFetchMessagesResult>
  fetchThread?(threadId: string): Promise<unknown>
  getChannelVisibility?(threadId: string): string
  handleWebhook(request: Request, options?: unknown): Promise<Response>
  initialize(chat: unknown): void | Promise<void>
  isDM?(threadId: string): boolean
  name: string
  openDM?(userId: string): Promise<string>
  parseMessage(raw: unknown): unknown | Promise<unknown>
  postChannelMessage?(channelId: string, message: unknown): Promise<BullXChatGatewayRawMessage>
  postMessage?(threadId: string, message: unknown): Promise<BullXChatGatewayRawMessage>
  removeReaction?(threadId: string, messageId: string, emoji: unknown): Promise<void>
  renderFormatted(content: unknown): string
  startTyping?(threadId: string, status?: string): Promise<void>
  userName: string
}

export interface BullXChatGatewayAdapterFactoryContext {
  agent: unknown
  channel: BullXAgentChannelBinding
  config: BullXPluginJsonValue | undefined
  externalIdentities?: BullXChatGatewayExternalIdentitySink
}

export interface BullXChatGatewayAdapterFactory {
  id: string
  setup?: BullXChatGatewayAdapterSetup
  create(context: BullXChatGatewayAdapterFactoryContext): BullXChatGatewayAdapter | Promise<BullXChatGatewayAdapter>
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

export interface BullXChatGatewayAdapterSetup {
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

export interface BullXPlugin {
  metadata: BullXPluginMetadata
  appConfigDefinitions?: readonly BullXAppConfigDefinition[]
  appConfigPatterns?: readonly BullXAppConfigPatternDefinition[]
  chatGatewayAdapters?: readonly BullXChatGatewayAdapterFactory[]
  identityProviderAdapters?: readonly BullXIdentityProviderAdapterFactory[]
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
