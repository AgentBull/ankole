import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { parseArgs } from 'node:util'
import { z } from 'zod'

const pollIntervalMs = 5_000
const devicePath = '/api/internal/runner-devices'
const secret = z.string().regex(/^[!-~]+$/)
const deviceIdentity = z.object({ runner_id: z.string().min(1), token: secret })
const deviceState = deviceIdentity.extend({ origin: z.string() })
const binding = z.object({
  agent_uid: z.string().regex(/^[a-z0-9][a-z0-9._@+-]{0,95}$/),
  tenant_id: z.string().min(1),
  image: z.string().regex(/^[a-zA-Z0-9][a-zA-Z0-9_.:/@-]*$/),
  generation: z.string().min(1),
  worker_token: secret,
  runtime_fabric_url: z.string()
})
const bindingList = z.object({ bindings: z.array(binding) })
type Device = z.infer<typeof deviceState>
type Binding = z.infer<typeof binding>

class DeviceRevoked extends Error {}

function localHost(hostname: string): boolean {
  return hostname === 'localhost' || hostname.endsWith('.localhost') || hostname === '127.0.0.1' || hostname === '[::1]'
}

function siteOrigin(value: string): string {
  const url = URL.parse(value)
  if (
    !url ||
    (url.protocol !== 'https:' && !(url.protocol === 'http:' && localHost(url.hostname))) ||
    url.username ||
    url.password ||
    url.pathname !== '/' ||
    url.search ||
    url.hash
  ) {
    throw new Error('Use the HTTPS origin of your Ankole site. Local development may use loopback HTTP.')
  }
  return url.origin
}

function workerEndpoint(value: string, origin: string): string {
  const url = URL.parse(value)
  const devSocket =
    url?.protocol === 'ws:' &&
    origin.startsWith('http:') &&
    (localHost(url.hostname) || url.hostname === 'host.docker.internal')
  if (
    !url ||
    (url.protocol !== 'wss:' && !devSocket) ||
    url.username ||
    url.password ||
    url.pathname === '/' ||
    url.search ||
    url.hash
  ) {
    throw new Error('Ankole did not provide a valid Worker endpoint.')
  }
  return url.href
}

async function request<T>(origin: string, path: string, schema: z.ZodType<T>, options: RequestInit): Promise<T> {
  const response = await fetch(`${origin}${devicePath}${path}`, {
    ...options,
    redirect: 'error',
    signal: AbortSignal.timeout(10_000)
  })
  if (path === '/bindings' && [401, 403].includes(response.status)) {
    throw new DeviceRevoked('Ankole revoked this device. Pair again with a new state file.')
  }
  if (!response.ok) throw new Error(`Ankole device request failed (HTTP ${response.status}).`)

  const result = schema.safeParse(await response.json().catch(() => null))
  if (!result.success) throw new Error('Ankole returned an invalid device response.')
  return result.data
}

async function pair(path: string, origin: string, code: string): Promise<void> {
  if (existsSync(path)) throw new Error(`A device is already paired in ${path}.`)
  mkdirSync(dirname(path), { mode: 0o700, recursive: true })
  const device = await request(origin, '/pair', deviceIdentity, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code })
  })
  writeFileSync(path, `${JSON.stringify({ origin, ...device })}\n`, { mode: 0o600, flag: 'wx' })
  process.stdout.write('Device paired. Run ankole-worker run to connect it.\n')
}

function readDevice(path: string): Device {
  if (!existsSync(path)) throw new Error(`No device is paired in ${path}. Run ankole-worker pair first.`)
  let state: unknown
  try {
    state = JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    throw new Error('Could not read device state. Pair again with a new state file.')
  }
  const parsed = deviceState.safeParse(state)
  if (!parsed.success) throw new Error('Invalid device state. Pair again with a new state file.')
  return { ...parsed.data, origin: siteOrigin(parsed.data.origin) }
}

function key(...parts: string[]): string {
  return createHash('sha256').update(JSON.stringify(parts)).digest('hex').slice(0, 24)
}

async function docker(args: string[], env?: Record<string, string | undefined>): Promise<string> {
  const child = Bun.spawn(['docker', ...args], {
    env,
    stdout: 'pipe',
    stderr: 'pipe',
    signal: AbortSignal.timeout(120_000)
  })
  const [status, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])
  if (status !== 0) throw new Error(`docker ${args[0]} failed (${status}): ${stderr.trim()}`)
  return stdout.trim()
}

async function containers(owner: string, all = true): Promise<string[]> {
  const names = await docker(['ps', ...(all ? ['-a'] : []), '--filter', `label=${owner}`, '--format', '{{.Names}}'])
  return names ? names.split('\n') : []
}

