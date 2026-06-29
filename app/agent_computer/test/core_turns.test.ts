import { afterEach, describe, expect, it } from 'bun:test'
import { mkdtempSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { runAgentLoop, runLlmTurnHandlers, runTextTurnLoop } from '../src/core'
import type { TurnStart } from '../src/actor_lane'
import type { Message, Model } from '../src/ai-gateway-client/ankole'
import type { LanguageModel, LanguageModelStreamPart } from '../src/ai-gateway-client/provider'
import {
  rpcMethods,
  type AgentConversationContext,
  type AIGatewayApiKeyResponse,
  type ConversationHistoryMessage,
  type ConversationHistoryResponse,
  type RpcMethod,
  type ScheduleRpcRequest
} from '../src/rpc_lane'

const originalFetch = globalThis.fetch

afterEach(() => {
  globalThis.fetch = originalFetch
})

describe('@ankole/agent-computer LLM turn loop', () => {
  it('loads session conversation history through RuntimeFabric history RPC data', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([{ text: 'HISTORY_OK' }])
    }) as typeof fetch

    const workspaceRoot = tempWorkspace()
    const start = turnStart('openrouter-main', 'z-ai/glm-5.2')
    const rows = [
      {
        id: 'msg-current',
        role: 'user',
        kind: 'normal',
        content: [{ type: 'text', text: 'Use one tool, then reply with OK.' }],
        metadata: {
          actor_input_id: 'input-1',
          message_context: {
            time: {
              injected: true,
              sent_at: '2026-06-24T00:00:00.000000Z',
              timezone: 'Asia/Shanghai'
            }
          }
        },
        created_at: '2026-06-24T00:00:00.000000Z'
      },
      {
        id: 'msg-assistant',
        role: 'assistant',
        kind: 'normal',
        content: [{ type: 'text', text: 'Previous answer from durable transcript.' }],
        metadata: {}
      },
      {
        id: 'msg-summary-old',
        role: 'assistant',
        kind: 'summary',
        content: [{ type: 'text', text: 'Outdated compressed previous chat history.' }],
        metadata: {}
      },
      {
        id: 'msg-summary-latest',
        role: 'assistant',
        kind: 'summary',
        content: [{ type: 'text', text: 'Latest compressed previous chat history.' }],
        metadata: {}
      },
      {
        id: 'msg-runtime-note',
        role: 'user',
        kind: 'introspection',
        content: [
          {
            type: 'text',
            text: 'The provider reported that a previously visible user entry was removed.'
          }
        ],
        metadata: {}
      }
    ]

    const reply = await runTextTurnLoop(start, {
      workspaceRoot,
      ...runtimeFixtures(start, rows),
      requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id)
    })

    expect(reply.reply?.text).toBe('HISTORY_OK')
    const body = calls[0].body
    const serializedMessages = requestText(body)
    expect(serializedMessages.match(/Use one tool, then reply with OK\./g)).toHaveLength(1)
    expect(serializedMessages).toContain('Previous answer from durable transcript.')
    expect(serializedMessages).toContain('<previous_chat_history>')
    expect(serializedMessages).toContain('Latest compressed previous chat history.')
    expect(serializedMessages).not.toContain('Outdated compressed previous chat history.')
    expect(serializedMessages).toContain('<agent_environment_info>')
    expect(serializedMessages).toContain('send_at: 2026-06-24 08:00:00 (Asia/Shanghai)')
    expect(serializedMessages).toContain(
      'runtime_note: The provider reported that a previously visible user entry was removed.'
    )
    const userMessages = JSON.stringify(requestMessages(body).filter((message: any) => message.role === 'user'))
    expect(userMessages.match(/<previous_chat_history>/g)).toHaveLength(1)
    expect(userMessages.match(/<agent_environment_info>/g)).toHaveLength(1)
    expect(userMessages.indexOf('<previous_chat_history>')).toBeLessThan(
      userMessages.indexOf('<agent_environment_info>')
    )
    const providerUserMessage = requestMessages(body).find(
      (message: any) => message.role === 'user' && JSON.stringify(message).includes('Use one tool, then reply with OK.')
    )
    expect(Array.isArray(providerUserMessage?.content)).toBe(true)
    const userTextParts = providerUserMessage.content
      .filter((part: any) => part.type === 'text' || part.type === 'input_text')
      .map((part: any) => part.text)
    expect(userTextParts).toHaveLength(3)
    expect(userTextParts[0]).toContain('<previous_chat_history>')
    expect(userTextParts[1]).toContain('<agent_environment_info>')
    expect(userTextParts[2]).toBe('Use one tool, then reply with OK.')
    const systemMessages = JSON.stringify(
      body.instructions ?? requestMessages(body).filter((message: any) => message.role === 'system')
    )
    expect(systemMessages).not.toContain('previously visible user entry')
    expect(systemMessages).not.toContain('Latest compressed previous chat history.')
  })

  it('injects send_at only for the first user row and user rows beyond the prompt gap', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([{ text: 'TIME_GAP_OK' }])
    }) as typeof fetch

    const start = turnStart('openrouter-main', 'z-ai/glm-5.2')
    const rows = [
      {
        id: 'msg-first',
        role: 'user',
        kind: 'normal',
        content: [{ type: 'text', text: 'First time-sensitive question.' }],
        metadata: { actor_input_id: 'input-1' },
        created_at: '2026-06-24T00:00:00.000000Z'
      },
      {
        id: 'msg-assistant',
        role: 'assistant',
        kind: 'normal',
        content: [{ type: 'text', text: 'First answer.' }],
        metadata: {},
        created_at: '2026-06-24T00:01:00.000000Z'
      },
      {
        id: 'msg-second',
        role: 'user',
        kind: 'normal',
        content: [{ type: 'text', text: 'Follow-up within the same hour.' }],
        metadata: { actor_input_id: 'input-2' },
        created_at: '2026-06-24T00:30:00.000000Z'
      },
      {
        id: 'msg-third',
        role: 'user',
        kind: 'normal',
        content: [{ type: 'text', text: 'Exactly one hour later.' }],
        metadata: { actor_input_id: 'input-3' },
        created_at: '2026-06-24T01:00:00.000000Z'
      },
      {
        id: 'msg-fourth',
        role: 'user',
        kind: 'normal',
        content: [{ type: 'text', text: 'One second beyond the gap.' }],
        metadata: { actor_input_id: 'input-4' },
        created_at: '2026-06-24T01:00:01.000000Z'
      }
    ]

    const reply = await runTextTurnLoop(start, {
      workspaceRoot: tempWorkspace(),
      ...runtimeFixtures(start, rows),
      requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id)
    })

    expect(reply.reply?.text).toBe('TIME_GAP_OK')
    const serializedMessages = requestText(calls[0].body)
    expect(serializedMessages.match(/send_at:/g) ?? []).toHaveLength(2)
    expect(serializedMessages).toContain('send_at: 2026-06-24 08:00:00 (Asia/Shanghai)')
    expect(serializedMessages).not.toContain('send_at: 2026-06-24 08:30:00 (Asia/Shanghai)')
    expect(serializedMessages).not.toContain('send_at: 2026-06-24 09:00:00 (Asia/Shanghai)')
    expect(serializedMessages).toContain('send_at: 2026-06-24 09:00:01 (Asia/Shanghai)')
  })

  it('uses summary covers_range to replace covered history rows in the next prompt', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([{ text: 'SUMMARY_REPLACEMENT_OK' }])
    }) as typeof fetch

    const start = turnStart('openrouter-main', 'z-ai/glm-5.2')
    const rows = [
      {
        id: 'msg-covered-user',
        role: 'user',
        kind: 'normal',
        content: [{ type: 'text', text: 'Old verbose user detail that should be compressed away.' }],
        metadata: { actor_input_id: 'input-old-user' },
        created_at: '2026-06-24T00:00:00.000000Z'
      },
      {
        id: 'msg-covered-assistant',
        role: 'assistant',
        kind: 'normal',
        content: [{ type: 'text', text: 'Old verbose assistant answer that should be compressed away.' }],
        metadata: {},
        created_at: '2026-06-24T00:01:00.000000Z'
      },
      {
        id: 'msg-summary',
        role: 'assistant',
        kind: 'summary',
        content: [{ type: 'text', text: 'Compressed old release discussion.' }],
        metadata: {},
        covers_range: {
          message_ids: ['msg-covered-user', 'msg-covered-assistant']
        },
        created_at: '2026-06-24T00:02:00.000000Z'
      },
      {
        id: 'msg-current',
        role: 'user',
        kind: 'normal',
        content: [{ type: 'text', text: 'Continue from the compressed release discussion.' }],
        metadata: { actor_input_id: 'input-current' },
        created_at: '2026-06-24T01:03:00.000000Z'
      }
    ]

    const reply = await runTextTurnLoop(start, {
      workspaceRoot: tempWorkspace(),
      ...runtimeFixtures(start, rows),
      requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id)
    })

    expect(reply.reply?.text).toBe('SUMMARY_REPLACEMENT_OK')
    const serializedMessages = requestText(calls[0].body)
    expect(serializedMessages).toContain('Compressed old release discussion.')
    expect(serializedMessages).toContain('Continue from the compressed release discussion.')
    expect(serializedMessages).not.toContain('Old verbose user detail that should be compressed away.')
    expect(serializedMessages).not.toContain('Old verbose assistant answer that should be compressed away.')
  })

  it('sends provider/model selectors to the AIGateway responses request', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([{ text: 'MODEL_SELECTOR_OK' }])
    }) as typeof fetch

    const start = turnStart('openrouter-main', 'google/gemini-3.5-flash')

    const reply = await runTextTurnLoop(start, {
      workspaceRoot: tempWorkspace(),
      ...runtimeFixtures(start, []),
      requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id)
    })

    expect(reply.reply?.text).toBe('MODEL_SELECTOR_OK')
    expect(calls[0].body.model).toBe('openrouter-main/google/gemini-3.5-flash')
  })

  it('uses agent model aliases as direct AIGateway selectors and fetches the key at turn start', async () => {
    const calls: Array<{ body: any }> = []
    const order: string[] = []
    globalThis.fetch = (async (_url, init) => {
      order.push('provider-http')
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([{ text: 'ALIAS_SELECTOR_OK' }])
    }) as typeof fetch

    const start = turnStart('ai_gateway', 'primary')

    const reply = await runTextTurnLoop(start, {
      workspaceRoot: tempWorkspace(),
      requestAIGatewayApiKey: async request => {
        order.push('ai-gateway-key')
        return aiGatewayApiKey(request.request_id)
      },
      requestAgentConversationContext: async () => {
        order.push('agent-context')
        return agentConversationContext(start)
      },
      requestConversationHistory: async request => {
        order.push('conversation-history')
        return conversationHistory(start, [], request.purpose)
      }
    })

    expect(reply.reply?.text).toBe('ALIAS_SELECTOR_OK')
    expect(calls[0].body.model).toBe('primary')
    expect(order).toEqual(['ai-gateway-key', 'agent-context', 'conversation-history', 'provider-http'])
  })

  it('refreshes an expired AIGateway API key before the provider HTTP request', async () => {
    const seenAuthorizations: string[] = []
    globalThis.fetch = (async (_url, init) => {
      seenAuthorizations.push(new Headers(init?.headers).get('authorization') ?? '')
      return openAIStream([{ text: 'REFRESHED_KEY_OK' }])
    }) as typeof fetch

    const start = turnStart('openrouter-main', 'z-ai/glm-5.2')
    let keyRequests = 0

    const reply = await runTextTurnLoop(start, {
      workspaceRoot: tempWorkspace(),
      ...runtimeFixtures(start, []),
      requestAIGatewayApiKey: async request => {
        keyRequests += 1
        return aiGatewayApiKey(request.request_id, {
          api_key: keyRequests === 1 ? 'expired-key' : 'fresh-key',
          expires_at: Math.floor(Date.now() / 1000) + (keyRequests === 1 ? -10 : 30 * 24 * 60 * 60)
        })
      }
    })

    expect(reply.reply?.text).toBe('REFRESHED_KEY_OK')
    expect(keyRequests).toBe(2)
    expect(seenAuthorizations).toEqual(['Bearer fresh-key'])
  })

  it('renders actor input attachments into the model prompt', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([{ text: 'ATTACHMENT_OK' }])
    }) as typeof fetch

    const workspaceRoot = tempWorkspace()
    const start = turnStart('openrouter-main', 'z-ai/glm-5.2', {
      inputs: [
        {
          actor_input_id: 'input-with-attachments',
          live_queue_sequence: 1,
          type: 'im.message.created',
          ingress_event_id: 'event-with-attachments',
          payload_json: {
            data: {
              entry: {
                text: 'Please inspect the attached files.',
                attachments: [
                  {
                    name: 'invoice.pdf',
                    resource_type: 'file',
                    size: 2048,
                    agent_computer_path: '/workspace/user-files/inbox/message-1/invoice.pdf'
                  },
                  {
                    name: 'screenshot.png',
                    resource_type: 'image',
                    provider_ref: 'lark:image:img_v3_abc'
                  }
                ]
              }
            }
          }
        }
      ]
    })

    const reply = await runTextTurnLoop(start, {
      workspaceRoot,
      ...runtimeFixtures(start, []),
      requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id)
    })

    expect(reply.reply?.text).toBe('ATTACHMENT_OK')
    const serializedMessages = requestText(calls[0].body)
    expect(serializedMessages).toContain('Please inspect the attached files.')
    expect(serializedMessages).toContain('/workspace/user-files/inbox/message-1/invoice.pdf')
    expect(serializedMessages).toContain('lark:image:img_v3_abc')
    expect(serializedMessages).toContain('not_materialized_in_workspace=true')
    expect(serializedMessages).not.toContain('[object Object]')
  })

  it('runs /compress as a worker-owned summarization turn', async () => {
    const calls: Array<{ body: any }> = []
    const commits: any[] = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([
        {
          text: '<analysis>scratch notes</analysis>\n\n## Active Task\n- compress the current context'
        }
      ])
    }) as typeof fetch

    const workspaceRoot = tempWorkspace()
    const start = turnStart('openrouter-main', 'z-ai/glm-5.2', {
      inputs: [
        {
          actor_input_id: 'compress-1',
          live_queue_sequence: 2,
          type: 'command.compress',
          ingress_event_id: 'event-compress',
          payload_json: {
            data: {
              entry: { text: '/compress release notes' },
              command: {
                name: 'compress',
                raw: '/compress release notes',
                argsText: 'release notes'
              }
            }
          }
        }
      ],
      model_ref: {
        profile: 'primary',
        provider_id: 'openrouter-main',
        model: 'z-ai/glm-5.2'
      }
    })
    const recentTail = 'RECENT tail should stay out of compression. '.repeat(2_500)
    const rows = [
      {
        id: 'msg-summary',
        role: 'assistant',
        kind: 'summary',
        content: [{ type: 'text', text: 'Previous compressed chat history.' }],
        metadata: {},
        created_at: '2026-06-23T23:59:00.000000Z'
      },
      {
        id: 'msg-user',
        role: 'user',
        kind: 'normal',
        content: [{ type: 'text', text: 'PING from /Users/ding/Projects/ankole' }],
        metadata: { actor_input_id: 'input-ping' },
        created_at: '2026-06-24T00:00:00.000000Z'
      },
      {
        id: 'msg-assistant',
        role: 'assistant',
        kind: 'normal',
        content: [
          {
            type: 'text',
            text: 'PONG with function_name and error_id=abc-123'
          }
        ],
        metadata: {},
        created_at: '2026-06-24T00:01:00.000000Z'
      },
      {
        id: 'msg-recent-user',
        role: 'user',
        kind: 'normal',
        content: [{ type: 'text', text: recentTail }],
        metadata: { actor_input_id: 'input-recent' },
        created_at: '2026-06-24T00:02:00.000000Z'
      },
      {
        id: 'msg-recent-assistant',
        role: 'assistant',
        kind: 'normal',
        content: [{ type: 'text', text: 'Recent answer kept verbatim after compression.' }],
        metadata: {},
        created_at: '2026-06-24T00:03:00.000000Z'
      },
      {
        id: 'msg-compress-command',
        role: 'user',
        kind: 'normal',
        content: [{ type: 'text', text: '/compress release notes' }],
        metadata: { actor_input_id: 'compress-1' },
        created_at: '2026-06-24T00:04:00.000000Z'
      }
    ]

    const proposal = await runLlmTurnHandlers(start, {
      workspaceRoot,
      agentConversationContext: agentConversationContext(start),
      conversationHistory: conversationHistory(start, rows, 'compression'),
      requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id),
      pollSteering: () => [
        {
          turn: { ...start.turn, revision: 1 },
          inputs: [
            {
              actor_input_id: 'steer-during-compress',
              live_queue_sequence: 3,
              type: 'command.steer',
              ingress_event_id: 'event-steer-compress',
              payload_json: { data: { command: { argsText: 'change compression focus' } } }
            }
          ]
        }
      ],
      commitConversationSummary: async request => {
        commits.push(request)
        return {
          request_id: request.request_id,
          status: 'committed',
          llm_turn_id: start.turn.llm_turn_id,
          summary_message_id: 'summary-message-1',
          covered_message_ids: request.summary.covered_message_ids
        }
      }
    })

    expect(proposal).toEqual({ summaryCommitted: true })
    expect(commits).toHaveLength(1)
    expect(commits[0].summary).toEqual({
      text: '## Active Task\n- compress the current context',
      covered_message_ids: ['msg-user', 'msg-assistant']
    })
    expect(commits[0].turn.revision).toBe(1)
    expect(commits[0].provider_metadata_json).toMatchObject({
      profile: 'light',
      provider_id: 'ai_gateway',
      model: 'light',
      runtime_provider: 'ai-gateway'
    })
    const body = calls[0].body
    const requestText = JSON.stringify(body)
    expect(body.model).toBe('light')
    expect(body.tools).toBeUndefined()
    expect(requestMessages(body).some((message: any) => message.role === 'user')).toBe(true)
    const userPrompt = JSON.stringify(
      requestMessages(body).find((message: any) => message.role === 'user')?.content ?? ''
    )
    expect(requestText).toContain('You are a context summarization assistant')
    expect(userPrompt).toMatch(/UPDATE \\"Completed Actions\\"/i)
    expect(userPrompt).toContain('<previous_chat_history>')
    expect(userPrompt).toContain('Previous compressed chat history.')
    expect(userPrompt).toContain('[User]:')
    expect(userPrompt).toContain('send_at: 2026-06-24 08:00:00 (Asia/Shanghai)')
    expect(userPrompt).toContain('PING from /Users/ding/Projects/ankole')
    expect(userPrompt).toContain('[Assistant]: PONG with function_name and error_id=abc-123')
    expect(userPrompt).not.toContain('RECENT tail should stay out of compression')
    expect(userPrompt).not.toContain('Recent answer kept verbatim after compression')
    expect(userPrompt).not.toContain('/compress release notes')
    expect(userPrompt).not.toContain('change compression focus')
    expect(userPrompt).toContain('<analysis>')
    expect(requestText).not.toContain('Agent UID:')
    expect(requestText).not.toContain('skill_view(name)')
  })

  it('does not treat a merged multi-entry addressed batch as a /compress command', async () => {
    const calls: Array<{ body: any }> = []
    const commits: any[] = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([{ text: 'ORDINARY_COMPRESS_TEXT_OK' }])
    }) as typeof fetch

    const start = turnStart('openrouter-main', 'z-ai/glm-5.2', {
      inputs: [
        {
          actor_input_id: 'input-compress-plus-text',
          live_queue_sequence: 1,
          type: 'im.message.created',
          ingress_event_id: 'event-compress-plus-text',
          payload_json: {
            data: {
              entry: { text: '/compress\nand also remember this detail' },
              entries: [
                { text: '/compress', provider_entry_id: 'msg-compress' },
                {
                  text: 'and also remember this detail',
                  provider_entry_id: 'msg-detail'
                }
              ]
            }
          }
        }
      ]
    })

    const proposal = await runLlmTurnHandlers(start, {
      workspaceRoot: tempWorkspace(),
      ...runtimeFixtures(start, []),
      requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id),
      commitConversationSummary: async request => {
        commits.push(request)
        throw new Error('summary commit should not run')
      }
    })

    if ('summaryCommitted' in proposal) throw new Error('expected ordinary final proposal')
    expect(proposal.reply?.text).toBe('ORDINARY_COMPRESS_TEXT_OK')
    expect(commits).toHaveLength(0)
    expect(requestText(calls[0].body)).toContain('and also remember this detail')
  })

  it('does not treat untyped /compress text as a compression command', async () => {
    const calls: Array<{ body: any }> = []
    const commits: any[] = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([{ text: 'UNTYPED_COMPRESS_TEXT_OK' }])
    }) as typeof fetch

    const start = turnStart('openrouter-main', 'z-ai/glm-5.2', {
      inputs: [
        {
          actor_input_id: 'input-untyped-compress',
          live_queue_sequence: 1,
          type: 'im.message.created',
          ingress_event_id: 'event-untyped-compress',
          payload_json: {
            data: {
              entry: { text: '/compress' }
            }
          }
        }
      ]
    })

    const proposal = await runLlmTurnHandlers(start, {
      workspaceRoot: tempWorkspace(),
      ...runtimeFixtures(start, []),
      requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id),
      commitConversationSummary: async request => {
        commits.push(request)
        throw new Error('summary commit should not run')
      }
    })

    if ('summaryCommitted' in proposal) throw new Error('expected ordinary final proposal')
    expect(proposal.reply?.text).toBe('UNTYPED_COMPRESS_TEXT_OK')
    expect(commits).toHaveLength(0)
    expect(requestText(calls[0].body)).toContain('/compress')
  })

  it('does not summarize when /compress would only cover the recent tail', async () => {
    const calls: Array<{ body: any }> = []
    const commits: any[] = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([{ text: 'SHOULD_NOT_RUN' }])
    }) as typeof fetch

    const start = turnStart('openrouter-main', 'z-ai/glm-5.2', {
      inputs: [
        {
          actor_input_id: 'compress-small',
          live_queue_sequence: 2,
          type: 'command.compress',
          ingress_event_id: 'event-compress-small',
          payload_json: {
            data: {
              entry: { text: '/compress' },
              command: {
                name: 'compress',
                raw: '/compress',
                argsText: ''
              }
            }
          }
        }
      ],
      model_ref: {
        profile: 'primary',
        provider_id: 'openrouter-main',
        model: 'z-ai/glm-5.2'
      }
    })

    const proposal = await runLlmTurnHandlers(start, {
      workspaceRoot: tempWorkspace(),
      agentConversationContext: agentConversationContext(start),
      conversationHistory: conversationHistory(
        start,
        [
          {
            id: 'msg-small-user',
            role: 'user',
            kind: 'normal',
            content: [{ type: 'text', text: 'small recent request' }],
            metadata: { actor_input_id: 'input-small' },
            created_at: '2026-06-24T00:00:00.000000Z'
          },
          {
            id: 'msg-small-assistant',
            role: 'assistant',
            kind: 'normal',
            content: [{ type: 'text', text: 'small recent answer' }],
            metadata: {},
            created_at: '2026-06-24T00:01:00.000000Z'
          },
          {
            id: 'msg-compress-small',
            role: 'user',
            kind: 'normal',
            content: [{ type: 'text', text: '/compress' }],
            metadata: { actor_input_id: 'compress-small' },
            created_at: '2026-06-24T00:02:00.000000Z'
          }
        ],
        'compression'
      ),
      requestAIGatewayApiKey: async () => {
        throw new Error('AIGateway API key should not be requested for a no-op compression')
      },
      commitConversationSummary: async request => {
        commits.push(request)
        return {
          request_id: request.request_id,
          status: 'committed',
          llm_turn_id: start.turn.llm_turn_id,
          summary_message_id: 'summary-message-small',
          covered_message_ids: request.summary.covered_message_ids
        }
      }
    })

    if ('summaryCommitted' in proposal) throw new Error('expected ordinary final proposal')
    expect(proposal.reply?.text).toBe('Conversation already fits in the active context.')
    expect(calls).toEqual([])
    expect(commits).toEqual([])
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
      ...runtimeFixtures(start, []),
      requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id),
      pollSteering: () => {
        if (delivered) return []
        delivered = true
        return [
          {
            turn: { ...start.turn, revision: 1 },
            inputs: [
              {
                actor_input_id: 'steer-1',
                live_queue_sequence: 2,
                type: 'command.steer',
                ingress_event_id: 'event-steer',
                payload_json: {
                  data: {
                    command: { argsText: 'switch to the steered answer' }
                  }
                }
              }
            ]
          }
        ]
      }
    })

    expect(reply.reply?.text).toBe('STEER_OK')
    expect(start.turn.revision).toBe(1)
    const secondBody = JSON.stringify(calls[1].body)
    expect(secondBody).toContain('Runtime note')
    expect(secondBody).toContain('switch to the steered answer')
  })

  it('lets a mocked model schedule a checkback through RuntimeFabric before replying', async () => {
    const providerCalls: Array<{ body: any }> = []
    const scheduleCalls: Array<{
      method: RpcMethod
      request: ScheduleRpcRequest
    }> = []
    globalThis.fetch = (async (_url, init) => {
      providerCalls.push({ body: JSON.parse(String(init?.body)) })
      if (providerCalls.length === 1) {
        return openAIStream([
          {
            toolCall: {
              id: 'checkback-call-1',
              name: 'check_back_later',
              arguments: {
                reason: 'Deployment is still running.',
                check: 'Ask whether the deployment completed cleanly.',
                after: { value: 15, unit: 'minute' },
                idempotency_key: 'deploy-followup-1'
              }
            }
          }
        ])
      }

      return openAIStream([{ text: 'I will check back in 15 minutes.' }])
    }) as typeof fetch

    const start = turnStart('openrouter-main', 'z-ai/glm-5.2', {
      inputs: [
        {
          actor_input_id: 'input-1',
          live_queue_sequence: 1,
          type: 'im.message.created',
          ingress_event_id: 'event-1',
          binding_name: 'mock-im',
          signal_channel_id: 'channel-1',
          provider_thread_id: 'thread-1',
          provider_entry_id: 'entry-1',
          payload_json: {
            data: { entry: { text: 'Check on the deployment in 15 minutes.' } }
          }
        }
      ]
    })

    const reply = await runTextTurnLoop(start, {
      workspaceRoot: tempWorkspace(),
      ...runtimeFixtures(start, []),
      requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id),
      requestScheduleRpc: async (method, request) => {
        scheduleCalls.push({ method, request })
        return {
          request_id: request.request_id,
          scheduled_event_id: 'scheduled-event-1',
          status: 'scheduled'
        }
      }
    })

    expect(reply.reply?.text).toBe('I will check back in 15 minutes.')
    expect(scheduleCalls).toHaveLength(1)
    expect(scheduleCalls[0]).toMatchObject({
      method: rpcMethods.scheduleCheckBackLaterCreate,
      request: {
        tool_call_id: 'checkback-call-1',
        idempotency_key: 'deploy-followup-1',
        schedule: { after: { value: 15, unit: 'minute' } },
        reply_route: {
          binding_name: 'mock-im',
          signal_channel_id: 'channel-1',
          provider_thread_id: 'thread-1',
          provider_entry_id: 'entry-1'
        }
      }
    })
  })

  it('turns an allowed schedule-origin marker into a silent success proposal', async () => {
    globalThis.fetch = (async (_url, _init) => openAIStream([{ text: '<silent_success/>' }])) as typeof fetch

    const start = turnStart('openrouter-main', 'z-ai/glm-5.2', {
      inputs: [
        {
          actor_input_id: 'schedule-input-1',
          live_queue_sequence: 1,
          type: 'check_back_later.wakeup',
          ingress_event_id: 'scheduled-event-1',
          payload_json: {
            data: {
              reason: 'Deployment follow-up',
              check: 'Check whether the deployment completed.'
            }
          }
        }
      ]
    })
    start.request_context = {
      turn_mode: 'checkback_generation',
      silent_success_allowed: true,
      schedule_origin: {
        kind: 'check_back_later',
        scheduled_event_id: 'scheduled-event-1'
      }
    }

    const reply = await runTextTurnLoop(start, {
      workspaceRoot: tempWorkspace(),
      ...runtimeFixtures(start, []),
      requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id)
    })

    expect(reply.silent_success).toBe(true)
    expect(reply.reply).toBeNull()
    expect(reply.messages).toEqual([])
  })

  it('skips ambient observations in normal generation but renders ambient intervention context', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([{ text: 'AMBIENT_REPLY_OK' }])
    }) as typeof fetch

    const workspaceRoot = tempWorkspace()
    const start = turnStart('openrouter-main', 'z-ai/glm-5.2')
    const rows = [
      {
        id: 'ambient-observed',
        role: 'im_ambient',
        kind: 'normal',
        content: [
          {
            type: 'text',
            text: 'This background chat must not enter normal generation.'
          }
        ],
        metadata: { actor_input_id: 'ambient-observed-input' }
      },
      {
        id: 'ambient-intervention-message',
        role: 'im_ambient',
        kind: 'introspection',
        content: [
          {
            type: 'text',
            text: '<chat_segment format="yaml">release summary request</chat_segment>'
          }
        ],
        metadata: {
          message_context: {
            speaker: {
              injected: true,
              display_name: 'agent-1',
              role: 'agent',
              trigger: 'introspection'
            },
            think: {
              injected: true,
              text: 'Runtime intervention, not human-authored text.'
            }
          }
        }
      }
    ]

    const reply = await runTextTurnLoop(start, {
      workspaceRoot,
      ...runtimeFixtures(start, rows),
      requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id)
    })

    expect(reply.reply?.text).toBe('AMBIENT_REPLY_OK')
    const serializedMessages = requestText(calls[0].body)
    expect(serializedMessages).toContain('<agent_environment_info>')
    expect(serializedMessages).toContain('Runtime intervention, not human-authored text.')
    expect(serializedMessages).toContain('release summary request')
    expect(serializedMessages).not.toContain('This background chat must not enter normal generation.')
  })

  it('runs ambient may-intervene events through light recognition before primary generation', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      if (calls.length === 1) {
        return openAIStream([
          {
            text: '{"intervene":true,"reason":"The group is asking the agent."}'
          }
        ])
      }
      return openAIStream([{ text: 'AMBIENT_REPLY_OK' }])
    }) as typeof fetch

    const workspaceRoot = tempWorkspace()
    const start = turnStart('openrouter-main', 'z-ai/glm-5.2', {
      inputs: [
        {
          actor_input_id: 'ambient-input-1',
          live_queue_sequence: 1,
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
      model_ref: {
        profile: 'primary',
        provider_id: 'openrouter-main',
        model: 'z-ai/glm-5.2'
      }
    })
    const rows = [
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
            time: {
              sent_at: '2026-06-24T08:00:00.000000Z',
              timezone: 'Asia/Shanghai'
            },
            actor: { display_name: 'Alice' },
            room: {
              label: 'group chat "Ops"',
              id: 'lark:chat:group-a',
              is_dm: false
            }
          }
        },
        created_at: '2026-06-24T08:00:00.000000Z'
      }
    ]

    const proposal = expectFinalProposal(
      await runLlmTurnHandlers(start, {
        workspaceRoot,
        ...runtimeFixtures(start, rows),
        requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id)
      })
    )

    expect(proposal.reply?.text).toBe('AMBIENT_REPLY_OK')
    const proposedMessage = proposal.messages?.[0]
    const proposedMetadata = proposedMessage?.metadata_json as any
    expect(proposedMessage?.role).toBe('im_ambient')
    expect(proposedMetadata?.control?.type).toBe('ambient_intervention')
    expect(calls[0].body.model).toBe('light')
    expect(calls[1].body.model).toBe('openrouter-main/z-ai/glm-5.2')
    const recognizerFormat = calls[0].body.response_format ?? calls[0].body.text?.format
    expect(recognizerFormat).toMatchObject({
      type: 'json_schema',
      name: 'ambient_intervention_decision'
    })
    expect(recognizerFormat.schema.required).toEqual(['intervene', 'reason'])
    const recognizerMessages = requestText(calls[0].body)
    expect(recognizerMessages).toContain('decide_if_agent_should_visibly_reply_now')
    expect(recognizerMessages).toContain('Alice')
    expect(recognizerMessages).toContain('ReleaseBot')
    expect(recognizerMessages).toContain('Bob')
    expect(recognizerMessages).toContain('08:00')
    expect(recognizerMessages).not.toContain('08:01')
  })

  it('keeps ambient may-intervene silent when light recognition says not to reply', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([
        {
          text: '{"intervene":false,"reason":"The group already handled it."}'
        }
      ])
    }) as typeof fetch

    const workspaceRoot = tempWorkspace()
    const start = turnStart('openrouter-main', 'z-ai/glm-5.2', {
      inputs: [
        {
          actor_input_id: 'ambient-input-1',
          live_queue_sequence: 1,
          type: 'im.message.may_intervene',
          ingress_event_id: 'evt-ambient-1',
          payload_json: {
            data: {
              entry: { text: 'FYI only: deploy finished.' },
              observed_messages: [
                {
                  id: 'signal:msg-ambient-1',
                  role: 'ambient_human',
                  kind: 'normal',
                  speaker: 'Alice',
                  sent_at: '2026-06-24T08:00:00.000000Z',
                  text: 'FYI only: deploy finished.',
                  signal_channel_id: 'lark:chat:group-a',
                  provider_entry_id: 'msg-ambient-1'
                }
              ]
            }
          }
        }
      ],
      model_ref: {
        profile: 'primary',
        provider_id: 'openrouter-main',
        model: 'z-ai/glm-5.2'
      }
    })
    const rows = [
      {
        id: 'ambient-current',
        role: 'im_ambient',
        kind: 'normal',
        content: [{ type: 'text', text: 'FYI only: deploy finished.' }],
        metadata: {
          actor_input_id: 'ambient-input-1',
          signal_channel_id: 'lark:chat:group-a',
          provider_thread_id: 'thread-1',
          provider_entry_id: 'msg-ambient-1',
          message_context: {
            time: {
              sent_at: '2026-06-24T08:00:00.000000Z',
              timezone: 'Asia/Shanghai'
            },
            actor: { display_name: 'Alice' },
            room: {
              label: 'group chat "Ops"',
              id: 'lark:chat:group-a',
              is_dm: false
            }
          }
        },
        created_at: '2026-06-24T08:00:00.000000Z'
      }
    ]

    const proposal = expectFinalProposal(
      await runLlmTurnHandlers(start, {
        workspaceRoot,
        ...runtimeFixtures(start, rows),
        requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id)
      })
    )

    expect(proposal.messages).toEqual([])
    expect(proposal.reply).toBeNull()
    expect(calls).toHaveLength(1)
    expect(calls[0].body.model).toBe('light')
  })

  it('rejects ambient recognizer aliases instead of repairing them in worker code', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([
        {
          text: '{"should_intervene":true,"reason":"The group is asking the agent."}'
        }
      ])
    }) as typeof fetch

    const workspaceRoot = tempWorkspace()
    const start = turnStart('openrouter-main', 'z-ai/glm-5.2', {
      inputs: [
        {
          actor_input_id: 'ambient-input-1',
          live_queue_sequence: 1,
          type: 'im.message.may_intervene',
          ingress_event_id: 'evt-ambient-1',
          payload_json: {
            data: { entry: { text: 'Can agent summarize the release?' } }
          }
        }
      ]
    })
    const rows = [
      {
        id: 'ambient-current',
        role: 'im_ambient',
        kind: 'normal',
        content: [{ type: 'text', text: 'Can agent summarize the release?' }],
        metadata: {
          actor_input_id: 'ambient-input-1',
          message_context: {
            time: {
              sent_at: '2026-06-24T08:00:00.000000Z',
              timezone: 'Asia/Shanghai'
            },
            actor: { display_name: 'Alice' },
            room: {
              label: 'group chat "Ops"',
              id: 'lark:chat:group-a',
              is_dm: false
            }
          }
        },
        created_at: '2026-06-24T08:00:00.000000Z'
      }
    ]

    await expect(
      runLlmTurnHandlers(start, {
        workspaceRoot,
        ...runtimeFixtures(start, rows),
        requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id)
      })
    ).rejects.toThrow(/No object generated|schema/i)

    expect(calls).toHaveLength(1)
  })

  it('stops waiting when a provider stream ignores abort', async () => {
    const controller = new AbortController()
    const timer = setTimeout(() => {
      controller.abort(new DOMException('provider stream test timeout', 'TimeoutError'))
    }, 20)
    timer.unref?.()

    const produced = await runAgentLoop(
      [
        {
          role: 'user',
          content: [{ type: 'text', text: 'This stream never yields.' }],
          timestamp: Date.now()
        }
      ],
      {
        systemPrompt: 'Return a short answer.',
        messages: [],
        tools: []
      },
      {
        model: hangingStreamModel(),
        convertToLlm: messages => messages.flatMap(message => (message.role === 'user' ? [message] : [])),
        maxTurns: 1
      },
      () => {},
      controller.signal
    )

    const latestAssistant = [...produced].reverse().find(message => message.role === 'assistant')
    expect(latestAssistant?.stopReason).toBe('aborted')
    expect(latestAssistant?.errorMessage).toContain('provider stream test timeout')
  })

  for (const scenario of [
    {
      name: 'tool call without result',
      messages: [
        assistantTranscriptMessage({
          content: [
            {
              type: 'toolCall',
              id: 'call-missing-result',
              name: 'command',
              arguments: {}
            }
          ],
          stopReason: 'toolUse'
        })
      ],
      error: 'tool call without result'
    },
    {
      name: 'orphan tool result',
      messages: [
        {
          role: 'toolResult',
          toolCallId: 'call-orphan',
          toolName: 'command',
          content: [{ type: 'text', text: 'orphaned' }],
          isError: false,
          timestamp: Date.now()
        } satisfies Message
      ],
      error: 'orphan tool result'
    },
    {
      name: 'empty assistant',
      messages: [assistantTranscriptMessage({ content: [] })],
      error: 'empty assistant message'
    }
  ]) {
    it(`fails provider transcript validation for ${scenario.name}`, async () => {
      await expect(
        runAgentLoop(
          [
            {
              role: 'user',
              content: [{ type: 'text', text: 'continue' }],
              timestamp: Date.now()
            }
          ],
          {
            systemPrompt: 'Return a short answer.',
            messages: [],
            tools: []
          },
          {
            model: hangingStreamModel(),
            convertToLlm: () => scenario.messages,
            maxTurns: 1
          },
          () => {}
        )
      ).rejects.toThrow(scenario.error)
    })
  }

  it('does not hide agent conversation context RPC failures behind a UID fallback', async () => {
    const start = turnStart('openrouter-main', 'z-ai/glm-5.2')

    await expect(
      runTextTurnLoop(start, {
        workspaceRoot: tempWorkspace(),
        conversationHistory: conversationHistory(start, []),
        requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id),
        requestAgentConversationContext: async () => {
          throw new Error('agent conversation context RPC down')
        }
      })
    ).rejects.toThrow('agent conversation context RPC down')
  })

  it('does not reject raw provider models before AIGateway dispatch', async () => {
    const calls: Array<{ body: any }> = []
    globalThis.fetch = (async (_url, init) => {
      calls.push({ body: JSON.parse(String(init?.body)) })
      return openAIStream([{ text: 'RAW_MODEL_OK' }])
    }) as typeof fetch

    const start = turnStart('openai-main', 'not-a-catalog-model')

    const reply = await runTextTurnLoop(start, {
      workspaceRoot: tempWorkspace(),
      ...runtimeFixtures(start, []),
      requestAIGatewayApiKey: async request => aiGatewayApiKey(request.request_id)
    })

    expect(reply.reply?.text).toBe('RAW_MODEL_OK')
    expect(calls[0].body.model).toBe('openai-main/not-a-catalog-model')
  })

  it('fails closed when the AIGateway API key RPC rejects the actor', async () => {
    const start = turnStart('openrouter-main', 'z-ai/glm-5.2')
    await expect(
      runTextTurnLoop(start, {
        workspaceRoot: tempWorkspace(),
        ...runtimeFixtures(start, []),
        requestAIGatewayApiKey: async request => ({
          request_id: request.request_id,
          agent_uid: request.agent_uid,
          session_id: request.session_id,
          code: 'route_forbidden',
          message: 'worker is not assigned to this actor'
        })
      })
    ).rejects.toThrow('AIGateway API key rejected: route_forbidden worker is not assigned to this actor')
  })
})

