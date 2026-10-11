import { afterEach, describe, expect, test } from 'bun:test'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { BrowserDaemonSupervisor, type BrowserDaemonEvent } from '../src/browser-runtime/daemon-supervisor'

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

  test('starts no daemon after stop() comes while a start is preparing', async () => {
    const root = await mkdtemp('/tmp/ankole-browser-supervisor-')
    roots.push(root)
    // A daemon that listens on the socket and runs until it is stopped.
    const daemonEntry = join(root, 'daemon.mjs')
    await writeFile(
      daemonEntry,
      `import { createServer } from 'node:net'
createServer().listen(process.env.ANKOLE_BROWSER_DAEMON_SOCKET)
setInterval(() => undefined, 1_000)
`
    )
    const events: BrowserDaemonEvent[] = []
    const supervisor = new BrowserDaemonSupervisor({
      socketPath: join(root, 'socket', 'browser.sock'),
      daemonEntry,
      onEvent: event => events.push(event)
    })

    const starting = supervisor.start()
    await supervisor.stop()
    try {
      await starting
      await Bun.sleep(200)
      expect(events.filter(event => event.kind === 'started')).toEqual([])
    } finally {
      for (const event of events) if (event.kind === 'started' && event.pid) process.kill(event.pid, 'SIGKILL')
    }
  })
})
