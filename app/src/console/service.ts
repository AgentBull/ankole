import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { asc, desc, eq, isNull, sql } from 'drizzle-orm'
import type {
  BullXExternalGatewayAdapterFactory,
  BullXExternalGatewayAdapterSetup,
  BullXPluginInteractiveConfigUpdate,
  BullXPluginSetupField
} from '@agentbull/bullx-sdk/plugins'
import { DB } from '@/common/database'
import { appConfigService } from '@/config/app-configure'
import { agentChannelConfigKey } from '@/external-gateway/config'
import {
  AgentLibraryContainerEntries,
  Agents,
  HumanUsers,
  LibrarySkills,
  PrincipalGroupMemberships,
  Principals,
  type JsonObject,
  type JsonValue
} from '@/common/db-schema'
import { isJsonObject } from '@/common/json'
import {
  getSoul,
  listEffectiveSkills,
  setAgentSkillEnabled,
  setSoul,
  type EffectiveSkillSummary
} from '@/ai-agent/library/service'
import {
  readAiAgentModelsConfig,
  validateAiAgentModelsConfig,
  writeAiAgentModelsConfig,
  type AiAgentModelsConfig
} from '@/ai-agent/config'
import { loadPluginCatalog, type PluginCatalog } from '@/plugins/catalog'
import {
  clonePluginJsonObject as cloneJsonObject,
  clonePluginJsonValue as cloneJsonValue,
  defaultPluginConfigForSetup,
  getPluginConfigPath as getPath,
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
import { ensureCanDisablePrincipal } from '@/principals/authorization/memberships'
import {
  createPrincipalGroup,
  deletePrincipalGroup,
  listPrincipalGroups,
  updatePrincipalGroup,
  type PrincipalGroup
} from '@/principals/authorization/groups'
import { createHuman, upsertHumanProfile } from '@/principals/human-users/service'
import { normalizeUid, updatePrincipalStatus, type Principal } from '@/principals/principals/service'
import {
  AgentChatMetadataError,
  parseAgentExternalBindingsAll,
  writeAgentExternalBindings,
  type AgentExternalBinding
} from '@/external-gateway/metadata'

const channelNamePattern = /^[a-z][a-z0-9_]*$/

const consoleResourceSummaries: ConsoleResourceSummary[] = [
  {
    id: 'agents',
    title: 'AI Agents',
    description: 'Create AI principals, tune model profiles, and attach chat channels, skills, schedules, and workers.',
    operations: ['create', 'inspect', 'edit profile/models', 'disable'],
    owner: 'operator'
  },
  {
    id: 'channels',
    title: 'Chat Channels',
    description: 'Bind an agent to external gateway adapters such as Lark, including interactive setup.',
    operations: ['create', 'inspect', 'edit config', 'enable/disable', 'delete'],
    owner: 'operator'
  },
  {
    id: 'llm-providers',
    title: 'LLM Providers',
    description: 'Manage provider credentials and runtime options consumed by agent model profiles.',
    operations: ['create', 'inspect', 'edit', 'check', 'delete'],
    owner: 'operator'
  },
  {
    id: 'schedules',
    title: 'Scheduled Tasks',
    description: 'Define recurring agent work and inspect immutable run history.',
    operations: ['create task', 'edit task', 'run now', 'delete task', 'inspect runs'],
    owner: 'operator'
  },
  {
    id: 'workers',
    title: 'Computer Workers',
    description:
      'Observe registered bullx-computerd instances and pin important agents to dedicated workers when Python package isolation matters.',
    operations: ['inspect workers', 'pin agent', 'remove pin'],
    owner: 'runtime'
  },
  {
    id: 'skills',
    title: 'Skills',
    description: 'Review canonical skills and toggle effective agent assignments.',
    operations: ['inspect library', 'enable/disable per agent'],
    owner: 'builtin'
  },
  {
    id: 'library',
    title: 'Agent Library Container',
    description: 'Edit agent-owned SOUL.md and inspect generated skill append/library entries.',
    operations: ['inspect entries', 'edit SOUL.md'],
    owner: 'operator'
  },
  {
    id: 'people',
    title: 'Human Users',
    description: 'Operate human principals while keeping login and directory bindings in their own flows.',
    operations: ['create local human', 'inspect', 'edit profile', 'activate/disable'],
    owner: 'directory'
  },
  {
    id: 'groups',
    title: 'Principal Groups',
    description: 'Manage authorization groups and computed membership definitions.',
    operations: ['create', 'inspect', 'edit', 'delete non-built-ins'],
    owner: 'operator'
  }
]

export interface ConsoleAgent {
  uid: string
  status: AgentResult['principal']['status']
  displayName: string | null
  avatarUrl: string | null
  createdAt: Date
  updatedAt: Date
  chatChannels: ConsoleChatChannel[]
  llmProfile?: ConsoleAgentLlmProfile
}

export interface ConsoleAgentLlmProfile {
  models: AiAgentModelsConfig
}

export interface ConsoleOverview {
  counts: {
    agents: number
    chatChannels: number
    humanUsers: number
    principalGroups: number
    librarySkills: number
    agentLibraryEntries: number
  }
  resources: ConsoleResourceSummary[]
}

export interface ConsoleResourceSummary {
  id: string
  title: string
  description: string
  operations: string[]
  owner: 'operator' | 'runtime' | 'directory' | 'builtin'
}

export interface ConsoleHumanUser {
  principal: Principal
  humanUser: typeof HumanUsers.$inferSelect
}

export interface UpsertConsoleHumanInput {
  uid: string
  displayName?: string | null
  avatarUrl?: string | null
  email?: string | null
  phone?: string | null
}

export interface UpdateConsoleHumanInput {
  displayName?: string | null
  avatarUrl?: string | null
  email?: string | null
  phone?: string | null
  status?: Principal['status']
}

export interface ConsolePrincipalGroup extends PrincipalGroup {
  membershipCount: number
}

export interface ConsoleLibrarySkill {
  id: string
  name: string
  description: string
  defaultEnabled: boolean
  enabled: boolean
  sourceKind: string
  rootPath: string
  tags: string[]
  category?: string
  createdAt: Date
  updatedAt: Date
}

export interface ConsoleAgentLibraryEntry {
  id: string
  agentUid: string
  virtualPath: string
  entryKind: string
  sourceKind: string
  enabled: boolean
  version: string
  contentMediaType: string
  contentText: string | null
  createdAt: Date
  updatedAt: Date
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

export interface UpsertConsoleAgentInput {
  avatarUrl?: string | null
  displayName?: string | null
  llmProfile?: ConsoleAgentLlmProfile
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

export async function getConsoleOverview(): Promise<ConsoleOverview> {
  const [agentsCount, channelBindingsCount, humanUsers, groups, skills, entries] = await Promise.all([
    DB.select({ count: sql<number>`count(*)::int` })
      .from(Principals)
      .where(sql`${Principals.type} = 'agent' AND ${Principals.status} = 'active'`),
    DB.select({ metadata: Agents.metadata })
      .from(Agents)
      .innerJoin(Principals, eq(Principals.uid, Agents.uid))
      .where(sql`${Principals.status} = 'active'`),
    listConsoleHumanUsers(),
    listConsolePrincipalGroups(),
    listConsoleLibrarySkills(),
    DB.select({ id: AgentLibraryContainerEntries.id })
      .from(AgentLibraryContainerEntries)
      .where(isNull(AgentLibraryContainerEntries.deletedAt))
  ])

  return {
    counts: {
      agents: agentsCount[0]?.count ?? 0,
      chatChannels: channelBindingsCount.reduce(
        (sum, row) => sum + readStoredChannelBindingsSafe(row.metadata).length,
        0
      ),
      humanUsers: humanUsers.length,
      principalGroups: groups.length,
      librarySkills: skills.length,
      agentLibraryEntries: entries.length
    },
    resources: consoleResourceSummaries
  }
}

export async function createConsoleAgent(
  uid: string,
  createdByPrincipalUid?: string,
  input: UpsertConsoleAgentInput = {}
): Promise<ConsoleAgent> {
  const metadata = input.llmProfile ? await agentMetadataWithLlmProfile({}, input.llmProfile) : undefined
  let result: AgentResult
  try {
    result = await createAgent({
      uid,
      avatarUrl: input.avatarUrl,
      displayName: input.displayName,
      metadata,
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

export async function updateConsoleAgent(uid: string, input: UpsertConsoleAgentInput): Promise<ConsoleAgent> {
  const metadata = input.llmProfile
    ? await agentMetadataWithLlmProfile((await requireActiveAgent(uid)).agent.metadata, input.llmProfile)
    : undefined
  const result = await updateAgent(uid, {
    avatarUrl: input.avatarUrl,
    displayName: input.displayName,
    metadata
  })
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
    metadata: writeAgentExternalBindings(agent.agent.metadata, [])
  })
  await disableAgent(agent.agent.uid)
}

export async function listConsoleHumanUsers(): Promise<ConsoleHumanUser[]> {
  const rows = await DB.select({ principal: Principals, humanUser: HumanUsers })
    .from(HumanUsers)
    .innerJoin(Principals, eq(Principals.uid, HumanUsers.principalUid))
    .orderBy(asc(HumanUsers.createdAt))
  return rows
}

export async function createConsoleHumanUser(input: UpsertConsoleHumanInput): Promise<ConsoleHumanUser> {
  const result = await createHuman(input)
  return {
    principal: result.principal,
    humanUser: result.humanUser
  }
}

export async function updateConsoleHumanUser(
  principalUid: string,
  input: UpdateConsoleHumanInput
): Promise<ConsoleHumanUser> {
  const uid = normalizeUid(principalUid)
  const result = await upsertHumanProfile({ uid, ...input })
  if (input.status && input.status !== result.principal.status) {
    if (input.status === 'disabled') await ensureCanDisablePrincipal(uid)
    const principal = await updatePrincipalStatus(uid, input.status)
    return {
      principal,
      humanUser: result.humanUser
    }
  }

  return {
    principal: result.principal,
    humanUser: result.humanUser
  }
}

export async function listConsolePrincipalGroups(): Promise<ConsolePrincipalGroup[]> {
  const groups = await listPrincipalGroups()
  return Promise.all(
    groups.map(async group => {
      const [membership] = await DB.select({ count: sql<number>`count(*)::int` })
        .from(PrincipalGroupMemberships)
        .where(eq(PrincipalGroupMemberships.groupId, group.id))
      return {
        ...group,
        membershipCount: membership?.count ?? 0
      }
    })
  )
}

export async function createConsolePrincipalGroup(input: Parameters<typeof createPrincipalGroup>[0]) {
  return createPrincipalGroup(input)
}

export async function updateConsolePrincipalGroup(id: string, input: Parameters<typeof updatePrincipalGroup>[1]) {
  return updatePrincipalGroup(id, input)
}

export async function deleteConsolePrincipalGroup(id: string): Promise<void> {
  await deletePrincipalGroup(id)
}

export async function listConsoleLibrarySkills(): Promise<ConsoleLibrarySkill[]> {
  const skills = await DB.select()
    .from(LibrarySkills)
    .where(isNull(LibrarySkills.archivedAt))
    .orderBy(asc(LibrarySkills.name))
  return skills.map(projectLibrarySkill)
}

export async function listConsoleAgentSkills(agentUid: string): Promise<EffectiveSkillSummary[]> {
  await requireActiveAgent(agentUid)
  return listEffectiveSkills(agentUid)
}

export async function setConsoleAgentSkillAssignment(input: {
  agentUid: string
  skillName: string
  enabled: boolean
  reason?: string | null
}): Promise<void> {
  await requireActiveAgent(input.agentUid)
  await setAgentSkillEnabled(input)
}

export async function listConsoleAgentLibraryEntries(agentUid: string): Promise<ConsoleAgentLibraryEntry[]> {
  await requireActiveAgent(agentUid)
  return DB.select({
    id: AgentLibraryContainerEntries.id,
    agentUid: AgentLibraryContainerEntries.agentUid,
    virtualPath: AgentLibraryContainerEntries.virtualPath,
    entryKind: AgentLibraryContainerEntries.entryKind,
    sourceKind: AgentLibraryContainerEntries.sourceKind,
    enabled: AgentLibraryContainerEntries.enabled,
    version: AgentLibraryContainerEntries.version,
    contentMediaType: AgentLibraryContainerEntries.contentMediaType,
    contentText: AgentLibraryContainerEntries.contentText,
    createdAt: AgentLibraryContainerEntries.createdAt,
    updatedAt: AgentLibraryContainerEntries.updatedAt
  })
    .from(AgentLibraryContainerEntries)
    .where(eq(AgentLibraryContainerEntries.agentUid, agentUid))
    .orderBy(asc(AgentLibraryContainerEntries.virtualPath), desc(AgentLibraryContainerEntries.updatedAt))
}

export async function getConsoleAgentSoul(agentUid: string): Promise<{ content: string | null }> {
  await requireActiveAgent(agentUid)
  return { content: await getSoul(agentUid) }
}

export async function setConsoleAgentSoul(agentUid: string, content: string): Promise<{ content: string }> {
  await requireActiveAgent(agentUid)
  await setSoul(agentUid, content)
  return { content }
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
    metadata: writeAgentExternalBindings(agent.agent.metadata, nextBindings)
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

function projectLibrarySkill(skill: typeof LibrarySkills.$inferSelect): ConsoleLibrarySkill {
  const metadata = isJsonObject(skill.metadata) ? skill.metadata : {}
  const tags = Array.isArray(metadata.tags) ? metadata.tags.filter((tag): tag is string => typeof tag === 'string') : []
  return {
    id: skill.id,
    name: skill.name,
    description: skill.description,
    defaultEnabled: skill.defaultEnabled,
    enabled: skill.enabled,
    sourceKind: skill.sourceKind,
    rootPath: skill.rootPath,
    tags,
    category: typeof metadata.category === 'string' ? metadata.category : undefined,
    createdAt: skill.createdAt,
    updatedAt: skill.updatedAt
  }
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
  const models = readAiAgentModelsConfig(agent.agent.metadata)
  return {
    uid: agent.agent.uid,
    status: agent.principal.status,
    displayName: agent.principal.displayName,
    avatarUrl: agent.principal.avatarUrl,
    createdAt: agent.agent.createdAt,
    updatedAt: agent.agent.updatedAt,
    chatChannels: await projectConsoleExternalRooms(agent),
    llmProfile: models ? { models } : undefined
  }
}

async function agentMetadataWithLlmProfile(metadata: JsonObject, profile: ConsoleAgentLlmProfile): Promise<JsonObject> {
  await validateAiAgentModelsConfig(profile.models)
  return writeAiAgentModelsConfig(metadata, profile.models)
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
  bindings: AgentExternalBinding[],
  channelName: string,
  config: JsonObject
): Promise<void> {
  await appConfigService.setByKey(agentChannelConfigKey(agent.agent.uid, channelName), config)
  await updateAgent(agent.agent.uid, {
    metadata: writeAgentExternalBindings(agent.agent.metadata, bindings)
  })
}

async function loadChannelConfig(agentUid: string, channelName: string): Promise<JsonObject> {
  const value = await appConfigService.getByKey(agentChannelConfigKey(agentUid, channelName))
  return isJsonObject(value) ? cloneJsonObject(value) : {}
}

function readStoredChannelBindings(metadata: JsonObject): AgentExternalBinding[] {
  // Console manages disabled channels too, so it reads the full binding list and
  // reuses External Gateway's validation. Malformed metadata is a 422 here, not a
  // startup-style hard failure.
  try {
    return parseAgentExternalBindingsAll(metadata)
  } catch (error) {
    if (error instanceof AgentChatMetadataError) throw new ConsoleDomainError(422, error.message)
    throw error
  }
}

function readStoredChannelBindingsSafe(metadata: JsonObject): AgentExternalBinding[] {
  try {
    return readStoredChannelBindings(metadata)
  } catch {
    return []
  }
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

function isDatabaseErrorCode(error: unknown, code: string): boolean {
  if (typeof error !== 'object' || error === null) return false
  if ((error as { code?: unknown }).code === code) return true
  if ((error as { errno?: unknown }).errno === code) return true

  return isDatabaseErrorCode((error as { cause?: unknown }).cause, code)
}
