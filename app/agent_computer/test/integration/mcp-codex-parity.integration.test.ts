import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { z } from 'zod'
import type { ModelConfig, ToolSet } from '../../src/core/llm'
import { buildResponseCreateParams } from '../../src/core/llm/wire'
import type { AgentTool } from '../../src/core'
import { RuntimeSkillSummarySchema } from '../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { RuntimeSkillSummary } from '../../src/lanes/rpc_lane'
import {
  CODEX_OPT_OUT_NOTIFICATION_METHODS,
  CodexAppServerClient,
  type JSONRPCMessage
} from '../../src/tools/codex/app-server-client'
import type { ThreadStartParams } from '../../src/tools/codex/generated/protocol/v2/ThreadStartParams'
import type { ThreadStartResponse } from '../../src/tools/codex/generated/protocol/v2/ThreadStartResponse'
import type { TurnStartParams } from '../../src/tools/codex/generated/protocol/v2/TurnStartParams'
import type { TurnStartResponse } from '../../src/tools/codex/generated/protocol/v2/TurnStartResponse'
import { createMCPTools } from '../../src/tools/mcp'

const enabledTools = [
  'tool.two-three',
  'hidden-tool',
  'model-tool',
  'tool-name',
  'tool_name',
  'extremely_lengthy_function_name_that_absolutely_surpasses_all_reasonable_limits',
  'denied-raw'
]
const disabledTools = ['denied-raw']