function assistantTranscriptMessage(
  overrides: Partial<Extract<Message, { role: 'assistant' }>>
): Extract<Message, { role: 'assistant' }> {
  return {
    role: 'assistant',
    content: [{ type: 'text', text: 'assistant text' }],
    api: 'open-responses',
    provider: 'ai-gateway',
    model: 'z-ai/glm-5.2',
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
    },
    stopReason: 'stop',
    timestamp: Date.now(),
    ...overrides
  }
}

function expectFinalProposal(result: Awaited<ReturnType<typeof runLlmTurnHandlers>>): any {
  if ('summaryCommitted' in result) throw new Error('expected ordinary final proposal')
  return result
}

function tempWorkspace(): string {
  return mkdtempSync(join(tmpdir(), 'ankole-agent-computer-'))
}

function hangingStreamModel(): Model<any> {
  const sdkModel = {
    provider: 'faux-hanging',
    modelId: 'faux-hanging-model',
    supportedUrls: {},
    async doGenerate() {
      return {
        content: [],
        finishReason: { unified: 'stop', raw: 'stop' },
        usage: { inputTokens: 0, outputTokens: 0, totalTokens: 0 },
        warnings: []
      }
    },
    async doStream() {
      return {
        stream: new ReadableStream<LanguageModelStreamPart>({
          pull() {
            return new Promise(() => {})
          }
        })
      }
    }
  } as unknown as LanguageModel

  return {
    id: 'faux-hanging-model',
    name: 'faux-hanging-model',
    api: 'faux',
    provider: 'faux-hanging',
    baseUrl: 'faux://hanging',
    reasoning: false,
    input: ['text'],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 128000,
    maxTokens: 8192,
    sdkModel
  }
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
        live_queue_sequence: 1,
        type: 'im.message.created',
        ingress_event_id: 'event-1',
        payload_json: {
          data: { entry: { text: 'Use one tool, then reply with OK.' } }
        }
      }
    ],
    model_ref: { profile: 'primary', provider_id: providerId, model }
  }
  return { ...base, ...overrides }
}

