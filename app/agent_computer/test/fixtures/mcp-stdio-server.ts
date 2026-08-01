import { writeSync } from 'node:fs'

if (process.env.MCP_STDIO_NOISY_STDERR === 'enabled-noisy-stderr-7f3a') {
  const chunk = Buffer.alloc(64 * 1024, 'x')
  for (let index = 0; index < 64; index++) writeSync(2, chunk)
}

let input = ''

process.stdin.setEncoding('utf8')
process.stdin.on('data', chunk => {
  input += chunk
  for (;;) {
    const lineEnd = input.indexOf('\n')
    if (lineEnd === -1) break
    const line = input.slice(0, lineEnd).trim()
    input = input.slice(lineEnd + 1)
    if (line) handleMessage(JSON.parse(line) as JSONRPCRequest)
  }
})

process.stdin.on('end', () => {
  const marker = process.env.MCP_CLOSE_MARKER
  if (!marker) return process.exit(0)

  void Bun.write(
    marker,
    JSON.stringify({
      closed: true,
      worker_env_seen: process.env.MCP_STDIO_SECRET === 'stdio-secret'
    })
  ).finally(() => process.exit(0))
})

interface JSONRPCRequest {
  jsonrpc: '2.0'
  id?: string | number
  method: string
  params?: Record<string, unknown>
}

function handleMessage(message: JSONRPCRequest): void {
  if (message.id === undefined) return
  if (message.method === 'initialize') {
    const responseBytes = Number(process.env.MCP_STDIO_RESPONSE_BYTES ?? 0)
    send(message.id, {
      protocolVersion: '2025-06-18',
      capabilities: { tools: {} },
      serverInfo: { name: 'ankole-test-stdio', version: '1.0.0' },
      ...(responseBytes > 0 ? { oversized: 'x'.repeat(responseBytes) } : {}),
      ...(parityFixtureEnabled() ? { instructions: 'Use the parity market data catalog.' } : {})
    })
    return
  }

  if (message.method === 'tools/list') {
    send(message.id, {
      tools: parityFixtureEnabled()
        ? parityTools()
        : [
            {
              name: 'stdio_echo',
              description: 'Echo through the local stdio fake server.',
              inputSchema: { type: 'object', properties: { text: { type: 'string' } } }
            }
          ]
    })
    return
  }

  if (message.method === 'tools/call') {
    send(message.id, { content: [{ type: 'text', text: 'stdio response' }] })
    return
  }

  process.stdout.write(
    `${JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'not found' } })}\n`
  )
}

function send(id: string | number, result: unknown): void {
  process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id, result })}\n`)
}

function parityFixtureEnabled(): boolean {
  return process.env.MCP_PARITY_FIXTURE === 'codex-0.146'
}

function parityTools(): Array<Record<string, unknown>> {
  return [
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
      },
      outputSchema: {
        type: 'object',
        properties: { price: { type: 'number' } },
        required: ['price']
      },
      annotations: { readOnlyHint: true }
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
    },
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
    },
    {
      name: 'denied-raw',
      description: 'Disabled by raw MCP name.',
      inputSchema: { type: 'object', properties: {} }
    },
    {
      name: 'not-enabled',
      description: 'Not present in the allowlist.',
      inputSchema: { type: 'object', properties: {} }
    }
  ]
}
