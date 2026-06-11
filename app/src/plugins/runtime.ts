import type {
  BullXAppConfigDefinition,
  BullXAppConfigPatternDefinition,
  BullXExternalGatewayAdapterFactory,
  BullXIdentityProviderAdapterFactory,
  BullXPlugin,
  BullXWebProvider,
  BullXWebProviderFactoryContext
} from '@agentbull/bullx-sdk/plugins'
import { webProviderRegistry } from '@/ai-agent/web/registry'
import { AppEnv } from '@/config/env'
import type { Runtime } from '@/common/lifecycle'
import {
  appConfigService,
  registerAppConfigDefinitions,
  registerAppConfigPatterns,
  type AppConfigDefinition,
  type AppConfigPatternDefinition
} from '@/config/app-configure'
import {
  registerExternalGatewayAdapterFactory,
  type ExternalGatewayAdapterFactory
} from '@/external-gateway/adapter-registry'
import {
  registerIdentityProviderAdapterFactory,
  type IdentityProviderAdapterFactory
} from '@/principals/identity-providers/registry'
import { PluginEnabledOverridesConfig, type PluginEnabledOverrides } from './config'
import { discoverLocalPluginsDetailed, type DiscoveredPlugins, type PluginDiscoveryOptions } from './discovery'

const pluginIdPattern = /^[a-z][a-z0-9_-]*$/
export const defaultEnabledPluginIds = ['lark-adapter'] as const

/**
 * Default-enabled set = the static defaults plus every plugin discovered from an
 * auto-enabled (internal) root. Overrides can still disable any of them. Shared
 * by the runtime and the plugin catalog so both agree on what is on by default.
 */
export function effectiveDefaultEnabledPluginIds(
  autoEnabledPluginIds: readonly string[],
  base: readonly string[] = defaultEnabledPluginIds
): string[] {
  return [...new Set([...base, ...autoEnabledPluginIds])]
}

export interface PluginRegistry {
  plugins: readonly BullXPlugin[]
  pluginsById: ReadonlyMap<string, BullXPlugin>
  externalGatewayAdapterIds: readonly string[]
  identityProviderAdapterIds: readonly string[]
}

export interface PluginRuntimeStats {
  knownPlugins: number
  enabledPlugins: string[]
  registeredExternalGatewayAdapters: string[]
  registeredIdentityProviderAdapters: string[]
  registeredWebProviders: string[]
}

export interface PluginRuntimeStartOptions extends PluginDiscoveryOptions {
  defaultEnabledPluginIds?: readonly string[]
  /** Plugin ids to treat as auto-enabled when `plugins`/`discoverPlugins` are injected (bypassing real discovery). */
  autoEnabledPluginIds?: readonly string[]
  discoverPlugins?: (options?: PluginDiscoveryOptions) => Promise<readonly BullXPlugin[]>
  getEnabledOverrides?: () => Promise<PluginEnabledOverrides>
  plugins?: readonly BullXPlugin[]
  registerAppConfigDefinitions?: (definitions: readonly BullXAppConfigDefinition[]) => void
  registerAppConfigPatterns?: (definitions: readonly BullXAppConfigPatternDefinition[]) => void
  registerExternalGatewayAdapterFactory?: (factory: BullXExternalGatewayAdapterFactory) => void
  registerIdentityProviderAdapterFactory?: (factory: BullXIdentityProviderAdapterFactory) => void
  registerWebProvider?: (provider: BullXWebProvider) => void
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

export class DuplicatePluginExternalGatewayAdapterError extends Error {
  constructor(id: string) {
    super(`External Gateway adapter id is already provided by a plugin: ${id}`)
    this.name = 'DuplicatePluginExternalGatewayAdapterError'
  }
}

export class DuplicatePluginIdentityProviderAdapterError extends Error {
  constructor(id: string) {
    super(`Identity provider adapter id is already provided by a plugin: ${id}`)
    this.name = 'DuplicatePluginIdentityProviderAdapterError'
  }
}

export class PluginRuntime implements Runtime<PluginRuntimeStats> {
  private startedStats: PluginRuntimeStats | null = null

