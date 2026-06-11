import { describe, expect, it } from 'bun:test'
import {
  defineBullXPlugin,
  type BullXExternalGatewayAdapter,
  type BullXExternalGatewayAdapterContext,
  type BullXExternalGatewayAdapterFactory,
  type BullXExternalGatewayWebhookOptions,
  type BullXIdentityProviderAdapterFactory
} from '@agentbull/bullx-sdk/plugins'
import { z } from 'zod'
import path from 'node:path'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const pluginRoot = path.resolve(import.meta.dir, '../../../plugin')
const { defaultAutoEnabledPluginRoots, defaultPluginRoots, discoverLocalPlugins, discoverLocalPluginsDetailed } =
  await import('./discovery')
const {
  buildPluginRegistry,
  DuplicatePluginExternalGatewayAdapterError,
  DuplicatePluginIdError,
  DuplicatePluginIdentityProviderAdapterError,
  effectiveDefaultEnabledPluginIds,
  PluginRuntime,
  resolveEnabledPluginIds,
  UnknownPluginOverrideError
} = await import('./runtime')

describe('plugin enablement', () => {
  it('starts from default plugins and applies operator overrides', () => {
    const registry = buildPluginRegistry([plugin('default-plugin'), plugin('future-plugin')])

    expect(
      resolveEnabledPluginIds({
        registry,
        defaultEnabledPluginIds: ['default-plugin'],
        overrides: {}
      })
    ).toEqual(['default-plugin'])

    expect(
      resolveEnabledPluginIds({
        registry,
        defaultEnabledPluginIds: ['default-plugin'],
        overrides: {
          'default-plugin': false
        }
      })
    ).toEqual([])

    expect(
      resolveEnabledPluginIds({
        registry,
        defaultEnabledPluginIds: ['default-plugin'],
        overrides: {
          'future-plugin': true
        }
      })
    ).toEqual(['default-plugin', 'future-plugin'])
  })

  it('rejects unknown override plugin ids', () => {
    const registry = buildPluginRegistry([plugin('default-plugin')])

    expect(() =>
      resolveEnabledPluginIds({
        registry,
        defaultEnabledPluginIds: ['default-plugin'],
        overrides: {
          missing: true
        }
      })
    ).toThrow(UnknownPluginOverrideError)
  })
})

describe('plugin registry validation', () => {
  it('rejects duplicate plugin ids', () => {
    expect(() => buildPluginRegistry([plugin('duplicate'), plugin('duplicate')])).toThrow(DuplicatePluginIdError)
  })

  it('rejects duplicate External Gateway adapter factory ids', () => {
    expect(() =>
      buildPluginRegistry([plugin('first', [adapterFactory('shared')]), plugin('second', [adapterFactory('shared')])])
    ).toThrow(DuplicatePluginExternalGatewayAdapterError)
  })

  it('rejects duplicate identity provider adapter factory ids', () => {
    expect(() =>
      buildPluginRegistry([
        plugin('first', [], [identityProviderFactory('shared')]),
        plugin('second', [], [identityProviderFactory('shared')])
      ])
    ).toThrow(DuplicatePluginIdentityProviderAdapterError)
  })
})

