import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { z } from 'zod'
import { buildCodexJobProjection, type CodexJobProjection } from '../../src/core/codex-runner/projection'
import type { AgentTool } from '../../src/core/types'
import { CodexAppServerClient, type JSONRPCMessage } from '../../src/core/codex-runner/app-server-client'
import type { DynamicToolCallParams } from '../../src/core/codex-runner/generated/protocol/v2/DynamicToolCallParams'
import type { ThreadStartParams } from '../../src/core/codex-runner/generated/protocol/v2/ThreadStartParams'
import type { ThreadStartResponse } from '../../src/core/codex-runner/generated/protocol/v2/ThreadStartResponse'
import type { TurnStartParams } from '../../src/core/codex-runner/generated/protocol/v2/TurnStartParams'
import type { TurnStartResponse } from '../../src/core/codex-runner/generated/protocol/v2/TurnStartResponse'

const searchCallID = 'analysis-search'
const analysisCallID = 'analysis-inspect-call'
const nativeMCPSearchCallID = 'native-mcp-search'
const nativeMCPSecondSearchCallID = 'native-mcp-search-again'
const nativeMCPToolCallID = 'native-mcp-stdio-echo'
const nativeMCPSecondToolCallID = 'native-mcp-stdio-echo-again'
const AnalysisArguments = z.object({ metric: z.string(), confidence: z.number().min(0).max(1) })
const analysisInputSchema = {
  type: 'object',
  properties: {
    metric: { type: 'string' },
    confidence: { type: 'number', minimum: 0, maximum: 1 }
  },
  required: ['metric', 'confidence'],
  additionalProperties: false
}

