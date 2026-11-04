import { afterEach, describe, expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  materializeMCPorterConfig,
  type MaterializedMCPorterConfig,
  type MCPServerConfig
} from '../../../src/tools/mcp'

describe('mcporter HTTP authentication', () => {
  let config: MaterializedMCPorterConfig | undefined
  let root: string | undefined
  let server: ReturnType<typeof Bun.serve> | undefined

  afterEach(() => {
    config?.cleanup()
    config = undefined
    server?.stop(true)
    server = undefined
    if (root) rmSync(root, { recursive: true, force: true })
    root = undefined
  })

  it('routes Skill HTTP through the Turn-authenticated gateway without an upstream credential', async () => {
    const requests: Array<{ rpcMethod: string | undefined; authorization: string | null; path: string }> = []
    server = Bun.serve({
      hostname: '127.0.0.1',
      port: 0,
      async fetch(request) {
        if (request.method !== 'POST') {
          requests.push({
            rpcMethod: undefined,
            authorization: request.headers.get('authorization'),
            path: new URL(request.url).pathname
          })
          return new Response('SSE stream is not supported', { status: 405, headers: { Allow: 'POST' } })
        }

        const message = (await request.json()) as { id?: string | number; method?: string }
        requests.push({
          rpcMethod: message.method,
          authorization: request.headers.get('authorization'),
          path: new URL(request.url).pathname
        })
        if (request.headers.get('authorization') !== 'Bearer integration-turn-token') {
          return jsonRPCResponse(
            message.id,
            undefined,
            {
              code: -32001,
              message: 'unauthorized'
            },
            401
          )
        }

        if (message.method === 'server/discover') {
          return jsonRPCResponse(message.id, {
            supportedVersions: ['2026-07-28'],
            capabilities: { tools: {} },
            ttlMs: 0,
            cacheScope: 'private'
          })
        }
        if (message.method === 'notifications/initialized') return new Response(null, { status: 202 })
        if (message.method === 'tools/list') {
          return jsonRPCResponse(message.id, {
            ttlMs: 0,
            cacheScope: 'private',
            tools: [
              {
                name: 'echo',
                description: 'Echo one value.',
                inputSchema: { type: 'object', properties: { value: { type: 'string' } } }
              }
            ]
          })
        }
        return jsonRPCResponse(message.id, undefined, { code: -32601, message: 'not found' }, 404)
      }
    })

    root = mkdtempSync(join(tmpdir(), 'ankole-mcporter-http-auth-'))
    const servers: MCPServerConfig[] = [
      {
        name: 'authenticated-fixture',
        sourceSkills: ['authenticated-fixture'],
        transport: 'streamable_http',
        url: 'https://upstream.example/mcp',
        bearerTokenEnvVar: 'MCP_AUTH_TOKEN'
      }
    ]
    config = materializeMCPorterConfig(servers, {
      directory: root,
      gatewayOrigin: `http://127.0.0.1:${server.port}`,
      gatewayToken: 'integration-turn-token'
    })
    const configSource = readFileSync(config.path, 'utf8')
    expect(configSource).toContain('"bearerToken": "integration-turn-token"')
    expect(configSource).not.toContain('MCP_AUTH_TOKEN')
    expect(configSource).not.toContain('upstream.example')

    const child = Bun.spawn(
      ['mcporter', 'list', 'authenticated-fixture.echo', '--schema', '--json', '--timeout', '10000'],
      {
        env: { ...process.env, ...config.env },
        stdout: 'pipe',
        stderr: 'pipe'
      }
    )
    const [exitCode, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text()
    ])

    expect(exitCode, stderr || stdout).toBe(0)
    expect(stdout).toContain('echo')
    expect(requests.map(request => request.rpcMethod)).toContain('server/discover')
    expect(requests.map(request => request.rpcMethod)).toContain('tools/list')
    expect(requests.every(request => request.authorization === 'Bearer integration-turn-token')).toBe(true)
    expect(
      requests.every(request => request.path === '/api/internal/mcp/skills/authenticated-fixture/authenticated-fixture')
    ).toBe(true)
  })
})

function jsonRPCResponse(
  id: string | number | undefined,
  result: unknown,
  error?: { code: number; message: string },
  status = 200
): Response {
  return Response.json(
    {
      jsonrpc: '2.0',
      ...(id === undefined ? {} : { id }),
      ...(error ? { error } : { result: { ...(result as object), resultType: 'complete' } })
    },
    { status }
  )
}
