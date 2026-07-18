import { describe, expect, it } from 'bun:test'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { tmpdir } from 'node:os'
import { z } from 'zod'
import { runAgentLoop } from '../../src/core/agent-loop'
import { zodToJSONSchema, type ContentPart } from '../../src/core/llm'
import { actorEventUserContent } from '../../src/core/turns/actor_event_content'
import { actorEventText } from '../../src/core/turns/actor_event_text'
import { channelContextModelMessages } from '../../src/core/turns/channel_context'
import {
  actorEventEnvironmentInfoLines,
  prependEnvironmentInfoLinesToUserMessage,
  turnRequestEnvironmentInfoLines
} from '../../src/core/turns/message_context'
import { modelConfigFromAIGatewayAPIKey } from '../../src/core/ai_gateway_transport'
import { acquireTurnAIGatewayAccess } from '../../src/core/turns/turn_ai_gateway_access'
import { textTurnResultFromAssistantReply } from '../../src/core/turns/text_turn'
import { steeringMessages } from '../../src/core/turns/turn_control'
import {
  AGENT_SYSTEM_PROMPT_EPOCH,
  buildAgentSystemPrompt,
  systemPromptForConversation
} from '../../src/prompts/system_prompt'
import type { TurnStart } from '../../src/lanes/actor_lane'
import { create } from '@bufbuild/protobuf'
import { jsonBytes } from '../../src/fabric/envelope_proto'
import {
  AgentConversationContextResponseSchema,
  AIGatewayAPIKeyResponseSchema
} from '../../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { AgentConversationContextResponse, AIGatewayAPIKeyResponse } from '../../src/lanes/rpc_lane'
import {
  FakeResponseSocket,
  fakeResponseSocket,
  fallbackModelForTest,
  imageActorEventPayload,
  modelRefForTest,
  testResponseSocket,
  turnStartForTest,
  withImageWorkspace
} from '../support/llm'