function runtimeFixtures(
  start: TurnStart,
  rows: ConversationHistoryMessage[]
): {
  agentConversationContext: AgentConversationContext
  conversationHistory: ConversationHistoryResponse
} {
  return {
    agentConversationContext: agentConversationContext(start),
    conversationHistory: conversationHistory(start, rows)
  }
}

function agentConversationContext(start: TurnStart): AgentConversationContext {
  return {
    request_id: `agent-conversation-context-${start.turn.llm_turn_id}`,
    agent_uid: start.turn.actor.agent_uid,
    session_id: start.turn.actor.session_id,
    turn: start.turn,
    agent: {
      display_name: 'ReleaseBot',
      role: 'agent'
    },
    conversation: {
      id: 'conversation-1',
      key: start.turn.actor.session_id,
      started_at: '2026-06-24T00:00:00.000000Z',
      timezone: 'Asia/Shanghai'
    },
    soul: 'Use restrained, factual judgment.',
    mission: '',
    skills: []
  }
}

function conversationHistory(
  start: TurnStart,
  rows: ConversationHistoryMessage[],
  purpose: 'prompt' | 'compression' = 'prompt'
): ConversationHistoryResponse {
  return {
    request_id: `conversation-history-${start.turn.llm_turn_id}`,
    agent_uid: start.turn.actor.agent_uid,
    session_id: start.turn.actor.session_id,
    conversation_id: 'conversation-1',
    conversation_started_at: '2026-06-24T00:00:00.000000Z',
    purpose,
    messages: rows
  }
}

