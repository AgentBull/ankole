import { describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { JsonObject } from '@pleisto/active-support'
import { CodexAppServerClient, type JsonRpcMessage } from '../../src/tools/codex/app-server-client'
import type { DynamicToolCallParams } from '../../src/tools/subagent/generated/protocol/v2/DynamicToolCallParams'
import type { DynamicToolCallResponse } from '../../src/tools/subagent/generated/protocol/v2/DynamicToolCallResponse'
import type { ThreadResumeParams } from '../../src/tools/subagent/generated/protocol/v2/ThreadResumeParams'
import type { ThreadResumeResponse } from '../../src/tools/subagent/generated/protocol/v2/ThreadResumeResponse'
import type { ThreadStartParams } from '../../src/tools/subagent/generated/protocol/v2/ThreadStartParams'
import type { ThreadStartResponse } from '../../src/tools/subagent/generated/protocol/v2/ThreadStartResponse'
import type { TurnStartParams } from '../../src/tools/subagent/generated/protocol/v2/TurnStartParams'
import type { TurnStartResponse } from '../../src/tools/subagent/generated/protocol/v2/TurnStartResponse'

describe('@ankole/agent-computer Codex durable resume contract', () => {
  it('keeps tools and stable user-message identity across interrupt and cross-process resume', async () => {
    const sharedRoot = process.env.ANKOLE_CODEX_CONTRACT_SHARED_ROOT ?? tmpdir()
    const root = mkdtempSync(join(sharedRoot, 'ankole-codex-resume-contract-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'shared-codex-home')
    const requests: JsonObject[] = []
    const toolCalls: DynamicToolCallParams[] = []
    const provider = createFakeResponsesProvider(requests)
    if (typeof provider.port !== 'number') throw new Error('fake Responses provider did not bind a TCP port')
    let firstClient: CodexAppServerClient | undefined
    let resumedClient: CodexAppServerClient | undefined

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      writeCodexConfig(codexHome, provider.port)

      const firstNotifications: JsonRpcMessage[] = []
      firstClient = codexClient({
        workspace,
        codexHome,
        notifications: firstNotifications,
        toolCalls
      })
      await firstClient.initialize()

      const started = (await firstClient.request('thread/start', {
        cwd: workspace,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        threadSource: 'ankole',
        developerInstructions: 'For marker prompts, call ankole_echo exactly once before replying.',
        dynamicTools: [
          {
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
        ]
      } satisfies ThreadStartParams)) as ThreadStartResponse
      const threadId = started.thread.id

      const firstTurn = (await firstClient.request('turn/start', {
        threadId,
        input: textInput('FIRST_DYNAMIC'),
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(() => turnCompleted(firstNotifications, firstTurn.turn.id, 'completed'))

      expect(toolCalls.map(call => call.callId)).toEqual(['call_first'])
      expect(requests[0]?.include).toEqual(['reasoning.encrypted_content'])
      expect(requests[0]?.prompt_cache_key).toBe(threadId)
      const firstToolFollowup = requests.find(request => JSON.stringify(request).includes('call_first'))
      expect(JSON.stringify(firstToolFollowup)).toContain('ENCRYPTED_FIRST')

      const interruptedTurn = (await firstClient.request('turn/start', {
        threadId,
        input: textInput('WAIT_UNTIL_INTERRUPTED'),
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(() => requestContains(requests, 'WAIT_UNTIL_INTERRUPTED'))
      await firstClient.request('turn/interrupt', { threadId, turnId: interruptedTurn.turn.id })
      await waitFor(() => turnCompleted(firstNotifications, interruptedTurn.turn.id, 'interrupted'))

      await firstClient.close()
      firstClient = undefined
      await sleep(200)

      const resumedNotifications: JsonRpcMessage[] = []
      resumedClient = codexClient({
        workspace,
        codexHome,
        notifications: resumedNotifications,
        toolCalls
      })
      await resumedClient.initialize()

      const resumed = (await resumedClient.request('thread/resume', {
        threadId,
        cwd: workspace,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        developerInstructions: 'For marker prompts, call ankole_echo exactly once before replying.'
      } satisfies ThreadResumeParams)) as ThreadResumeResponse
      expect(resumed.thread.id).toBe(threadId)

      const resumedTurn = (await resumedClient.request('turn/start', {
        threadId,
        clientUserMessageId: 'steer-event-after-resume',
        input: textInput('AFTER_RESUME'),
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(() => turnCompleted(resumedNotifications, resumedTurn.turn.id, 'completed'))

      expect(toolCalls.map(call => call.callId)).toEqual(['call_first', 'call_resume'])
      expect(toolCalls.map(call => call.tool)).toEqual(['ankole_echo', 'ankole_echo'])

      const durableFiles = recursiveFiles(codexHome)
      expect(durableFiles.some(path => path.endsWith('.jsonl'))).toBe(true)
      expect(durableFiles.some(path => /state[^/]*\.sqlite$/.test(path))).toBe(true)
      expect(started.thread.path).toBeString()
      expect(started.thread.path ? existsSync(started.thread.path) : false).toBe(true)
    } finally {
      await firstClient?.close()
      await resumedClient?.close()
      await provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 30_000)
})

function codexClient(input: {
  workspace: string
  codexHome: string
  notifications: JsonRpcMessage[]
  toolCalls: DynamicToolCallParams[]
}): CodexAppServerClient {
  return new CodexAppServerClient({
    cwd: input.workspace,
    env: {
      PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
      HOME: input.workspace,
      CODEX_HOME: input.codexHome,
      OPENAI_API_KEY: 'contract-key',
      CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
      LANG: 'C.UTF-8'
    },
    onNotification: notification => input.notifications.push(notification),
    onServerRequest: async (message, client) => {
      if (message.method !== 'item/tool/call' || message.id === undefined) {
        if (message.id !== undefined) {
          await client.respondError(message.id, -32601, `Unexpected server request: ${message.method ?? 'unknown'}`)
        }
        return
      }

      const params = message.params as DynamicToolCallParams
      input.toolCalls.push(params)
      await client.respond(message.id, {
        contentItems: [{ type: 'inputText', text: `echo:${JSON.stringify(params.arguments)}` }],
        success: true
      } satisfies DynamicToolCallResponse)
    }
  })
}

function createFakeResponsesProvider(requests: JsonObject[]) {
  return Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    async fetch(request) {
      const url = new URL(request.url)
      if (request.method !== 'POST' || url.pathname !== '/v1/responses') {
        return Response.json({ error: { message: 'not found' } }, { status: 404 })
      }

      const body = (await request.json()) as JsonObject
      requests.push(body)
      const bodyText = JSON.stringify(body)
      const model = typeof body.model === 'string' ? body.model : 'gpt-5.4'

      if (bodyText.includes('AFTER_RESUME')) {
        return bodyText.includes('call_resume')
          ? messageResponse('resp_resume_done', model, 'resume tool accepted')
          : functionCallResponse('resp_resume_tool', model, 'call_resume', 'AFTER_RESUME')
      }

      if (bodyText.includes('WAIT_UNTIL_INTERRUPTED')) {
        return heldResponse(request, 'resp_interrupted', model)
      }

      if (bodyText.includes('FIRST_DYNAMIC')) {
        return bodyText.includes('call_first')
          ? messageResponse('resp_first_done', model, 'first tool accepted')
          : functionCallResponse('resp_first_tool', model, 'call_first', 'FIRST_DYNAMIC', 'ENCRYPTED_FIRST')
      }

      return Response.json({ error: { message: 'unexpected contract input' } }, { status: 400 })
    }
  })
}

function functionCallResponse(
  responseId: string,
  model: string,
  callId: string,
  text: string,
  encryptedReasoning?: string
): Response {
  const response = responseEnvelope(responseId, model)
  const argumentsText = JSON.stringify({ text })
  const reasoningItem = encryptedReasoning
    ? {
        id: `rs_${callId}`,
        type: 'reasoning',
        summary: [],
        encrypted_content: encryptedReasoning
      }
    : undefined
  const outputIndex = reasoningItem ? 1 : 0
  const item = {
    id: `fc_${callId}`,
    type: 'function_call',
    status: 'completed',
    name: 'ankole_echo',
    call_id: callId,
    arguments: argumentsText
  }

  const events: JsonObject[] = [{ type: 'response.created', sequence_number: 0, response }]
  if (reasoningItem) {
    events.push(
      {
        type: 'response.output_item.added',
        sequence_number: events.length,
        output_index: 0,
        item: reasoningItem
      },
      {
        type: 'response.output_item.done',
        sequence_number: events.length + 1,
        output_index: 0,
        item: reasoningItem
      }
    )
  }
  events.push(
    {
      type: 'response.output_item.added',
      sequence_number: events.length,
      output_index: outputIndex,
      item: { ...item, status: 'in_progress', arguments: '' }
    },
    {
      type: 'response.function_call_arguments.delta',
      sequence_number: events.length + 1,
      item_id: item.id,
      output_index: outputIndex,
      delta: argumentsText
    },
    {
      type: 'response.function_call_arguments.done',
      sequence_number: events.length + 2,
      item_id: item.id,
      output_index: outputIndex,
      arguments: argumentsText
    },
    {
      type: 'response.output_item.done',
      sequence_number: events.length + 3,
      output_index: outputIndex,
      item
    },
    {
      type: 'response.completed',
      sequence_number: events.length + 4,
      response: completedResponse(response, reasoningItem ? [reasoningItem, item] : [item])
    }
  )
  return sseResponse(events)
}

function messageResponse(responseId: string, model: string, text: string): Response {
  const response = responseEnvelope(responseId, model)
  const item = {
    id: `msg_${responseId}`,
    type: 'message',
    status: 'completed',
    role: 'assistant',
    content: [{ type: 'output_text', text, annotations: [] }]
  }

  return sseResponse([
    { type: 'response.created', sequence_number: 0, response },
    {
      type: 'response.output_item.added',
      sequence_number: 1,
      output_index: 0,
      item: { ...item, status: 'in_progress', content: [] }
    },
    {
      type: 'response.content_part.added',
      sequence_number: 2,
      item_id: item.id,
      output_index: 0,
      content_index: 0,
      part: { type: 'output_text', text: '', annotations: [] }
    },
    {
      type: 'response.output_text.delta',
      sequence_number: 3,
      item_id: item.id,
      output_index: 0,
      content_index: 0,
      delta: text
    },
    {
      type: 'response.output_text.done',
      sequence_number: 4,
      item_id: item.id,
      output_index: 0,
      content_index: 0,
      text
    },
    {
      type: 'response.content_part.done',
      sequence_number: 5,
      item_id: item.id,
      output_index: 0,
      content_index: 0,
      part: item.content[0]
    },
    { type: 'response.output_item.done', sequence_number: 6, output_index: 0, item },
    { type: 'response.completed', sequence_number: 7, response: completedResponse(response, [item]) }
  ])
}

function heldResponse(request: Request, responseId: string, model: string): Response {
  const encoder = new TextEncoder()
  const response = responseEnvelope(responseId, model)
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(encoder.encode(sseEvent({ type: 'response.created', sequence_number: 0, response })))
      request.signal.addEventListener('abort', () => controller.close(), { once: true })
    }
  })
  return new Response(stream, { headers: sseHeaders() })
}

function responseEnvelope(id: string, model: string): JsonObject {
  return {
    id,
    object: 'response',
    created_at: 1_764_967_971,
    completed_at: null,
    status: 'in_progress',
    model,
    previous_response_id: null,
    output: [],
    usage: null
  }
}

function completedResponse(response: JsonObject, output: unknown[]): JsonObject {
  return {
    ...response,
    completed_at: 1_764_967_972,
    status: 'completed',
    output,
    usage: {
      input_tokens: 1,
      input_tokens_details: { cached_tokens: 0 },
      output_tokens: 1,
      output_tokens_details: { reasoning_tokens: 0 },
      total_tokens: 2
    }
  }
}

function sseResponse(events: JsonObject[]): Response {
  return new Response(events.map(sseEvent).join(''), { headers: sseHeaders() })
}

function sseEvent(event: JsonObject): string {
  return `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`
}

function sseHeaders(): HeadersInit {
  return {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    connection: 'keep-alive'
  }
}

function writeCodexConfig(codexHome: string, port: number): void {
  writeFileSync(
    join(codexHome, 'config.toml'),
    `model = "gpt-5.4"
model_provider = "contract"
model_reasoning_effort = "low"
approval_policy = "never"
sandbox_mode = "danger-full-access"
cli_auth_credentials_store = "file"
features.remote_compaction_v2 = false

[model_providers.contract]
name = "Ankole Codex durable resume contract"
base_url = "http://127.0.0.1:${port}/v1"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
supports_websockets = false
`
  )
}

function textInput(text: string): TurnStartParams['input'] {
  return [{ type: 'text', text, text_elements: [] }]
}

function turnCompleted(notifications: JsonRpcMessage[], turnId: string, status: string): boolean {
  return notifications.some(notification => {
    if (notification.method !== 'turn/completed' || !isObject(notification.params)) return false
    const turn = notification.params.turn
    return isObject(turn) && turn.id === turnId && turn.status === status
  })
}

function requestContains(requests: JsonObject[], marker: string): boolean {
  return requests.some(request => JSON.stringify(request).includes(marker))
}

function recursiveFiles(root: string): string[] {
  return readdirSync(root, { recursive: true, withFileTypes: true })
    .filter(entry => entry.isFile())
    .map(entry => join(entry.parentPath, entry.name))
}

async function waitFor(predicate: () => boolean, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('timed out waiting for Codex contract condition')
    await sleep(10)
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
