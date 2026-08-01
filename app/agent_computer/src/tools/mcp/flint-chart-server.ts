import { flintChartDirectMCPServer } from './direct-registry'

const enabledTools = new Set(flintChartDirectMCPServer.enabledTools)
const chartTools = new Set(['compile_chart', 'render_chart', 'validate_chart'])
const blockedChartTypes = new Set(['map', 'choropleth'])

const toolDescriptions: Record<string, string> = {
  compile_chart: 'Compile a Flint chart into a Vega-Lite specification without rendering it.',
  list_chart_types: 'List supported Flint chart types and their Vega-Lite encoding channels.',
  render_chart: 'Render a static Flint chart. PNG is the default. Request SVG only when vector output is needed.',
  validate_chart: 'Validate a Flint chart for the Vega-Lite backend without rendering it.'
}

const bunx = Bun.which('bunx')
if (!bunx) throw new Error('flint-chart MCP proxy requires bunx')

const upstream = Bun.spawn(
  [bunx, '--bun', '--no-install', 'flint-chart-mcp', '--backends', 'vegalite', '--disable-file-reference'],
  {
    cwd: process.cwd(),
    env: process.env,
    stdin: 'pipe',
    stdout: 'pipe',
    stderr: 'inherit'
  }
)

type PendingOperation = 'initialize' | 'list_chart_types' | 'tools_list'
const pendingOperations = new Map<string, PendingOperation>()

const stopUpstream = () => upstream.kill()
process.once('SIGINT', stopUpstream)
process.once('SIGTERM', stopUpstream)

const clientPump = pumpNodeLines(process.stdin, async line => {
  const message = parseMessage(line)
  const id = messageID(message)
  const method = stringValue(message.method)

  if (id && method && methodIsUnavailable(method)) {
    writeMethodUnavailable(message.id, method)
    return
  }

  if (id && method === 'initialize') pendingOperations.set(id, 'initialize')
  if (id && method === 'tools/list') pendingOperations.set(id, 'tools_list')

  if (id && method === 'tools/call') {
    const params = recordValue(message.params)
    const toolName = stringValue(params.name)
    const args = { ...recordValue(params.arguments) }
    const chartType = stringValue(recordValue(args.chart_spec).chartType)?.trim().toLowerCase()

    if (toolName && !enabledTools.has(toolName)) {
      writeMethodUnavailable(message.id, `tools/call ${toolName}`)
      return
    }

    if (toolName && chartTools.has(toolName) && chartType && blockedChartTypes.has(chartType)) {
      writeMessage({
        jsonrpc: '2.0',
        id: message.id,
        result: {
          content: [{ type: 'text', text: 'Error: Flint Map and Choropleth charts are disabled in Ankole.' }],
          isError: true
        }
      })
      return
    }

    if (toolName === 'render_chart' && args.format === undefined) args.format = 'png'
    if (toolName === 'list_chart_types') pendingOperations.set(id, 'list_chart_types')

    await writeUpstream(
      JSON.stringify({
        ...message,
        params: { ...params, arguments: args }
      })
    )
    return
  }

  await writeUpstream(JSON.stringify(message))
})

const serverPump = pumpWebLines(upstream.stdout, line => {
  const message = parseMessage(line)
  const id = messageID(message)
  const operation = id ? pendingOperations.get(id) : undefined
  if (id) pendingOperations.delete(id)

  if (operation === 'initialize') rewriteInitializeResult(message)
  if (operation === 'tools_list') rewriteToolsList(message)
  if (operation === 'list_chart_types') rewriteChartTypeResult(message)
  writeMessage(message)
})

clientPump.catch(error => {
  process.stderr.write(`flint-chart MCP proxy input failed: ${errorMessage(error)}\n`)
  upstream.kill()
})

const exitCode = await upstream.exited
process.stdin.pause()
await serverPump
process.exit(exitCode)