function aiGatewayApiKey(requestId: string, overrides: Partial<AIGatewayApiKeyResponse> = {}): AIGatewayApiKeyResponse {
  return {
    request_id: requestId,
    agent_uid: 'agent-1',
    session_id: 'signal-channel:test',
    api_key: 'test-ai-gateway-key',
    token_type: 'Bearer',
    expires_at: Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60,
    expires_in: 30 * 24 * 60 * 60,
    scope: 'ai_gateway',
    base_url: 'https://control-plane.test/api/v1/ai-gateway',
    ...overrides
  }
}

function requestMessages(body: any): any[] {
  return body.input ?? body.messages ?? []
}

function requestText(body: any): string {
  return JSON.stringify(requestMessages(body))
}

type StreamPart =
  | { text: string }
  | {
      toolCall: {
        id: string
        name: string
        arguments: Record<string, unknown>
      }
    }

function openAIStream(parts: StreamPart[]): Response {
  const chunks: string[] = []
  let sequenceNumber = 1
  let outputIndex = 0
  chunks.push(
    sse({
      type: 'response.created',
      response: {
        id: 'resp-test',
        created_at: 1_803_000_000,
        model: 'test-model'
      }
    })
  )

  for (const part of parts) {
    if ('text' in part) {
      const itemId = `msg-test-${outputIndex}`
      chunks.push(
        sse({
          type: 'response.output_item.added',
          sequence_number: sequenceNumber++,
          output_index: outputIndex,
          item: { id: itemId, type: 'message', role: 'assistant', status: 'in_progress', content: [] }
        })
      )
      chunks.push(
        sse({
          type: 'response.output_text.delta',
          sequence_number: sequenceNumber++,
          item_id: itemId,
          output_index: outputIndex,
          content_index: 0,
          delta: part.text
        })
      )
      chunks.push(
        sse({
          type: 'response.output_item.done',
          sequence_number: sequenceNumber++,
          output_index: outputIndex,
          item: {
            id: itemId,
            type: 'message',
            role: 'assistant',
            status: 'completed',
            content: [{ type: 'output_text', text: part.text, annotations: [] }]
          }
        })
      )
    } else {
      const itemId = `fc-test-${outputIndex}`
      const input = JSON.stringify(part.toolCall.arguments)
      chunks.push(
        sse({
          type: 'response.output_item.added',
          sequence_number: sequenceNumber++,
          output_index: outputIndex,
          item: {
            id: itemId,
            type: 'function_call',
            call_id: part.toolCall.id,
            name: part.toolCall.name,
            arguments: ''
          }
        })
      )
      chunks.push(
        sse({
          type: 'response.function_call_arguments.delta',
          sequence_number: sequenceNumber++,
          item_id: itemId,
          output_index: outputIndex,
          delta: input
        })
      )
      chunks.push(
        sse({
          type: 'response.output_item.done',
          sequence_number: sequenceNumber++,
          output_index: outputIndex,
          item: {
            id: itemId,
            type: 'function_call',
            call_id: part.toolCall.id,
            name: part.toolCall.name,
            arguments: input,
            status: 'completed'
          }
        })
      )
    }
    outputIndex += 1
  }
  chunks.push(
    sse({
      type: 'response.completed',
      sequence_number: sequenceNumber++,
      response: {
        usage: {
          input_tokens: 1,
          output_tokens: 1,
          total_tokens: 2
        }
      }
    })
  )
  return new Response(chunks.join(''), {
    headers: { 'content-type': 'text/event-stream' }
  })
}

function sse(value: unknown): string {
  return `data: ${JSON.stringify(value)}\n\n`
}