  async start(options: PluginRuntimeStartOptions = {}): Promise<PluginRuntimeStats> {
    if (this.startedStats) return this.startedStats

    const discovered: DiscoveredPlugins = options.plugins
      ? { plugins: [...options.plugins], autoEnabledPluginIds: [...(options.autoEnabledPluginIds ?? [])] }
      : options.discoverPlugins
        ? {
            plugins: [
              ...(await options.discoverPlugins({
                pluginRoots: options.pluginRoots,
                autoEnabledPluginRoots: options.autoEnabledPluginRoots
              }))
            ],
            autoEnabledPluginIds: [...(options.autoEnabledPluginIds ?? [])]
          }
        : await discoverLocalPluginsDetailed({
            pluginRoots: options.pluginRoots,
            autoEnabledPluginRoots: options.autoEnabledPluginRoots
          })
    const plugins = discovered.plugins
    const registry = buildPluginRegistry(plugins)
    const registerDefinitions = options.registerAppConfigDefinitions ?? registerHostAppConfigDefinitions
    const registerPatterns = options.registerAppConfigPatterns ?? registerHostAppConfigPatterns
    const registerAdapterFactory =
      options.registerExternalGatewayAdapterFactory ?? registerHostExternalGatewayAdapterFactory
    const registerIdentityProviderFactory =
      options.registerIdentityProviderAdapterFactory ?? registerHostIdentityProviderAdapterFactory
    const registerWebProvider = options.registerWebProvider ?? registerHostWebProvider
    const webProviderContext: BullXWebProviderFactoryContext = {
      getConfig: async key => {
        try {
          return await appConfigService.getByKey(key)
        } catch {
          return undefined
        }
      },
      getSecret: async key => {
        try {
          return await appConfigService.getByKey<string>(key)
        } catch {
          return undefined
        }
      },
      isProduction: AppEnv.NODE_ENV === 'production'
    }

    for (const plugin of registry.plugins) {
      if (plugin.appConfigDefinitions?.length) registerDefinitions(plugin.appConfigDefinitions)
      if (plugin.appConfigPatterns?.length) registerPatterns(plugin.appConfigPatterns)
    }

    const overrides =
      options.getEnabledOverrides !== undefined
        ? await options.getEnabledOverrides()
        : await appConfigService.get(PluginEnabledOverridesConfig)
    const enabledPluginIds = resolveEnabledPluginIds({
      defaultEnabledPluginIds: effectiveDefaultEnabledPluginIds(
        discovered.autoEnabledPluginIds,
        options.defaultEnabledPluginIds ?? defaultEnabledPluginIds
      ),
      overrides: overrides ?? {},
      registry
    })

    const registeredExternalGatewayAdapters: string[] = []
    const registeredIdentityProviderAdapters: string[] = []
    const registeredWebProviders: string[] = []
    for (const pluginId of enabledPluginIds) {
      const plugin = registry.pluginsById.get(pluginId)
      if (!plugin) continue

      for (const factory of plugin.externalGatewayAdapters ?? []) {
        registerAdapterFactory(factory)
        registeredExternalGatewayAdapters.push(factory.id)
      }

      for (const factory of plugin.identityProviderAdapters ?? []) {
        registerIdentityProviderFactory(factory)
        registeredIdentityProviderAdapters.push(factory.id)
      }

      for (const factory of plugin.webProviders ?? []) {
        registerWebProvider(await factory.create(webProviderContext))
        registeredWebProviders.push(factory.id)
      }
    }

    this.startedStats = {
      knownPlugins: registry.plugins.length,
      enabledPlugins: enabledPluginIds,
      registeredExternalGatewayAdapters,
      registeredIdentityProviderAdapters,
      registeredWebProviders
    }
    return this.startedStats
  }

  async stop(): Promise<void> {
    // Plugin activation is process-lifetime. There is no hot unload path because
    // plugin code is loaded by local discovery, and can only be disabled on restart.
  }
}

export function buildPluginRegistry(plugins: readonly BullXPlugin[]): PluginRegistry {
  const pluginsById = new Map<string, BullXPlugin>()
  const externalGatewayAdapterIds = new Set<string>()
  const identityProviderAdapterIds = new Set<string>()

  for (const plugin of plugins) {
    const id = plugin.metadata.id
    if (!pluginIdPattern.test(id)) throw new InvalidPluginIdError(id)
    if (pluginsById.has(id)) throw new DuplicatePluginIdError(id)
    pluginsById.set(id, plugin)

    for (const factory of plugin.externalGatewayAdapters ?? []) {
      if (externalGatewayAdapterIds.has(factory.id)) throw new DuplicatePluginExternalGatewayAdapterError(factory.id)
      externalGatewayAdapterIds.add(factory.id)
    }

    for (const factory of plugin.identityProviderAdapters ?? []) {
      if (identityProviderAdapterIds.has(factory.id)) throw new DuplicatePluginIdentityProviderAdapterError(factory.id)
      identityProviderAdapterIds.add(factory.id)
    }
  }

  return {
    plugins: [...plugins],
    pluginsById,
    externalGatewayAdapterIds: [...externalGatewayAdapterIds],
    identityProviderAdapterIds: [...identityProviderAdapterIds]
  }
}

export function resolveEnabledPluginIds(input: {
  defaultEnabledPluginIds: readonly string[]
  overrides: PluginEnabledOverrides
  registry: PluginRegistry
}): string[] {
  const enabled = new Set<string>()

  for (const id of input.defaultEnabledPluginIds) {
    enabled.add(id)
  }

  for (const [id, override] of Object.entries(input.overrides)) {
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

function registerHostExternalGatewayAdapterFactory(factory: BullXExternalGatewayAdapterFactory): void {
  registerExternalGatewayAdapterFactory(factory as ExternalGatewayAdapterFactory)
}

function registerHostIdentityProviderAdapterFactory(factory: BullXIdentityProviderAdapterFactory): void {
  registerIdentityProviderAdapterFactory(factory as IdentityProviderAdapterFactory)
}

function registerHostWebProvider(provider: BullXWebProvider): void {
  const search = provider.search
  const extract = provider.extract
  webProviderRegistry.register({
    id: provider.id,
    supports: provider.supports,
    available: kind => provider.available(kind),
    search: search ? (args, signal) => search(args, signal) : undefined,
    extract: extract ? (args, signal) => extract(args, signal) : undefined
  })
}

export const pluginRuntime = new PluginRuntime()