async function pumpNodeLines(
  stream: NodeJS.ReadableStream,
  handleLine: (line: string) => Promise<void> | void
): Promise<void> {
  let buffer = ''
  stream.setEncoding('utf8')
  for await (const chunk of stream) {
    buffer += String(chunk)
    buffer = await drainLines(buffer, handleLine)
  }
  if (buffer.trim()) await handleLine(buffer.trim())
  upstream.stdin.end()
}

async function pumpWebLines(
  stream: ReadableStream<Uint8Array>,
  handleLine: (line: string) => Promise<void> | void
): Promise<void> {
  const decoder = new TextDecoder()
  const reader = stream.getReader()
  let buffer = ''
  for (;;) {
    const { value, done } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })
    buffer = await drainLines(buffer, handleLine)
  }
  buffer += decoder.decode()
  if (buffer.trim()) await handleLine(buffer.trim())
}

async function drainLines(input: string, handleLine: (line: string) => Promise<void> | void): Promise<string> {
  let buffer = input
  for (;;) {
    const lineEnd = buffer.indexOf('\n')
    if (lineEnd < 0) return buffer
    const line = buffer.slice(0, lineEnd).trim()
    buffer = buffer.slice(lineEnd + 1)
    if (line) await handleLine(line)
  }
}

async function writeUpstream(line: string): Promise<void> {
  upstream.stdin.write(`${line}\n`)
  await upstream.stdin.flush()
}

function writeMessage(message: Record<string, unknown>): void {
  process.stdout.write(`${JSON.stringify(message)}\n`)
}

function writeMethodUnavailable(id: unknown, method: string): void {
  writeMessage({
    jsonrpc: '2.0',
    id,
    error: { code: -32601, message: `Flint MCP method is not available in Ankole: ${method}` }
  })
}

function methodIsUnavailable(method: string): boolean {
  return method.startsWith('prompts/') || method.startsWith('resources/') || method.startsWith('completion/')
}

function rewriteInitializeResult(message: Record<string, unknown>): void {
  const result = recordValue(message.result)
  if (Object.keys(result).length === 0) return
  const capabilities = recordValue(result.capabilities)
  message.result = {
    ...result,
    capabilities: { tools: recordValue(capabilities.tools) },
    instructions: flintChartDirectMCPServer.description
  }
}

function rewriteToolsList(message: Record<string, unknown>): void {
  const result = recordValue(message.result)
  if (!Array.isArray(result.tools)) return

  const tools = result.tools.flatMap(tool => {
    const record = recordValue(tool)
    const name = stringValue(record.name)
    if (!name || !enabledTools.has(name)) return []
    return [{ ...record, description: toolDescriptions[name] ?? stringValue(record.description) ?? '' }]
  })
  message.result = { ...result, tools }
}

function rewriteChartTypeResult(message: Record<string, unknown>): void {
  const result = recordValue(message.result)
  if (!Array.isArray(result.content)) return

  message.result = {
    ...result,
    content: result.content.map(part => {
      const content = recordValue(part)
      if (content.type !== 'text' || typeof content.text !== 'string') return part
      try {
        const catalogs = JSON.parse(content.text)
        if (!Array.isArray(catalogs)) return part
        const filtered = catalogs.map(catalog => {
          const value = recordValue(catalog)
          const chartTypes = Array.isArray(value.chartTypes)
            ? value.chartTypes.filter(entry => {
                const chartType = stringValue(recordValue(entry).chartType)?.trim().toLowerCase()
                return !chartType || !blockedChartTypes.has(chartType)
              })
            : []
          return { ...value, count: chartTypes.length, chartTypes }
        })
        return { ...content, text: JSON.stringify(filtered, null, 2) }
      } catch {
        return part
      }
    })
  }
}

function parseMessage(line: string): Record<string, unknown> {
  const value = JSON.parse(line)
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('MCP stdio message must be a JSON object')
  }
  return value as Record<string, unknown>
}

function messageID(message: Record<string, unknown>): string | undefined {
  const id = message.id
  return typeof id === 'string' || typeof id === 'number' ? `${typeof id}:${id}` : undefined
}

function recordValue(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : {}
}

function stringValue(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