async function stopContainers(names: string[]): Promise<void> {
  if (names.length > 0) await docker(['stop', '--time', '15', ...names])
}

async function createContainer(
  owner: string,
  name: string,
  home: string,
  bind: Binding,
  endpoint: string
): Promise<void> {
  const workerEnv = {
    WORKER_ID: bind.agent_uid,
    ANKOLE_WORKER_TENANT_ID: bind.tenant_id,
    ANKOLE_WORKER_STORAGE: 'mounted',
    ANKOLE_WORKER_STORAGE_NAME: home,
    ANKOLE_RUNTIME_FABRIC_ENDPOINT: endpoint,
    ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY: bind.worker_token
  }
  await docker(
    [
      'create',
      '--name',
      name,
      '--label',
      owner,
      '--security-opt',
      'no-new-privileges',
      '--add-host',
      'host.docker.internal:host-gateway',
      '--mount',
      `type=volume,source=${home},target=/workspace`,
      ...Object.keys(workerEnv).flatMap(variable => ['--env', variable]),
      bind.image
    ],
    { ...process.env, ...workerEnv }
  )
}

async function reconcile(device: Device, owner: string): Promise<void> {
  const response = await request(device.origin, '/bindings', bindingList, {
    headers: { Authorization: `Bearer ${device.token}` }
  })
  const desired = response.bindings.map(bind => {
    const home = `ankole-device-${key(device.origin, device.runner_id, bind.tenant_id, bind.agent_uid)}`
    const endpoint = workerEndpoint(bind.runtime_fabric_url, device.origin)
    const name = `${home}-${key(bind.generation, bind.image, endpoint)}`
    return { bind, home, name, endpoint }
  })
  if (new Set(desired.map(item => item.home)).size !== desired.length) {
    throw new Error('Ankole returned more than one binding for the same Agent.')
  }

  const existing = await containers(owner)
  const needed = new Set(desired.map(item => item.name))
  const obsolete = existing.filter(name => !needed.has(name))
  if (obsolete.length > 0) {
    await stopContainers(obsolete)
    await docker(['rm', ...obsolete])
  }

  const running = new Set(await containers(owner, false))
  for (const { bind, home, name, endpoint } of desired) {
    if (running.has(name)) continue
    try {
      if (!existing.includes(name)) await createContainer(owner, name, home, bind, endpoint)
      await docker(['start', name])
    } catch (error) {
      console.error(`Cannot start Worker for ${bind.agent_uid}: ${message(error)}`)
    }
  }
}

async function run(device: Device): Promise<void> {
  const owner = `ankole.runner-device=${key(device.origin, device.runner_id)}`
  const shutdown = new AbortController()
  const stop = () => shutdown.abort()
  process.on('SIGINT', stop)
  process.on('SIGTERM', stop)
  try {
    while (!shutdown.signal.aborted) {
      try {
        await reconcile(device, owner)
      } catch (error) {
        if (error instanceof DeviceRevoked) {
          const revoked = await containers(owner)
          await stopContainers(revoked)
          if (revoked.length > 0) await docker(['rm', ...revoked])
          throw error
        }
        console.error(message(error))
      }
      if (!shutdown.signal.aborted) await Bun.sleep(pollIntervalMs)
    }
  } finally {
    process.removeListener('SIGINT', stop)
    process.removeListener('SIGTERM', stop)
    await stopContainers(await containers(owner, false))
  }
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

async function main(): Promise<void> {
  const { positionals, values } = parseArgs({
    args: process.argv.slice(2),
    allowPositionals: true,
    options: {
      url: { type: 'string' },
      code: { type: 'string' },
      state: { type: 'string' },
      help: { type: 'boolean', short: 'h' }
    }
  })
  const [command] = positionals
  const config = process.env.XDG_CONFIG_HOME || join(homedir(), '.config')
  const path = values.state || join(config, 'ankole-worker', 'device.json')
  if (values.help) {
    process.stdout.write(
      'ankole-worker pair --url <site-origin> --code <pairing-code> [--state <path>]\n' +
        'ankole-worker run [--state <path>]\n'
    )
  } else if (command === 'pair' && positionals.length === 1 && values.url && values.code) {
    await pair(path, siteOrigin(values.url), values.code)
  } else if (command === 'run' && positionals.length === 1 && !values.url && !values.code) {
    await run(readDevice(path))
  } else {
    throw new Error('Choose pair or run. See ankole-worker --help.')
  }
}

await main().catch(error => {
  console.error(message(error))
  process.exitCode = 1
})
