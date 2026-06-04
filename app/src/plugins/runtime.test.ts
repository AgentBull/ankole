import 'reflect-metadata'
import { describe, expect, it } from 'bun:test'
import { Message, type Adapter, type ChatInstance, type WebhookOptions } from 'chat'
import {
  defineBullXPlugin,
  type BullXChatGatewayAdapterFactory,
  type BullXIdentityProviderAdapterFactory
} from '@agentbull/bullx-sdk/plugins'
import { z } from 'zod'
import path from 'node:path'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const pluginRoot = path.resolve(import.meta.dir, '../../../plugin')
const { defaultPluginRoots, discoverLocalPlugins, discoverPluginEntryPaths } = await import('./discovery')
const {
  buildPluginRegistry,
  DuplicatePluginChatGatewayAdapterError,
  DuplicatePluginIdError,
  DuplicatePluginIdentityProviderAdapterError,
  PluginRuntime,
  resolveEnabledPluginIds,
  UnknownPluginOverrideError
} = await import('./runtime')

describe('plugin enablement', () => {
  it('enables default plugins without overrides', () => {
    const registry = buildPluginRegistry([plugin('default-plugin'), plugin('future-plugin')])

    expect(
      resolveEnabledPluginIds({
        registry,
        defaultEnabledPluginIds: ['default-plugin'],
        overrides: {}
      })
    ).toEqual(['default-plugin'])
  })

  it('applies false overrides to disable default plugins', () => {
    const registry = buildPluginRegistry([plugin('default-plugin'), plugin('future-plugin')])

    expect(
      resolveEnabledPluginIds({
        registry,
        defaultEnabledPluginIds: ['default-plugin'],
        overrides: {
          'default-plugin': false
        }
      })
    ).toEqual([])
  })

  it('applies true overrides to enable known non-default plugins', () => {
    const registry = buildPluginRegistry([plugin('default-plugin'), plugin('future-plugin')])

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

  it('rejects duplicate Chat Gateway adapter factory ids', () => {
    expect(() =>
      buildPluginRegistry([plugin('first', [adapterFactory('shared')]), plugin('second', [adapterFactory('shared')])])
    ).toThrow(DuplicatePluginChatGatewayAdapterError)
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

  it('discovers local plugin entries by scanning the configured plugin directory', async () => {
    const entryPaths = await discoverPluginEntryPaths([pluginRoot])
    expect(entryPaths.some(entryPath => entryPath.endsWith('plugin/lark-adapter/src/index.ts'))).toBe(true)

    const plugins = await discoverLocalPlugins({ pluginRoots: [pluginRoot] })
    expect(plugins.map(plugin => plugin.metadata.id)).toContain('lark-adapter')
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
          chatGatewayAdapters: [adapterFactory('config_plugin')]
        })
      ],
      defaultEnabledPluginIds: [],
      getEnabledOverrides: async () => ({}),
      registerAppConfigDefinitions: definitions => {
        registeredDefinitions.push(...definitions.map(definition => definition.key))
      },
      registerChatGatewayAdapterFactory: factory => {
        registeredFactories.push(factory.id)
      }
    })

    expect(stats).toEqual({
      knownPlugins: 1,
      enabledPlugins: [],
      registeredChatGatewayAdapters: [],
      registeredIdentityProviderAdapters: []
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
      registerChatGatewayAdapterFactory: factory => {
        registeredFactories.push(factory.id)
      }
    })

    expect(stats.enabledPlugins).toEqual([])
    expect(registeredFactories).toEqual([])
  })

  it('registers lark factory and validates required app config before opening transport', async () => {
    const registeredFactories: BullXChatGatewayAdapterFactory[] = []
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
      registerChatGatewayAdapterFactory: factory => {
        registeredFactories.push(factory)
      },
      registerIdentityProviderAdapterFactory: factory => {
        registeredIdentityFactories.push(factory)
      }
    })

    expect(stats.enabledPlugins).toEqual(['lark-adapter'])
    expect(stats.registeredChatGatewayAdapters).toEqual(['lark'])
    expect(stats.registeredIdentityProviderAdapters).toEqual(['lark'])
    expect(registeredFactories.map(factory => factory.id)).toEqual(['lark'])
    expect(registeredIdentityFactories.map(factory => factory.id)).toEqual(['lark'])
    expect(registeredPatterns).toEqual([
      expect.objectContaining({
        id: 'identity_providers.lark',
        encrypted: true
      })
    ])
    expect(registeredPatterns[0]!.keyPattern.test('identity_providers.lark.lark-main')).toBe(true)
    expect(() =>
      registeredFactories[0]!.create({
        agent: {},
        channel: {
          adapter: 'lark',
          enabled: true,
          name: 'lark'
        },
        config: {},
        projection: {}
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
        platformProviderId: 'lark-main',
        userName: 'BullX'
      },
      projection: {}
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

function plugin(
  id: string,
  chatGatewayAdapters: readonly BullXChatGatewayAdapterFactory[] = [],
  identityProviderAdapters: readonly BullXIdentityProviderAdapterFactory[] = []
) {
  return defineBullXPlugin({
    metadata: {
      id,
      apiVersion: 1
    },
    chatGatewayAdapters,
    identityProviderAdapters
  })
}

function adapterFactory(id: string): BullXChatGatewayAdapterFactory {
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

class TestAdapter implements Adapter {
  readonly userName = 'Test'

  constructor(readonly name: string) {}

  async initialize(_chat: ChatInstance): Promise<void> {}

  async handleWebhook(_request: Request, _options?: WebhookOptions): Promise<Response> {
    return new Response('ok')
  }

  parseMessage(): Message {
    return new Message({
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
        dateSent: new Date(),
        edited: false
      },
      attachments: []
    })
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

  async fetchMessages() {
    return { messages: [] }
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

  async editMessage(threadId: string, messageId: string, message: unknown) {
    return {
      id: messageId,
      threadId,
      raw: message
    }
  }

  async deleteMessage(): Promise<void> {}

  async addReaction(): Promise<void> {}

  async removeReaction(): Promise<void> {}

  async startTyping(): Promise<void> {}

  renderFormatted(): string {
    return ''
  }
}
