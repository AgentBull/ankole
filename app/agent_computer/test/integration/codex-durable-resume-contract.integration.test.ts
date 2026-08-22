import { sleep } from '../support/llm'
import { describe, expect, it } from 'bun:test'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import {
  CODEX_OPT_OUT_NOTIFICATION_METHODS,
  CodexAppServerClient,
  type JSONRPCMessage
} from '../../src/core/codex-runner/runtime/app-server-client'
import type { DynamicToolCallParams } from '../../src/core/codex-runner/generated/protocol/v2/DynamicToolCallParams'
import type { DynamicToolCallResponse } from '../../src/core/codex-runner/generated/protocol/v2/DynamicToolCallResponse'
import type { ThreadResumeParams } from '../../src/core/codex-runner/generated/protocol/v2/ThreadResumeParams'
import type { ThreadResumeResponse } from '../../src/core/codex-runner/generated/protocol/v2/ThreadResumeResponse'
import type { ThreadStartParams } from '../../src/core/codex-runner/generated/protocol/v2/ThreadStartParams'
import type { ThreadStartResponse } from '../../src/core/codex-runner/generated/protocol/v2/ThreadStartResponse'
import type { TurnStartParams } from '../../src/core/codex-runner/generated/protocol/v2/TurnStartParams'
import type { TurnStartResponse } from '../../src/core/codex-runner/generated/protocol/v2/TurnStartResponse'
import type { TurnSteerResponse } from '../../src/core/codex-runner/generated/protocol/v2/TurnSteerResponse'
import { PARENT_INPUT_TOOL_NAME, parentInputToolSpec } from '../../src/core/codex-runner/job/parent-input'

