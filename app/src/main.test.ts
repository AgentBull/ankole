import 'reflect-metadata'
import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from './common/tests/load-test-env'

await loadTestEnvFiles()

const { startBullXAgent } = await import('./main')

describe('startBullXAgent', () => {
  it('starts Chat Gateway before listening and logs ready runtime stats', async () => {
    const events: string[] = []
    const logs: Array<{ data: unknown; message: string }> = []
    const started = await startBullXAgent({
      registerSignals: false,
      exitOnSignal: false,
      httpPort: 31_337,
      env: 'test',
      pluginRuntime: {
        async start() {
          events.push('plugins.start')
          return {
            knownPlugins: 1,
            enabledPlugins: ['lark-adapter'],
            registeredChatGatewayAdapters: ['lark']
          }
        },
        async stop() {
          events.push('plugins.stop')
        }
      },
      chatGatewayRuntime: {
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

    expect(events).toEqual(['plugins.start', 'runtime.start.begin', 'runtime.start.end', 'listen:31337:0'])
    expect(started.chatGateway).toEqual({ readyAgents: 2, readyChannels: 3 })
    expect(started.plugins).toEqual({
      knownPlugins: 1,
      enabledPlugins: ['lark-adapter'],
      registeredChatGatewayAdapters: ['lark']
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
          registeredChatGatewayAdapters: ['lark']
        },
        chatGateway: {
          readyAgents: 2,
          readyChannels: 3
        }
      }
    })

    await started.shutdown('SIGTERM')
    expect(events).toEqual([
      'plugins.start',
      'runtime.start.begin',
      'runtime.start.end',
      'listen:31337:0',
      'runtime.stop',
      'plugins.stop',
      'database.close'
    ])
  })

  it('does not listen if Chat Gateway startup fails', async () => {
    const events: string[] = []
    const error = new Error('startup failed')

    await expect(
      startBullXAgent({
        registerSignals: false,
        exitOnSignal: false,
        pluginRuntime: {
          async start() {
            events.push('plugins.start')
            return {
              knownPlugins: 0,
              enabledPlugins: [],
              registeredChatGatewayAdapters: []
            }
          },
          async stop() {
            events.push('plugins.stop')
          }
        },
        chatGatewayRuntime: {
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

    expect(events).toEqual(['plugins.start', 'runtime.start', 'runtime.stop', 'plugins.stop', 'database.close'])
  })

  it('does not start Chat Gateway or listen if plugin startup fails', async () => {
    const events: string[] = []
    const error = new Error('plugin startup failed')

    await expect(
      startBullXAgent({
        registerSignals: false,
        exitOnSignal: false,
        pluginRuntime: {
          async start() {
            events.push('plugins.start')
            throw error
          },
          async stop() {
            events.push('plugins.stop')
          }
        },
        chatGatewayRuntime: {
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

    expect(events).toEqual(['plugins.start', 'runtime.stop', 'plugins.stop', 'database.close'])
  })
})
