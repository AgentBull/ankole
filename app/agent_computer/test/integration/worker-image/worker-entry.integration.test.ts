import { afterEach, describe, expect, it } from 'bun:test'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// These tests run as root in the Worker image, like the entrypoint on
// Cloudflare. The entrypoint starts the supervisor that the image installs.
if (process.platform !== 'linux' || !existsSync('/etc/ankole-agent-computer-container')) {
  throw new Error('Worker entrypoint tests require the Worker image. Run `bun run test:integration:docker`.')
}
const scripts = join(import.meta.dir, '..', '..', '..', 'scripts')
const entryPath = join(scripts, 'ankole-worker-entry.sh')
const supervisorPath = join(scripts, 'ankole-worker-supervisor.sh')
const restoredHome = '/var/lib/ankole/agent-home-restored'
const credential = 'entry-test-credential'
const cleanups: Array<() => void> = []

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup()
  rmSync(restoredHome, { force: true })
})

type RestoreReply = 'ok' | 'fail' | 'hold'

describe('Worker entrypoint with adapter storage (WP 3.4)', () => {
  it('restores a disk without the marker, marks it, and backs up the Home after the Worker', async () => {
    const adapter = fakeAdapter('ok')
    const worker = fakeWorker()

    const entry = startEntry(adapter.url, worker)

    expect(await entry.exited).toBe(0)
    expect(adapter.requests).toEqual([
      ['restore', `Bearer ${credential}`],
      ['backup', `Bearer ${credential}`]
    ])
    expect(runs(worker)).toBe(1)
    expect(existsSync(restoredHome)).toBeTrue()
  })

  it('does not restore again on a disk that holds the marker', async () => {
    // The supervisor or the container process started again on the same disk.
    markRestored()
    const adapter = fakeAdapter('ok')
    const worker = fakeWorker()

    const entry = startEntry(adapter.url, worker)

    expect(await entry.exited).toBe(0)
    expect(adapter.requests.map(([route]) => route)).toEqual(['backup'])
    expect(runs(worker)).toBe(1)
  })

  it('starts no Worker and requests no backup after a failed restore', async () => {
    const adapter = fakeAdapter('fail')
    const worker = fakeWorker()

    const entry = startEntry(adapter.url, worker)

    expect(await entry.exited).not.toBe(0)
    expect(adapter.requests.map(([route]) => route)).toEqual(['restore'])
    expect(runs(worker)).toBe(0)
    expect(existsSync(restoredHome)).toBeFalse()
  })

  for (const [signal, status] of [
    ['SIGTERM', 143],
    ['SIGUSR1', 138]
  ] as const) {
    it(`stops at ${signal} during the restore and starts no Worker`, async () => {
      const adapter = fakeAdapter('hold')
      const worker = fakeWorker()
      const entry = startEntry(adapter.url, worker)
      await adapter.restoreReceived

      const signalledAt = performance.now()
      process.kill(entry.pid, signal)

      // A trap ends the script. Without a trap, bash as PID 1 ignores the
      // signal; outside PID 1 the signal kills bash, and curl stays.
      expect(await entry.exited).toBe(status)
      expect(entry.signalCode).toBeNull()
      await adapter.restoreAborted
      expect(performance.now() - signalledAt).toBeLessThan(2_000)
      expect(adapter.requests.map(([route]) => route)).toEqual(['restore'])
      expect(runs(worker)).toBe(0)
      expect(existsSync(restoredHome)).toBeFalse()
    })
  }

  it('refuses a backup from a disk without a restored Home', async () => {
    const adapter = fakeAdapter('ok')
    const worker = fakeWorker()

    const supervisor = Bun.spawn(['bash', supervisorPath, worker.script], {
      env: adapterEnv(adapter.url, worker.agent),
      stdout: 'ignore',
      stderr: 'pipe'
    })

    expect(await supervisor.exited).toBe(1)
    expect(await new Response(supervisor.stderr).text()).toContain('Agent Home was not restored on this disk')
    expect(runs(worker)).toBe(1)
    expect(adapter.requests).toEqual([])
  })
})

function fakeAdapter(restore: RestoreReply) {
  const requests: Array<[string, string | null]> = []
  const received = Promise.withResolvers<void>()
  const aborted = Promise.withResolvers<void>()
  const server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    fetch(request) {
      const route = new URL(request.url).pathname.split('/').at(-1)!
      requests.push([route, request.headers.get('authorization')])
      if (route === 'backup') return Response.json({ storage_ref: null })
      if (restore === 'ok') return Response.json({ restored: true })
      if (restore === 'fail') return Response.json({ error: 'restore_failed' }, { status: 500 })
      received.resolve()
      return new Promise<Response>(resolve => {
        request.signal.addEventListener('abort', () => {
          aborted.resolve()
          resolve(new Response(null, { status: 499 }))
        })
      })
    }
  })
  cleanups.push(() => server.stop(true))
  return {
    url: `http://127.0.0.1:${server.port}`,
    requests,
    restoreReceived: received.promise,
    restoreAborted: aborted.promise
  }
}

/** A trusted Worker that counts its runs and exits after a drain. It runs as root. */
function fakeWorker() {
  const dir = mkdtempSync(join(tmpdir(), 'ankole-worker-entry-'))
  chmodSync(dir, 0o777)
  const agent = `entry-test-${Math.random().toString(36).slice(2, 10)}`
  const script = join(dir, 'worker.sh')
  writeFileSync(script, `#!/usr/bin/env bash\necho run >> ${JSON.stringify(join(dir, 'runs'))}\n`)
  chmodSync(script, 0o755)
  cleanups.push(() => {
    rmSync(dir, { recursive: true, force: true })
    rmSync(`/agents/${agent}`, { force: true })
  })
  return { dir, agent, script }
}

function startEntry(adapterURL: string, worker: ReturnType<typeof fakeWorker>) {
  return Bun.spawn(['bash', entryPath, worker.script], {
    env: adapterEnv(adapterURL, worker.agent),
    stdout: 'ignore',
    stderr: 'inherit'
  })
}

function adapterEnv(adapterURL: string, agent: string): Record<string, string | undefined> {
  return {
    ...process.env,
    WORKER_ID: agent,
    ANKOLE_WORKER_STORAGE: 'adapter',
    ANKOLE_WORKER_ADAPTER_URL: adapterURL,
    ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY: credential
  }
}

function markRestored(): void {
  mkdirSync('/var/lib/ankole', { recursive: true })
  writeFileSync(restoredHome, '')
}

function runs(worker: ReturnType<typeof fakeWorker>): number {
  const file = join(worker.dir, 'runs')
  return existsSync(file) ? readFileSync(file, 'utf8').trim().split('\n').length : 0
}
