import { mkdirAgentSync } from '../../../src/common/agent-user'
import { resetCodexAgentRuntimeConfig } from '../../support/codex-runtime-config'
import { create } from '@bufbuild/protobuf'
import { isRecord, type JsonObject as JSONObject } from '@agentbull/active-support'
import { describe, expect, it } from 'bun:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { AIGatewayAPIKeyResponseSchema } from '../../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { CodexAppServerClient, type JSONRPCMessage } from '../../../src/core/codex-runner/runtime/app-server-client'
import type { ThreadStartParams } from '../../../src/core/codex-runner/generated/protocol/v2/ThreadStartParams'
import type { ThreadStartResponse } from '../../../src/core/codex-runner/generated/protocol/v2/ThreadStartResponse'
import type { TurnStartResponse } from '../../../src/core/codex-runner/generated/protocol/v2/TurnStartResponse'
import { refreshCodexAgentRuntimeCredential } from '../../../src/core/codex-runner/runtime/agent-home-config'
import {
  materializeCodexJobProjectConfig,
  readCodexJobProjectConfig
} from '../../../src/core/codex-runner/job/project-config'
import { codexJobThreadConfig } from '../../../src/core/codex-runner/job/thread-config'
import { parentInputToolSpec } from '../../../src/core/codex-runner/job/parent-input'
import type { CodexRuntimeConfig } from '../../../src/core/codex-runner/runtime-config'
import { errorMessage } from '../../../src/common/errors'

const childProbe = 'CHILD_PROBE: reply once.'

/**
 * The Job project config must make a spawned child thread see every dynamic
 * tool of the lead thread. Codex gates that inheritance behind the
 * `multi_agent_v2_dynamic_tools` feature, so this test fails when the pinned
 * Codex stops honoring the flag that `applyRunnerSafety` sets.
 */
describe('Codex dynamic tool inheritance', () => {
  it('declares every lead dynamic tool to the spawned child thread', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-codex-dynamic-tools-inheritance-'))
    mkdirAgentSync(root, 0o700)
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'codex-home')
    const requests: JSONObject[] = []
    const notifications: JSONRPCMessage[] = []
    const provider = createSpawnResponsesCapture(requests)
    if (typeof provider.port !== 'number') throw new Error('Responses capture server did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      mkdirAgentSync(workspace)
      mkdirAgentSync(codexHome)
      const baseURL = `http://127.0.0.1:${provider.port}/v1`
      resetCodexAgentRuntimeConfig(codexHome, baseURL)
      refreshCodexAgentRuntimeCredential(codexHome, 'contract-key')
      materializeCodexJobProjectConfig({ projectRoot: workspace, hostedWebSearch: false })
      const runtime = testRuntime(baseURL)
      const config = codexJobThreadConfig({
        cwd: workspace,
        codexHome,
        env: {},
        runtime,
        projectConfig: readCodexJobProjectConfig(workspace)
      }) as Record<string, any>
      config.model_providers.ankole_aigateway.supports_websockets = false
      client = new CodexAppServerClient({
        cwd: workspace,
        env: {
          PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
          HOME: workspace,
          CODEX_HOME: codexHome,
          CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
          LANG: 'C.UTF-8'
        },
        onNotification: notification => notifications.push(notification),
        onServerRequest: async (message, appServer) => {
          if (message.id !== undefined) {
            await appServer.respondError(
              message.id,
              -32601,
              `Unexpected server request: ${message.method ?? 'unknown'}`
            )
          }
        }
      })

      await client.initialize()
      const dynamicTools = [echoToolSpec(), parentInputToolSpec()]
      const started = (await client.request('thread/start', {
        cwd: workspace,
        model: runtime.modelProfile.model,
        modelProvider: 'ankole_aigateway',
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        experimentalRawEvents: true,
        config,
        threadSource: 'ankole',
        dynamicTools
      } satisfies ThreadStartParams)) as ThreadStartResponse
      const turn = (await client.request('turn/start', {
        threadId: started.thread.id,
        input: [{ type: 'text', text: 'PARENT_PROBE: spawn one child.', text_elements: [] }],
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      })) as TurnStartResponse
      await waitFor(() => turnTreeCompleted(notifications, started.thread.id, turn.turn.id))

      const leadRequest = requests[0]
      const childRequest = requests.find(isChildRequest)
      if (!leadRequest || !childRequest) throw new Error(`missing lead or child request in ${requests.length} requests`)
      for (const tool of dynamicTools) {
        const leadDeclaration = declaredTool(leadRequest, tool.name)
        expect(leadDeclaration).toBeDefined()
        expect(declaredTool(childRequest, tool.name)).toEqual(leadDeclaration)
      }
    } catch (error) {
      const stderr = notifications
        .filter(notification => notification.method === '$stderr')
        .flatMap(notification => (isRecord(notification.params) ? [notification.params.text] : []))
        .filter((value): value is string => typeof value === 'string')
        .join('')
      throw new Error(`${errorMessage(error)}\n${stderr}`)
    } finally {
      await client?.close()
      provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 90_000)
})