describe('PluginRuntime', () => {
  it('uses PLUGIN_DIR as the only default plugin root', () => {
    const previousPluginDir = Bun.env.PLUGIN_DIR
    Bun.env.PLUGIN_DIR = '../plugin'

    try {
      expect(defaultPluginRoots()).toEqual([path.resolve(process.cwd(), '../plugin')])
    } finally {
      if (previousPluginDir === undefined) {
        delete Bun.env.PLUGIN_DIR
      } else {
        Bun.env.PLUGIN_DIR = previousPluginDir
      }
    }
  })

  it('discovers local plugins from PLUGIN_DIR by default', async () => {
    const previousPluginDir = Bun.env.PLUGIN_DIR
    Bun.env.PLUGIN_DIR = pluginRoot

    try {
      const plugins = await discoverLocalPlugins()
      expect(plugins.map(plugin => plugin.metadata.id)).toContain('lark-adapter')
    } finally {
      if (previousPluginDir === undefined) {
        delete Bun.env.PLUGIN_DIR
      } else {
        Bun.env.PLUGIN_DIR = previousPluginDir
      }
    }
  })

  it('registers config definitions for known plugins before filtering enabled plugins', async () => {
    const registeredDefinitions: string[] = []
    const registeredFactories: string[] = []
    const configDefinition = {
      key: 'test.plugin.config',
      encrypted: false,
      schema: z.string()
    }

    const runtime = new PluginRuntime()
    const stats = await runtime.start({
      plugins: [
        defineBullXPlugin({
          metadata: { id: 'config-plugin', apiVersion: 1 },
          appConfigDefinitions: [configDefinition],
          externalGatewayAdapters: [adapterFactory('config_plugin')]
        })
      ],
      defaultEnabledPluginIds: [],
      getEnabledOverrides: async () => ({}),
      registerAppConfigDefinitions: definitions => {
        registeredDefinitions.push(...definitions.map(definition => definition.key))
      },
      registerExternalGatewayAdapterFactory: factory => {
        registeredFactories.push(factory.id)
      }
    })

    expect(stats).toEqual({
      knownPlugins: 1,
      enabledPlugins: [],
      registeredExternalGatewayAdapters: [],
      registeredIdentityProviderAdapters: [],
      registeredWebProviders: []
    })
    expect(registeredDefinitions).toEqual(['test.plugin.config'])
    expect(registeredFactories).toEqual([])
  })

  it('does not register lark factory when lark-adapter is disabled', async () => {
    const registeredFactories: string[] = []
    const runtime = new PluginRuntime()

    const stats = await runtime.start({
      pluginRoots: [pluginRoot],
      defaultEnabledPluginIds: ['lark-adapter'],
      getEnabledOverrides: async () => ({ 'lark-adapter': false }),
      registerAppConfigPatterns: () => {},
      registerExternalGatewayAdapterFactory: factory => {
        registeredFactories.push(factory.id)
      }
    })

    expect(stats.enabledPlugins).toEqual([])
    expect(registeredFactories).toEqual([])
  })

  it('registers lark factory and validates required app config before opening transport', async () => {
    const registeredFactories: BullXExternalGatewayAdapterFactory[] = []
    const registeredIdentityFactories: BullXIdentityProviderAdapterFactory[] = []
    const registeredPatterns: Array<{ id: string; encrypted: boolean; keyPattern: RegExp }> = []
    const runtime = new PluginRuntime()

    const stats = await runtime.start({
      pluginRoots: [pluginRoot],
      defaultEnabledPluginIds: ['lark-adapter'],
      getEnabledOverrides: async () => ({}),
      registerAppConfigPatterns: patterns => {
        registeredPatterns.push(...patterns)
      },
      registerExternalGatewayAdapterFactory: factory => {
        registeredFactories.push(factory)
      },
      registerIdentityProviderAdapterFactory: factory => {
        registeredIdentityFactories.push(factory)
      }
    })

    expect(stats.enabledPlugins).toEqual(['lark-adapter'])
    expect(stats.registeredExternalGatewayAdapters).toEqual(['lark'])
    expect(stats.registeredIdentityProviderAdapters).toEqual(['lark'])
    expect(registeredFactories.map(factory => factory.id)).toEqual(['lark'])
    expect(registeredIdentityFactories.map(factory => factory.id)).toEqual(['lark'])
    expect(registeredPatterns).toEqual([])
    expect(() =>
      registeredFactories[0]!.create({
        agent: {},
        channel: {
          adapter: 'lark',
          enabled: true,
          name: 'lark'
        },
        config: {}
      })
    ).toThrow('Invalid Lark adapter config for channel lark')

    const adapter = await registeredFactories[0]!.create({
      agent: {},
      channel: {
        adapter: 'lark',
        enabled: true,
        name: 'lark'
      },
      config: {
        appId: 'cli_test',
        appSecret: 'secret',
        group_message_mode: 'observe_all',
        platformSubjectNamespace: 'lark-main',
        userName: 'BullX'
      }
    })

    expect(adapter.name).toBe('lark')

    expect(() =>
      registeredIdentityFactories[0]!.create({
        providerId: 'lark-main',
        config: {
          appId: 'cli_test',
          appSecret: 'secret'
        },
        isProduction: true,
        syncSink: identityProviderSink()
      })
    ).toThrow('admin_auth.public_base_url is required for Lark OIDC provider lark-main')

    expect(
      registeredIdentityFactories[0]!.create({
        providerId: 'lark-main',
        config: {
          appId: 'cli_test',
          appSecret: 'secret'
        },
        isProduction: false,
        syncSink: identityProviderSink()
      })
    ).toHaveProperty('fullSync')
  })
})

