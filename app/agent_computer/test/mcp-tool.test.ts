import { afterEach, describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { jsonBytes } from '../src/fabric/envelope_proto'
import { RuntimeSkillSummarySchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
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
    writeHTTPMetadata(roots.builtinSkillsRoot, 'main-only', 'shared', 'https://example.test/mcp')

    const servers = await loadEnabledSkillMCPServers({
      enabledSkills: [
        enabledSkill('enabled-one'),
        enabledSkill('enabled-two'),
        create(RuntimeSkillSummarySchema, {
          ...enabledSkill('background-only'),
          metadataJson: jsonBytes({ 'ankole-runtime': 'background_job' })
        }),
        create(RuntimeSkillSummarySchema, {
          ...enabledSkill('main-only'),
          metadataJson: jsonBytes({ 'ankole-runtime': 'main' })
        })
      ],
      skillRoots: roots
    })

    expect(servers).toHaveLength(1)
    expect(servers[0]).toMatchObject({
      name: 'shared',
      description: 'Shared fake server',
      transport: 'streamable_http',
      url: 'https://example.test/mcp',
      sourceSkills: ['enabled-one', 'enabled-two', 'main-only']
    })
    expect(servers[0]?.generation).toMatch(/^[a-f0-9]{64}$/)
  })

  it('discovers an internal BullX Skill declaration without opening the server', async () => {
    const roots = skillRoots()
    const internalSkillsRoot = join(dirname(roots.builtinSkillsRoot), 'internal')
    writeHTTPMetadata(
      internalSkillsRoot,
      'bullx-financial-data',
      'bullx-financial-data',
      'https://ai.agentbull.cn/api/v1/financial-data/mcp',
      'BULLX_FINANCIAL_DATA_MCP_API_KEY',
      'BullX Financial Data MCP server'
    )
    const enabledBullXSkill = create(RuntimeSkillSummarySchema, {
      skillName: 'bullx-financial-data',
      sourceKind: 'builtin',
      relativePath: 'bullx-financial-data',
      skillRoot: 'internal'
    })
    const skillRootsWithInternal = { ...roots, internalSkillsRoot }

    const servers = await loadEnabledSkillMCPServers({
      enabledSkills: [enabledBullXSkill],
      skillRoots: skillRootsWithInternal
    })
    expect(servers).toEqual([
      expect.objectContaining({
        name: 'bullx-financial-data',
        transport: 'streamable_http',
        url: 'https://ai.agentbull.cn/api/v1/financial-data/mcp',
        bearerTokenEnvVar: 'BULLX_FINANCIAL_DATA_MCP_API_KEY',
        sourceSkills: ['bullx-financial-data']
      })
    ])
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

  it('materializes deferred namespace children and calls one selected MCP tool with bearer auth', async () => {
    const requests: FakeRequest[] = []
    const fake = startHTTPMCPServer(requests, { leakAuthorizationInCallKey: true })
    const roots = skillRoots()
    writeHTTPMetadata(roots.builtinSkillsRoot, 'finance', 'finance-data', `${fake.url}/mcp`, 'MCP_TOKEN')
    writeHTTPMetadata(roots.builtinSkillsRoot, 'disabled', 'disabled-data', `${fake.url}/disabled`)

    const tools = await createMCPTools({
      enabledSkills: [enabledSkill('finance')],
      skillRoots: roots,
      workerEnv: { MCP_TOKEN: 'top-secret-token' }
    })
    expect(tools.map(tool => tool.name)).toEqual(['echo', 'large', 'slow'])
    expect(tools.every(tool => tool.namespace === 'mcp__finance_data')).toBe(true)
    expect(tools.every(tool => tool.namespaceDescription === 'Shared fake server')).toBe(true)
    expect(tools.every(tool => tool.deferLoading === true)).toBe(true)
    expect(
      JSON.stringify(tools.map(tool => ({ description: tool.description, schema: tool.jsonSchema })))
    ).not.toContain('top-secret-token')
    expect(requests.filter(request => request.method === 'tools/list')).toHaveLength(1)

    const echo = tools.find(tool => tool.name === 'echo')
    expect(echo?.jsonSchema).toEqual({
      type: 'object',
      properties: { value: { type: 'string' } },
      required: ['value']
    })
    expect(echo?.isReadOnly).toBe(true)
    expect(echo?.isDestructive).toBe(false)

    const called = await echo!.execute('call', { value: 'hello' })
    expect(resultJSON(called)).toMatchObject({
      content: [{ type: 'text', text: 'hello' }]
    })
    expect(textOf(called)).toContain('[REDACTED]')
    expect(textOf(called)).not.toContain('top-secret-token')
    expect(requests.filter(request => request.method === 'tools/call').map(request => request.tool)).toEqual(['echo'])
    expect(requests.every(request => request.authorization === 'Bearer top-secret-token')).toBe(true)
  })

  it('matches Codex 0.146 model visibility, canonical names, raw routing, and search metadata', async () => {
    const requests: FakeRequest[] = []
    const fake = startHTTPMCPServer(requests, {
      instructions: 'Use the market data catalog.',
      tools: [
        {
          name: 'tool.two-three',
          title: 'Market Quote',
          description: 'Fetch one quote.',
          inputSchema: {
            type: 'object',
            properties: {
              security_id: {
                const: '600519',
                description: 'Security identifier.',
                format: 'stock-code',
                examples: ['600519']
              },
              tags: { type: 'array' },
              options: { required: ['market'] }
            },
            required: ['security_id'],
            examples: [{ security_id: '600519' }],
            $defs: { unused: { type: 'string' } }
          }
        },
        {
          name: 'hidden-tool',
          description: 'Only the MCP application UI can use this.',
          inputSchema: { type: 'object', properties: {} },
          _meta: { ui: { visibility: ['app'] } }
        },
        {
          name: 'model-tool',
          description: 'The model can use this.',
          inputSchema: { type: 'object', properties: {} },
          _meta: { ui: { visibility: ['app', 'model'] } }
        },
        {
          name: 'tool.two-three',
          description: 'Duplicate raw identity that Codex skips.',
          inputSchema: { type: 'object', properties: {} }
        }
      ]
    })
    const roots = skillRoots()
    writeHTTPMetadata(roots.builtinSkillsRoot, 'market', 'server.one', `${fake.url}/mcp`)

    const tools = await createMCPTools({ enabledSkills: [enabledSkill('market')], skillRoots: roots })

    expect(tools.map(tool => `${tool.namespace}.${tool.name}`)).toEqual([
      'mcp__server_one.model_tool',
      'mcp__server_one.tool_two_three'
    ])
    expect(tools.every(tool => tool.namespaceDescription === 'Use the market data catalog.')).toBe(true)
    expect(tools.every(tool => JSON.stringify(tool.allowedCallers) === '["direct","programmatic"]')).toBe(true)

    const quote = tools.find(tool => tool.name === 'tool_two_three')
    expect(quote?.description).toBe('Fetch one quote.')
    expect(quote?.jsonSchema).toEqual({
      type: 'object',
      properties: {
        options: {
          type: 'object',
          properties: {},
          required: ['market']
        },
        security_id: {
          type: 'string',
          description: 'Security identifier.',
          enum: ['600519']
        },
        tags: {
          type: 'array',
          items: { type: 'string' }
        }
      },
      required: ['security_id']
    })
    expect(quote?.toolSearchText).toContain('tool.two-three')
    expect(quote?.toolSearchText).toContain('tool_two_three')
    expect(quote?.toolSearchText).toContain('Market Quote')
    expect(quote?.toolSearchText).toContain('server.one')
    expect(quote?.toolSearchText).toContain('Use the market data catalog.')
    expect(quote?.toolSearchText).toContain('security_id')

    await quote!.execute('raw-route', { security_id: '600519' })
    expect(requests.filter(request => request.method === 'tools/call').map(request => request.tool)).toEqual([
      'tool.two-three'
    ])
  })

  it('uses Codex 0.146 collision hashes and keeps every complete model name within 64 bytes', async () => {
    const firstRequests: FakeRequest[] = []
    const secondRequests: FakeRequest[] = []
    const first = startHTTPMCPServer(firstRequests, {
      tools: [
        {
          name: 'tool-name',
          description: 'First colliding tool.',
          inputSchema: { type: 'object', properties: {} }
        },
        {
          name: 'tool_name',
          description: 'Second colliding tool.',
          inputSchema: { type: 'object', properties: {} }
        },
        {
          name: 'extremely_lengthy_function_name_that_absolutely_surpasses_all_reasonable_limits',
          description: 'Long tool.',
          inputSchema: { type: 'object', properties: {} }
        }
      ]
    })
    const second = startHTTPMCPServer(secondRequests, {
      tools: [
        {
          name: 'lookup',
          description: 'Lookup from the second server.',
          inputSchema: { type: 'object', properties: {} }
        }
      ]
    })
    const roots = skillRoots()
    writeHTTPMetadata(roots.builtinSkillsRoot, 'first', 'basic-server', `${first.url}/mcp`)
    writeHTTPMetadata(roots.builtinSkillsRoot, 'second', 'basic_server', `${second.url}/mcp`)

    const tools = await createMCPTools({
      enabledSkills: [enabledSkill('first'), enabledSkill('second')],
      skillRoots: roots
    })
    const completeNames = tools.map(tool => `${tool.namespace}__${tool.name}`)

    expect(new Set(completeNames).size).toBe(completeNames.length)
    expect(completeNames.every(name => /^[A-Za-z0-9_-]+$/.test(name))).toBe(true)
    expect(completeNames.every(name => Buffer.byteLength(name, 'utf8') <= 64)).toBe(true)
    expect(tools.map(tool => tool.namespace).every(name => /^mcp__basic_server_[a-f0-9]{12}$/.test(name!))).toBe(true)
    expect(
      tools
        .filter(tool => tool.description.includes('colliding'))
        .map(tool => tool.name)
        .every(name => /^tool_name_[a-f0-9]{12}$/.test(name))
    ).toBe(true)

    for (const tool of tools) await tool.execute(`call-${tool.name}`, {})
    expect(firstRequests.filter(request => request.method === 'tools/call').map(request => request.tool)).toEqual([
      'extremely_lengthy_function_name_that_absolutely_surpasses_all_reasonable_limits',
      'tool-name',
      'tool_name'
    ])
    expect(secondRequests.filter(request => request.method === 'tools/call').map(request => request.tool)).toEqual([
      'lookup'
    ])
  })

  it('applies Codex enabled_tools allowlist before disabled_tools denylist using raw MCP names', async () => {
    const fake = startHTTPMCPServer([], {
      tools: [
        {
          name: 'allowed-raw',
          description: 'Allowed.',
          inputSchema: { type: 'object', properties: {} }
        },
        {
          name: 'denied-raw',
          description: 'Denied.',
          inputSchema: { type: 'object', properties: {} }
        },
        {
          name: 'not-enabled',
          description: 'Not enabled.',
          inputSchema: { type: 'object', properties: {} }
        }
      ]
    })
    const roots = skillRoots()
    writeMetadata(
      roots.builtinSkillsRoot,
      'filtered',
      [
        'dependencies:',
        '  tools:',
        '    - type: "mcp"',
        '      value: "filtered-server"',
        '      transport: "streamable_http"',
        `      url: ${JSON.stringify(`${fake.url}/mcp`)}`,
        '      enabled_tools: ["allowed-raw", "denied-raw"]',
        '      disabled_tools: ["denied-raw"]'
      ].join('\n')
    )

    const servers = await loadEnabledSkillMCPServers({
      enabledSkills: [enabledSkill('filtered')],
      skillRoots: roots
    })
    expect(servers[0]).toMatchObject({
      enabledTools: ['allowed-raw', 'denied-raw'],
      disabledTools: ['denied-raw']
    })

    const tools = await createMCPTools({ enabledSkills: [enabledSkill('filtered')], skillRoots: roots })
    expect(tools.map(tool => tool.name)).toEqual(['allowed_raw'])
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
    const create = () =>
      createMCPTools({
        enabledSkills: [enabledSkill('leaky')],
        skillRoots: roots,
        workerEnv: { MCP_TOKEN: 'catalog-secret' }
      })

    const failure = await create().catch(error => error as Error)
    expect(failure).toBeInstanceOf(Error)
    if (!(failure instanceof Error)) throw new Error('expected a rejected MCP catalog')
    expect(failure.message).toContain('MCP catalog contained WorkerEnv data and was rejected')
    expect(failure.message).not.toContain('catalog-secret')

    await expect(create()).rejects.toThrow('MCP catalog contained WorkerEnv data and was rejected')
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
    await createMCPTools(options)
    expect(requests.filter(request => request.method === 'tools/list')).toHaveLength(1)

    await createMCPTools(options)
    expect(requests.filter(request => request.method === 'tools/list')).toHaveLength(1)

    await createMCPTools({
      ...options,
      workerEnv: { MCP_TOKEN: 'credential-two' }
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
    await createMCPTools({
      ...options,
      workerEnv: { MCP_TOKEN: 'credential-two' }
    })
    expect(requests.filter(request => request.method === 'tools/list')).toHaveLength(3)
  })

  it('bounds call results and applies total timeout and caller cancellation', async () => {
    const fake = startHTTPMCPServer([])
    const roots = skillRoots()
    writeHTTPMetadata(roots.builtinSkillsRoot, 'bounded', 'bounded-server', `${fake.url}/mcp`)

    const tools = await createMCPTools({ enabledSkills: [enabledSkill('bounded')], skillRoots: roots })
    const largeTool = tools.find(tool => tool.name === 'large')
    const slowTool = tools.find(tool => tool.name === 'slow')
    const large = await largeTool!.execute('large', {})
    const largeText = textOf(large)
    expect(utf8ByteLength(largeText)).toBeLessThanOrEqual(64 * 1024)
    expect(largeText).toContain('...[truncated]')

    const controller = new AbortController()
    setTimeout(() => controller.abort(new Error('caller stopped MCP')), 20)
    const aborted = await slowTool!.execute('abort', { delay_ms: 500 }, controller.signal)
    expect(resultJSON(aborted)).toMatchObject({ isError: true })
    expect(textOf(aborted)).toMatch(/caller stopped MCP|abort/i)
  })

  it('uses the Skill timeout for direct namespace child calls', async () => {
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

    const tools = await createMCPTools({ enabledSkills: [enabledSkill('slow-server')], skillRoots: roots })
    const slow = tools.find(tool => tool.name === 'slow')
    const timedOut = await slow!.execute('server-timeout', { delay_ms: 250 })
    expect(resultJSON(timedOut)).toMatchObject({ isError: true })
    expect(textOf(timedOut)).toMatch(/timed out|abort/i)
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

    const tools = await createMCPTools({
      enabledSkills: [enabledSkill('stdio-skill')],
      skillRoots: roots,
      workerEnv: {
        MCP_CLOSE_MARKER: marker,
        MCP_STDIO_SECRET: 'stdio-secret',
        MCP_STDIO_NOISY_STDERR: 'enabled-noisy-stderr-7f3a'
      }
    })
    const tool = tools.find(tool => tool.name === 'stdio_echo')
    await tool!.execute('stdio-call', { value: 'hello' })

    await waitFor(() => existsSync(marker))
    expect(JSON.parse(readFileSync(marker, 'utf8'))).toEqual({ closed: true, worker_env_seen: true })
  })

  it('cleans up the operation budget when transport preparation rejects missing credentials', async () => {
    const fake = startHTTPMCPServer([])
    const roots = skillRoots()
    writeHTTPMetadata(roots.builtinSkillsRoot, 'missing-token', 'missing-token-server', `${fake.url}/mcp`, 'MCP_TOKEN')
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
      createMCPTools({
        enabledSkills: [enabledSkill('missing-token')],
        skillRoots: roots,
        abortSignal: signal
      })
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
  instructions?: string
  tools?: Array<Record<string, unknown>>
}

function startHTTPMCPServer(requests: FakeRequest[], options: FakeMCPServerOptions = {}): { url: string } {
  const server = Bun.serve({
    hostname: '127.0.0.1',
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
          serverInfo: { name: 'ankole-test-http', version: '1.0.0' },
          instructions: options.instructions ?? 'Shared fake server'
        })
      }
      if (message.method === 'tools/list') {
        const credential = request.headers.get('authorization')?.replace(/^Bearer /, '') ?? ''
        return jsonRPCResult(message.id, {
          tools: options.tools ?? [
            {
              name: 'echo',
              description: 'Echo one value.',
              inputSchema: {
                type: 'object',
                properties: options.leakAuthorizationInCatalog
                  ? { [credential]: { type: 'string' } }
                  : { value: { type: 'string' } },
                required: ['value']
              },
              annotations: { readOnlyHint: true }
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
  return create(RuntimeSkillSummarySchema, { skillName: name, sourceKind: 'builtin', relativePath: name })
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
