import type { Adapter } from 'chat'

/**
 * Canonical syntax for `principal_external_identities.provider`.
 *
 * This id names an external identity namespace, usually one enterprise platform
 * tenant such as `lark-main`. It is not a plugin id, not a bot app id, and not a
 * foreign key to a running identity-provider adapter. Chat adapters and identity
 * provider adapters can converge only by independently using the same namespace
 * plus the same platform subject id.
 */
export const bullxExternalIdentityProviderIdPatternSource = '[a-z][a-z0-9_-]*'
export const bullxExternalIdentityProviderIdPattern = new RegExp(`^${bullxExternalIdentityProviderIdPatternSource}$`)

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
   * External identity namespace stored in `principal_external_identities.provider`.
   *
   * For Lark self-built apps this is the tenant-level BullX namespace configured
   * by the operator, not an app-scoped `open_id` namespace.
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
 * This is deliberately not an identity-provider adapter reference. A chat
 * adapter can record a platform subject fact from an inbound event; if a
 * directory/OIDC adapter later emits the same `provider + externalId`, both
 * paths land on the same `principal_external_identities` row.
 */
export interface BullXChatGatewayExternalIdentitySink {
  upsertPlatformSubject(input: BullXPlatformSubjectInput): Promise<BullXPlatformSubjectResult>
}

export interface BullXChatGatewayAdapterFactoryContext {
  agent: unknown
  channel: BullXAgentChannelBinding
  config: BullXPluginJsonValue | undefined
  projection: unknown
  externalIdentities?: BullXChatGatewayExternalIdentitySink
}

export interface BullXChatGatewayAdapterFactory {
  id: string
  create(context: BullXChatGatewayAdapterFactoryContext): Adapter | Promise<Adapter>
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
  fullSync?(): Promise<BullXIdentityProviderFullSyncSnapshot>
  start?(): Promise<void>
  stop?(): Promise<void>
}

export interface BullXIdentityProviderAdapterFactory {
  id: string
  create(
    context: BullXIdentityProviderAdapterFactoryContext
  ): BullXIdentityProviderAdapter | Promise<BullXIdentityProviderAdapter>
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