describe('auto-enabled internal plugins', () => {
  it('resolves default plugin ids and auto-enabled plugin roots from operator configuration', () => {
    expect(effectiveDefaultEnabledPluginIds(['internal-a', 'lark-adapter'], ['lark-adapter'])).toEqual([
      'lark-adapter',
      'internal-a'
    ])

    const previous = Bun.env.INTERNAL_PLUGIN_DIR
    delete Bun.env.INTERNAL_PLUGIN_DIR

    try {
      expect(defaultAutoEnabledPluginRoots()).toEqual([])
      Bun.env.INTERNAL_PLUGIN_DIR = '../internals/plugins'
      expect(defaultAutoEnabledPluginRoots()).toEqual([path.resolve(process.cwd(), '../internals/plugins')])
    } finally {
      if (previous === undefined) delete Bun.env.INTERNAL_PLUGIN_DIR
      else Bun.env.INTERNAL_PLUGIN_DIR = previous
    }
  })

  it('flags plugins discovered from auto-enabled roots', async () => {
    const result = await discoverLocalPluginsDetailed({ pluginRoots: [], autoEnabledPluginRoots: [pluginRoot] })

    expect(result.plugins.map(discovered => discovered.metadata.id)).toContain('lark-adapter')
    expect(result.autoEnabledPluginIds).toContain('lark-adapter')
  })

  it('enables internal plugins by default while still allowing explicit disable overrides', async () => {
    const runtime = new PluginRuntime()
    const stats = await runtime.start({
      plugins: [defineBullXPlugin({ metadata: { id: 'internal-plugin', apiVersion: 1 } })],
      autoEnabledPluginIds: ['internal-plugin'],
      defaultEnabledPluginIds: [],
      getEnabledOverrides: async () => ({})
    })

    expect(stats.enabledPlugins).toEqual(['internal-plugin'])

    const disabledRuntime = new PluginRuntime()
    const disabledStats = await disabledRuntime.start({
      plugins: [defineBullXPlugin({ metadata: { id: 'internal-plugin', apiVersion: 1 } })],
      autoEnabledPluginIds: ['internal-plugin'],
      defaultEnabledPluginIds: [],
      getEnabledOverrides: async () => ({ 'internal-plugin': false })
    })

    expect(disabledStats.enabledPlugins).toEqual([])
  })

  it('does not throw when an auto-enabled root is absent', async () => {
    const runtime = new PluginRuntime()
    const stats = await runtime.start({
      pluginRoots: [path.resolve(import.meta.dir, '../../../missing-plugin-dir')],
      autoEnabledPluginRoots: [path.resolve(import.meta.dir, '../../../missing-internals/plugins')],
      defaultEnabledPluginIds: [],
      getEnabledOverrides: async () => ({})
    })

    expect(stats.knownPlugins).toBe(0)
    expect(stats.enabledPlugins).toEqual([])
  })
})

function plugin(
  id: string,
  externalGatewayAdapters: readonly BullXExternalGatewayAdapterFactory[] = [],
  identityProviderAdapters: readonly BullXIdentityProviderAdapterFactory[] = []
) {
  return defineBullXPlugin({
    metadata: {
      id,
      apiVersion: 1
    },
    externalGatewayAdapters,
    identityProviderAdapters
  })
}

function adapterFactory(id: string): BullXExternalGatewayAdapterFactory {
  return {
    id,
    create: () => new TestAdapter(id)
  }
}

function identityProviderFactory(id: string): BullXIdentityProviderAdapterFactory {
  return {
    id,
    create: () => ({})
  }
}

function identityProviderSink() {
  return {
    applyFullSync: async () => {},
    upsertUser: async () => {},
    disableUser: async () => {},
    upsertGroup: async () => {},
    deleteGroup: async () => {},
    requestFullSync: async () => {}
  }
}

class TestAdapter implements BullXExternalGatewayAdapter {
  readonly userName = 'Test'

  constructor(readonly name: string) {}

  async initialize(_context: BullXExternalGatewayAdapterContext): Promise<void> {}

  async handleWebhook(_request: Request, _options?: BullXExternalGatewayWebhookOptions): Promise<Response> {
    return new Response('ok')
  }

  parseMessage() {
    return {
      id: 'test',
      threadId: `${this.name}:channel:thread`,
      text: 'test',
      formatted: { type: 'root', children: [] } as never,
      raw: {},
      author: {
        userId: 'user',
        userName: 'user',
        fullName: 'User',
        isBot: false,
        isMe: false
      },
      metadata: {
        dateSent: new Date()
      },
      attachments: []
    }
  }

  channelIdFromThreadId(threadId: string): string {
    return threadId.split(':').slice(0, 2).join(':')
  }

  decodeThreadId(threadId: string): string {
    return threadId
  }

  encodeThreadId(threadId: string): string {
    return threadId
  }

  async fetchThread(threadId: string) {
    return {
      id: threadId,
      channelId: this.channelIdFromThreadId(threadId),
      isDM: false,
      metadata: {}
    }
  }

  async postMessage(threadId: string, message: unknown) {
    return {
      id: `${this.name}-message`,
      threadId,
      raw: message
    }
  }

  async deleteMessage(): Promise<void> {}

  async addReaction(): Promise<void> {}

  async removeReaction(): Promise<void> {}

  renderFormatted(): string {
    return ''
  }
}
