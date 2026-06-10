import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import path from 'node:path'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

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
