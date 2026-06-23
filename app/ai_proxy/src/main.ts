import { startAIProxyServer } from './server'

const runtime = await startAIProxyServer()

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.once(signal, async () => {
    await runtime.stop()
    process.exit(0)
  })
}
