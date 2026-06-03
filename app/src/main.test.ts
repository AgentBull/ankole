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

    expect(events).toEqual(['runtime.start.begin', 'runtime.start.end', 'listen:31337:0'])
    expect(started.chatGateway).toEqual({ readyAgents: 2, readyChannels: 3 })
    expect(logs).toContainEqual({
      message: 'BullX Agent is running',
      data: {
        port: 31_337,
        env: 'test',
        idleTimeoutSeconds: 0,
        chatGateway: {
          readyAgents: 2,
          readyChannels: 3
        }
      }
    })

    await started.shutdown('SIGTERM')
    expect(events).toEqual([
      'runtime.start.begin',
      'runtime.start.end',
      'listen:31337:0',
      'runtime.stop',
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

    expect(events).toEqual(['runtime.start', 'runtime.stop', 'database.close'])
  })
})
