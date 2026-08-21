import { afterEach, describe, expect, test } from 'bun:test'
import { mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { BrowserDaemonSupervisor } from '../src/browser-runtime/daemon-supervisor'

const roots: string[] = []

afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

describe('browser daemon supervisor', () => {
  test('reports an early daemon exit without waiting for readiness timeout', async () => {
    const root = await mkdtemp('/tmp/ankole-browser-supervisor-')
    roots.push(root)
    const supervisor = new BrowserDaemonSupervisor({
      socketPath: join(root, 'socket', 'browser.sock'),
      daemonEntry: join(root, 'missing-daemon.js')
    })
    const startedAt = Date.now()

    await expect(supervisor.start()).rejects.toThrow('ankole-browserd exited before ready')
    expect(Date.now() - startedAt).toBeLessThan(2_000)
    await supervisor.stop()
  })
})
