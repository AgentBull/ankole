import { describe, expect, it } from 'bun:test'
import { isApiError } from './api-client/api-error'
import { Command, CommandFinished } from './command'
import { Computer } from './computer'
import type { FetchLike } from './types'

interface Captured {
  method: string
  path: string
  headers: Headers
  body: unknown
  tls?: unknown
}

const TEST_TLS = { caCert: 'CA CERT', cert: 'CLIENT CERT', key: 'CLIENT KEY' }

function sleepForTest(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(signal.reason ?? new Error('aborted'))
      return
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort)
      resolve()
    }, ms)
    const onAbort = () => {
      clearTimeout(timer)
      reject(signal?.reason ?? new Error('aborted'))
    }
    signal?.addEventListener('abort', onAbort, { once: true })
  })
}

function makeFetch(captured: Captured[]): FetchLike {
  const ndjson = (text: string) => new Response(text, { headers: { 'content-type': 'application/x-ndjson' } })
  const json = (value: unknown, status = 200) =>
    new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } })

  return (async (input, init) => {
    const url = new URL(String(input))
    const method = (init?.method ?? 'GET').toUpperCase()
    captured.push({
      method,
      path: url.pathname,
      headers: new Headers(init?.headers),
      body: init?.body ?? null,
      tls: (init as RequestInit & { tls?: unknown })?.tls
    })

    if (method === 'POST' && url.pathname === '/internal/computer/sessions/resolve') {
      return json({
        agentUid: 'agent_123',
        worker: { workerId: 'w0', instanceId: 'i0', baseUrl: 'https://worker.local' },
        binding: { kind: 'implicit', reason: 'least_bound_random' },
        tls: TEST_TLS
      })
    }
    if (method === 'PUT' && url.pathname === '/v1/sessions/agent_123') {
      return json({
        sessionId: 's1',
        agentUid: 'agent_123',
        workerId: 'w0',
        created: true,
        workspace: {
          libraryContainers: '/workspace/library-containers',
          userFiles: '/workspace/user-files',
          temp: '/workspace/temp'
        },
        createdAt: 'now',
        lastUsedAt: 'now'
      })
    }
    if (method === 'POST' && url.pathname === '/v1/sessions/agent_123/cmd') {
      const body = JSON.parse(String(init?.body)) as { wait: boolean }
      return body.wait
        ? ndjson(
            '{"command":{"id":"cmd_1","status":"running","cwd":"/workspace"}}\n' +
              '{"command":{"id":"cmd_1","status":"finished","exitCode":0}}\n'
          )
        : ndjson('{"command":{"id":"cmd_det","status":"running"}}\n')
    }
    if (method === 'POST' && url.pathname === '/v1/sessions/agent_123/shell') {
      return ndjson(
        '{"command":{"id":"sh_1","status":"running","cwd":"/workspace/user-files"}}\n' +
          '{"command":{"id":"sh_1","status":"finished","exitCode":0}}\n'
      )
    }
    if (method === 'GET' && url.pathname.endsWith('/logs')) {
      return ndjson('{"stream":"stdout","data":"hello\\n"}\n{"stream":"stderr","data":"warn\\n"}\n')
    }
    if (method === 'GET' && url.pathname === '/v1/sessions/agent_123/cmd/cmd_signal') {
      return json({ id: 'cmd_signal', status: 'killed', exitCode: null })
    }
    if (method === 'POST' && url.pathname.endsWith('/kill')) return new Response(null, { status: 204 })
    if (method === 'GET' && url.pathname === '/v1/sessions/agent_123/cmd') {
      return json({
        commands: [
          { id: 'cmd_det', status: 'running', detached: true, exitCode: null },
          { id: 'cmd_fg', status: 'finished', detached: false, exitCode: 0 }
        ]
      })
    }
    if (method === 'GET' && url.pathname === '/v1/sessions/agent_123/terminals') {
      return json({ terminals: [{ name: 'codex', windows: 1, attached: false }] })
    }
    if (method === 'POST' && url.pathname === '/v1/sessions/agent_123/terminals/codex/start') {
      return json({ name: 'codex', status: 'started' })
    }
    if (method === 'POST' && url.pathname === '/v1/sessions/agent_123/terminals/codex/send') {
      return json({ name: 'codex', status: 'sent' })
    }
    if (method === 'GET' && url.pathname === '/v1/sessions/agent_123/terminals/codex/capture') {
      return json({ name: 'codex', screen: 'READY' })
    }
    if (method === 'DELETE' && url.pathname === '/v1/sessions/agent_123/terminals/codex') {
      return json({ name: 'codex', status: 'killed' })
    }
    if (method === 'POST' && url.pathname === '/v1/sessions/agent_123/fs/write') {
      return new Response(null, { status: 204 })
    }
    if (method === 'POST' && url.pathname === '/v1/sessions/agent_123/fs/read') {
      const body = JSON.parse(String(init?.body)) as { path: string }
      if (body.path.includes('missing')) return json({ code: 'not_found' }, 404)
      return new Response(new TextEncoder().encode('FILE-CONTENT'), {
        headers: { 'content-type': 'application/octet-stream' }
      })
    }
    return new Response('not found', { status: 404 })
  }) as FetchLike
}