describe('Codex dynamic namespace integration', () => {
  it('runs an allowed non-MCP namespace through real Codex Tool Search without rewriting its input schema', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-dynamic-namespace-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const requests: JSONObject[] = []
    const manifestRequests: string[] = []
    const notifications: JSONRPCMessage[] = []
    const provider = createResponsesCapture(requests, manifestRequests)
    if (typeof provider.port !== 'number') throw new Error('Responses capture server did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      writeCodexConfig(codexHome, workspace, provider.port)
      const projection = buildCodexJobProjection({
        tools: [analysisTool()],
        allowedToolPaths: new Set(['analysis_tools.inspect_data'])
      })
      expect(projection.dynamicTools).toEqual([
        {
          type: 'namespace',
          name: 'analysis_tools',
          description: 'Data analysis tools.',
          tools: [
            {
              type: 'function',
              name: 'inspect_data',
              description: 'Inspect one named metric.',
              inputSchema: analysisInputSchema,
              deferLoading: true
            }
          ]
        }
      ])
      client = codexClient({ workspace, codexHome, notifications, projection })

      const initializeResponse = await client.initialize()
      expect(initializeResponse.userAgent).toContain('/0.146.0 ')
      const models = (await client.request('model/list', { includeHidden: true })) as {
        data: Array<{ model: string }>
      }
      expect(manifestRequests.length).toBeGreaterThan(0)
      expect(manifestRequests.every(url => url.includes('client_version=0.146.0'))).toBe(true)
      expect(models.data.some(model => model.model === 'gpt-5.4')).toBe(true)
      const started = (await client.request('thread/start', {
        cwd: workspace,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        threadSource: 'ankole',
        dynamicTools: projection.dynamicTools
      } satisfies ThreadStartParams)) as ThreadStartResponse
      expect(started.model).toBe('gpt-5.4')
      const turn = (await client.request('turn/start', {
        threadId: started.thread.id,
        input: [{ type: 'text', text: 'Inspect the revenue metric.', text_elements: [] }],
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(() => turnCompleted(notifications, turn.turn.id, 'completed'))

      expect(requests).toHaveLength(3)
      expect(toolTypes(requests[0]!)).toContain('tool_search')
      expect(namespaceSurfaceFromSearch(requests[1]!, searchCallID)).toMatchObject([
        {
          name: 'analysis_tools',
          description: 'Data analysis tools.',
          tools: [
            {
              name: 'inspect_data',
              description: 'Inspect one named metric.',
              strict: false,
              defer_loading: true
            }
          ]
        }
      ])
      expect(functionCallOutputText(requests[2]!, analysisCallID)).toContain('inspected revenue at 0.9 confidence')
    } catch (error) {
      const stderr = notifications
        .filter(notification => notification.method === '$stderr')
        .flatMap(notification => (isRecord(notification.params) ? [notification.params.text] : []))
        .filter((value): value is string => typeof value === 'string')
        .join('')
      throw new Error(`${error instanceof Error ? error.message : String(error)}\n${stderr}`)
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 90_000)

  it('discovers and calls a native MCP tool through the model-visible mcp namespace', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-native-mcp-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const requests: JSONObject[] = []
    const manifestRequests: string[] = []
    const notifications: JSONRPCMessage[] = []
    const provider = createNativeMCPResponsesCapture(requests, manifestRequests)
    if (typeof provider.port !== 'number') throw new Error('Responses capture server did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      writeCodexConfig(codexHome, workspace, provider.port, { nativeMCP: true })
      client = new CodexAppServerClient({
        cwd: workspace,
        env: codexEnvironment(workspace, codexHome),
        onNotification: notification => notifications.push(notification)
      })

      const initializeResponse = await client.initialize()
      expect(initializeResponse.userAgent).toContain('/0.146.0 ')
      const started = (await client.request('thread/start', {
        cwd: workspace,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        threadSource: 'ankole'
      } satisfies ThreadStartParams)) as ThreadStartResponse
      const turn = (await client.request('turn/start', {
        threadId: started.thread.id,
        input: [{ type: 'text', text: 'Echo through the native MCP server.', text_elements: [] }],
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(() => turnCompleted(notifications, turn.turn.id, 'completed'))

      expect(manifestRequests.length).toBeGreaterThan(0)
      expect(requests).toHaveLength(3)
      expect(toolTypes(requests[0]!)).toContain('tool_search')
      const searchContinuationInput = arrayValue(requests[1]!.input).filter(isRecord)
      const latestUserIndex = searchContinuationInput.reduce(
        (latest, item, index) => (item.type === 'message' && item.role === 'user' ? index : latest),
        -1
      )
      const searchOutputIndex = searchContinuationInput.findIndex(
        item => item.type === 'tool_search_output' && item.call_id === nativeMCPSearchCallID
      )
      expect(latestUserIndex).toBeGreaterThanOrEqual(0)
      expect(searchOutputIndex).toBeGreaterThan(latestUserIndex)
      expect(namespaceSurfaceFromSearch(requests[1]!, nativeMCPSearchCallID)).toMatchObject([
        {
          name: 'mcp__native_fixture',
          tools: [
            {
              name: 'stdio_echo',
              description: 'Echo through the local stdio fake server.',
              strict: false,
              defer_loading: true
            }
          ]
        }
      ])
      expect(functionCallOutputText(requests[2]!, nativeMCPToolCallID)).toContain('stdio response')

      const secondTurn = (await client.request('turn/start', {
        threadId: started.thread.id,
        input: [{ type: 'text', text: 'Echo through the same native MCP server again.', text_elements: [] }],
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(() => turnCompleted(notifications, secondTurn.turn.id, 'completed'))

      expect(requests).toHaveLength(6)
      const secondTurnInput = arrayValue(requests[3]!.input).filter(isRecord)
      const secondTurnUserIndex = secondTurnInput.reduce(
        (latest, item, index) => (item.type === 'message' && item.role === 'user' ? index : latest),
        -1
      )
      const retainedSearchOutputIndex = secondTurnInput.findIndex(
        item => item.type === 'tool_search_output' && item.call_id === nativeMCPSearchCallID
      )
      expect(retainedSearchOutputIndex).toBeGreaterThanOrEqual(0)
      expect(secondTurnUserIndex).toBeGreaterThan(retainedSearchOutputIndex)
      expect(namespaceSurfaceFromSearch(requests[4]!, nativeMCPSecondSearchCallID)).toMatchObject([
        {
          name: 'mcp__native_fixture',
          tools: [{ name: 'stdio_echo' }]
        }
      ])
      expect(functionCallOutputText(requests[5]!, nativeMCPSecondToolCallID)).toContain('stdio response')
    } catch (error) {
      const stderr = notifications
        .filter(notification => notification.method === '$stderr')
        .flatMap(notification => (isRecord(notification.params) ? [notification.params.text] : []))
        .filter((value): value is string => typeof value === 'string')
        .join('')
      throw new Error(`${error instanceof Error ? error.message : String(error)}\n${stderr}`)
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 90_000)
})

function analysisTool(): AgentTool<typeof AnalysisArguments> {
  return {
    name: 'inspect_data',
    description: 'Inspect one named metric.',
    schema: AnalysisArguments,
    jsonSchema: analysisInputSchema,
    namespace: 'analysis_tools',
    namespaceDescription: 'Data analysis tools.',
    deferLoading: true,
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => 'Inspect data',
    async execute(_callID, params) {
      return {
        content: [{ type: 'text', text: `inspected ${params.metric} at ${params.confidence} confidence` }],
        details: params
      }
    }
  }
}

function createResponsesCapture(requests: JSONObject[], manifestRequests: string[]) {
  return Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    async fetch(request) {
      const url = new URL(request.url)
      if (request.method === 'GET' && url.pathname === '/v1/models') {
        manifestRequests.push(url.toString())
        return Response.json(codexModelsManifest())
      }
      if (request.method !== 'POST' || url.pathname !== '/v1/responses') {
        return Response.json({ error: { message: 'not found' } }, { status: 404 })
      }

      const body = (await request.json()) as JSONObject
      requests.push(body)
      const model = typeof body.model === 'string' ? body.model : 'gpt-5.4'
      if (requests.length === 1) {
        return sseResponse(
          responseEvents('resp-analysis-search', model, [
            {
              type: 'tool_search_call',
              call_id: searchCallID,
              execution: 'client',
              arguments: { query: 'inspect metric', limit: 8 }
            }
          ])
        )
      }
      if (requests.length === 2) {
        return sseResponse(
          responseEvents('resp-analysis-call', model, [
            {
              type: 'function_call',
              call_id: analysisCallID,
              namespace: 'analysis_tools',
              name: 'inspect_data',
              arguments: JSON.stringify({ metric: 'revenue', confidence: 0.9 })
            }
          ])
        )
      }
      return sseResponse(
        responseEvents('resp-analysis-done', model, [
          {
            id: 'msg-analysis-done',
            type: 'message',
            status: 'completed',
            role: 'assistant',
            content: [{ type: 'output_text', text: 'Revenue inspected.', annotations: [] }]
          }
        ])
      )
    }
  })
}

function createNativeMCPResponsesCapture(requests: JSONObject[], manifestRequests: string[]) {
  return Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    async fetch(request) {
      const url = new URL(request.url)
      if (request.method === 'GET' && url.pathname === '/v1/models') {
        manifestRequests.push(url.toString())
        return Response.json(codexModelsManifest())
      }
      if (request.method !== 'POST' || url.pathname !== '/v1/responses') {
        return Response.json({ error: { message: 'not found' } }, { status: 404 })
      }

      const body = (await request.json()) as JSONObject
      requests.push(body)
      const model = typeof body.model === 'string' ? body.model : 'gpt-5.4'
      if (requests.length === 1) {
        return sseResponse(
          responseEvents('resp-native-mcp-search', model, [
            {
              type: 'tool_search_call',
              call_id: nativeMCPSearchCallID,
              execution: 'client',
              arguments: { query: 'stdio echo', limit: 8 }
            }
          ])
        )
      }
      if (requests.length === 2) {
        return sseResponse(
          responseEvents('resp-native-mcp-call', model, [
            {
              type: 'function_call',
              call_id: nativeMCPToolCallID,
              namespace: 'mcp__native_fixture',
              name: 'stdio_echo',
              arguments: JSON.stringify({ text: 'native MCP' })
            }
          ])
        )
      }
      if (requests.length === 4) {
        return sseResponse(
          responseEvents('resp-native-mcp-search-again', model, [
            {
              type: 'tool_search_call',
              call_id: nativeMCPSecondSearchCallID,
              execution: 'client',
              arguments: { query: 'stdio echo again', limit: 8 }
            }
          ])
        )
      }
      if (requests.length === 5) {
        return sseResponse(
          responseEvents('resp-native-mcp-call-again', model, [
            {
              type: 'function_call',
              call_id: nativeMCPSecondToolCallID,
              namespace: 'mcp__native_fixture',
              name: 'stdio_echo',
              arguments: JSON.stringify({ text: 'native MCP again' })
            }
          ])
        )
      }
      return sseResponse(
        responseEvents('resp-native-mcp-done', model, [
          {
            id: 'msg-native-mcp-done',
            type: 'message',
            status: 'completed',
            role: 'assistant',
            content: [{ type: 'output_text', text: 'Native MCP completed.', annotations: [] }]
          }
        ])
      )
    }
  })
}

function codexModelsManifest(): JSONObject {
  return {
    models: [
      {
        slug: 'gpt-5.4',
        display_name: 'gpt-5.4',
        description: null,
        supported_reasoning_levels: [],
        shell_type: 'default',
        visibility: 'none',
        supported_in_api: true,
        priority: 99,
        availability_nux: null,
        upgrade: null,
        base_instructions: 'Run the supplied test request.',
        default_reasoning_summary: 'auto',
        support_verbosity: false,
        default_verbosity: null,
        apply_patch_tool_type: 'freeform',
        web_search_tool_type: 'text',
        truncation_policy: { mode: 'tokens', limit: 10_000 },
        supports_parallel_tool_calls: false,
        context_window: 272_000,
        max_context_window: 272_000,
        effective_context_window_percent: 95,
        experimental_supported_tools: [],
        input_modalities: ['text'],
        supports_search_tool: true,
        use_responses_lite: false
      }
    ]
  }
}

function codexClient(input: {
  workspace: string
  codexHome: string
  notifications: JSONRPCMessage[]
  projection: CodexJobProjection
}): CodexAppServerClient {
  return new CodexAppServerClient({
    cwd: input.workspace,
    env: codexEnvironment(input.workspace, input.codexHome),
    onNotification: notification => input.notifications.push(notification),
    onServerRequest: async (message, appServer) => {
      if (message.id === undefined || message.method !== 'item/tool/call') {
        if (message.id !== undefined) {
          await appServer.respondError(message.id, -32601, 'Unsupported test server request')
        }
        return
      }
      const response = await input.projection.handleToolCall(
        message.params as DynamicToolCallParams,
        new AbortController().signal
      )
      await appServer.respond(message.id, response)
    }
  })
}

function codexEnvironment(workspace: string, codexHome: string): Record<string, string> {
  return {
    PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
    HOME: workspace,
    CODEX_HOME: codexHome,
    OPENAI_API_KEY: 'contract-key',
    CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
    LANG: 'C.UTF-8'
  }
}

function writeCodexConfig(
  codexHome: string,
  workspace: string,
  port: number,
  options: { nativeMCP?: boolean } = {}
): void {
  const trustedWorkspace = workspace.replaceAll('\\', '\\\\').replaceAll('"', '\\"')
  const nativeMCP = options.nativeMCP
    ? `
[mcp_servers.native_fixture]
command = "bun"
args = ["/repo/app/agent_computer/test/fixtures/mcp-stdio-server.ts"]
cwd = "/repo/app/agent_computer"
required = true
startup_timeout_sec = 10
tool_timeout_sec = 10
enabled_tools = ["stdio_echo"]
`
    : ''
  writeFileSync(
    join(codexHome, 'config.toml'),
    `model = "gpt-5.4"
model_provider = "contract"

[model_providers.contract]
name = "Ankole dynamic namespace contract"
base_url = "http://127.0.0.1:${port}/v1"
wire_api = "responses"
supports_websockets = false

[model_providers.contract.auth]
command = "/bin/sh"
args = ["-c", "printf %s \\"$OPENAI_API_KEY\\""]
refresh_interval_ms = 0

[projects."${trustedWorkspace}"]
trust_level = "trusted"
${nativeMCP}
`
  )
}

function namespaceSurfaceFromSearch(request: JSONObject, callID: string) {
  const output = arrayValue(request.input)
    .filter(isRecord)
    .find(item => item.type === 'tool_search_output' && item.call_id === callID)
  return arrayValue(output?.tools)
    .filter(isRecord)
    .filter(tool => tool.type === 'namespace')
    .map(namespace => ({
      name: namespace.name,
      description: namespace.description,
      tools: arrayValue(namespace.tools)
        .filter(isRecord)
        .map(tool => ({
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters,
          strict: tool.strict === true,
          defer_loading: tool.defer_loading === true
        }))
    }))
}

function functionCallOutputText(request: JSONObject, callID: string): string {
  const output = arrayValue(request.input)
    .filter(isRecord)
    .find(item => item.type === 'function_call_output' && item.call_id === callID)?.output
  if (typeof output === 'string') return output
  return arrayValue(output)
    .filter(isRecord)
    .flatMap(item => (typeof item.text === 'string' ? [item.text] : []))
    .join('\n')
}

function toolTypes(request: JSONObject): string[] {
  return arrayValue(request.tools)
    .filter(isRecord)
    .flatMap(tool => (typeof tool.type === 'string' ? [tool.type] : []))
}

function responseEvents(responseID: string, model: string, items: JSONObject[]): JSONObject[] {
  const response = {
    id: responseID,
    object: 'response',
    created_at: 1_764_967_971,
    completed_at: null,
    status: 'in_progress',
    model,
    previous_response_id: null,
    output: [],
    usage: null
  }
  return [
    { type: 'response.created', sequence_number: 0, response },
    ...items.map((item, index) => ({
      type: 'response.output_item.done',
      sequence_number: index + 1,
      output_index: index,
      item
    })),
    {
      type: 'response.completed',
      sequence_number: items.length + 1,
      response: {
        ...response,
        completed_at: 1_764_967_972,
        status: 'completed',
        output: items,
        usage: {
          input_tokens: 1,
          input_tokens_details: { cached_tokens: 0 },
          output_tokens: 1,
          output_tokens_details: { reasoning_tokens: 0 },
          total_tokens: 2
        }
      }
    }
  ]
}

function sseResponse(events: JSONObject[]): Response {
  return new Response(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(''), {
    headers: {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
      connection: 'keep-alive'
    }
  })
}

function turnCompleted(notifications: JSONRPCMessage[], turnID: string, status: string): boolean {
  return notifications.some(notification => {
    if (notification.method !== 'turn/completed' || !isRecord(notification.params)) return false
    const turn = notification.params.turn
    return isRecord(turn) && turn.id === turnID && turn.status === status
  })
}

async function waitFor(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 60_000
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('timed out waiting for Codex dynamic namespace turn')
    await Bun.sleep(10)
  }
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