describe('@ankole/agent-computer MCP Codex parity contract', () => {
  it('projects the exact Codex 0.146 model-visible MCP surface', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-mcp-codex-parity-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const skillsRoot = join(root, 'skills')
    const requests: JSONObject[] = []
    const notifications: JSONRPCMessage[] = []
    const provider = createResponsesCapture(requests)
    if (typeof provider.port !== 'number') throw new Error('Responses capture server did not bind a TCP port')
    const fixture = join(import.meta.dir, '..', 'fixtures', 'mcp-stdio-server.ts')
    const command = `MCP_PARITY_FIXTURE=codex-0.146 ${shellQuote(process.execPath)} ${shellQuote(fixture)}`
    let client: CodexAppServerClient | undefined

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      writeSkill(skillsRoot, command)
      writeCodexConfig(codexHome, provider.port, command)

      client = codexClient({ workspace, codexHome, notifications })
      await initializeCodex(client)

      const mainTools = await createMCPTools({
        enabledSkills: [enabledSkill('parity')],
        skillRoots: {
          builtinSkillsRoot: skillsRoot,
          agentInstalledSkillsRoot: join(root, 'installed-skills')
        }
      })
      const mainRequest = buildResponseCreateParams(modelStub(), {
        messages: [{ role: 'user', content: 'CAPTURE_MCP_SURFACE' }],
        tools: agentToolSet(mainTools),
        programmaticToolCalling: true
      })

      const started = (await client.request('thread/start', {
        cwd: workspace,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        threadSource: 'ankole'
      } satisfies ThreadStartParams)) as ThreadStartResponse
      const turn = (await client.request('turn/start', {
        ['threadId']: started.thread.id,
        input: [{ type: 'text', text: 'CAPTURE_MCP_SURFACE', text_elements: [] }],
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(() => turnCompleted(notifications, turn.turn.id, 'completed'))

      expect(requests).toHaveLength(2)
      expect(mcpSurface(mainRequest as unknown as JSONObject)).toEqual(
        mergeNamespaceSurfaces([
          toolSearchSurface(requests[1]!, 'mcp-parity-search-tools'),
          toolSearchSurface(requests[1]!, 'mcp-parity-search-quote')
        ])
      )
      expect(toolTypes(mainRequest as unknown as JSONObject)).toContain('tool_search')
      expect(toolTypes(requests[0]!)).toContain('tool_search')
      expect(toolTypes(mainRequest as unknown as JSONObject)).toContain('programmatic_tool_calling')
      expect(mainTools.every(tool => tool.allowedCallers?.includes('programmatic'))).toBe(true)
      expect(
        mergeNamespaceSurfaces([
          toolSearchSurface(requests[1]!, 'mcp-parity-search-tools'),
          toolSearchSurface(requests[1]!, 'mcp-parity-search-quote')
        ])
          .flatMap(namespace => namespace.tools)
          .every(tool => Buffer.byteLength(`${tool.namespace}__${tool.name}`, 'utf8') <= 64)
      ).toBe(true)
    } catch (error) {
      const stderr = notifications
        .filter(notification => notification.method === '$stderr')
        .map(notification => (isRecord(notification.params) ? notification.params.text : ''))
        .filter((text): text is string => typeof text === 'string')
        .join('')
      throw new Error(`${error instanceof Error ? error.message : String(error)}\n${stderr}`)
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 60_000)
})

function createResponsesCapture(requests: JSONObject[]) {
  return Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    async fetch(request) {
      const url = new URL(request.url)
      if (request.method !== 'POST' || url.pathname !== '/v1/responses') {
        return Response.json({ error: { message: 'not found' } }, { status: 404 })
      }

      const body = (await request.json()) as JSONObject
      requests.push(body)
      const model = typeof body.model === 'string' ? body.model : 'gpt-5.4'
      if (requests.length === 1) {
        return sseResponse(
          toolSearchEvents('resp_mcp_search', model, [
            { callID: 'mcp-parity-search-tools', query: 'tool' },
            { callID: 'mcp-parity-search-quote', query: 'tool.two-three' }
          ])
        )
      }
      return sseResponse(messageEvents('resp_mcp_parity', model, 'surface captured'))
    }
  })
}

function codexClient(input: {
  workspace: string
  codexHome: string
  notifications: JSONRPCMessage[]
}): CodexAppServerClient {
  return new CodexAppServerClient({
    cwd: input.workspace,
    env: {
      PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
      HOME: process.env.HOME ?? input.workspace,
      CODEX_HOME: input.codexHome,
      OPENAI_API_KEY: 'contract-key',
      CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
      LANG: 'C.UTF-8'
    },
    onNotification: notification => input.notifications.push(notification)
  })
}

async function initializeCodex(client: CodexAppServerClient): Promise<void> {
  await client.request(
    'initialize',
    {
      clientInfo: {
        name: 'ankole_agent_computer',
        title: 'Ankole Agent Computer',
        version: '0.1.0'
      },
      capabilities: {
        ['experimentalApi']: true,
        ['optOutNotificationMethods']: [...CODEX_OPT_OUT_NOTIFICATION_METHODS]
      }
    },
    30_000
  )
  await client.notify('initialized', {})
}

function writeCodexConfig(codexHome: string, port: number, command: string): void {
  const serverConfig = (name: string) => `
[mcp_servers.${JSON.stringify(name)}]
command = "/bin/sh"
args = ["-lc", ${JSON.stringify(command)}]
enabled_tools = ${JSON.stringify(enabledTools)}
disabled_tools = ${JSON.stringify(disabledTools)}
tool_timeout_sec = 10
`
  writeFileSync(
    join(codexHome, 'config.toml'),
    `model = "gpt-5.4"
model_provider = "contract"
model_reasoning_effort = "low"
approval_policy = "never"
sandbox_mode = "danger-full-access"
cli_auth_credentials_store = "file"
web_search = "disabled"

[features]
memories = false
remote_compaction_v2 = false
multi_agent = false
apps = false
enable_mcp_apps = false
tool_suggest = false
plugins = false

[features.code_mode]
enabled = true

[model_providers.contract]
name = "Ankole MCP parity contract"
base_url = "http://127.0.0.1:${port}/v1"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
supports_websockets = false
${serverConfig('basic-server')}
`
  )
}

function writeSkill(skillsRoot: string, command: string): void {
  const root = join(skillsRoot, 'parity')
  mkdirSync(join(root, 'agents'), { recursive: true })
  writeFileSync(join(root, 'SKILL.md'), '---\nname: parity\ndescription: MCP parity fixture.\n---\n')
  writeFileSync(
    join(root, 'agents', 'openai.yaml'),
    `dependencies:
  tools:
    - type: "mcp"
      value: "basic-server"
      transport: "stdio"
      command: ${JSON.stringify(command)}
      enabled_tools: ${JSON.stringify(enabledTools)}
      disabled_tools: ${JSON.stringify(disabledTools)}
`
  )
}

function enabledSkill(name: string): RuntimeSkillSummary {
  return create(RuntimeSkillSummarySchema, { skillName: name, sourceKind: 'builtin', relativePath: name })
}

function agentToolSet(tools: AgentTool[]): ToolSet {
  return Object.fromEntries(
    tools.map(tool => [
      `${tool.namespace}.${tool.name}`,
      {
        name: tool.name,
        description: tool.description,
        parameters: tool.schema as z.ZodType,
        jsonSchema: tool.jsonSchema,
        namespace: tool.namespace,
        namespaceDescription: tool.namespaceDescription,
        deferLoading: tool.deferLoading,
        toolSearchText: tool.toolSearchText,
        allowedCallers: tool.allowedCallers
      }
    ])
  )
}

function modelStub(): ModelConfig {
  return {
    client: undefined as never,
    selector: 'gpt-5.4',
    name: 'gpt-5.4',
    provider: 'contract'
  }
}

type MCPToolSurface = {
  namespace: string
  name: string
  description: string
  parameters: unknown
  strict: boolean
  defer_loading: boolean
}

type MCPNamespaceSurface = {
  name: string
  description: string
  tools: MCPToolSurface[]
}

function mcpSurface(request: JSONObject): MCPNamespaceSurface[] {
  const tools = Array.isArray(request.tools) ? request.tools : []
  return namespaceSurface(tools)
}

function toolSearchSurface(request: JSONObject, callID: string): MCPNamespaceSurface[] {
  const input = Array.isArray(request.input) ? request.input : []
  const output = input.filter(isRecord).find(item => item.type === 'tool_search_output' && item.call_id === callID)
  return namespaceSurface(output && Array.isArray(output.tools) ? output.tools : [])
}

function namespaceSurface(tools: unknown[]): MCPNamespaceSurface[] {
  return tools
    .filter(isRecord)
    .filter(tool => tool.type === 'namespace' && typeof tool.name === 'string' && tool.name.startsWith('mcp__'))
    .map(namespace => ({
      name: namespace.name as string,
      description: typeof namespace.description === 'string' ? namespace.description : '',
      tools: (Array.isArray(namespace.tools) ? namespace.tools : [])
        .filter(isRecord)
        .map(tool => ({
          namespace: namespace.name as string,
          name: typeof tool.name === 'string' ? tool.name : '',
          description: typeof tool.description === 'string' ? tool.description : '',
          parameters: tool.parameters,
          strict: tool.strict === true,
          defer_loading: tool.defer_loading === true
        }))
        .sort((left, right) => left.name.localeCompare(right.name))
    }))
    .sort((left, right) => left.name.localeCompare(right.name))
}

function mergeNamespaceSurfaces(surfaces: MCPNamespaceSurface[][]): MCPNamespaceSurface[] {
  const namespaces = new Map<string, MCPNamespaceSurface>()
  for (const surface of surfaces.flat()) {
    const current = namespaces.get(surface.name) ?? { ...surface, tools: [] }
    const tools = new Map(current.tools.map(tool => [tool.name, tool]))
    for (const tool of surface.tools) tools.set(tool.name, tool)
    current.tools = [...tools.values()].sort((left, right) => left.name.localeCompare(right.name))
    namespaces.set(surface.name, current)
  }
  return [...namespaces.values()].sort((left, right) => left.name.localeCompare(right.name))
}

function toolTypes(request: JSONObject): string[] {
  return (Array.isArray(request.tools) ? request.tools : [])
    .filter(isRecord)
    .flatMap(tool => (typeof tool.type === 'string' ? [tool.type] : []))
}

function messageEvents(responseID: string, model: string, text: string): JSONObject[] {
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
  const item = {
    id: `msg_${responseID}`,
    type: 'message',
    status: 'completed',
    role: 'assistant',
    content: [{ type: 'output_text', text, annotations: [] }]
  }
  const completed = {
    ...response,
    completed_at: 1_764_967_972,
    status: 'completed',
    output: [item],
    usage: {
      input_tokens: 1,
      input_tokens_details: { cached_tokens: 0 },
      output_tokens: 1,
      output_tokens_details: { reasoning_tokens: 0 },
      total_tokens: 2
    }
  }

  return [
    { type: 'response.created', sequence_number: 0, response },
    { type: 'response.output_item.added', sequence_number: 1, output_index: 0, item },
    { type: 'response.output_item.done', sequence_number: 2, output_index: 0, item },
    { type: 'response.completed', sequence_number: 3, response: completed }
  ]
}

function toolSearchEvents(
  responseID: string,
  model: string,
  calls: Array<{ callID: string; query: string }>
): JSONObject[] {
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
  const items = calls.map(call => ({
    type: 'tool_search_call',
    call_id: call.callID,
    execution: 'client',
    arguments: { query: call.query, limit: 8 }
  }))

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
  const deadline = Date.now() + 10_000
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('timed out waiting for Codex MCP parity turn')
    await Bun.sleep(10)
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`
}