function createSpawnResponsesCapture(requests: JSONObject[]) {
  return Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    async fetch(request) {
      const url = new URL(request.url)
      if (request.method === 'GET' && url.pathname === '/v1/models') {
        return Response.json({ models: [modelCard('gpt-5.4')] })
      }
      if (request.method !== 'POST' || url.pathname !== '/v1/responses') {
        return Response.json({ error: { message: 'not found' } }, { status: 404 })
      }

      const body = (await request.json()) as JSONObject
      requests.push(body)
      const model = typeof body.model === 'string' ? body.model : 'gpt-5.4'
      const responseID = `dynamic-tools-response-${requests.length}`
      if (isChildRequest(body)) {
        return sseResponse(responseEvents(responseID, model, [assistantMessage('child-done', 'CHILD_DONE')]))
      }
      if (JSON.stringify(body.input).includes('function_call_output')) {
        return sseResponse(responseEvents(responseID, model, [assistantMessage('parent-done', 'PARENT_DONE')]))
      }
      return sseResponse(
        responseEvents(responseID, model, [
          {
            type: 'function_call',
            call_id: 'dynamic-tools-spawn-call',
            namespace: 'collaboration',
            name: 'spawn_agent',
            arguments: JSON.stringify({ task_name: 'probe_child', message: childProbe, fork_turns: 'none' })
          }
        ])
      )
    }
  })
}

function testRuntime(baseURL: string): CodexRuntimeConfig {
  const model = 'gpt-5.4'
  return {
    aiGatewayKey: create(AIGatewayAPIKeyResponseSchema, {
      apiKey: 'contract-key',
      baseUrl: baseURL,
      expiresAt: BigInt(Math.floor(Date.now() / 1_000) + 3_600),
      expiresIn: 3_600n,
      scope: 'ai_gateway'
    }),
    modelProfile: {
      model,
      selector: model,
      providerOptions: {},
      supportsParallelToolCalls: false,
      inputModalities: ['text']
    }
  }
}

function echoToolSpec(): NonNullable<ThreadStartParams['dynamicTools']>[number] {
  return {
    type: 'function',
    name: 'ankole_echo',
    description: 'Echo one marker through Ankole.',
    inputSchema: {
      type: 'object',
      properties: { text: { type: 'string' } },
      required: ['text'],
      additionalProperties: false
    }
  }
}

/**
 * Codex hands the brief to the child thread as an `agent_message` input item.
 * The lead's follow-up request carries the same text only inside the spawn
 * call arguments.
 */
function isChildRequest(request: JSONObject): boolean {
  return arrayValue(request.input).some(
    item => isRecord(item) && item.type === 'agent_message' && JSON.stringify(item.content).includes(childProbe)
  )
}

/** Finds one tool declaration by name at the top level or inside a namespace. */
function declaredTool(request: JSONObject, name: string): JSONObject | undefined {
  const tools = arrayValue(request.tools).filter(isRecord)
  for (const tool of tools) {
    if (tool.name === name) return tool
    const nested = arrayValue(tool.tools)
      .filter(isRecord)
      .find(candidate => candidate.name === name)
    if (nested) return nested
  }
  return undefined
}

function modelCard(model: string): JSONObject {
  return {
    slug: model,
    display_name: model,
    description: null,
    supported_reasoning_levels: [],
    shell_type: 'unified_exec',
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
    context_window: 272_000,
    max_context_window: 272_000,
    effective_context_window_percent: 95,
    experimental_supported_tools: [],
    input_modalities: ['text'],
    supports_search_tool: true,
    use_responses_lite: false
  }
}

function assistantMessage(id: string, text: string): JSONObject {
  return {
    id,
    type: 'message',
    status: 'completed',
    role: 'assistant',
    content: [{ type: 'output_text', text, annotations: [] }]
  }
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

/** The lead Turn and at least one Turn on another thread have completed. */
function turnTreeCompleted(notifications: JSONRPCMessage[], rootThreadID: string, rootTurnID: string): boolean {
  const completed = notifications.filter(
    (notification): notification is JSONRPCMessage & { params: Record<string, unknown> } =>
      notification.method === 'turn/completed' && isRecord(notification.params)
  )
  const rootCompleted = completed.some(notification => {
    const turn = isRecord(notification.params.turn) ? notification.params.turn : {}
    return notification.params.threadId === rootThreadID && turn.id === rootTurnID
  })
  const childCompleted = completed.some(notification => notification.params.threadId !== rootThreadID)
  return rootCompleted && childCompleted
}

async function waitFor(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 60_000
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('timed out waiting for the Codex Turn tree')
    await Bun.sleep(10)
  }
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}
