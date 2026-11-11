import { afterEach, expect, test } from 'bun:test'
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const entrypoint = join(import.meta.dir, '../src/cli/device/device-cli.ts')
const stateDirectories: string[] = []

function statePath(): string {
  const dir = mkdtempSync(join(tmpdir(), 'ankole-runner-device-'))
  stateDirectories.push(dir)
  return join(dir, 'device.json')
}

afterEach(() => {
  for (const dir of stateDirectories.splice(0)) rmSync(dir, { recursive: true })
})

async function cli(...args: string[]) {
  const child = Bun.spawn([process.execPath, entrypoint, ...args], { stdout: 'pipe', stderr: 'pipe' })
  const [code, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])
  return { code, stdout, stderr }
}

test('pairs once and saves the device token to a private state file', async () => {
  const path = statePath()
  const token = 'test-device-credential'
  const requests: unknown[] = []
  const server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    async fetch(request) {
      requests.push([request.method, new URL(request.url).pathname, await request.json()])
      return Response.json({ runner_id: 'runner-id', token })
    }
  })
  try {
    const args = ['pair', '--url', server.url.origin, '--code', 'one-use-code', '--state', path]
    const paired = await cli(...args)
    expect(paired.code).toBe(0)
    expect(paired.stdout + paired.stderr).not.toContain(token)
    expect(requests).toEqual([['POST', '/api/internal/runner-devices/pair', { code: 'one-use-code' }]])
    expect(JSON.parse(readFileSync(path, 'utf8'))).toEqual({
      origin: server.url.origin,
      runner_id: 'runner-id',
      token
    })
    if (process.platform !== 'win32') expect(statSync(path).mode & 0o777).toBe(0o600)
    expect((await cli(...args)).code).toBe(1)
    expect(requests).toHaveLength(1)
  } finally {
    await server.stop(true)
  }
})

test('rejects insecure remote origins and incomplete pairing responses', async () => {
  const path = statePath()
  const rejected = await cli('pair', '--url', 'http://ankole.example', '--code', 'code', '--state', path)
  expect(rejected.code).toBe(1)
  expect(rejected.stderr).toContain('HTTPS origin')

  const server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    fetch: () => Response.json({ runner_id: 'runner-id', token: null })
  })
  try {
    const incomplete = await cli('pair', '--url', server.url.origin, '--code', 'code', '--state', path)
    expect(incomplete.code).toBe(1)
    expect(incomplete.stderr).toContain('invalid device response')
    expect(existsSync(path)).toBe(false)
  } finally {
    await server.stop(true)
  }
})
