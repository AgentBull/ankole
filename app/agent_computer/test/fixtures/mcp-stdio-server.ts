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
    send(message.id, {
      protocolVersion: '2025-06-18',
      capabilities: { tools: {} },
      serverInfo: { name: 'ankole-test-stdio', version: '1.0.0' }
    })
    return
  }

  if (message.method === 'tools/list') {
    send(message.id, {
      tools: [
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
