import { afterEach, describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import type { LlmProviderCredentialResponse, TurnStart } from '../src/actor_bus'
import { runLlmTurnHandlers, runTextTurnLoop } from '../src/llm_runtime/text_turn_loop'

const originalFetch = globalThis.fetch

afterEach(() => {
  globalThis.fetch = originalFetch
})

describe('@ankole/agent-computer LLM turn loop', () => {
  it('loads session conversation history from the semantic workspace store', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([{ text: 'HISTORY_OK' }])
    }) as typeof fetch

    const workspaceRoot = tempWorkspace()
    writeConversationStore(workspaceRoot, [
      {
        id: 'msg-current',
        role: 'user',
        kind: 'normal',
        content: [{ type: 'text', text: 'Use one tool, then reply with OK.' }],
        metadata: { actor_input_id: 'input-1' }
      },
      {
        id: 'msg-assistant',
        role: 'assistant',
        kind: 'normal',
        content: [{ type: 'text', text: 'Previous answer from durable transcript.' }],
        metadata: {}
      },
      {
        id: 'msg-summary',
        role: 'assistant',
        kind: 'summary',
        content: [{ type: 'text', text: 'Old summary checkpoint.' }],
        metadata: {}
      }
    ])

    const reply = await runTextTurnLoop(turnStart('openrouter-main', 'z-ai/glm-5.2'), {
      workspaceRoot,
      requestCredential: async request =>
        credential(request.request_id, 'openrouter', 'openrouter-main', 'z-ai/glm-5.2')
    })

    expect(reply).toBe('HISTORY_OK')
    const body = calls[0].body
    const serializedMessages = JSON.stringify(body.messages)
    expect(serializedMessages.match(/Use one tool, then reply with OK\./g)).toHaveLength(1)
    expect(serializedMessages).toContain('Previous answer from durable transcript.')
    expect(JSON.stringify(body)).toContain('Old summary checkpoint.')
  })

  it('injects active steer updates after a tool boundary and advances the turn revision', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      if (calls.length === 1) {
        return openAIStream([
          {
            toolCall: {
              id: 'call_1',
              name: 'todo',
              arguments: {
                todos: [{ id: 't1', content: 'before-steer', status: 'in_progress' }]
              }
            }
          }
        ])
      }
      return openAIStream([{ text: 'STEER_OK' }])
    }) as typeof fetch

    const start = turnStart('openrouter-main', 'z-ai/glm-5.2')
    let delivered = false
    const reply = await runTextTurnLoop(start, {
      workspaceRoot: tempWorkspace(),
      requestCredential: async request =>
        credential(request.request_id, 'openrouter', 'openrouter-main', 'z-ai/glm-5.2'),
      pollSteering: () => {
        if (delivered) return []
        delivered = true
        return [
          {
            turn: { ...start.turn, revision: 1 },
            inputs: [
              {
                actor_input_id: 'steer-1',
                broker_sequence: 2,
                type: 'command.steer',
                ingress_event_id: 'event-steer',
                payload_json: { data: { command: { argsText: 'switch to the steered answer' } } }
              }
            ]
          }
        ]
      }
    })

    expect(reply).toBe('STEER_OK')
    expect(start.turn.revision).toBe(1)
    const secondBody = JSON.stringify(calls[1].body)
    expect(secondBody).toContain('Runtime note')
    expect(secondBody).toContain('switch to the steered answer')
  })

  it('skips ambient observations in normal generation but renders ambient intervention context', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([{ text: 'AMBIENT_REPLY_OK' }])
    }) as typeof fetch

    const workspaceRoot = tempWorkspace()
    writeConversationStore(workspaceRoot, [
      {
        id: 'ambient-observed',
        role: 'im_ambient',
        kind: 'normal',
        content: [{ type: 'text', text: 'This background chat must not enter normal generation.' }],
        metadata: { actor_input_id: 'ambient-observed-input' }
      },
      {
        id: 'ambient-intervention-message',
        role: 'im_ambient',
        kind: 'introspection',
        content: [{ type: 'text', text: '<chat_segment format="yaml">release summary request</chat_segment>' }],
        metadata: {
          message_context: {
            speaker: { injected: true, display_name: 'agent-1', role: 'agent', trigger: 'introspection' },
            think: { injected: true, text: 'Runtime intervention, not human-authored text.' }
          }
        }
      }
    ])

    const reply = await runTextTurnLoop(turnStart('openrouter-main', 'z-ai/glm-5.2'), {
      workspaceRoot,
      requestCredential: async request =>
        credential(request.request_id, 'openrouter', 'openrouter-main', 'z-ai/glm-5.2')
    })

    expect(reply).toBe('AMBIENT_REPLY_OK')
    const serializedMessages = JSON.stringify(calls[0].body.messages)
    expect(serializedMessages).toContain('<message_context>')
    expect(serializedMessages).toContain('Runtime intervention, not human-authored text.')
    expect(serializedMessages).toContain('release summary request')
    expect(serializedMessages).not.toContain('This background chat must not enter normal generation.')
  })

  it('runs ambient may-intervene events through light recognition before primary generation', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      if (calls.length === 1) {
        return openAIJson('{"intervene":true,"reason":"The group is asking the agent."}')
      }
      return openAIStream([{ text: 'AMBIENT_REPLY_OK' }])
    }) as typeof fetch

    const workspaceRoot = tempWorkspace()
    writeConversationStore(workspaceRoot, [
      {
        id: 'ambient-current',
        role: 'im_ambient',
        kind: 'normal',
        content: [{ type: 'text', text: 'Can agent summarize the release?' }],
        metadata: {
          actor_input_id: 'ambient-input-1',
          signal_channel_id: 'lark:chat:group-a',
          provider_thread_id: 'thread-1',
          provider_entry_id: 'msg-ambient-2',
          message_context: {
            time: { sent_at: '2026-06-24T08:00:00.000000Z', timezone: 'Asia/Shanghai' },
            actor: { display_name: 'Alice' },
            room: { label: 'group chat "Ops"', id: 'lark:chat:group-a', is_dm: false }
          }
        },
        inserted_at: '2026-06-24T08:00:00.000000Z'
      }
    ])

    const proposal = await runLlmTurnHandlers(
      turnStart('openrouter-main', 'z-ai/glm-5.2', {
        inputs: [
          {
            actor_input_id: 'ambient-input-1',
            broker_sequence: 1,
            type: 'im.message.may_intervene',
            ingress_event_id: 'evt-ambient-1',
            payload_json: {
              data: {
                entry: { text: 'Can agent summarize the release?' },
                observed_messages: [
                  {
                    id: 'signal:msg-ambient-1',
                    role: 'ambient_human',
                    kind: 'normal',
                    speaker: 'Alice',
                    sent_at: '2026-06-24T08:00:00.000000Z',
                    text: 'Can agent summarize the release?',
                    signal_channel_id: 'lark:chat:group-a',
                    provider_entry_id: 'msg-ambient-1'
                  },
                  {
                    id: 'signal:msg-agent-middle',
                    role: 'agent',
                    kind: 'normal',
                    speaker: 'ReleaseBot',
                    sent_at: '2026-06-24T08:01:00.000000Z',
                    text: 'The release notes are almost ready.',
                    signal_channel_id: 'lark:chat:group-a',
                    provider_entry_id: 'msg-agent-middle'
                  },
                  {
                    id: 'signal:msg-ambient-2',
                    role: 'ambient_human',
                    kind: 'normal',
                    speaker: 'Bob',
                    sent_at: '2026-06-24T08:03:00.000000Z',
                    text: 'Please ask agent-1 for the short summary.',
                    signal_channel_id: 'lark:chat:group-a',
                    provider_entry_id: 'msg-ambient-2'
                  }
                ]
              }
            }
          }
        ],
        model_ref: { profile: 'primary', provider_id: 'openrouter-main', model: 'z-ai/glm-5.2' }
      }),
      {
        workspaceRoot,
        requestCredential: async request => {
          if (request.profile === 'light') {
            return credential(request.request_id, 'openrouter', 'openrouter-light', 'openai/gpt-5.4-nano', 'light')
          }
          return credential(request.request_id, 'openrouter', 'openrouter-main', 'z-ai/glm-5.2')
        }
      }
    )

    expect(proposal.reply?.text).toBe('AMBIENT_REPLY_OK')
    const proposedMessage = proposal.messages?.[0]
    const proposedMetadata = proposedMessage?.metadata_json as any
    expect(proposedMessage?.role).toBe('im_ambient')
    expect(proposedMetadata?.control?.type).toBe('ambient_intervention')
    expect(calls[0].body.model).toBe('openai/gpt-5.4-nano')
    expect(calls[1].body.model).toBe('z-ai/glm-5.2')
    expect(calls[0].body.response_format).toMatchObject({
      type: 'json_schema',
      json_schema: {
        name: 'ambient_intervention_decision'
      }
    })
    expect(calls[0].body.response_format.json_schema.schema.required).toEqual(['intervene', 'reason'])
    const recognizerMessages = JSON.stringify(calls[0].body.messages)
    expect(recognizerMessages).toContain('decide_if_agent_should_visibly_reply_now')
    expect(recognizerMessages).toContain('Alice')
    expect(recognizerMessages).toContain('ReleaseBot')
    expect(recognizerMessages).toContain('Bob')
    expect(recognizerMessages).toContain('08:00')
    expect(recognizerMessages).not.toContain('08:01')
  })

  it('rejects ambient recognizer aliases instead of repairing them in worker code', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIJson('{"should_intervene":true,"reason":"The group is asking the agent."}')
    }) as typeof fetch

    const workspaceRoot = tempWorkspace()
    writeConversationStore(workspaceRoot, [
      {
        id: 'ambient-current',
        role: 'im_ambient',
        kind: 'normal',
        content: [{ type: 'text', text: 'Can agent summarize the release?' }],
        metadata: {
          actor_input_id: 'ambient-input-1',
          message_context: {
            time: { sent_at: '2026-06-24T08:00:00.000000Z', timezone: 'Asia/Shanghai' },
            actor: { display_name: 'Alice' },
            room: { label: 'group chat "Ops"', id: 'lark:chat:group-a', is_dm: false }
          }
        },
        inserted_at: '2026-06-24T08:00:00.000000Z'
      }
    ])

    await expect(
      runLlmTurnHandlers(
        turnStart('openrouter-main', 'z-ai/glm-5.2', {
          inputs: [
            {
              actor_input_id: 'ambient-input-1',
              broker_sequence: 1,
              type: 'im.message.may_intervene',
              ingress_event_id: 'evt-ambient-1',
              payload_json: { data: { entry: { text: 'Can agent summarize the release?' } } }
            }
          ]
        }),
        {
          workspaceRoot,
          requestCredential: async request => {
            if (request.profile === 'light') {
              return credential(request.request_id, 'openrouter', 'openrouter-light', 'openai/gpt-5.4-nano', 'light')
            }
            return credential(request.request_id, 'openrouter', 'openrouter-main', 'z-ai/glm-5.2')
          }
        }
      )
    ).rejects.toThrow(/No object generated|schema/i)

    expect(calls).toHaveLength(1)
  })

  it('rejects credentials that do not match the turn model ref', async () => {
    await expect(
      runTextTurnLoop(turnStart('openrouter-main', 'z-ai/glm-5.2'), {
        workspaceRoot: tempWorkspace(),
        requestCredential: async request =>
          credential(request.request_id, 'openrouter', 'other-provider', 'z-ai/glm-5.2')
      })
    ).rejects.toThrow('credential response does not match turn model_ref')
  })
})

