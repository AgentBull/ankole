import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import type {
  BullXExternalGatewayAdapterFactory,
  BullXExternalGatewayAdapterSetup,
  BullXPluginInteractiveConfigUpdate,
  BullXPluginSetupField
} from '@agentbull/bullx-sdk/plugins'
import { appConfigService } from '@/config/app-configure'
import { agentChannelConfigKey } from '@/external-gateway/config'
import type { JsonObject, JsonValue } from '@/common/db-schema'
import { loadPluginCatalog, type PluginCatalog } from '@/plugins/catalog'
import {
  clonePluginJsonObject as cloneJsonObject,
  clonePluginJsonValue as cloneJsonValue,
  defaultPluginConfigForSetup,
  getPluginConfigPath as getPath,
  isPluginConfigJsonObject,
  mergePluginConfigObjects as mergeJsonObjects,
  setPluginConfigPath as setPath
} from '@/plugins/config-json'
import {
  type AgentResult,
  createAgent,
  disableAgent,
  getAgent,
  listActiveAgents,
  updateAgent
} from '@/principals/agents/service'

const channelNamePattern = /^[a-z][a-z0-9_]*$/

export interface ConsoleAgent {
  uid: string
  status: AgentResult['principal']['status']
  createdAt: Date
  updatedAt: Date
  chatChannels: ConsoleChatChannel[]
}

export interface ConsoleExternalGatewayAdapter {
  id: string
  pluginId: string
  setup?: BullXExternalGatewayAdapterSetup
  interactiveConfig: boolean
}

export interface ConsoleChatChannel {
  name: string
  adapter: string
  enabled: boolean
  config: JsonObject
  adapterInstalled: boolean
  restartRequired: true
}

export interface UpsertConsoleChatChannelInput {
  name?: string
  adapter?: string
  enabled?: boolean
  config?: JsonObject
}

interface StoredChannelBinding {
  /**
   * Stored in `agents.metadata.external.adapters[]`.
   *
   * Only routing metadata lives on the Agent row. Adapter config is stored
   * separately under `agents.<uid>.<channel>` so secret erasure can be scoped to
   * the channel without rewriting unrelated Agent metadata.
   */
  adapter: string
  enabled: boolean
  name: string
}

type InteractiveConfigState = 'running' | 'succeeded' | 'failed' | 'cancelled'

export interface ConsoleInteractiveConfigSessionProjection {
  sessionId: string
  adapterId: string
  state: InteractiveConfigState
  status?: BullXPluginInteractiveConfigUpdate['status']
  html?: string
  values?: JsonObject
  error?: string
}

interface ConsoleInteractiveConfigSession extends ConsoleInteractiveConfigSessionProjection {
  abortController: AbortController
}

export class ConsoleDomainError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message)
    this.name = 'ConsoleDomainError'
  }
}

/**
 * Process-local interactive config sessions.
 *
 * These sessions hold abort signals and provider-side progress for flows such
 * as Lark one-click app registration. Completed values only patch the browser
 * form; durable config is written by the normal channel save path.
 */
const interactiveConfigSessions = new Map<string, ConsoleInteractiveConfigSession>()

export async function loadConsolePluginCatalog(): Promise<PluginCatalog> {
  return loadPluginCatalog()
}

export async function listConsoleExternalGatewayAdapters(): Promise<ConsoleExternalGatewayAdapter[]> {
  const catalog = await loadConsolePluginCatalog()
  return listEnabledExternalGatewayAdapters(catalog)
}

export async function listConsoleAgents(): Promise<ConsoleAgent[]> {
  const agents = await listActiveAgents()
  return Promise.all(agents.map(projectConsoleAgent))
}

export async function createConsoleAgent(uid: string, createdByPrincipalUid?: string): Promise<ConsoleAgent> {
  let result: AgentResult
  try {
    result = await createAgent({
      uid,
      createdByPrincipalUid
    })
  } catch (error) {
    if (isDatabaseErrorCode(error, '23505')) throw new ConsoleDomainError(409, 'agent uid already exists')
    throw error
  }

  return projectConsoleAgent(result)
}

