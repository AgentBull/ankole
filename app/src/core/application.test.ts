import 'reflect-metadata'
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '../common/tests/load-test-env'

await loadTestEnvFiles()

const { startBullXAgent } = await import('./application')

describe('startBullXAgent', () => {
  it('starts External Gateway before realtime identity providers and listening', async () => {
    const events: string[] = []
    const logs: Array<{ data: unknown; message: string }> = []
    const started = await startBullXAgent({
      registerSignals: false,
      exitOnSignal: false,
      httpPort: 31_337,
      env: 'test',
      async initializeSetupBootstrap() {
        events.push('setup.init')
        return { completed: false }
      },
      pluginRuntime: {
        async start() {
          events.push('plugins.start')
          return {
            knownPlugins: 1,
            enabledPlugins: ['lark-adapter'],
            registeredExternalGatewayAdapters: ['lark'],
            registeredIdentityProviderAdapters: ['lark']
          }
        },
        async stop() {
          events.push('plugins.stop')
        }
      },
      identityProviderRuntime: {
        async start() {
          events.push('identity.start')
          return {
            activeProviders: ['lark-main'],
            startedProviders: ['lark-main'],
            degradedProviders: []
          }
        },
        async stop() {
          events.push('identity.stop')
        }
      },
      externalGatewayRuntime: {
        async start() {
          events.push('runtime.start.begin')
          await Bun.sleep(1)
          events.push('runtime.start.end')
          return {
            readyAgents: 2,
            readyChannels: 3
          }
        },
        async stop() {
          events.push('runtime.stop')
        }
      },
      webServer: {
        listen(options) {
          events.push(`listen:${options.port}:${options.idleTimeout}`)
        }
      },
      closeDatabase: async () => {
        events.push('database.close')
      },
      logger: {
        info(data, message) {
          logs.push({ data, message })
        },
        error(data, message) {
          logs.push({ data, message })
        }
      }
    })

    expect(events).toEqual([
      'setup.init',
      'plugins.start',
      'runtime.start.begin',
      'runtime.start.end',
      'identity.start',
      'listen:31337:0'
    ])
    expect(started.externalGateway).toEqual({ readyAgents: 2, readyChannels: 3 })
    expect(started.plugins).toEqual({
      knownPlugins: 1,
      enabledPlugins: ['lark-adapter'],
      registeredExternalGatewayAdapters: ['lark'],
      registeredIdentityProviderAdapters: ['lark']
    })
    expect(logs).toContainEqual({
      message: 'BullX Agent is running',
      data: {
        port: 31_337,
        env: 'test',
        idleTimeoutSeconds: 0,
        plugins: {
          knownPlugins: 1,
          enabledPlugins: ['lark-adapter'],
          registeredExternalGatewayAdapters: ['lark'],
          registeredIdentityProviderAdapters: ['lark']
        },
        identityProviders: {
          activeProviders: ['lark-main'],
          startedProviders: ['lark-main'],
          degradedProviders: []
        },
        externalGateway: {
          readyAgents: 2,
          readyChannels: 3
        },
        setup: {
          completed: false
        }
      }
    })

    await started.shutdown('SIGTERM')
    expect(events).toEqual([
      'setup.init',
      'plugins.start',
      'runtime.start.begin',
      'runtime.start.end',
      'identity.start',
      'listen:31337:0',
      'identity.stop',
      'runtime.stop',
      'plugins.stop',
      'database.close'
    ])
  })

  it('does not listen if External Gateway startup fails', async () => {
    const events: string[] = []
    const error = new Error('startup failed')

    await expect(
      startBullXAgent({
        registerSignals: false,
        exitOnSignal: false,
        async initializeSetupBootstrap() {
          events.push('setup.init')
          return { completed: false }
        },
        pluginRuntime: {
          async start() {
            events.push('plugins.start')
            return {
              knownPlugins: 0,
              enabledPlugins: [],
              registeredExternalGatewayAdapters: [],
              registeredIdentityProviderAdapters: []
            }
          },
          async stop() {
            events.push('plugins.stop')
          }
        },
        identityProviderRuntime: {
          async start() {
            events.push('identity.start')
            return {
              activeProviders: [],
              startedProviders: [],
              degradedProviders: []
            }
          },
          async stop() {
            events.push('identity.stop')
          }
        },
        externalGatewayRuntime: {
          async start() {
            events.push('runtime.start')
            throw error
          },
          async stop() {
            events.push('runtime.stop')
          }
        },
        webServer: {
          listen() {
            events.push('listen')
          }
        },
        closeDatabase: async () => {
          events.push('database.close')
        },
        logger: {
          info() {},
          error() {}
        }
      })
    ).rejects.toThrow(error)

    expect(events).toEqual([
      'setup.init',
      'plugins.start',
      'runtime.start',
      'runtime.stop',
      'plugins.stop',
      'database.close'
    ])
  })

  it('does not listen if realtime identity-provider startup fails', async () => {
    const events: string[] = []
    const error = new Error('identity startup failed')

    await expect(
      startBullXAgent({
        registerSignals: false,
        exitOnSignal: false,
        async initializeSetupBootstrap() {
          events.push('setup.init')
          return { completed: false }
        },
        pluginRuntime: {
          async start() {
            events.push('plugins.start')
            return {
              knownPlugins: 0,
              enabledPlugins: [],
              registeredExternalGatewayAdapters: [],
              registeredIdentityProviderAdapters: []
            }
          },
          async stop() {
            events.push('plugins.stop')
          }
        },
        identityProviderRuntime: {
          async start() {
            events.push('identity.start')
            throw error
          },
          async stop() {
            events.push('identity.stop')
          }
        },
        externalGatewayRuntime: {
          async start() {
            events.push('runtime.start')
            return {
              readyAgents: 0,
              readyChannels: 0
            }
          },
          async stop() {
            events.push('runtime.stop')
          }
        },
        webServer: {
          listen() {
            events.push('listen')
          }
        },
        closeDatabase: async () => {
          events.push('database.close')
        },
        logger: {
          info() {},
          error() {}
        }
      })
    ).rejects.toThrow(error)

    expect(events).toEqual([
      'setup.init',
      'plugins.start',
      'runtime.start',
      'identity.start',
      'identity.stop',
      'runtime.stop',
      'plugins.stop',
      'database.close'
    ])
  })

  it('does not start External Gateway or listen if plugin startup fails', async () => {
    const events: string[] = []
    const error = new Error('plugin startup failed')

    await expect(
      startBullXAgent({
        registerSignals: false,
        exitOnSignal: false,
        async initializeSetupBootstrap() {
          events.push('setup.init')
          return { completed: false }
        },
        pluginRuntime: {
          async start() {
            events.push('plugins.start')
            throw error
          },
          async stop() {
            events.push('plugins.stop')
          }
        },
        identityProviderRuntime: {
          async start() {
            events.push('identity.start')
            return {
              activeProviders: [],
              startedProviders: [],
              degradedProviders: []
            }
          },
          async stop() {
            events.push('identity.stop')
          }
        },
        externalGatewayRuntime: {
          async start() {
            events.push('runtime.start')
            return {
              readyAgents: 0,
              readyChannels: 0
            }
          },
          async stop() {
            events.push('runtime.stop')
          }
        },
        webServer: {
          listen() {
            events.push('listen')
          }
        },
        closeDatabase: async () => {
          events.push('database.close')
        },
        logger: {
          info() {},
          error() {}
        }
      })
    ).rejects.toThrow(error)

    expect(events).toEqual(['setup.init', 'plugins.start', 'plugins.stop', 'database.close'])
  })
})
