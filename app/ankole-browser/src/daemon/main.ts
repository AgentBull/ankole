#!/usr/bin/env bun
import { BrowserDaemonServer } from './server'

const socketPath = process.env.ANKOLE_BROWSER_DAEMON_SOCKET?.trim()
if (!socketPath) {
  process.stderr.write('ANKOLE_BROWSER_DAEMON_SOCKET is required\n')
  process.exit(2)
}

const maxActiveBrowsers = positiveInteger(process.env.ANKOLE_BROWSER_MAX_ACTIVE_BROWSERS, 4)
const daemon = new BrowserDaemonServer(socketPath, maxActiveBrowsers)
let stopping = false

const stop = async (signal: string): Promise<void> => {
  if (stopping) return
  stopping = true
  await daemon.close().catch(error => {
    process.stderr.write(
      `browser daemon shutdown failed after ${signal}: ${error instanceof Error ? error.message : String(error)}\n`
    )
  })
}

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.once(signal, () => {
    void stop(signal).finally(() => process.exit(0))
  })
}

try {
  await daemon.listen()
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
  process.exit(1)
}

function positiveInteger(value: string | undefined, fallback: number): number {
  if (!value?.trim()) return fallback
  const parsed = Number(value)
  if (Number.isInteger(parsed) && parsed >= 1 && parsed <= 64) return parsed
  process.stderr.write('ANKOLE_BROWSER_MAX_ACTIVE_BROWSERS must be an integer from 1 to 64\n')
  process.exit(2)
}