export async function getConsoleAgent(uid: string): Promise<ConsoleAgent> {
  return projectConsoleAgent(await requireActiveAgent(uid))
}

export async function updateConsoleAgent(
  uid: string,
  input: { displayName?: string | null; avatarUrl?: string | null }
): Promise<ConsoleAgent> {
  const result = await updateAgent(uid, input)
  if (result.principal.status !== 'active') throw new ConsoleDomainError(404, 'agent not found')

  return projectConsoleAgent(result)
}

export async function deleteConsoleAgent(uid: string): Promise<void> {
  const agent = await requireActiveAgent(uid)
  const bindings = readStoredChannelBindings(agent.agent.metadata)

  for (const binding of bindings) {
    await appConfigService.deleteByKey(agentChannelConfigKey(agent.agent.uid, binding.name))
  }

  await updateAgent(agent.agent.uid, {
    metadata: writeStoredChannelBindings(agent.agent.metadata, [])
  })
  await disableAgent(agent.agent.uid)
}

export async function listConsoleExternalRooms(agentUid: string): Promise<ConsoleChatChannel[]> {
  const agent = await requireActiveAgent(agentUid)
  return projectConsoleExternalRooms(agent)
}

export async function createConsoleChatChannel(
  agentUid: string,
  input: UpsertConsoleChatChannelInput
): Promise<ConsoleChatChannel> {
  const agent = await requireActiveAgent(agentUid)
  const adapter = await requireEnabledExternalGatewayAdapter(requiredText(input.adapter, 'adapter'))
  const name = normalizeChannelName(input.name ?? adapter.setup?.defaultChannelName ?? adapter.id)
  const bindings = readStoredChannelBindings(agent.agent.metadata)
  if (bindings.some(binding => binding.name === name)) throw new ConsoleDomainError(409, 'chat channel already exists')

  const config = mergeConfigForSave(adapter.setup, defaultConfigForSetup(adapter.setup), input.config ?? {})
  await persistChannelConfigWithMetadata(
    agent,
    [
      ...bindings,
      {
        name,
        adapter: adapter.id,
        enabled: input.enabled ?? true
      }
    ],
    name,
    config
  )

  return getConsoleChatChannel(agent.agent.uid, name)
}

export async function updateConsoleChatChannel(
  agentUid: string,
  channelName: string,
  input: UpsertConsoleChatChannelInput
): Promise<ConsoleChatChannel> {
  const agent = await requireActiveAgent(agentUid)
  const name = normalizeChannelName(channelName)
  const bindings = readStoredChannelBindings(agent.agent.metadata)
  const index = bindings.findIndex(binding => binding.name === name)
  if (index === -1) throw new ConsoleDomainError(404, 'chat channel not found')

  const current = bindings[index]!
  if (input.adapter && input.adapter !== current.adapter) {
    throw new ConsoleDomainError(422, 'chat channel adapter cannot be changed; delete and recreate the channel')
  }
  const adapter = await requireEnabledExternalGatewayAdapter(input.adapter ?? current.adapter)
  const previousConfig = await loadChannelConfig(agent.agent.uid, name)
  const config = mergeConfigForSave(adapter.setup, previousConfig, input.config ?? {})
  const nextBindings = [...bindings]
  nextBindings[index] = {
    name,
    adapter: adapter.id,
    enabled: input.enabled ?? current.enabled
  }

  await persistChannelConfigWithMetadata(agent, nextBindings, name, config)
  return getConsoleChatChannel(agent.agent.uid, name)
}

export async function deleteConsoleChatChannel(agentUid: string, channelName: string): Promise<void> {
  const agent = await requireActiveAgent(agentUid)
  const name = normalizeChannelName(channelName)
  const bindings = readStoredChannelBindings(agent.agent.metadata)
  const nextBindings = bindings.filter(binding => binding.name !== name)
  if (nextBindings.length === bindings.length) throw new ConsoleDomainError(404, 'chat channel not found')

  await updateAgent(agent.agent.uid, {
    metadata: writeStoredChannelBindings(agent.agent.metadata, nextBindings)
  })
  await appConfigService.deleteByKey(agentChannelConfigKey(agent.agent.uid, name))
}

