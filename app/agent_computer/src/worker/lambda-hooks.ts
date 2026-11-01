import { rm } from 'node:fs/promises'

// Lambda snapshots this process before it receives an Agent contract.
const hookRoot = '/aws/lambda-microvms/runtime/v1/'
const readyFile = '/run/ankole-entry-ready'
const task = process.env.ANKOLE_WORKER_TASK
const allowedKeys = new Set([
  'WORKER_ID',
  'ANKOLE_WORKER_STORAGE_NAME',
  'ANKOLE_RUNTIME_FABRIC_ENDPOINT',
  'ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY',
  'ANKOLE_WORKER_STORAGE',
  'ANKOLE_WORKER_NFS_SOURCE'
])

let launch: { payload: string; result: Promise<void> } | undefined
let child: ReturnType<typeof Bun.spawn> | undefined
let termination: Promise<void> | undefined

function contract(payload: string): Record<string, string> {
  if (Buffer.byteLength(payload) > 4096) throw new Error('Contract exceeds 4096 bytes')
  const value: unknown = JSON.parse(payload)
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Contract must be an object')
  }
  for (const [key, entry] of Object.entries(value)) {
    if (!allowedKeys.has(key) || typeof entry !== 'string') throw new Error('Invalid contract field')
  }
  const env = value as Record<string, string>
  if (!/^[a-z0-9][a-z0-9._@+-]{0,95}$/.test(env.WORKER_ID ?? '')) throw new Error('Invalid Agent UID')
  if (env.ANKOLE_WORKER_STORAGE !== 'nfs' || !env.ANKOLE_WORKER_NFS_SOURCE) {
    throw new Error('NFS source is required')
  }
  if (
    task !== 'delete_storage' &&
    (!env.ANKOLE_RUNTIME_FABRIC_ENDPOINT || !env.ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY)
  ) {
    throw new Error('Worker connection is required')
  }
  return env
}

async function start(env: Record<string, string>): Promise<void> {
  await rm(readyFile, { force: true })
  child = Bun.spawn(['/usr/local/bin/ankole-worker-command-entry', 'bun', '/repo/app/agent_computer/src/main.ts'], {
    env: { ...process.env, ...env, ANKOLE_WORKER_BOOTSTRAP: '' },
    stdin: 'ignore',
    stdout: 'inherit',
    stderr: 'inherit'
  })
  const deadline = Date.now() + 55_000
  while (!(await Bun.file(readyFile).exists())) {
    if (child.exitCode !== null) throw new Error(`Entry exited with status ${child.exitCode}`)
    if (Date.now() >= deadline) throw new Error('Entry did not prepare storage in time')
    await Bun.sleep(50)
  }
}

function terminate(): Promise<void> {
  return (termination ??= stopEntry())
}

async function stopEntry(): Promise<void> {
  const deadline = Date.now() + 55_000
  // A terminate can arrive while the entry still prepares its mount. Wait
  // within this hook's deadline before reading the entry's PID file.
  if (launch) await Promise.race([launch.result.catch(() => undefined), Bun.sleep(55_000)])
  if (!child || child.exitCode !== null) return
  // flock starts the entry as its child. Signal the recorded tini PID, so the
  // Worker receives TERM and can drain before the platform ends the VM.
  const pid = Number((await Bun.file('/run/ankole-worker.pid').text()).trim())
  if (!Number.isInteger(pid) || pid <= 1) throw new Error('Entry PID is not available')
  try {
    process.kill(pid, 'SIGTERM')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error
  }
  await Promise.race([child.exited, Bun.sleep(Math.max(0, deadline - Date.now()))])
}

Bun.serve({
  port: 8080,
  hostname: '0.0.0.0',
  idleTimeout: 0,
  maxRequestBodySize: 65_536,
  async fetch(request) {
    if (request.method !== 'POST') return new Response(null, { status: 405 })
    const path = new URL(request.url).pathname
    if (path === `${hookRoot}ready`) return new Response(null, { status: 200 })
    if (path === `${hookRoot}terminate`) {
      await terminate()
      return new Response(null, { status: 200 })
    }
    if (path !== `${hookRoot}run`) return new Response(null, { status: 404 })
    if (termination) return new Response('Instance is terminating', { status: 409 })
    try {
      const body = await request.json()
      if (typeof body.microvmId !== 'string' || typeof body.runHookPayload !== 'string') {
        return new Response('Invalid run hook', { status: 400 })
      }
      const payload = body.runHookPayload
      if (launch && launch.payload !== payload) return new Response('Instance already has a contract', { status: 409 })
      if (!launch) launch = { payload, result: start(contract(payload)) }
      await launch.result
      return new Response(null, { status: 200 })
    } catch {
      // Never log the request: it contains the generation credential.
      console.error('Lambda entry failed')
      return new Response('Entry failed', { status: 503 })
    }
  }
})

for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    void terminate().then(
      () => process.exit(0),
      () => process.exit(1)
    )
  })
}
