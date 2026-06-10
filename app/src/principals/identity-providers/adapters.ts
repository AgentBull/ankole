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

export interface IdentityProviderAdapterDescriptor {
  id: string
  pluginId: string
  setup?: BullXIdentityProviderAdapterSetup
}

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
  const publicBaseUrl = await resolveIdentityProviderPublicBaseUrl(request)
  const adapter = await factory.create({
    providerId,
    config: clonePluginJsonValue(config),
    publicBaseUrl,
    isProduction: AppEnv.IS_PRODUCTION,
    syncSink: createNoopIdentityProviderSyncSink()
  })

  return { active, adapter }
}
