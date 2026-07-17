import { afterEach, describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { utf8ByteLength } from '../src/common/text-sanitize'
import { createMCPTools, loadEnabledSkillMCPServers } from '../src/tools/mcp'
import { boundedMCPResultValue, resolveMCPTimeoutMs } from '../src/tools/mcp/mcp-tool'
import type { RuntimeSkillSummary } from '../src/lanes/rpc_lane'

const temporaryRoots: string[] = []
const runningServers: Bun.Server<undefined>[] = []

afterEach(() => {
  for (const server of runningServers.splice(0)) server.stop(true)
  for (const root of temporaryRoots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('main-agent native MCP tool', () => {
  it('loads only enabled inline Skill declarations and strictly deduplicates identical servers', async () => {
    const roots = skillRoots()
    writeHTTPMetadata(roots.builtinSkillsRoot, 'enabled-one', 'shared', 'https://example.test/mcp')
    writeHTTPMetadata(roots.builtinSkillsRoot, 'enabled-two', 'shared', 'https://example.test/mcp')
    writeHTTPMetadata(roots.builtinSkillsRoot, 'disabled', 'disabled-server', 'https://disabled.test/mcp')
    writeHTTPMetadata(roots.builtinSkillsRoot, 'background-only', 'background-server', 'https://background.test/mcp')

    const servers = await loadEnabledSkillMCPServers({
      enabledSkills: [
        enabledSkill('enabled-one'),
        enabledSkill('enabled-two'),
        { ...enabledSkill('background-only'), metadata: { long_running: true } }
      ],
      skillRoots: roots
    })

    expect(servers).toHaveLength(1)
    expect(servers[0]).toMatchObject({
      name: 'shared',
      description: 'Shared fake server',
      transport: 'streamable_http',
      url: 'https://example.test/mcp',
      sourceSkills: ['enabled-one', 'enabled-two']
    })
    expect(servers[0]?.generation).toMatch(/^[a-f0-9]{64}$/)
  })

  it('selects the model timeout before the server timeout and the 360-second default', () => {
    expect(resolveMCPTimeoutMs(900_000, 600_000)).toBe(900_000)
    expect(resolveMCPTimeoutMs(undefined, 600_000)).toBe(600_000)
    expect(resolveMCPTimeoutMs()).toBe(360_000)
  })

  it('rejects conflicting and unsupported declarations instead of selecting one silently', async () => {
    const roots = skillRoots()
    writeHTTPMetadata(roots.builtinSkillsRoot, 'one', 'shared', 'https://one.test/mcp')
    writeHTTPMetadata(roots.builtinSkillsRoot, 'two', 'shared', 'https://two.test/mcp')

    await expect(
      loadEnabledSkillMCPServers({
        enabledSkills: [enabledSkill('one'), enabledSkill('two')],
        skillRoots: roots
      })
    ).rejects.toThrow('conflicting MCP server declaration "shared"')

    writeMetadata(
      roots.builtinSkillsRoot,
      'unsupported',
      ['dependencies:', '  tools:', '    - type: "http"', '      value: "wrong"'].join('\n')
    )
    await expect(
      loadEnabledSkillMCPServers({ enabledSkills: [enabledSkill('unsupported')], skillRoots: roots })
    ).rejects.toThrow('invalid MCP dependency for Skill unsupported')
  })

  it('orders materialized names by Unicode code point without host locale rules', async () => {
    const roots = skillRoots()
    const privateUseBMP = '\uE000'
    const supplementary = '\u{10000}'
    writeMetadata(
      roots.builtinSkillsRoot,
      'ordered',
      [
        'dependencies:',
        '  tools:',
        '    - type: "mcp"',
        `      value: ${JSON.stringify(supplementary)}`,
        '      transport: "streamable_http"',
        '      url: "https://supplementary.test/mcp"',
        '    - type: "mcp"',
        `      value: ${JSON.stringify(privateUseBMP)}`,
        '      transport: "streamable_http"',
        '      url: "https://bmp.test/mcp"'
      ].join('\n')
    )

    const servers = await loadEnabledSkillMCPServers({
      enabledSkills: [enabledSkill('ordered')],
      skillRoots: roots
    })
    expect(servers.map(server => server.name)).toEqual([privateUseBMP, supplementary])
  })

  it('lists only names and descriptions, describes one schema, and calls one allowlisted tool with bearer auth', async () => {
    const requests: FakeRequest[] = []
    const fake = startHTTPMCPServer(requests, { leakAuthorizationInCallKey: true })
    const roots = skillRoots()
    writeHTTPMetadata(roots.builtinSkillsRoot, 'finance', 'finance-data', `${fake.url}/mcp`, 'MCP_TOKEN')
    writeHTTPMetadata(roots.builtinSkillsRoot, 'disabled', 'disabled-data', `${fake.url}/disabled`)

    const [tool] = await createMCPTools({
      enabledSkills: [enabledSkill('finance')],
      skillRoots: roots,
      workerEnv: { MCP_TOKEN: 'top-secret-token' }
    })
    expect(tool?.name).toBe('mcp')

    const listed = await tool!.execute('list', { action: 'list' })
    const listJSON = resultJSON(listed)
    expect(listJSON).toEqual({
      servers: [
        {
          name: 'finance-data',
          description: 'Shared fake server'
        }
      ]
    })
    expect(requests).toEqual([])
    expect(JSON.stringify(listJSON)).not.toContain(fake.url)
    expect(JSON.stringify(listJSON)).not.toContain('top-secret-token')

    const discovered = await tool!.execute('list-server', { action: 'list', server: 'finance-data' })
    expect(resultJSON(discovered)).toEqual({
      servers: [
        {
          name: 'finance-data',
          description: 'Shared fake server',
          tools: [
            { name: 'echo', description: 'Echo one value.' },
            { name: 'large', description: 'Return a large result.' },
            { name: 'slow', description: 'Return after a delay.' }
          ]
        }
      ]
    })
    expect(requests.filter(request => request.method === 'tools/list')).toHaveLength(1)

    const described = await tool!.execute('describe', {
      action: 'describe',
      server: 'finance-data',
      tool: 'echo'
    })
    expect(resultJSON(described)).toEqual({
      server: 'finance-data',
      tool: {
        name: 'echo',
        description: 'Echo one value.',
        input_schema: {
          type: 'object',
          properties: { value: { type: 'string' } },
          required: ['value']
        }
      }
    })

    expect(resultJSON(await tool!.execute('list-cached', { action: 'list' }))).toEqual({
      servers: [
        {
          name: 'finance-data',
          description: 'Shared fake server',
          tools: [
            { name: 'echo', description: 'Echo one value.' },
            { name: 'large', description: 'Return a large result.' },
            { name: 'slow', description: 'Return after a delay.' }
          ]
        }
      ]
    })

    const called = await tool!.execute('call', {
      action: 'call',
      server: 'finance-data',
      tool: 'echo',
      arguments: { value: 'hello' }
    })
    expect(resultJSON(called)).toMatchObject({
      server: 'finance-data',
      tool: 'echo',
      result: { content: [{ type: 'text', text: 'hello' }] }
    })
    expect(textOf(called)).toContain('[REDACTED]')
    expect(textOf(called)).not.toContain('top-secret-token')
    expect(requests.filter(request => request.method === 'tools/call').map(request => request.tool)).toEqual(['echo'])
    expect(requests.every(request => request.authorization === 'Bearer top-secret-token')).toBe(true)

    await expect(
      tool!.execute('disabled', {
        action: 'call',
        server: 'disabled-data',
        tool: 'echo',
        arguments: {}
      })
    ).rejects.toThrow('not allowlisted')
  })

  it('keeps prototype-shaped result keys as inert JSON data', () => {
    const malicious = JSON.parse(
      '{"__proto__":{"polluted":true},"constructor":"server supplied constructor key","normal":"ok"}'
    )
    const bounded = boundedMCPResultValue(malicious, []) as Record<string, unknown>

    expect(Object.getPrototypeOf(bounded)).toBeNull()
    expect(Object.prototype.hasOwnProperty.call(bounded, '__proto__')).toBe(true)
    expect(bounded.__proto__).toEqual({ polluted: true })
    expect(Reflect.get(bounded, 'constructor')).toBe('server supplied constructor key')
    expect(JSON.parse(JSON.stringify(bounded))).toEqual(malicious)
    expect(({} as { polluted?: boolean }).polluted).toBeUndefined()
  })

  it('rejects and does not cache catalogs that reflect WorkerEnv data in schema keys', async () => {
    const requests: FakeRequest[] = []
    const fake = startHTTPMCPServer(requests, { leakAuthorizationInCatalog: true })
    const roots = skillRoots()
    writeHTTPMetadata(roots.builtinSkillsRoot, 'leaky', 'leaky-server', `${fake.url}/mcp`, 'MCP_TOKEN')
    const [tool] = await createMCPTools({
      enabledSkills: [enabledSkill('leaky')],
      skillRoots: roots,
      workerEnv: { MCP_TOKEN: 'catalog-secret' }
    })

    const failure = await tool!
      .execute('leaky-list', { action: 'list', server: 'leaky-server' })
      .catch(error => error as Error)
    expect(failure).toBeInstanceOf(Error)
    if (!(failure instanceof Error)) throw new Error('expected a rejected MCP catalog')
    expect(failure.message).toContain('MCP catalog contained WorkerEnv data and was rejected')
    expect(failure.message).not.toContain('catalog-secret')

    await expect(tool!.execute('leaky-list-again', { action: 'list', server: 'leaky-server' })).rejects.toThrow(
      'MCP catalog contained WorkerEnv data and was rejected'
    )
    expect(requests.filter(request => request.method === 'tools/list')).toHaveLength(2)
  })

  it('reuses catalogs across turns only for the same Skill generation and credential identity', async () => {
    const requests: FakeRequest[] = []
    const fake = startHTTPMCPServer(requests)
    const roots = skillRoots()
    writeHTTPMetadata(roots.builtinSkillsRoot, 'cached', 'cached-server', `${fake.url}/mcp`, 'MCP_TOKEN')

    const options = {
      enabledSkills: [enabledSkill('cached')],
      skillRoots: roots,
      workerEnv: { MCP_TOKEN: 'credential-one' }
    }
    const [first] = await createMCPTools(options)
    await first!.execute('describe-first', { action: 'describe', server: 'cached-server', tool: 'echo' })
    expect(requests.filter(request => request.method === 'tools/list')).toHaveLength(1)

    const [sameIdentity] = await createMCPTools(options)
    await sameIdentity!.execute('describe-second', { action: 'describe', server: 'cached-server', tool: 'echo' })
    expect(requests.filter(request => request.method === 'tools/list')).toHaveLength(1)

    const [newCredential] = await createMCPTools({
      ...options,
      workerEnv: { MCP_TOKEN: 'credential-two' }
    })
    await newCredential!.execute('describe-new-credential', {
      action: 'describe',
      server: 'cached-server',
      tool: 'echo'
    })
    expect(requests.filter(request => request.method === 'tools/list')).toHaveLength(2)

    writeHTTPMetadata(
      roots.builtinSkillsRoot,
      'cached',
      'cached-server',
      `${fake.url}/mcp`,
      'MCP_TOKEN',
      'Refreshed fake server'
    )
    const [newGeneration] = await createMCPTools({
      ...options,
      workerEnv: { MCP_TOKEN: 'credential-two' }
    })
    await newGeneration!.execute('describe-new-generation', {
      action: 'describe',
      server: 'cached-server',
      tool: 'echo'
    })
    expect(requests.filter(request => request.method === 'tools/list')).toHaveLength(3)
  })

  it('bounds call results and applies total timeout and caller cancellation', async () => {
    const fake = startHTTPMCPServer([])
    const roots = skillRoots()
    writeHTTPMetadata(roots.builtinSkillsRoot, 'bounded', 'bounded-server', `${fake.url}/mcp`)

    const [tool] = await createMCPTools({ enabledSkills: [enabledSkill('bounded')], skillRoots: roots })
    const large = await tool!.execute('large', {
      action: 'call',
      server: 'bounded-server',
      tool: 'large'
    })
    const largeText = textOf(large)
    expect(utf8ByteLength(largeText)).toBeLessThanOrEqual(64 * 1024)
    expect(largeText).toContain('...[truncated]')

    await expect(
      tool!.execute('timeout', {
        action: 'call',
        server: 'bounded-server',
        tool: 'slow',
        arguments: { delay_ms: 500 },
        timeout_ms: 100
      })
    ).rejects.toThrow(/timed out|abort/i)

    const controller = new AbortController()
    setTimeout(() => controller.abort(new Error('caller stopped MCP')), 20)
    await expect(
      tool!.execute(
        'abort',
        {
          action: 'call',
          server: 'bounded-server',
          tool: 'slow',
          arguments: { delay_ms: 500 }
        },
        controller.signal
      )
    ).rejects.toThrow(/caller stopped MCP|abort/i)
  })

  it('uses a Skill timeout unless the model requests a wider legal timeout', async () => {
    const fake = startHTTPMCPServer([])
    const roots = skillRoots()
    writeHTTPMetadata(
      roots.builtinSkillsRoot,
      'slow-server',
      'slow-server',
      `${fake.url}/mcp`,
      undefined,
      undefined,
      100
    )

    const [tool] = await createMCPTools({ enabledSkills: [enabledSkill('slow-server')], skillRoots: roots })
    await expect(
      tool!.execute('server-timeout', {
        action: 'call',
        server: 'slow-server',
        tool: 'slow',
        arguments: { delay_ms: 250 }
      })
    ).rejects.toThrow(/timed out|abort/i)

    const result = await tool!.execute('model-timeout', {
      action: 'call',
      server: 'slow-server',
      tool: 'slow',
      arguments: { delay_ms: 250 },
      timeout_ms: 500
    })
    expect(resultJSON(result)).toMatchObject({ server: 'slow-server', tool: 'slow' })
  })

  it('passes WorkerEnv to stdio, discards noisy stderr, and closes each ephemeral child', async () => {
    const roots = skillRoots()
    const root = temporaryRoot('ankole-mcp-stdio-')
    const marker = join(root, 'closed.json')
    const fixture = join(import.meta.dir, 'fixtures', 'mcp-stdio-server.ts')
    writeMetadata(
      roots.builtinSkillsRoot,
      'stdio-skill',
      [
        'dependencies:',
        '  tools:',
        '    - type: "mcp"',
        '      value: "stdio-server"',
        '      description: "Local stdio fake server"',
        '      transport: "stdio"',
        `      command: ${JSON.stringify(`${process.execPath} ${shellQuote(fixture)}`)}`
      ].join('\n')
    )

    const [tool] = await createMCPTools({
      enabledSkills: [enabledSkill('stdio-skill')],
      skillRoots: roots,
      workerEnv: {
        MCP_CLOSE_MARKER: marker,
        MCP_STDIO_SECRET: 'stdio-secret',
        MCP_STDIO_NOISY_STDERR: 'enabled-noisy-stderr-7f3a'
      }
    })
    await tool!.execute('stdio-describe', {
      action: 'describe',
      server: 'stdio-server',
      tool: 'stdio_echo'
    })

    await waitFor(() => existsSync(marker))
    expect(JSON.parse(readFileSync(marker, 'utf8'))).toEqual({ closed: true, worker_env_seen: true })
  })

  it('cleans up the operation budget when transport preparation rejects missing credentials', async () => {
    const fake = startHTTPMCPServer([])
    const roots = skillRoots()
    writeHTTPMetadata(roots.builtinSkillsRoot, 'missing-token', 'missing-token-server', `${fake.url}/mcp`, 'MCP_TOKEN')
    const [tool] = await createMCPTools({ enabledSkills: [enabledSkill('missing-token')], skillRoots: roots })
    let added = 0
    let removed = 0
    const signal = {
      aborted: false,
      reason: undefined,
      addEventListener: () => {
        added += 1
      },
      removeEventListener: () => {
        removed += 1
      }
    } as unknown as AbortSignal

    await expect(
      tool!.execute('missing-token', { action: 'list', server: 'missing-token-server' }, signal)
    ).rejects.toThrow('requires WorkerEnv variable MCP_TOKEN')
    expect({ added, removed }).toEqual({ added: 1, removed: 1 })
  })
})

interface FakeRequest {
  method: string
  tool?: string
  authorization: string | null
}

interface FakeMCPServerOptions {
  leakAuthorizationInCallKey?: boolean
  leakAuthorizationInCatalog?: boolean
}

function startHTTPMCPServer(requests: FakeRequest[], options: FakeMCPServerOptions = {}): { url: string } {
  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      if (request.method === 'GET') return new Response(null, { status: 405 })
      const message = (await request.json()) as {
        id?: string | number
        method: string
        params?: { name?: string; arguments?: Record<string, unknown>; protocolVersion?: string }
      }
      requests.push({
        method: message.method,
        ...(message.params?.name ? { tool: message.params.name } : {}),
        authorization: request.headers.get('authorization')
      })

      if (message.id === undefined) return new Response(null, { status: 202 })
      if (message.method === 'initialize') {
        return jsonRPCResult(message.id, {
          protocolVersion: message.params?.protocolVersion ?? '2025-06-18',
          capabilities: { tools: {} },
          serverInfo: { name: 'ankole-test-http', version: '1.0.0' }
        })
      }
      if (message.method === 'tools/list') {
        const credential = request.headers.get('authorization')?.replace(/^Bearer /, '') ?? ''
        return jsonRPCResult(message.id, {
          tools: [
            {
              name: 'echo',
              description: 'Echo one value.',
              inputSchema: {
                type: 'object',
                properties: options.leakAuthorizationInCatalog
                  ? { [credential]: { type: 'string' } }
                  : { value: { type: 'string' } },
                required: ['value']
              }
            },
            {
              name: 'large',
              description: 'Return a large result.',
              inputSchema: { type: 'object', properties: {} }
            },
            {
              name: 'slow',
              description: 'Return after a delay.',
              inputSchema: {
                type: 'object',
                properties: { delay_ms: { type: 'number' } }
              }
            }
          ]
        })
      }
      if (message.method === 'tools/call') {
        const tool = message.params?.name
        if (tool === 'slow') await Bun.sleep(Number(message.params?.arguments?.delay_ms ?? 500))
        const text =
          tool === 'large'
            ? 'x'.repeat(100_000)
            : tool === 'echo'
              ? String(message.params?.arguments?.value ?? '')
              : 'slow result'
        const credential = request.headers.get('authorization')?.replace(/^Bearer /, '') ?? ''
        return jsonRPCResult(message.id, {
          content: [{ type: 'text', text }],
          ...(options.leakAuthorizationInCallKey && credential
            ? {
                structuredContent: {
                  [credential]: 'server reflected a secret in an object key'
                }
              }
            : {})
        })
      }
      return new Response('not found', { status: 404 })
    }
  })
  runningServers.push(server)
  return { url: `http://127.0.0.1:${server.port}` }
}

function jsonRPCResult(id: string | number, result: unknown): Response {
  return Response.json({ jsonrpc: '2.0', id, result }, { headers: { 'content-type': 'application/json' } })
}

function skillRoots() {
  const root = temporaryRoot('ankole-mcp-skills-')
  return {
    builtinSkillsRoot: join(root, 'builtin'),
    agentInstalledSkillsRoot: join(root, 'installed')
  }
}

function enabledSkill(name: string): RuntimeSkillSummary {
  return { skill_name: name, source_kind: 'builtin', relative_path: name }
}

function writeHTTPMetadata(
  root: string,
  skill: string,
  server: string,
  url: string,
  bearerTokenEnvVar?: string,
  description = 'Shared fake server',
  timeoutMs?: number
): void {
  writeMetadata(
    root,
    skill,
    [
      'interface:',
      `  display_name: ${JSON.stringify(skill)}`,
      'dependencies:',
      '  tools:',
      '    - type: "mcp"',
      `      value: ${JSON.stringify(server)}`,
      `      description: ${JSON.stringify(description)}`,
      '      transport: "streamable_http"',
      `      url: ${JSON.stringify(url)}`,
      ...(bearerTokenEnvVar ? [`      bearer_token_env_var: ${JSON.stringify(bearerTokenEnvVar)}`] : []),
      ...(timeoutMs !== undefined ? [`      timeout_ms: ${timeoutMs}`] : [])
    ].join('\n')
  )
}

function writeMetadata(root: string, skill: string, content: string): void {
  const skillRoot = join(root, skill)
  mkdirSync(join(skillRoot, 'agents'), { recursive: true })
  writeFileSync(join(skillRoot, 'SKILL.md'), `---\nname: ${skill}\ndescription: Test skill.\n---\n`)
  writeFileSync(join(skillRoot, 'agents', 'openai.yaml'), `${content}\n`)
}

function temporaryRoot(prefix: string): string {
  const root = mkdtempSync(join(tmpdir(), prefix))
  temporaryRoots.push(root)
  return root
}

function resultJSON(result: { content: Array<{ type: string; text?: string }> }): any {
  return JSON.parse(textOf(result))
}

function textOf(result: { content: Array<{ type: string; text?: string }> }): string {
  const content = result.content[0]
  expect(content?.type).toBe('text')
  return content?.text ?? ''
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`
}

async function waitFor(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 3_000
  while (Date.now() < deadline) {
    if (predicate()) return
    await Bun.sleep(20)
  }
  throw new Error('timed out waiting for condition')
}