function tempWorkspace(): string {
  return mkdtempSync(join(tmpdir(), 'ankole-agent-computer-'))
}

function writeConversationStore(workspaceRoot: string, rows: any[]): void {
  const dir = join(
    workspaceRoot,
    'actors',
    encodeURIComponent('agent-1'),
    encodeURIComponent('signal-channel:test'),
    'conversation'
  )
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'messages.jsonl'), rows.map(row => JSON.stringify(row)).join('\n'))
}

function turnStart(providerId: string, model: string, overrides: Partial<TurnStart> = {}): TurnStart {
  const base: TurnStart = {
    turn: {
      actor: { agent_uid: 'agent-1', session_id: 'signal-channel:test' },
      activation_uid: 'activation-1',
      actor_epoch: 1,
      llm_turn_id: 'turn-1',
      revision: 0
    },
    inputs: [
      {
        actor_input_id: 'input-1',
        broker_sequence: 1,
        type: 'im.message.created',
        ingress_event_id: 'event-1',
        payload_json: { data: { entry: { text: 'Use one tool, then reply with OK.' } } }
      }
    ],
    model_ref: { profile: 'primary', provider_id: providerId, model }
  }
  return { ...base, ...overrides }
}

function credential(
  requestId: string,
  providerSource: string,
  providerId: string,
  model: string,
  profile = 'primary'
): LlmProviderCredentialResponse {
  return {
    request_id: requestId,
    agent_uid: 'agent-1',
    session_id: 'signal-channel:test',
    profile,
    provider_id: providerId,
    provider_source: providerSource,
    model,
    credential: 'test-key',
    credential_mode: 'api_key',
    base_url: 'https://openrouter.ai/api/v1'
  }
}