describe('@ankole/agent-computer Codex durable resume contract', () => {
  it('rejects cross-process resume before a thread has started its first turn', async () => {
    const sharedRoot = process.env.ANKOLE_CODEX_CONTRACT_SHARED_ROOT ?? tmpdir()
    const root = mkdtempSync(join(sharedRoot, 'ankole-codex-empty-thread-contract-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'shared-codex-home')
    const provider = createFakeResponsesProvider([])
    if (typeof provider.port !== 'number') throw new Error('fake Responses provider did not bind a TCP port')
    let firstClient: CodexAppServerClient | undefined
    let resumedClient: CodexAppServerClient | undefined

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      writeCodexConfig(codexHome, provider.port)
      firstClient = codexClient({ workspace, codexHome, notifications: [], toolCalls: [] })
      await firstClient.initialize()

      const started = (await firstClient.request('thread/start', {
        cwd: workspace,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        threadSource: 'ankole',
        dynamicTools: []
      } satisfies ThreadStartParams)) as ThreadStartResponse
      await firstClient.close()
      firstClient = undefined

      resumedClient = codexClient({ workspace, codexHome, notifications: [], toolCalls: [] })
      await resumedClient.initialize()
      await expect(
        resumedClient.request('thread/resume', {
          ['threadId']: started.thread.id,
          cwd: workspace,
          approvalPolicy: 'never',
          sandbox: 'danger-full-access'
        } satisfies ThreadResumeParams)
      ).rejects.toThrow('no rollout found for thread id')
    } finally {
      await firstClient?.close()
      await resumedClient?.close()
      await provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 30_000)

  it('keeps tools and stable user-message identity across interrupt and cross-process resume', async () => {
    const sharedRoot = process.env.ANKOLE_CODEX_CONTRACT_SHARED_ROOT ?? tmpdir()
    const root = mkdtempSync(join(sharedRoot, 'ankole-codex-resume-contract-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'shared-codex-home')
    const requests: JSONObject[] = []
    const toolCalls: DynamicToolCallParams[] = []
    const provider = createFakeResponsesProvider(requests)
    if (typeof provider.port !== 'number') throw new Error('fake Responses provider did not bind a TCP port')
    let firstClient: CodexAppServerClient | undefined
    let resumedClient: CodexAppServerClient | undefined

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      writeCodexConfig(codexHome, provider.port)

      const firstNotifications: JSONRPCMessage[] = []
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
      const threadID = started.thread.id

      const firstTurn = (await firstClient.request('turn/start', {
        ['threadId']: threadID,
        input: textInput('FIRST_DYNAMIC'),
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(() => turnCompleted(firstNotifications, firstTurn.turn.id, 'completed'))

      const firstMethods = firstNotifications.map(notification => notification.method)
      expect(firstMethods).toContain('turn/started')
      expect(firstMethods).toContain('item/started')
      expect(firstMethods).toContain('item/completed')
      expect(firstMethods).toContain('thread/tokenUsage/updated')
      expect(firstMethods).toContain('turn/completed')
      for (const method of CODEX_OPT_OUT_NOTIFICATION_METHODS) expect(firstMethods).not.toContain(method)

      expect(toolCalls.map(call => call.callId)).toEqual(['call_first'])
      expect(requests[0]?.include).toEqual(['reasoning.encrypted_content'])
      expect(requests[0]?.prompt_cache_key).toBe(threadID)
      const firstToolFollowup = requests.find(request => JSON.stringify(request).includes('call_first'))
      expect(JSON.stringify(firstToolFollowup)).toContain('ENCRYPTED_FIRST')

      const interruptedTurn = (await firstClient.request('turn/start', {
        ['threadId']: threadID,
        input: textInput('WAIT_UNTIL_INTERRUPTED'),
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(() => requestContains(requests, 'WAIT_UNTIL_INTERRUPTED'))
      await firstClient.request('turn/interrupt', {
        ['threadId']: threadID,
        ['turnId']: interruptedTurn.turn.id
      })
      await waitFor(() => turnCompleted(firstNotifications, interruptedTurn.turn.id, 'interrupted'))

      await firstClient.close()
      firstClient = undefined
      await sleep(200)

      const resumedNotifications: JSONRPCMessage[] = []
      resumedClient = codexClient({
        workspace,
        codexHome,
        notifications: resumedNotifications,
        toolCalls
      })
      await resumedClient.initialize()

      const resumed = (await resumedClient.request('thread/resume', {
        ['threadId']: threadID,
        cwd: workspace,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        developerInstructions: 'For marker prompts, call ankole_echo exactly once before replying.'
      } satisfies ThreadResumeParams)) as ThreadResumeResponse
      expect(resumed.thread.id).toBe(threadID)

      const resumedTurn = (await resumedClient.request('turn/start', {
        ['threadId']: threadID,
        ['clientUserMessageId']: 'steer-event-after-resume',
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

  it('preserves plan, request-user-input, and steer control paths after notification opt-out', async () => {
    const sharedRoot = process.env.ANKOLE_CODEX_CONTRACT_SHARED_ROOT ?? tmpdir()
    const root = mkdtempSync(join(sharedRoot, 'ankole-codex-control-contract-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'shared-codex-home')
    const requests: JSONObject[] = []
    const notifications: JSONRPCMessage[] = []
    const userInputRequests: JSONRPCMessage[] = []
    const provider = createControlContractProvider(requests)
    if (typeof provider.port !== 'number') throw new Error('control contract provider did not bind a TCP port')
    let client: CodexAppServerClient | undefined

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      writeCodexConfig(codexHome, provider.port)
      client = codexClient({
        workspace,
        codexHome,
        notifications,
        toolCalls: [],
        userInputRequests
      })
      await client.initialize()

      const started = (await client.request('thread/start', {
        cwd: workspace,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        threadSource: 'ankole',
        dynamicTools: [parentInputToolSpec()]
      } satisfies ThreadStartParams)) as ThreadStartResponse
      const threadID = started.thread.id

      const planTurn = (await client.request('turn/start', {
        ['threadId']: threadID,
        input: textInput('PLAN_ONLY'),
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' },
        collaborationMode: {
          mode: 'default',
          settings: { model: 'gpt-5.4', reasoning_effort: 'low', developer_instructions: null }
        }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(() => turnCompleted(notifications, planTurn.turn.id, 'completed'), 10_000, 'plan turn completion')

      const planUpdate = notifications.find(notification => notification.method === 'turn/plan/updated')
      expect(planUpdate?.params).toMatchObject({
        threadId: threadID,
        turnId: planTurn.turn.id,
        plan: [{ step: 'Confirm the audience', status: 'inProgress' }]
      })

      const askTurn = (await client.request('turn/start', {
        ['threadId']: threadID,
        input: textInput('ASK_ONLY'),
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' },
        collaborationMode: {
          mode: 'plan',
          settings: { model: 'gpt-5.4', reasoning_effort: 'low', developer_instructions: null }
        }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(() => turnCompleted(notifications, askTurn.turn.id, 'completed'), 10_000, 'ask turn completion')
      expect(userInputRequests).toHaveLength(1)
      expect(userInputRequests[0]?.method).toBe('item/tool/requestUserInput')
      expect(userInputRequests[0]?.params).toMatchObject({
        threadId: threadID,
        turnId: askTurn.turn.id,
        questions: [{ id: 'audience' }]
      })

      const bridgeTurn = (await client.request('turn/start', {
        ['threadId']: threadID,
        input: textInput('BRIDGE_AND_ASK'),
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' },
        collaborationMode: {
          mode: 'default',
          settings: { model: 'gpt-5.4', reasoning_effort: 'low', developer_instructions: null }
        }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(
        () => turnCompleted(notifications, bridgeTurn.turn.id, 'completed'),
        10_000,
        'parent-input bridge completion'
      )
      const bridgeRequest = userInputRequests.find(request => request.method === 'item/tool/call')
      expect(bridgeRequest?.params).toMatchObject({
        threadId: threadID,
        turnId: bridgeTurn.turn.id,
        tool: PARENT_INPUT_TOOL_NAME,
        arguments: { questions: [{ id: 'audience' }] }
      })

      const steerTurn = (await client.request('turn/start', {
        ['threadId']: threadID,
        input: textInput('STEER_WAIT'),
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(() => requestContains(requests, 'STEER_WAIT'), 10_000, 'initial steer provider request')
      const steerResponse = (await client.request('turn/steer', {
        ['threadId']: threadID,
        ['expectedTurnId']: steerTurn.turn.id,
        input: textInput('STEERED_INPUT')
      })) as TurnSteerResponse
      expect(steerResponse.turnId).toBe(steerTurn.turn.id)
      await waitFor(() => requestContains(requests, 'STEERED_INPUT'), 10_000, 'steered provider request')
      await waitFor(() => hasCompletedAgentText(notifications, 'steer accepted'), 10_000, 'steered agent completion')

      const methods = notifications.map(notification => notification.method)
      expect(methods).toContain('turn/plan/updated')
      expect(methods).toContain('item/completed')
      expect(methods).toContain('thread/tokenUsage/updated')
      expect(methods).toContain('turn/completed')
      for (const method of CODEX_OPT_OUT_NOTIFICATION_METHODS) expect(methods).not.toContain(method)
    } finally {
      await client?.close()
      await provider.stop(true)
      rmSync(root, { recursive: true, force: true })
    }
  }, 30_000)

  it('interrupts on the Default-mode parent-input bridge and resumes the same durable thread with answers', async () => {
    const sharedRoot = process.env.ANKOLE_CODEX_CONTRACT_SHARED_ROOT ?? tmpdir()
    const root = mkdtempSync(join(sharedRoot, 'ankole-codex-parent-input-resume-'))
    const workspace = join(root, 'workspace')
    const codexHome = join(root, 'shared-codex-home')
    const requests: JSONObject[] = []
    const userInputRequests: JSONRPCMessage[] = []
    const provider = createControlContractProvider(requests)
    if (typeof provider.port !== 'number') throw new Error('control contract provider did not bind a TCP port')
    let firstClient: CodexAppServerClient | undefined
    let resumedClient: CodexAppServerClient | undefined

    try {
      mkdirSync(workspace, { recursive: true })
      mkdirSync(codexHome, { recursive: true })
      writeCodexConfig(codexHome, provider.port)

      const firstNotifications: JSONRPCMessage[] = []
      firstClient = codexClient({
        workspace,
        codexHome,
        notifications: firstNotifications,
        toolCalls: [],
        userInputRequests,
        pauseParentInput: true
      })
      await firstClient.initialize()

      const started = (await firstClient.request('thread/start', {
        cwd: workspace,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access',
        threadSource: 'ankole',
        dynamicTools: [parentInputToolSpec()]
      } satisfies ThreadStartParams)) as ThreadStartResponse
      const threadID = started.thread.id

      const waitingTurn = (await firstClient.request('turn/start', {
        ['threadId']: threadID,
        input: textInput('PAUSE_FOR_PARENT'),
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' },
        collaborationMode: {
          mode: 'default',
          settings: { model: 'gpt-5.4', reasoning_effort: 'low', developer_instructions: null }
        }
      } satisfies TurnStartParams)) as TurnStartResponse

      await waitFor(() => userInputRequests.length === 1, 10_000, 'parent-input bridge request')
      await waitFor(
        () => turnCompleted(firstNotifications, waitingTurn.turn.id, 'interrupted'),
        10_000,
        'parent-input interruption'
      )
      expect(userInputRequests[0]?.params).toMatchObject({
        threadId: threadID,
        turnId: waitingTurn.turn.id,
        tool: PARENT_INPUT_TOOL_NAME
      })

      const providerRequest = requests.find(request => JSON.stringify(request).includes('PAUSE_FOR_PARENT'))
      expect(JSON.stringify(providerRequest)).toContain(PARENT_INPUT_TOOL_NAME)
      expect(JSON.stringify(providerRequest)).toContain('instead of request_user_input')

      await firstClient.close()
      firstClient = undefined
      await sleep(200)

      const resumedNotifications: JSONRPCMessage[] = []
      resumedClient = codexClient({
        workspace,
        codexHome,
        notifications: resumedNotifications,
        toolCalls: []
      })
      await resumedClient.initialize()

      const resumed = (await resumedClient.request('thread/resume', {
        ['threadId']: threadID,
        cwd: workspace,
        approvalPolicy: 'never',
        sandbox: 'danger-full-access'
      } satisfies ThreadResumeParams)) as ThreadResumeResponse
      expect(resumed.thread.id).toBe(threadID)

      const answerTurn = (await resumedClient.request('turn/start', {
        ['threadId']: threadID,
        ['clientUserMessageId']: 'parent-answer-event',
        input: textInput('PARENT_ANSWER: Operators'),
        cwd: workspace,
        approvalPolicy: 'never',
        sandboxPolicy: { type: 'dangerFullAccess' }
      } satisfies TurnStartParams)) as TurnStartResponse
      await waitFor(
        () => turnCompleted(resumedNotifications, answerTurn.turn.id, 'completed'),
        10_000,
        'parent-input answer completion'
      )
      expect(hasCompletedAgentText(resumedNotifications, 'parent answer accepted')).toBe(true)
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
  notifications: JSONRPCMessage[]
  toolCalls: DynamicToolCallParams[]
  userInputRequests?: JSONRPCMessage[]
  pauseParentInput?: boolean
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
      if (message.method === 'item/tool/requestUserInput' && message.id !== undefined) {
        input.userInputRequests?.push(message)
        await client.respond(message.id, { answers: { audience: { answers: ['Operators'] } } })
        return
      }
      if (message.method !== 'item/tool/call' || message.id === undefined) {
        if (message.id !== undefined) {
          await client.respondError(message.id, -32601, `Unexpected server request: ${message.method ?? 'unknown'}`)
        }
        return
      }

      const params = message.params as DynamicToolCallParams
      if (params.tool === PARENT_INPUT_TOOL_NAME) {
        input.userInputRequests?.push(message)
        if (input.pauseParentInput) {
          await client.request('turn/interrupt', {
            ['threadId']: params.threadId,
            ['turnId']: params.turnId
          })
          return
        }
        await client.respond(message.id, {
          contentItems: [{ type: 'inputText', text: 'Parent input request accepted.' }],
          success: true
        } satisfies DynamicToolCallResponse)
        return
      }
      input.toolCalls.push(params)
      await client.respond(message.id, {
        contentItems: [{ type: 'inputText', text: `echo:${JSON.stringify(params.arguments)}` }],
        success: true
      } satisfies DynamicToolCallResponse)
    }
  })
}

function createFakeResponsesProvider(requests: JSONObject[]) {
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

function createControlContractProvider(requests: JSONObject[]) {
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
      const bodyText = JSON.stringify(body)
      const model = typeof body.model === 'string' ? body.model : 'gpt-5.4'

      if (bodyText.includes('PARENT_ANSWER')) {
        return messageResponse('resp_parent_answer', model, 'parent answer accepted')
      }

      if (bodyText.includes('PAUSE_FOR_PARENT')) {
        return namedFunctionCallResponse('resp_pause_parent', model, 'call_pause_parent', PARENT_INPUT_TOOL_NAME, {
          questions: [
            {
              id: 'audience',
              header: 'Audience',
              question: 'Who should receive the report?',
              options: [{ label: 'Operators', description: 'The operations team.' }]
            }
          ]
        })
      }

      if (bodyText.includes('STEER_WAIT')) {
        return bodyText.includes('STEERED_INPUT')
          ? messageResponse('resp_steer_done', model, 'steer accepted')
          : delayedMessageResponse(request, 'resp_steer_wait', model, 'before steer', 500)
      }

      if (bodyText.includes('BRIDGE_AND_ASK')) {
        return bodyText.includes('call_parent_input')
          ? messageResponse('resp_bridge_done', model, 'parent input bridge accepted')
          : namedFunctionCallResponse('resp_parent_input', model, 'call_parent_input', PARENT_INPUT_TOOL_NAME, {
              questions: [
                {
                  id: 'audience',
                  header: 'Audience',
                  question: 'Who should receive the report?',
                  options: [{ label: 'Operators', description: 'The operations team.' }]
                }
              ]
            })
      }

      if (bodyText.includes('ASK_ONLY')) {
        return bodyText.includes('call_input')
          ? messageResponse('resp_input_done', model, 'input accepted')
          : namedFunctionCallResponse('resp_input', model, 'call_input', 'request_user_input', {
              questions: [
                {
                  id: 'audience',
                  header: 'Audience',
                  question: 'Who should receive the report?',
                  options: [{ label: 'Operators', description: 'The operations team.' }]
                }
              ]
            })
      }

      if (bodyText.includes('PLAN_ONLY')) {
        return bodyText.includes('call_plan')
          ? messageResponse('resp_plan_done', model, 'plan accepted')
          : namedFunctionCallResponse('resp_plan', model, 'call_plan', 'update_plan', {
              explanation: 'Need one audience decision.',
              plan: [{ step: 'Confirm the audience', status: 'in_progress' }]
            })
      }

      return Response.json({ error: { message: 'unexpected control contract input' } }, { status: 400 })
    }
  })
}

function functionCallResponse(
  responseID: string,
  model: string,
  callID: string,
  text: string,
  encryptedReasoning?: string
): Response {
  return namedFunctionCallResponse(responseID, model, callID, 'ankole_echo', { text }, encryptedReasoning)
}

function namedFunctionCallResponse(
  responseID: string,
  model: string,
  callID: string,
  name: string,
  argumentsValue: JSONObject,
  encryptedReasoning?: string
): Response {
  const response = responseEnvelope(responseID, model)
  const argumentsText = JSON.stringify(argumentsValue)
  const reasoningItem = encryptedReasoning
    ? {
        id: `rs_${callID}`,
        type: 'reasoning',
        summary: [],
        encrypted_content: encryptedReasoning
      }
    : undefined
  const outputIndex = reasoningItem ? 1 : 0
  const item = {
    id: `fc_${callID}`,
    type: 'function_call',
    status: 'completed',
    name,
    call_id: callID,
    arguments: argumentsText
  }

  const events: JSONObject[] = [{ type: 'response.created', sequence_number: 0, response }]
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

function messageResponse(responseID: string, model: string, text: string): Response {
  return sseResponse(messageEvents(responseID, model, text))
}

function messageEvents(responseID: string, model: string, text: string): JSONObject[] {
  const response = responseEnvelope(responseID, model)
  const item = {
    id: `msg_${responseID}`,
    type: 'message',
    status: 'completed',
    role: 'assistant',
    content: [{ type: 'output_text', text, annotations: [] }]
  }

  return [
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
  ]
}

function delayedMessageResponse(
  request: Request,
  responseID: string,
  model: string,
  text: string,
  delayMs: number
): Response {
  const encoder = new TextEncoder()
  const events = messageEvents(responseID, model, text)
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      let closed = false
      controller.enqueue(encoder.encode(sseEvent(events[0]!)))
      const timer = setTimeout(() => {
        if (closed) return
        for (const event of events.slice(1)) controller.enqueue(encoder.encode(sseEvent(event)))
        closed = true
        controller.close()
      }, delayMs)
      request.signal.addEventListener(
        'abort',
        () => {
          if (closed) return
          closed = true
          clearTimeout(timer)
          controller.close()
        },
        { once: true }
      )
    }
  })
  return new Response(stream, { headers: sseHeaders() })
}

function heldResponse(request: Request, responseID: string, model: string): Response {
  const encoder = new TextEncoder()
  const response = responseEnvelope(responseID, model)
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(encoder.encode(sseEvent({ type: 'response.created', sequence_number: 0, response })))
      request.signal.addEventListener('abort', () => controller.close(), { once: true })
    }
  })
  return new Response(stream, { headers: sseHeaders() })
}

function responseEnvelope(id: string, model: string): JSONObject {
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

function completedResponse(response: JSONObject, output: unknown[]): JSONObject {
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

function sseResponse(events: JSONObject[]): Response {
  return new Response(events.map(sseEvent).join(''), { headers: sseHeaders() })
}

function sseEvent(event: JSONObject): string {
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

function turnCompleted(notifications: JSONRPCMessage[], turnID: string, status: string): boolean {
  return notifications.some(notification => {
    if (notification.method !== 'turn/completed' || !isObject(notification.params)) return false
    const turn = notification.params.turn
    return isObject(turn) && turn.id === turnID && turn.status === status
  })
}

function hasCompletedAgentText(notifications: JSONRPCMessage[], text: string): boolean {
  return notifications.some(notification => {
    if (notification.method !== 'item/completed' || !isObject(notification.params)) return false
    if (!isObject(notification.params.item) || notification.params.item.type !== 'agentMessage') return false
    return notification.params.item.text === text
  })
}

function requestContains(requests: JSONObject[], marker: string): boolean {
  return requests.some(request => JSON.stringify(request).includes(marker))
}

function recursiveFiles(root: string): string[] {
  return readdirSync(root, { recursive: true, withFileTypes: true })
    .filter(entry => entry.isFile())
    .map(entry => join(entry.parentPath, entry.name))
}

async function waitFor(
  predicate: () => boolean,
  timeoutMs = 10_000,
  description = 'Codex contract condition'
): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${description}`)
    await sleep(10)
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
