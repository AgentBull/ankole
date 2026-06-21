import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import path from 'node:path'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

// Point the plugin loader at the repo's real plugin tree so the test exercises
// the actual lark adapter rather than a fixture. The original PLUGIN_DIR is saved
// and restored in afterEach so this does not leak into other test files.
const pluginRoot = path.resolve(import.meta.dir, '../../../../plugin')
const originalPluginDir = Bun.env.PLUGIN_DIR
const { appConfigService } = await import('@/config/app-configure')
const { PluginEnabledOverridesConfig } = await import('@/plugins/config')
const { getEnabledIdentityProviderAdapter, listEnabledIdentityProviderAdapters } = await import('./adapters')

beforeEach(async () => {
  Bun.env.PLUGIN_DIR = pluginRoot
  await appConfigService.delete(PluginEnabledOverridesConfig)
})

afterEach(async () => {
  await appConfigService.delete(PluginEnabledOverridesConfig)
  if (originalPluginDir === undefined) delete Bun.env.PLUGIN_DIR
  else Bun.env.PLUGIN_DIR = originalPluginDir
})

describe('enabled identity provider adapters', () => {
  // Pins the core invariant that adapter availability is derived live from plugin
  // enablement: disabling the plugin via overrides must immediately hide its
  // adapter and make direct resolution throw, with no caching in between.
  it('only exposes adapters from plugins that are currently enabled', async () => {
    await expect(listEnabledIdentityProviderAdapters()).resolves.toEqual([
      expect.objectContaining({
        id: 'lark',
        pluginId: 'lark-adapter'
      })
    ])

    await appConfigService.set(PluginEnabledOverridesConfig, {
      'lark-adapter': false
    })

    await expect(listEnabledIdentityProviderAdapters()).resolves.toEqual([])
    await expect(getEnabledIdentityProviderAdapter('lark')).rejects.toThrow('Identity provider adapter is not enabled')
  })
})