export async function getConsoleChatChannel(agentUid: string, channelName: string): Promise<ConsoleChatChannel> {
  const agent = await requireActiveAgent(agentUid)
  const name = normalizeChannelName(channelName)
  const channel = (await projectConsoleExternalRooms(agent)).find(candidate => candidate.name === name)
  if (!channel) throw new ConsoleDomainError(404, 'chat channel not found')

  return channel
}

export async function startConsoleInteractiveConfigSession(input: {
  adapterId: string
  currentConfig?: JsonObject
  locale?: string
}): Promise<ConsoleInteractiveConfigSessionProjection> {
  const adapter = await requireEnabledExternalGatewayAdapter(input.adapterId)
  const interactiveConfig = adapter.setup?.interactiveConfig
  if (!interactiveConfig) throw new ConsoleDomainError(404, 'chat adapter does not support interactive config')

  const sessionId = genUUIDv7()
  const session: ConsoleInteractiveConfigSession = {
    sessionId,
    adapterId: adapter.id,
    state: 'running',
    abortController: new AbortController()
  }
  interactiveConfigSessions.set(sessionId, session)

  /*
   * Run the plugin flow in the background and let the browser poll this session.
   * The plugin may push QR HTML/status first and return credentials later. The
   * session remains readable until the browser merges final values or cancels.
   */
  void Promise.resolve()
    .then(() =>
      interactiveConfig.start({
        locale: input.locale,
        currentConfig: input.currentConfig,
        signal: session.abortController.signal,
        onUpdate: update => mergeInteractiveConfigUpdate(session, update)
      })
    )
    .then(update => {
      if (session.state === 'cancelled') return
      mergeInteractiveConfigUpdate(session, update)
      session.state = 'succeeded'
    })
    .catch(error => {
      if (session.state === 'cancelled') return
      session.state = session.abortController.signal.aborted ? 'cancelled' : 'failed'
      session.error = error instanceof Error ? error.message : String(error)
    })

  return projectInteractiveConfigSession(session)
}

export function getConsoleInteractiveConfigSession(sessionId: string): ConsoleInteractiveConfigSessionProjection {
  const session = interactiveConfigSessions.get(sessionId)
  if (!session) throw new ConsoleDomainError(404, 'interactive config session not found')

  return projectInteractiveConfigSession(session)
}

export function deleteConsoleInteractiveConfigSession(sessionId: string): void {
  const session = interactiveConfigSessions.get(sessionId)
  if (!session) return

  // DELETE is idempotent because the frontend calls it on explicit cancel and
  // again from effect cleanup when the form unmounts or switches sessions.
  session.state = 'cancelled'
  session.abortController.abort()
  interactiveConfigSessions.delete(sessionId)
}

function listEnabledExternalGatewayAdapters(catalog: PluginCatalog): ConsoleExternalGatewayAdapter[] {
  const enabled = new Set(catalog.enabledPluginIds)
  const adapters: ConsoleExternalGatewayAdapter[] = []

  for (const plugin of catalog.plugins) {
    if (!enabled.has(plugin.metadata.id)) continue

    for (const adapter of plugin.externalGatewayAdapters ?? []) {
      adapters.push({
        id: adapter.id,
        pluginId: plugin.metadata.id,
        setup: adapter.setup,
        interactiveConfig: Boolean(adapter.setup?.interactiveConfig)
      })
    }
  }

  return adapters
}

async function requireEnabledExternalGatewayAdapter(adapterId: string): Promise<BullXExternalGatewayAdapterFactory> {
  const catalog = await loadConsolePluginCatalog()
  const enabled = new Set(catalog.enabledPluginIds)

  for (const plugin of catalog.plugins) {
    if (!enabled.has(plugin.metadata.id)) continue

    const adapter = (plugin.externalGatewayAdapters ?? []).find(candidate => candidate.id === adapterId)
    if (adapter) return adapter
  }

  throw new ConsoleDomainError(404, 'chat adapter is not enabled')
}

