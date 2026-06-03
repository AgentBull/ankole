import type {
  BullXAppConfigDefinition,
  BullXAppConfigPatternDefinition,
  BullXChatGatewayAdapterFactory,
  BullXPlugin
} from '@agentbull/bullx-sdk/plugins'
import { rootContainer, singleton } from '@/common/di'
import {
  appConfigService,
  registerAppConfigDefinitions,
  registerAppConfigPatterns,
  type AppConfigDefinition,
  type AppConfigPatternDefinition
} from '@/config/app-configure'
import { registerChatGatewayAdapterFactory, type ChatGatewayAdapterFactory } from '@/chat-gateway/adapter-registry'
import { PluginEnabledOverridesConfig, type PluginEnabledOverrides } from './config'
import { discoverLocalPlugins, type PluginDiscoveryOptions } from './discovery'

const pluginIdPattern = /^[a-z][a-z0-9_-]*$/
export const defaultEnabledPluginIds = ['lark-adapter'] as const

export interface PluginRegistry {
  plugins: readonly BullXPlugin[]
  pluginsById: ReadonlyMap<string, BullXPlugin>
  chatGatewayAdapterIds: readonly string[]
}

export interface PluginRuntimeStats {
  knownPlugins: number
  enabledPlugins: string[]
  registeredChatGatewayAdapters: string[]
}

export interface PluginRuntimeStartOptions extends PluginDiscoveryOptions {
  defaultEnabledPluginIds?: readonly string[]
  discoverPlugins?: (options?: PluginDiscoveryOptions) => Promise<readonly BullXPlugin[]>
  getEnabledOverrides?: () => Promise<PluginEnabledOverrides>
  plugins?: readonly BullXPlugin[]
  registerAppConfigDefinitions?: (definitions: readonly BullXAppConfigDefinition[]) => void
  registerAppConfigPatterns?: (definitions: readonly BullXAppConfigPatternDefinition[]) => void
  registerChatGatewayAdapterFactory?: (factory: BullXChatGatewayAdapterFactory) => void
}

export class DuplicatePluginIdError extends Error {
  constructor(id: string) {
    super(`BullX plugin id is already registered: ${id}`)
    this.name = 'DuplicatePluginIdError'
  }
}

export class InvalidPluginIdError extends Error {
  constructor(id: string) {
    super(`BullX plugin id must match ${pluginIdPattern}: ${id}`)
    this.name = 'InvalidPluginIdError'
  }
}

export class DuplicatePluginChatGatewayAdapterError extends Error {
  constructor(id: string) {
    super(`Chat Gateway adapter id is already provided by a plugin: ${id}`)
    this.name = 'DuplicatePluginChatGatewayAdapterError'
  }
}

export class UnknownPluginOverrideError extends Error {
  constructor(id: string) {
    super(`Plugin enablement override references an unknown plugin: ${id}`)
    this.name = 'UnknownPluginOverrideError'
  }
}

export class UnknownDefaultPluginError extends Error {
  constructor(id: string) {
    super(`Default enabled plugin is not in the trusted plugin registry: ${id}`)
    this.name = 'UnknownDefaultPluginError'
  }
}

@singleton()
export class PluginRuntime {
  private startedStats: PluginRuntimeStats | null = null

  async start(options: PluginRuntimeStartOptions = {}): Promise<PluginRuntimeStats> {
    if (this.startedStats) return this.startedStats

    const plugins =
      options.plugins ??
      (await (options.discoverPlugins ?? discoverLocalPlugins)({
        pluginRoots: options.pluginRoots
      }))
    const registry = buildPluginRegistry(plugins)
    const registerDefinitions = options.registerAppConfigDefinitions ?? registerHostAppConfigDefinitions
    const registerPatterns = options.registerAppConfigPatterns ?? registerHostAppConfigPatterns
    const registerAdapterFactory = options.registerChatGatewayAdapterFactory ?? registerHostChatGatewayAdapterFactory

    for (const plugin of registry.plugins) {
      if (plugin.appConfigDefinitions?.length) registerDefinitions(plugin.appConfigDefinitions)
      if (plugin.appConfigPatterns?.length) registerPatterns(plugin.appConfigPatterns)
    }

    const overrides =
      options.getEnabledOverrides !== undefined
        ? await options.getEnabledOverrides()
        : await appConfigService.get(PluginEnabledOverridesConfig)
    const enabledPluginIds = resolveEnabledPluginIds({
      defaultEnabledPluginIds: options.defaultEnabledPluginIds ?? defaultEnabledPluginIds,
      overrides: overrides ?? {},
      registry
    })

    const registeredChatGatewayAdapters: string[] = []
    for (const pluginId of enabledPluginIds) {
      const plugin = registry.pluginsById.get(pluginId)
      if (!plugin) throw new UnknownPluginOverrideError(pluginId)

      for (const factory of plugin.chatGatewayAdapters ?? []) {
        registerAdapterFactory(factory)
        registeredChatGatewayAdapters.push(factory.id)
      }
    }

    this.startedStats = {
      knownPlugins: registry.plugins.length,
      enabledPlugins: enabledPluginIds,
      registeredChatGatewayAdapters
    }
    return this.startedStats
  }

  async stop(): Promise<void> {
    // Plugin activation is process-lifetime. There is no hot unload path because
    // plugin code is trusted, statically imported, and disabled only on restart.
  }
}

export function buildPluginRegistry(plugins: readonly BullXPlugin[]): PluginRegistry {
  const pluginsById = new Map<string, BullXPlugin>()
  const chatGatewayAdapterIds = new Set<string>()

  for (const plugin of plugins) {
    const id = plugin.metadata.id
    if (!pluginIdPattern.test(id)) throw new InvalidPluginIdError(id)
    if (pluginsById.has(id)) throw new DuplicatePluginIdError(id)
    pluginsById.set(id, plugin)

    for (const factory of plugin.chatGatewayAdapters ?? []) {
      if (chatGatewayAdapterIds.has(factory.id)) throw new DuplicatePluginChatGatewayAdapterError(factory.id)
      chatGatewayAdapterIds.add(factory.id)
    }
  }

  return {
    plugins: [...plugins],
    pluginsById,
    chatGatewayAdapterIds: [...chatGatewayAdapterIds]
  }
}

export function resolveEnabledPluginIds(input: {
  defaultEnabledPluginIds: readonly string[]
  overrides: PluginEnabledOverrides
  registry: PluginRegistry
}): string[] {
  const enabled = new Set<string>()

  for (const id of input.defaultEnabledPluginIds) {
    if (!input.registry.pluginsById.has(id)) throw new UnknownDefaultPluginError(id)
    enabled.add(id)
  }

  for (const [id, override] of Object.entries(input.overrides)) {
    if (!input.registry.pluginsById.has(id)) throw new UnknownPluginOverrideError(id)
    override ? enabled.add(id) : enabled.delete(id)
  }

  return input.registry.plugins.map(plugin => plugin.metadata.id).filter(id => enabled.has(id))
}

function registerHostAppConfigDefinitions(definitions: readonly BullXAppConfigDefinition[]): void {
  registerAppConfigDefinitions(definitions as readonly AppConfigDefinition[])
}

function registerHostAppConfigPatterns(definitions: readonly BullXAppConfigPatternDefinition[]): void {
  registerAppConfigPatterns(definitions as readonly AppConfigPatternDefinition[])
}

function registerHostChatGatewayAdapterFactory(factory: BullXChatGatewayAdapterFactory): void {
  registerChatGatewayAdapterFactory(factory as ChatGatewayAdapterFactory)
}

export const pluginRuntime = rootContainer.resolve(PluginRuntime)