type StreamPart = { text: string } | { toolCall: { id: string; name: string; arguments: Record<string, unknown> } }

function openAIStream(parts: StreamPart[]): Response {
  const chunks: string[] = []
  let finishReason = 'stop'
  for (const part of parts) {
    if ('text' in part) {
      chunks.push(
        sse({
          id: 'chatcmpl-test',
          model: 'test-model',
          choices: [{ delta: { role: 'assistant', content: part.text }, finish_reason: null }]
        })
      )
    } else {
      finishReason = 'tool_calls'
      chunks.push(
        sse({
          id: 'chatcmpl-test',
          model: 'test-model',
          choices: [
            {
              delta: {
                role: 'assistant',
                tool_calls: [
                  {
                    index: 0,
                    id: part.toolCall.id,
                    function: { name: part.toolCall.name, arguments: JSON.stringify(part.toolCall.arguments) }
                  }
                ]
              },
              finish_reason: null
            }
          ]
        })
      )
    }
  }
  chunks.push(
    sse({
      id: 'chatcmpl-test',
      model: 'test-model',
      choices: [{ delta: {}, finish_reason: finishReason }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }
    })
  )
  chunks.push('data: [DONE]\n\n')
  return new Response(chunks.join(''), { headers: { 'content-type': 'text/event-stream' } })
}

function openAIJson(text: string): Response {
  return new Response(
    JSON.stringify({
      id: 'chatcmpl-test',
      model: 'test-model',
      choices: [{ message: { role: 'assistant', content: text }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }
    }),
    { headers: { 'content-type': 'application/json' } }
  )
}

function sse(value: unknown): string {
  return `data: ${JSON.stringify(value)}\n\n`
}