async function requireActiveAgent(uid: string): Promise<AgentResult> {
  const agent = await getAgent(uid)
  if (!agent || agent.principal.status !== 'active') throw new ConsoleDomainError(404, 'agent not found')

  return agent
}

async function projectConsoleAgent(agent: AgentResult): Promise<ConsoleAgent> {
  return {
    uid: agent.agent.uid,
    status: agent.principal.status,
    createdAt: agent.agent.createdAt,
    updatedAt: agent.agent.updatedAt,
    chatChannels: await projectConsoleExternalRooms(agent)
  }
}

async function projectConsoleExternalRooms(agent: AgentResult): Promise<ConsoleChatChannel[]> {
  const adapters = new Map((await listConsoleExternalGatewayAdapters()).map(adapter => [adapter.id, adapter]))
  const channels: ConsoleChatChannel[] = []

  for (const binding of readStoredChannelBindings(agent.agent.metadata)) {
    const adapter = adapters.get(binding.adapter)
    const config = adapter
      ? publicConfigForSetup(adapter.setup, await loadChannelConfig(agent.agent.uid, binding.name))
      : {}

    channels.push({
      name: binding.name,
      adapter: binding.adapter,
      enabled: binding.enabled,
      config,
      adapterInstalled: Boolean(adapter),
      restartRequired: true
    })
  }

  return channels
}

async function persistChannelConfigWithMetadata(
  agent: AgentResult,
  bindings: StoredChannelBinding[],
  channelName: string,
  config: JsonObject
): Promise<void> {
  await appConfigService.setByKey(agentChannelConfigKey(agent.agent.uid, channelName), config)
  await updateAgent(agent.agent.uid, {
    metadata: writeStoredChannelBindings(agent.agent.metadata, bindings)
  })
}

async function loadChannelConfig(agentUid: string, channelName: string): Promise<JsonObject> {
  const value = await appConfigService.getByKey(agentChannelConfigKey(agentUid, channelName))
  return isJsonObject(value) ? cloneJsonObject(value) : {}
}

function readStoredChannelBindings(metadata: JsonObject): StoredChannelBinding[] {
  const external = jsonObject(metadata.external) ?? jsonObject(metadata.chat)
  const adapters = external?.adapters
  if (adapters === undefined) return []
  if (!Array.isArray(adapters)) throw new ConsoleDomainError(422, 'agents.metadata.external.adapters must be an array')

  const bindings = adapters.map((value, index) => parseStoredBinding(value, index))
  const seen = new Set<string>()
  for (const binding of bindings) {
    if (seen.has(binding.name)) throw new ConsoleDomainError(422, `duplicate chat channel name: ${binding.name}`)
    seen.add(binding.name)
  }

  return bindings
}

function parseStoredBinding(value: JsonValue, index: number): StoredChannelBinding {
  const input = jsonObject(value)
  if (!input) throw new ConsoleDomainError(422, `agents.metadata.external.adapters[${index}] must be an object`)

  return {
    name: normalizeChannelName(input.name),
    adapter: normalizeChannelName(input.adapter),
    enabled:
      input.enabled === undefined
        ? true
        : requiredBoolean(input.enabled, `agents.metadata.external.adapters[${index}].enabled`)
  }
}

function writeStoredChannelBindings(metadata: JsonObject, bindings: readonly StoredChannelBinding[]): JsonObject {
  const next = cloneJsonObject(metadata)
  const external = jsonObject(next.external)
    ? cloneJsonObject(next.external as JsonObject)
    : jsonObject(next.chat)
      ? cloneJsonObject(next.chat as JsonObject)
      : {}
  external.adapters = bindings.map(binding => ({
    name: binding.name,
    adapter: binding.adapter,
    enabled: binding.enabled
  }))
  next.external = external
  delete next.chat
  return next
}