describe('@ankole/agent-computer llm helpers: transport and actor content', () => {
  it('acquires one AIGateway access handle for a turn and validates the initial key', async () => {
    const access = await acquireTurnAIGatewayAccess(turnStartForTest(), {
      requestAIGatewayAPIKey: async agentUid => aiGatewayKeyForTest(agentUid, 'agent-key')
    })

    expect(access.model.selector).toBe('openrouter/z-ai/glm-5.2')
    expect(access.aiGateway.baseURL).toBe('https://control.test/api/v1/ai-gateway')
    await expect(access.model.responseWebSocket?.authorization()).resolves.toBe('Bearer agent-key')
  })

  it('rejects AIGateway access acquisition when the key belongs to another agent', async () => {
    await expect(
      acquireTurnAIGatewayAccess(turnStartForTest(), {
        requestAIGatewayAPIKey: async () => aiGatewayKeyForTest('another-agent', 'agent-key')
      })
    ).rejects.toThrow('AIGateway API key response does not match turn agent or auth contract')
  })

  it('rejects refreshed AIGateway keys that no longer match the turn agent', async () => {
    const originalFetch = globalThis.fetch
    const refreshOptions: Array<{ forceRefresh?: boolean } | undefined> = []
    let keyRequests = 0

    globalThis.fetch = (async () => new Response('revoked', { status: 401 })) as unknown as typeof fetch

    try {
      const access = await acquireTurnAIGatewayAccess(turnStartForTest(), {
        requestAIGatewayAPIKey: async (agentUid, options) => {
          refreshOptions.push(options)
          keyRequests += 1

          return keyRequests === 1
            ? aiGatewayKeyForTest(agentUid, 'old-key')
            : aiGatewayKeyForTest('other-agent', 'wrong-key')
        }
      })

      await expect(access.aiGateway.fetch('https://control.test/api/v1/ai-gateway/web_tools')).rejects.toThrow(
        'AIGateway API key response does not match turn agent or auth contract'
      )
      expect(refreshOptions).toEqual([undefined, { forceRefresh: true }])
    } finally {
      globalThis.fetch = originalFetch
    }
  })

  it('builds the AIGateway model config from the control-plane key response', async () => {
    const model = modelConfigFromAIGatewayAPIKey(
      {
        profile: 'primary',
        provider_id: 'openrouter',
        model: 'z-ai/glm-5.2'
      },
      aiGatewayKeyForTest('agent-1', 'agent-key')
    )

    expect(model.selector).toBe('openrouter/z-ai/glm-5.2')
    expect(model.provider).toBe('openrouter')
    expect(model.responseWebSocket?.url).toBe('wss://control.test/api/v1/ai-gateway/responses')
    await expect(model.responseWebSocket?.authorization()).resolves.toBe('Bearer agent-key')
  })

  it('forces AIGateway key refresh after an HTTP 401 before retrying', async () => {
    const originalFetch = globalThis.fetch
    const seenAuthorization: string[] = []
    const refreshOptions: Array<{ forceRefresh?: boolean } | undefined> = []
    let calls = 0

    globalThis.fetch = (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined))
      seenAuthorization.push(headers.get('authorization') ?? '')
      calls += 1

      if (calls === 1) {
        return new Response(JSON.stringify({ error: { message: 'revoked key' } }), {
          status: 401,
          headers: { 'content-type': 'application/json' }
        })
      }

      return new Response(
        JSON.stringify({
          id: 'resp_after_refresh',
          object: 'response',
          status: 'completed',
          output: [
            {
              type: 'message',
              role: 'assistant',
              content: [{ type: 'output_text', text: 'ok' }]
            }
          ]
        }),
        { status: 200, headers: { 'content-type': 'application/json' } }
      )
    }) as unknown as typeof fetch

    try {
      const model = modelConfigFromAIGatewayAPIKey(
        {
          profile: 'primary',
          provider_id: 'ai_gateway',
          model: 'primary'
        },
        aiGatewayKeyForTest('agent-1', 'old-key'),
        async options => {
          refreshOptions.push(options)
          return aiGatewayKeyForTest('agent-1', 'new-key')
        }
      )

      const response = await model.client.responses.create({
        model: model.selector,
        input: 'hello'
      })

      expect(response.id).toBe('resp_after_refresh')
      expect(seenAuthorization).toEqual(['Bearer old-key', 'Bearer new-key'])
      expect(refreshOptions).toEqual([{ forceRefresh: true }])
    } finally {
      globalThis.fetch = originalFetch
    }
  })

  it('makes a third HTTP attempt only after a refreshed key also receives 401', async () => {
    const originalFetch = globalThis.fetch
    const seenAuthorization: string[] = []
    const refreshOptions: Array<{ forceRefresh?: boolean } | undefined> = []
    const cancelledAttempts: number[] = []
    let calls = 0

    globalThis.fetch = (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined))
      seenAuthorization.push(headers.get('authorization') ?? '')
      calls += 1
      if (calls < 3) {
        const attempt = calls
        return new Response(
          new ReadableStream({
            cancel() {
              cancelledAttempts.push(attempt)
            }
          }),
          { status: 401 }
        )
      }
      return new Response('ok', { status: 200 })
    }) as typeof fetch

    try {
      let refreshes = 0
      const access = await acquireTurnAIGatewayAccess(turnStartForTest(), {
        requestAIGatewayAPIKey: async (agentUid, options) => {
          refreshOptions.push(options)
          if (!options?.forceRefresh) return aiGatewayKeyForTest(agentUid, 'old-key')
          refreshes += 1
          return aiGatewayKeyForTest(agentUid, `refreshed-key-${refreshes}`)
        }
      })

      const response = await access.aiGateway.fetch('https://control.test/api/v1/ai-gateway/web_tools')
      expect(await response.text()).toBe('ok')
      expect(seenAuthorization).toEqual(['Bearer old-key', 'Bearer refreshed-key-1', 'Bearer refreshed-key-2'])
      expect(refreshOptions).toEqual([undefined, { forceRefresh: true }, { forceRefresh: true }])
      expect(cancelledAttempts).toEqual([1, 2])
    } finally {
      globalThis.fetch = originalFetch
    }
  }, 10_000)

  it('aborts during refreshed-key backoff without consuming the third HTTP attempt', async () => {
    const originalFetch = globalThis.fetch
    let calls = 0

    globalThis.fetch = (async () => {
      calls += 1
      return new Response('revoked', { status: 401 })
    }) as unknown as typeof fetch

    try {
      const access = await acquireTurnAIGatewayAccess(turnStartForTest(), {
        requestAIGatewayAPIKey: async agentUid => aiGatewayKeyForTest(agentUid, `key-${calls}`)
      })
      const controller = new AbortController()
      setTimeout(() => controller.abort(new Error('caller stopped AIGateway retry')), 20)

      await expect(
        access.aiGateway.fetch('https://control.test/api/v1/ai-gateway/web_tools', { signal: controller.signal })
      ).rejects.toThrow('caller stopped AIGateway retry')
      expect(calls).toBe(2)
    } finally {
      globalThis.fetch = originalFetch
    }
  })

  it('forces AIGateway key refresh after a WebSocket open failure before retrying', async () => {
    const seenAuthorization: string[] = []
    const refreshOptions: Array<{ forceRefresh?: boolean } | undefined> = []
    const sentPayloads: JSONObject[] = []
    let attempts = 0

    const model = modelConfigFromAIGatewayAPIKey(
      {
        profile: 'primary',
        provider_id: 'ai_gateway',
        model: 'primary'
      },
      aiGatewayKeyForTest('agent-1', 'old-key'),
      async options => {
        refreshOptions.push(options)
        return aiGatewayKeyForTest('agent-1', 'new-key')
      }
    )

    model.responseWebSocket!.createWebSocket = (_url, init) => {
      attempts += 1
      seenAuthorization.push(init.headers.authorization ?? init.headers.Authorization ?? '')

      if (attempts === 1) {
        const socket = new FakeResponseSocket(init, () => {
          throw new Error('request should not be sent before open')
        })
        queueMicrotask(() => socket.emitClose('revoked key'))
        return testResponseSocket(socket)
      }

      return fakeResponseSocket(init, data => {
        sentPayloads.push(JSON.parse(data) as JSONObject)
        return [
          {
            type: 'response.completed',
            response: {
              id: 'resp_after_ws_refresh',
              status: 'completed',
              output: [
                {
                  type: 'message',
                  role: 'assistant',
                  content: [{ type: 'output_text', text: 'retried with refreshed key' }]
                }
              ]
            }
          }
        ]
      })
    }

    const final = await runAgentLoop({
      model,
      maxModelIterations: 90,
      messages: [{ role: 'user', content: 'retry websocket auth' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000401',
        conversationID: '40140140-1401-4014-0140-140140140140'
      }
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'retried with refreshed key' }])
    expect(attempts).toBe(2)
    expect(sentPayloads).toHaveLength(1)
    expect(seenAuthorization).toEqual(['Bearer old-key', 'Bearer new-key'])
    expect(refreshOptions).toEqual([{ forceRefresh: true }])
  })

  it('extracts active steer text from the mailbox actor event', () => {
    const turnStart = {
      turn: {
        actor: { agent_uid: 'agent-1', session_id: 'session-1' },
        activation_uid: 'activation-1',
        actor_epoch: 1,
        actor_event_id: '00000000-0000-0000-0000-000000000001',
        revision: 0
      },
      actor_event: {
        actor_event_id: '00000000-0000-0000-0000-000000000001',
        queue_sequence: 1,
        type: 'im.message.addressed',
        source_event_id: 'evt-1',
        payload_json: {}
      }
    }

    const messages = steeringMessages(turnStart, [
      {
        turn: {
          ...turnStart.turn,
          revision: 1
        },
        actorEvent: {
          actor_event_id: '00000000-0000-0000-0000-000000000002',
          queue_sequence: 2,
          type: 'command.steer',
          source_event_id: 'evt-steer-1',
          payload_json: {
            data: {
              command: {
                argsText: 'Reply exactly CHAOS_STEERED_OK and do not call any more tools.'
              }
            }
          }
        }
      }
    ])

    expect(messages).toHaveLength(1)
    expect(messages[0]?.role).toBe('user')
    const content = messages[0]?.role === 'user' ? messages[0].content : ''
    expect(content).toContain('Steering instruction:')
    expect(content).toContain('CHAOS_STEERED_OK')
    expect(turnStart.turn.revision).toBe(1)
  })

  it('does not invent /steer text when a mailbox update has no actor event', () => {
    const turnStart = turnStartForTest()

    const messages = steeringMessages(turnStart, [
      {
        turn: {
          ...turnStart.turn,
          revision: 1
        }
      }
    ])

    expect(messages).toHaveLength(1)
    const content = messages[0]?.role === 'user' ? messages[0].content : ''
    expect(content).toContain('mailbox update arrived')
    expect(content).not.toContain('The user sent /steer')
    expect(turnStart.turn.revision).toBe(1)
  })

  it('ignores mailbox updates that do not match the active turn fence', () => {
    const turnStart = turnStartForTest()

    const messages = steeringMessages(turnStart, [
      {
        turn: {
          ...turnStart.turn,
          actor: { ...turnStart.turn.actor, agent_uid: 'other-agent' },
          revision: 1
        },
        actorEvent: {
          actor_event_id: '00000000-0000-0000-0000-000000000101',
          queue_sequence: 2,
          type: 'command.steer',
          source_event_id: 'evt-steer-other-agent',
          payload_json: { data: { command: { argsText: 'wrong agent' } } }
        }
      },
      {
        turn: {
          ...turnStart.turn,
          actor: { ...turnStart.turn.actor, session_id: 'other-session' },
          revision: 2
        },
        actorEvent: {
          actor_event_id: '00000000-0000-0000-0000-000000000102',
          queue_sequence: 3,
          type: 'command.steer',
          source_event_id: 'evt-steer-other-session',
          payload_json: { data: { command: { argsText: 'wrong session' } } }
        }
      },
      {
        turn: {
          ...turnStart.turn,
          activation_uid: 'other-activation',
          revision: 3
        },
        actorEvent: {
          actor_event_id: '00000000-0000-0000-0000-000000000103',
          queue_sequence: 4,
          type: 'command.steer',
          source_event_id: 'evt-steer-other-activation',
          payload_json: { data: { command: { argsText: 'wrong activation' } } }
        }
      },
      {
        turn: {
          ...turnStart.turn,
          actor_epoch: turnStart.turn.actor_epoch + 1,
          revision: 4
        },
        actorEvent: {
          actor_event_id: '00000000-0000-0000-0000-000000000104',
          queue_sequence: 5,
          type: 'command.steer',
          source_event_id: 'evt-steer-other-epoch',
          payload_json: { data: { command: { argsText: 'wrong epoch' } } }
        }
      },
      {
        turn: {
          ...turnStart.turn,
          actor_event_id: '00000000-0000-0000-0000-000000000999',
          revision: 5
        },
        actorEvent: {
          actor_event_id: '00000000-0000-0000-0000-000000000105',
          queue_sequence: 6,
          type: 'command.steer',
          source_event_id: 'evt-steer-other-event',
          payload_json: { data: { command: { argsText: 'wrong actor event' } } }
        }
      }
    ])

    expect(messages).toEqual([])
    expect(turnStart.turn.revision).toBe(0)
  })

  it('ignores stale mailbox updates for the active turn', () => {
    const turnStart = {
      ...turnStartForTest(),
      turn: {
        ...turnStartForTest().turn,
        revision: 2
      }
    }

    const messages = steeringMessages(turnStart, [
      {
        turn: {
          ...turnStart.turn,
          revision: 2
        },
        actorEvent: {
          actor_event_id: '00000000-0000-0000-0000-000000000201',
          queue_sequence: 7,
          type: 'command.steer',
          source_event_id: 'evt-steer-stale-equal',
          payload_json: { data: { command: { argsText: 'equal revision' } } }
        }
      },
      {
        turn: {
          ...turnStart.turn,
          revision: 1
        },
        actorEvent: {
          actor_event_id: '00000000-0000-0000-0000-000000000202',
          queue_sequence: 8,
          type: 'command.steer',
          source_event_id: 'evt-steer-stale-lower',
          payload_json: { data: { command: { argsText: 'lower revision' } } }
        }
      }
    ])

    expect(messages).toEqual([])
    expect(turnStart.turn.revision).toBe(2)
  })

  it('maps schedule silent-success replies to noop completion only when allowed', () => {
    const scheduledTurnStart = {
      ...turnStartForTest(),
      request_context: { silent_success_allowed: true }
    }

    expect(
      textTurnResultFromAssistantReply(scheduledTurnStart, '<silent_success/>', 'resp_silent', 'loop_finished')
    ).toEqual({
      kind: 'noop_completed',
      reason: 'schedule_silent_success'
    })
    expect(textTurnResultFromAssistantReply(scheduledTurnStart, '   ', 'resp_silent', 'loop_finished')).toEqual({
      kind: 'turn_completed',
      finalResponseID: 'resp_silent',
      outcome: 'loop_finished'
    })
    expect(
      textTurnResultFromAssistantReply(turnStartForTest(), '<silent_success/>', 'resp_final', 'loop_finished')
    ).toEqual({
      kind: 'turn_completed',
      finalResponseID: 'resp_final',
      outcome: 'loop_finished'
    })
    expect(textTurnResultFromAssistantReply(turnStartForTest(), '', 'resp_projection', 'loop_finished')).toEqual({
      kind: 'turn_completed',
      finalResponseID: 'resp_projection',
      outcome: 'loop_finished'
    })
    expect(
      textTurnResultFromAssistantReply(scheduledTurnStart, '<silent_success/>', 'resp_exhausted', 'iteration_exhausted')
    ).toEqual({
      kind: 'turn_completed',
      finalResponseID: 'resp_exhausted',
      outcome: 'iteration_exhausted'
    })
  })

  it('prepends compact group environment info as a separate user message part', () => {
    const lines = actorEventEnvironmentInfoLines(
      {
        time: '2026-07-04T02:03:04.000Z',
        data: {
          channel: { kind: 'im_group', id: 'lark:chat-1', name: 'Ops' },
          entry: {
            text: 'Deploy status?',
            provider_time: '2026-07-04T02:03:04.000Z',
            author: {
              display_name: 'Alice',
              metadata: { sender_type: 'user' }
            }
          }
        }
      },
      { timezone: 'Asia/Shanghai' }
    )

    const message = prependEnvironmentInfoLinesToUserMessage({ role: 'user', content: 'Deploy status?' }, lines)

    expect(message.content).toEqual([
      {
        type: 'text',
        text: [
          '<agent_environment_info>',
          'send_at: 2026-07-04 10:03:04 (Asia/Shanghai)',
          'signal_channel_id: lark:chat-1',
          'speaker: Alice',
          '</agent_environment_info>'
        ].join('\n')
      },
      { type: 'text', text: 'Deploy status?' }
    ])
  })

  it('omits DM speaker metadata and appends only a non-user group role', () => {
    const dm = actorEventEnvironmentInfoLines({
      time: '2026-07-04T02:03:04.000Z',
      data: {
        channel: { kind: 'im_dm', id: 'lark:dm-1' },
        entry: {
          author: {
            display_name: 'Mike',
            metadata: { sender_type: 'user' }
          }
        }
      }
    })
    const chatbotGroup = actorEventEnvironmentInfoLines({
      data: {
        channel: { kind: 'im_group', id: 'lark:chat-1', name: 'Ops' },
        entry: {
          author: {
            display_name: 'Alice',
            metadata: { sender_type: 'chatbot' }
          }
        }
      }
    })

    expect(dm).toEqual(['send_at: 2026-07-04T02:03:04.000Z', 'signal_channel_id: lark:dm-1'])
    expect(chatbotGroup).toEqual(['signal_channel_id: lark:chat-1', 'speaker: Alice (chatbot)'])
  })

  it('keeps durable context in the system suffix and refreshes a stale conversation prompt', () => {
    const turnStart = turnStartForTest() as TurnStart
    const context: AgentConversationContextResponse = create(AgentConversationContextResponseSchema, {
      agent: { displayName: 'Research Agent', role: 'Analyst' },
      conversation: {
        id: 'conversation-1',
        key: 'session-1',
        startedAt: '2026-07-15T01:00:00Z',
        timezone: 'Asia/Shanghai'
      },
      soul: 'Be precise.',
      mission: 'Help with research.',
      design: 'Use cobalt only in visual artifacts.',
      brainSnapshot: {
        pinnedMemo: { residentText: 'Prefer concise evidence.', truncated: false }
      },
      skills: [{ skillName: 'financial-data', description: 'Read current market data.' }]
    })
    const options = {
      workspaceRoot: '/workspace',
      turnStart,
      agentConversationContext: context,
      currentChannel: { kind: 'external_dm' as const, id: 'dm-1', platform: 'feishu' },
      availableToolNames: ['memory_search', 'skill_view']
    }

    const instructions = buildAgentSystemPrompt(options)
    const changedContext: AgentConversationContextResponse = create(AgentConversationContextResponseSchema, {
      agent: { displayName: 'Research Agent', role: 'Analyst' },
      conversation: {
        id: 'conversation-2',
        key: 'session-1',
        startedAt: '2026-07-15T01:00:00Z',
        timezone: 'UTC'
      },
      soul: 'Be precise.',
      mission: 'Help with research.',
      design: 'Use cobalt only in visual artifacts.',
      brainSnapshot: {
        pinnedMemo: { residentText: 'Prefer detailed explanations.', truncated: false }
      },
      skills: [{ skillName: 'documents', description: 'Create documents.' }]
    })
    changedContext.systemPromptSnapshot = instructions
    const changedOptions = {
      ...options,
      agentConversationContext: changedContext,
      currentChannel: { kind: 'external_group' as const, id: 'group-2', platform: 'feishu' }
    }

    expect(instructions).toContain('Asia/Shanghai')
    expect(instructions).toContain('Prefer concise evidence.')
    expect(instructions).toContain('financial-data')
    expect(instructions).toContain(`ankole-system-prompt-epoch:${AGENT_SYSTEM_PROMPT_EPOCH}`)
    expect(instructions).not.toContain('Use cobalt only in visual artifacts.')
    const changedInstructions = buildAgentSystemPrompt(changedOptions)
    expect(changedInstructions).not.toBe(instructions)
    expect(systemPromptForConversation(changedOptions)).toBe(changedInstructions)
    expect(systemPromptForConversation(options)).toBe(instructions)
    expect(instructions.indexOf('<completion_contract>')).toBeLessThan(instructions.indexOf('<runtime_context>'))
    expect(instructions.indexOf('<runtime_context>')).toBeLessThan(instructions.indexOf('<durable_context>'))
  })

  it('refreshes legacy prompt snapshots when the tool contract epoch changes', () => {
    const turnStart = turnStartForTest() as TurnStart
    const context: AgentConversationContextResponse = create(AgentConversationContextResponseSchema, {
      conversation: { id: 'conversation-1', key: 'session-1', timezone: 'UTC' },
      skills: [
        {
          skillName: 'documents',
          description: 'Create and verify a Word document.',
          metadataJson: jsonBytes({ long_running: true })
        }
      ],
      systemPromptSnapshot: 'Legacy prompt with browser automation, Chromium/CDP, tmux, and interactive_terminal.'
    })

    const instructions = systemPromptForConversation({
      workspaceRoot: '/workspace',
      turnStart,
      agentConversationContext: context,
      availableToolNames: ['background_agent_job', 'skill_view']
    })

    expect(instructions).toContain(`ankole-system-prompt-epoch:${AGENT_SYSTEM_PROMPT_EPOCH}`)
    expect(instructions).toContain('<background_agent_job_policy>')
    expect(instructions).toContain('If direct work becomes heavier than expected')
    expect(instructions).toContain('background_agent_job(status)')
    expect(instructions).toContain('background_agent_job(steer)')
    expect(instructions).toContain('documents: [background task]')
    expect(instructions).not.toContain('browser automation')
    expect(instructions).not.toContain('Chromium/CDP')
    expect(instructions).not.toContain('tmux')
    expect(instructions).not.toContain('interactive_terminal')
  })

  it('states the hosted image delivery contract only when that tool is projected', () => {
    const turnStart = turnStartForTest() as TurnStart
    const options = {
      workspaceRoot: '/workspace',
      turnStart,
      agentConversationContext: create(AgentConversationContextResponseSchema, {
        conversation: { id: 'conversation-1', key: 'session-1', timezone: 'UTC' }
      }),
      availableToolNames: ['reply_attachment']
    }

    expect(buildAgentSystemPrompt(options)).not.toContain('image_generation_call IDs')
    expect(
      buildAgentSystemPrompt({
        ...options,
        turnStart: { ...turnStart, hosted_tools: [{ type: 'image_generation' as const }] }
      })
    ).toContain('Images created in this turn with the hosted image_generation tool are attached')
  })

  it('keeps schedule values in the current event block while system policy owns their meaning', () => {
    const turnStart = {
      ...turnStartForTest(),
      request_context: {
        turn_mode: 'check_back_later',
        silent_success_allowed: false,
        schedule_origin: {
          scheduled_event_id: 'schedule-1',
          due_at: '2026-07-15T02:00:00Z',
          fired_at: '2026-07-15T02:00:01Z',
          timezone: 'Asia/Shanghai',
          payload: { symbol: '600519.SH' }
        }
      }
    } as TurnStart

    const lines = turnRequestEnvironmentInfoLines(turnStart)
    expect(lines).toContain('schedule_turn_mode: check_back_later')
    expect(lines).toContain('schedule_silent_success_allowed: false')
    expect(lines).toContain('schedule_payload: {"symbol":"600519.SH"}')

    const context: AgentConversationContextResponse = create(AgentConversationContextResponseSchema, {
      conversation: { id: 'conversation-1', key: 'session-1', timezone: 'Asia/Shanghai' }
    })
    const instructions = buildAgentSystemPrompt({
      workspaceRoot: '/workspace',
      turnStart,
      agentConversationContext: context,
      availableToolNames: []
    })
    expect(instructions).toContain('When schedule_turn_mode is check_back_later')
    expect(instructions).not.toContain('schedule_event_id: schedule-1')
  })

  it('builds multipart actor-event content when the main model supports image input', async () => {
    await withImageWorkspace(async (workspaceRoot, imagePath) => {
      const content = await actorEventUserContent(
        imageActorEventPayload(imagePath),
        'im.message.addressed',
        modelRefForTest(['text', 'image']),
        { workspaceRoot }
      )

      expect(Array.isArray(content)).toBe(true)
      const parts = content as ContentPart[]
      expect(parts[0]).toEqual({
        type: 'text',
        text: `Please inspect this.\n\nAttachments:\n- photo.png: type=image, path=${imagePath}`
      })
      expect(parts[1]!.type).toBe('image')
      const imagePart = parts[1] as Extract<ContentPart, { type: 'image' }>
      expect(imagePart).toMatchObject({ mimeType: 'image/webp' })
      expect(typeof imagePart.image).toBe('string')
      const imageURL = imagePart.image as string
      expect(imageURL).toMatch(/^data:image\/webp;base64,[A-Za-z0-9+/]+=*$/)
      const bytes = Buffer.from(imageURL.slice('data:image/webp;base64,'.length), 'base64')
      expect(bytes.subarray(0, 4).toString('ascii')).toBe('RIFF')
      expect(bytes.subarray(8, 12).toString('ascii')).toBe('WEBP')
    })
  })

  it('passes a materialized image from the explicit reply target to the vision model', async () => {
    await withImageWorkspace(async (workspaceRoot, imagePath) => {
      const content = await actorEventUserContent(
        {
          data: {
            entry: {
              text: '',
              author: { display_name: 'Alice' },
              attachments: [],
              reply_to_source_entry_id: 'parent-image',
              reply_to: {
                source_entry_id: 'parent-image',
                resolution: 'resolved',
                role: 'human',
                attachments: [{ name: 'photo.png', resource_type: 'image', agent_computer_path: imagePath }]
              }
            }
          }
        },
        'im.message.addressed',
        modelRefForTest(['text', 'image']),
        { workspaceRoot }
      )

      expect(Array.isArray(content)).toBe(true)
      const parts = content as ContentPart[]
      expect(parts[0]).toMatchObject({ type: 'text' })
      expect((parts[0] as Extract<ContentPart, { type: 'text' }>).text).toContain('source_entry_id: parent-image')
      expect((parts[0] as Extract<ContentPart, { type: 'text' }>).text).toContain(`path=${imagePath}`)
      expect(parts[1]!.type).toBe('image')
    })
  })

  it('summarizes actor-event images through vision fallback for text-only models', async () => {
    await withImageWorkspace(async (workspaceRoot, imagePath) => {
      const fallbackBodies: JSONObject[] = []
      const fallbackModel = fallbackModelForTest('A small image with visible text.', fallbackBodies)

      const content = await actorEventUserContent(
        imageActorEventPayload(imagePath),
        'im.message.addressed',
        modelRefForTest(['text']),
        { workspaceRoot, visionFallbackModel: fallbackModel }
      )

      expect(typeof content).toBe('string')
      expect(content).toContain("The user attached an image. Here's what it contains")
      expect(content).toContain('A small image with visible text.')
      expect(content).not.toContain('data:image/png;base64,')
      expect(fallbackBodies).toHaveLength(1)
      expect(JSON.stringify(fallbackBodies[0]!.input)).toContain('"type":"input_image"')
      expect(JSON.stringify(fallbackBodies[0]!.input)).toContain('data:image/webp;base64,')
    })
  })

  it('degrades actor-event images to attachment text when no fallback is configured', async () => {
    await withImageWorkspace(async (workspaceRoot, imagePath) => {
      const content = await actorEventUserContent(
        imageActorEventPayload(imagePath),
        'im.message.addressed',
        modelRefForTest(['text']),
        { workspaceRoot }
      )

      expect(content).toContain(`path=${imagePath}`)
      expect(content).toContain('The current model cannot directly view the attached image content')
      expect(content).not.toContain('data:image/png;base64,')
    })
  })

  it('keeps sticker actor-event content deterministic and does not call vision fallback', async () => {
    const fallbackBodies: JSONObject[] = []
    const fallbackModel = fallbackModelForTest('should not be called', fallbackBodies)

    const content = await actorEventUserContent(
      { data: { entry: { text: '<|sticker|>' } } },
      'im.message.addressed',
      modelRefForTest(['text']),
      { workspaceRoot: tmpdir(), visionFallbackModel: fallbackModel }
    )

    expect(content).toBe('<|sticker|>')
    expect(fallbackBodies).toHaveLength(0)
  })

  it('projects shared channel context as a separate provenance-preserving model message', () => {
    const messages = channelContextModelMessages({
      data: {
        channel_context: {
          messages: [
            {
              role: 'human',
              speaker: 'Alice',
              sent_at: '2026-07-15T05:08:00Z',
              text: '这个排版为什么能做这么好？',
              source_entry_id: 'msg-prior-question'
            },
            {
              role: 'agent',
              speaker: 'Research Agent',
              sent_at: '2026-07-15T05:09:00Z',
              text: '是按既有技能和现场内容一起组织的。',
              source_entry_id: 'msg-other-agent-answer'
            }
          ]
        }
      }
    })

    expect(messages).toHaveLength(1)
    expect(messages[0]!.role).toBe('user')
    expect(messages[0]!.content).toContain('Alice')
    expect(messages[0]!.content).toContain('这个排版为什么能做这么好？')
    expect(messages[0]!.content).toContain('Research Agent')
    expect(messages[0]!.content).toContain('是按既有技能和现场内容一起组织的。')
    expect(messages[0]!.content).not.toContain('msg-prior-question')
    expect(messages[0]!.content).not.toContain('source_entry_id')
  })

  it('projects a structured reply action as an explicit user choice without raw callback JSON', () => {
    const text = actorEventText(
      {
        data: {
          action: {
            name: 'reply_interaction',
            value: {
              interaction_id: 'clarify:call-1',
              source_actor_event_id: '019f-source',
              answer: {
                kind: 'choice',
                option_id: 'operators',
                value: 'Operators'
              }
            },
            operator_principal_uid: 'human-1'
          },
          raw: { token: 'must-not-reach-the-model' }
        }
      },
      'signal.action.invoked'
    )

    expect(text).toContain('Selected value: Operators')
    expect(text).toContain('Continue the conversation using this explicit user choice.')
    expect(text).not.toContain('must-not-reach-the-model')
    expect(text).not.toContain('sourceActorEventId')
    expect(text).not.toContain('operator_principal_uid')
  })

  it('projects a free-text clarification answer without exposing callback fields', () => {
    const text = actorEventText(
      {
        data: {
          action: {
            name: 'reply_interaction',
            value: {
              interaction_id: 'clarify:call-2',
              source_actor_event_id: '019f-source',
              answer: {
                kind: 'free_text',
                value: 'Use the latest paragraph above.'
              }
            },
            operator_principal_uid: 'human-1'
          }
        }
      },
      'signal.action.invoked'
    )

    expect(text).toContain('answered a clarification in their own words')
    expect(text).toContain('Answer: Use the latest paragraph above.')
    expect(text).not.toContain('source_actor_event_id')
    expect(text).not.toContain('operator_principal_uid')
  })

  it('converts Zod tool parameters with zod v4 JSON Schema support', () => {
    const schema = z.object({
      command: z.string(),
      timeoutMs: z.number().int().positive().optional()
    })

    const jsonSchema = zodToJSONSchema(schema)

    expect(jsonSchema).toMatchObject({
      type: 'object',
      properties: {
        command: { type: 'string' },
        timeoutMs: { type: 'integer', exclusiveMinimum: 0 }
      },
      required: ['command']
    })
    expect(jsonSchema).toMatchObject({ additionalProperties: false })
  })

  it('rejects function parameters without a root object schema before provider dispatch', () => {
    const schema = z.union([z.string(), z.number()])

    expect(() => zodToJSONSchema(schema)).toThrow('function tool parameters must use a root object schema')
  })
})

function aiGatewayKeyForTest(agentUID: string, apiKey: string): AIGatewayAPIKeyResponse {
  return create(AIGatewayAPIKeyResponseSchema, {
    agentUid: agentUID,
    apiKey,
    tokenType: 'Bearer',
    expiresAt: BigInt(Math.floor(Date.now() / 1000) + 3_600),
    expiresIn: 3_600n,
    scope: 'ai_gateway',
    baseUrl: 'https://control.test/api/v1/ai-gateway/'
  })
}
