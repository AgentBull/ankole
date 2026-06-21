import type {
  BullXIdentityProviderAdapterFactory,
  BullXIdentityProviderAdapterSetup
} from '@agentbull/bullx-sdk/plugins'
import { appConfigService } from '@/config/app-configure'
import { AppEnv } from '@/config/env'
import { loadPluginCatalog } from '@/plugins/catalog'
import { clonePluginJsonValue } from '@/plugins/config-json'
import { resolveIdentityProviderPublicBaseUrl } from '@/principals/admin-auth/oidc'
import { ActiveIdentityProvidersConfig, identityProviderConfigKey } from './config'
import { createNoopIdentityProviderSyncSink } from './noop-sync-sink'

/**
 * A plugin-advertised identity-provider adapter that is currently usable.
 *
 * `pluginId` is kept alongside the adapter `id` so the admin UI can show which
 * plugin an adapter came from, and so disabling a plugin removes its adapters.
 */
export interface IdentityProviderAdapterDescriptor {
  id: string
  pluginId: string
  setup?: BullXIdentityProviderAdapterSetup
}

/**
 * Lists adapters contributed by plugins that are enabled right now.
 *
 * Adapters live inside plugins, so the effective set is "adapters of enabled
 * plugins" rather than a static registry. A plugin that ships an adapter but is
 * disabled contributes nothing here.
 */
export async function listEnabledIdentityProviderAdapters(): Promise<IdentityProviderAdapterDescriptor[]> {
  const catalog = await loadPluginCatalog()
  const enabled = new Set(catalog.enabledPluginIds)
  const adapters: IdentityProviderAdapterDescriptor[] = []

  for (const plugin of catalog.plugins) {
    if (!enabled.has(plugin.metadata.id)) continue

    for (const adapter of plugin.identityProviderAdapters ?? []) {
      adapters.push({
        id: adapter.id,
        pluginId: plugin.metadata.id,
        setup: adapter.setup
      })
    }
  }

  return adapters
}

/**
 * Resolves the adapter factory for an id, but only across enabled plugins.
 *
 * Throws when the id belongs to a disabled or absent plugin. Enablement is
 * re-checked here (not cached) so an adapter that was turned off after activation
 * cannot still be instantiated.
 */
export async function getEnabledIdentityProviderAdapter(
  adapterId: string
): Promise<BullXIdentityProviderAdapterFactory> {
  const catalog = await loadPluginCatalog()
  const enabled = new Set(catalog.enabledPluginIds)

  for (const plugin of catalog.plugins) {
    if (!enabled.has(plugin.metadata.id)) continue

    const adapter = (plugin.identityProviderAdapters ?? []).find(candidate => candidate.id === adapterId)
    if (adapter) return adapter
  }

  throw new Error(`Identity provider adapter is not enabled: ${adapterId}`)
}

/**
 * Instantiates a configured identity-provider adapter for a login-shaped flow
 * (OIDC authorization/callback). Directory sync is a no-op sink here; the
 * long-running sync transport is owned by the identity-provider runtime.
 */
export async function createOidcLoginAdapter(providerId: string, request: Request) {
  const active = ((await appConfigService.get(ActiveIdentityProvidersConfig)) ?? []).find(
    provider => provider.providerId === providerId && provider.enabled !== false
  )
  if (!active) throw new Error(`Identity provider is not configured: ${providerId}`)

  const factory = await getEnabledIdentityProviderAdapter(active.adapter)
  const config = await appConfigService.getByKey(identityProviderConfigKey(providerId))
  // Derive the redirect base from the incoming request rather than a fixed
  // setting so login works behind whatever host/proxy the admin reached.
  const publicBaseUrl = await resolveIdentityProviderPublicBaseUrl(request)
  const adapter = await factory.create({
    providerId,
    // Hand the plugin its own copy so adapter code cannot mutate the cached,
    // decrypted app-config value held by the host.
    config: clonePluginJsonValue(config),
    publicBaseUrl,
    isProduction: AppEnv.IS_PRODUCTION,
    // This is a short-lived adapter built only to drive one OIDC exchange. The
    // real sync transport belongs to the long-running runtime, so any sync
    // callbacks fired during login are dropped instead of writing Principals.
    syncSink: createNoopIdentityProviderSyncSink()
  })

  return { active, adapter }
}
