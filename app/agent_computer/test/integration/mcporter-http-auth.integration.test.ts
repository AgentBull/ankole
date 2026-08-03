import { afterEach, describe, expect, it } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { materializeMCPorterConfig, type MaterializedMCPorterConfig, type MCPServerConfig } from '../../src/tools/mcp'

describe('mcporter HTTP authentication through the Worker image', () => {
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

  it('adds the Bearer scheme to a token resolved from WorkerEnv', async () => {
    const requests: Array<{ rpcMethod: string | undefined; authorization: string | null }> = []
    server = Bun.serve({
      hostname: '127.0.0.1',
      port: 0,
      async fetch(request) {
        if (request.method !== 'POST') {
          requests.push({
            rpcMethod: undefined,
            authorization: request.headers.get('authorization')
          })
          return new Response('SSE stream is not supported', { status: 405, headers: { Allow: 'POST' } })
        }

        const message = (await request.json()) as { id?: string | number; method?: string }
        requests.push({
          rpcMethod: message.method,
          authorization: request.headers.get('authorization')
        })
        if (request.headers.get('authorization') !== 'Bearer integration-token') {
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

        if (message.method === 'initialize') {
          return jsonRPCResponse(message.id, {
            protocolVersion: '2025-06-18',
            capabilities: { tools: {} },
            serverInfo: { name: 'authenticated-fixture', version: '1.0.0' }
          })
        }
        if (message.method === 'notifications/initialized') return new Response(null, { status: 202 })
        if (message.method === 'tools/list') {
          return jsonRPCResponse(message.id, {
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
        url: `http://127.0.0.1:${server.port}/mcp`,
        bearerTokenEnvVar: 'MCP_AUTH_TOKEN'
      }
    ]
    config = materializeMCPorterConfig(servers, { directory: root })
    const configSource = readFileSync(config.path, 'utf8')
    expect(configSource).toContain('"bearerToken": "${MCP_AUTH_TOKEN}"')
    expect(configSource).not.toContain('integration-token')

    const child = Bun.spawn(
      ['mcporter', 'list', 'authenticated-fixture.echo', '--schema', '--json', '--timeout', '10000'],
      {
        env: { ...process.env, ...config.env, MCP_AUTH_TOKEN: 'integration-token' },
        stdout: 'pipe',
        stderr: 'pipe'
      }
    )
    const [exitCode, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text()
    ])

    expect(exitCode, stderr).toBe(0)
    expect(stdout).toContain('echo')
    expect(requests.map(request => request.rpcMethod)).toContain('initialize')
    expect(requests.map(request => request.rpcMethod)).toContain('tools/list')
    expect(requests.every(request => request.authorization === 'Bearer integration-token')).toBe(true)
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
      ...(error ? { error } : { result })
    },
    { status }
  )
}