function connect(captured: Captured[]) {
  return { baseUrl: 'http://control.local', token: 'svc-token', fetch: makeFetch(captured) }
}

describe('Computer', () => {
  it('getOrCreate resolves a worker, creates the session, and runs onCreate', async () => {
    const captured: Captured[] = []
    let createdHook = false
    const computer = await Computer.getOrCreate({
      agentUid: 'agent_123',
      ...connect(captured),
      onCreate: async () => {
        createdHook = true
      }
    })
    expect(computer.workerId).toBe('w0')
    expect(computer.sessionId).toBe('s1')
    expect(createdHook).toBe(true)
    expect(captured.map(c => c.path)).toContain('/internal/computer/sessions/resolve')
    expect(captured.some(c => c.method === 'PUT' && c.path === '/v1/sessions/agent_123')).toBe(true)
    const sessionRequest = captured.find(c => c.method === 'PUT' && c.path === '/v1/sessions/agent_123')
    expect(sessionRequest?.tls).toEqual({ ca: ['CA CERT'], cert: 'CLIENT CERT', key: 'CLIENT KEY' })
    expect(sessionRequest?.headers.has('authorization')).toBe(false)
  })

  it('runCommand returns a finished command with stdout/stderr', async () => {
    const computer = await Computer.getOrCreate({ agentUid: 'agent_123', ...connect([]) })
    const result = await computer.runCommand('echo', ['hello'])
    expect(result).toBeInstanceOf(CommandFinished)
    expect(result.exitCode).toBe(0)
    expect(await result.stdout()).toBe('hello\n')
    expect(await result.stderr()).toBe('warn\n')
  })

  it('runCommand detached returns a Command that can be killed', async () => {
    const captured: Captured[] = []
    const computer = await Computer.getOrCreate({ agentUid: 'agent_123', ...connect(captured) })
    const cmd = await computer.runCommand({ cmd: 'sleep', args: ['10'], detached: true })
    expect(cmd).toBeInstanceOf(Command)
    expect(cmd).not.toBeInstanceOf(CommandFinished)
    expect(cmd.cmdId).toBe('cmd_det')
    await cmd.kill('SIGTERM')
    expect(captured.some(c => c.path === '/v1/sessions/agent_123/cmd/cmd_det/kill')).toBe(true)
  })

  it('lists worker command snapshots', async () => {
    const computer = await Computer.getOrCreate({ agentUid: 'agent_123', ...connect([]) })
    const commands = await computer.listCommands()
    expect(commands).toEqual([
      { id: 'cmd_det', status: 'running', detached: true, exitCode: null },
      { id: 'cmd_fg', status: 'finished', detached: false, exitCode: 0 }
    ])
  })

  it('runShellCommand preserves the shell-reported cwd', async () => {
    const computer = await Computer.getOrCreate({ agentUid: 'agent_123', ...connect([]) })
    const result = await computer.runShellCommand('cd /workspace/user-files && pwd')
    expect(result.exitCode).toBe(0)
    expect(result.cwd).toBe('/workspace/user-files')
  })

  it('manages tmux-backed terminals through the worker API', async () => {
    const captured: Captured[] = []
    const computer = await Computer.getOrCreate({ agentUid: 'agent_123', ...connect(captured) })
    await expect(computer.terminals.list()).resolves.toEqual([{ name: 'codex', windows: 1, attached: false }])
    await expect(
      computer.terminals.start('codex', { command: 'codex', cwd: '/workspace', cols: 120 })
    ).resolves.toEqual({
      name: 'codex',
      status: 'started'
    })
    await expect(computer.terminals.send('codex', { input: 'hello', enter: true })).resolves.toEqual({
      name: 'codex',
      status: 'sent'
    })
    await expect(computer.terminals.capture('codex', { lines: 40 })).resolves.toEqual({
      name: 'codex',
      screen: 'READY'
    })
    await expect(computer.terminals.kill('codex')).resolves.toEqual({ name: 'codex', status: 'killed' })

    expect(captured.some(c => c.method === 'GET' && c.path === '/v1/sessions/agent_123/terminals')).toBe(true)
    const start = captured.find(c => c.path === '/v1/sessions/agent_123/terminals/codex/start')
    expect(start?.body).toBe(JSON.stringify({ command: 'codex', cwd: '/workspace', cols: 120 }))
  })

  it('treats timeoutMs as a worker execution timeout, not a fetch abort', async () => {
    const captured: Captured[] = []
    const baseFetch = makeFetch(captured)
    const fetchImpl = (async (input, init) => {
      const url = new URL(String(input))
      const method = (init?.method ?? 'GET').toUpperCase()
      if (method === 'POST' && url.pathname === '/v1/sessions/agent_123/shell') {
        await sleepForTest(10, init?.signal ?? undefined)
        return new Response(
          '{"command":{"id":"sh_timeout","status":"running","cwd":"/workspace"}}\n' +
            '{"command":{"id":"sh_timeout","status":"killed","exitCode":124}}\n',
          { headers: { 'content-type': 'application/x-ndjson' } }
        )
      }
      return baseFetch(input, init)
    }) as FetchLike
    const computer = await Computer.getOrCreate({
      agentUid: 'agent_123',
      baseUrl: 'http://control.local',
      fetch: fetchImpl
    })
    const result = await computer.runShellCommand('sleep 1', { timeoutMs: 1 })
    expect(result.exitCode).toBe(124)
  })

  it('does not treat signal-killed commands as successful when exitCode is missing', async () => {
    const computer = await Computer.getOrCreate({ agentUid: 'agent_123', ...connect([]) })
    const finished = await computer.getCommand('cmd_signal').wait()
    expect(finished.exitCode).toBe(1)
  })

  it('rejects sudo with unsupported_sudo', async () => {
    const computer = await Computer.getOrCreate({ agentUid: 'agent_123', ...connect([]) })
    let caught: unknown
    try {
      await computer.runCommand({ cmd: 'whoami', sudo: true })
    } catch (error) {
      caught = error
    }
    expect(isApiError(caught, 'unsupported_sudo')).toBe(true)
  })

  it('writeFiles uploads a gzip tarball with X-Cwd', async () => {
    const captured: Captured[] = []
    const computer = await Computer.getOrCreate({ agentUid: 'agent_123', ...connect(captured) })
    await computer.writeFiles([{ path: 'temp/hello.txt', content: 'hello', mode: 0o644 }])
    const write = captured.find(c => c.path === '/v1/sessions/agent_123/fs/write')
    expect(write).toBeDefined()
    expect(write!.headers.get('content-type')).toBe('application/gzip')
    expect(write!.headers.get('x-cwd')).toBe('/workspace')
    const bytes = write!.body as Uint8Array
    expect(bytes[0]).toBe(0x1f)
    expect(bytes[1]).toBe(0x8b)
  })

  it('readFileToBuffer returns content and null on 404', async () => {
    const computer = await Computer.getOrCreate({ agentUid: 'agent_123', ...connect([]) })
    const present = await computer.readFileToBuffer({ path: 'user-files/x.txt' })
    expect(present?.toString('utf-8')).toBe('FILE-CONTENT')
    const missing = await computer.readFileToBuffer({ path: 'user-files/missing.txt' })
    expect(missing).toBeNull()
  })

  it('supports an in-process resolveWorker (no control HTTP)', async () => {
    const captured: Captured[] = []
    const fetchImpl = makeFetch(captured)
    const computer = await Computer.getOrCreate({
      agentUid: 'agent_123',
      fetch: fetchImpl,
      resolveWorker: async () => ({
        agentUid: 'agent_123',
        worker: { workerId: 'w0', instanceId: 'i0', baseUrl: 'https://worker.local' },
        binding: { kind: 'explicit_pin', reason: 'configured_pin' },
        tls: TEST_TLS
      })
    })
    expect(computer.workerId).toBe('w0')
    expect(captured.some(c => c.path === '/internal/computer/sessions/resolve')).toBe(false)
  })
})