function defaultConfigForSetup(setup: BullXExternalGatewayAdapterSetup | undefined): JsonObject {
  return defaultPluginConfigForSetup(setup) as JsonObject
}

function mergeConfigForSave(
  setup: BullXExternalGatewayAdapterSetup | undefined,
  base: JsonObject,
  input: JsonObject
): JsonObject {
  let next = mergeJsonObjects(base, input)

  /*
   * Editing a secret field sends either an empty string or a `{ present: true }`
   * marker when the operator did not type a replacement. In both cases the old
   * encrypted value must survive. Deleting the channel/agent is the erase path.
   */
  for (const field of setup?.fields ?? []) {
    if (!isSecretField(field)) continue

    const incoming = getPath(input, field.path)
    if (secretShouldKeepExisting(incoming)) {
      const existing = getPath(base, field.path)
      if (existing !== undefined) next = setPath(next, field.path, cloneJsonValue(existing))
    }
  }

  return next
}

function publicConfigForSetup(setup: BullXExternalGatewayAdapterSetup | undefined, config: JsonObject): JsonObject {
  let next = cloneJsonObject(config)
  /*
   * Secret values are never returned to console. The UI only needs to know
   * whether a value exists so it can show a "saved" placeholder and preserve it
   * on submit.
   */
  for (const field of setup?.fields ?? []) {
    if (!isSecretField(field)) continue

    next = setPath(next, field.path, {
      present: !secretShouldKeepExisting(getPath(config, field.path))
    })
  }

  return next
}

function isSecretField(field: BullXPluginSetupField): boolean {
  return field.secret === true || field.type === 'password'
}

function secretShouldKeepExisting(value: JsonValue | undefined): boolean {
  if (value === undefined || value === null) return true
  if (typeof value === 'string') return value.trim() === ''
  if (isJsonObject(value) && typeof value.present === 'boolean') return true
  return false
}

function mergeInteractiveConfigUpdate(
  session: ConsoleInteractiveConfigSession,
  update: BullXPluginInteractiveConfigUpdate | undefined
): void {
  if (!update) return
  if (update.status !== undefined) session.status = update.status
  if (update.html !== undefined) session.html = update.html
  if (update.values !== undefined) session.values = isJsonObject(update.values) ? cloneJsonObject(update.values) : {}
}

function projectInteractiveConfigSession(
  session: ConsoleInteractiveConfigSession
): ConsoleInteractiveConfigSessionProjection {
  return {
    sessionId: session.sessionId,
    adapterId: session.adapterId,
    state: session.state,
    status: session.status,
    html: session.html,
    values: session.values,
    error: session.error
  }
}

function normalizeChannelName(value: unknown): string {
  const name = requiredText(value, 'channel name')
  if (!channelNamePattern.test(name)) throw new ConsoleDomainError(422, `channel name must match ${channelNamePattern}`)

  return name
}

function requiredText(value: unknown, label: string): string {
  if (typeof value !== 'string') throw new ConsoleDomainError(422, `${label} must be a string`)

  const trimmed = value.trim()
  if (!trimmed) throw new ConsoleDomainError(422, `${label} must not be empty`)
  return trimmed
}

function requiredBoolean(value: JsonValue, label: string): boolean {
  if (typeof value !== 'boolean') throw new ConsoleDomainError(422, `${label} must be a boolean`)
  return value
}

function jsonObject(value: JsonValue | undefined): JsonObject | undefined {
  return isJsonObject(value) ? value : undefined
}

function isJsonObject(value: unknown): value is JsonObject {
  return isPluginConfigJsonObject(value)
}

function isDatabaseErrorCode(error: unknown, code: string): boolean {
  if (typeof error !== 'object' || error === null) return false
  if ((error as { code?: unknown }).code === code) return true
  if ((error as { errno?: unknown }).errno === code) return true

  return isDatabaseErrorCode((error as { cause?: unknown }).cause, code)
}
