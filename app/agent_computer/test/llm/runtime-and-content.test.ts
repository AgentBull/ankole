import { describe, expect, it } from 'bun:test'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { tmpdir } from 'node:os'
import { z } from 'zod'
import { runAgentLoop } from '../../src/core/agent-loop'
import { zodToJSONSchema, type ContentPart } from '../../src/core/llm'
import { actorEventUserContent } from '../../src/core/turns/actor_event_content'
import {
  actorEventEnvironmentInfoLines,
  prependEnvironmentInfoLinesToUserMessage
} from '../../src/core/turns/message_context'
import { modelConfigFromAIGatewayAPIKey } from '../../src/core/ai_gateway_transport'
import { acquireTurnAIGatewayAccess } from '../../src/core/turns/turn_ai_gateway_access'
import { textTurnResultFromAssistantReply } from '../../src/core/turns/text_turn'
import { steeringMessages } from '../../src/core/turns/turn_control'
import type { AIGatewayAPIKeyResponse } from '../../src/lanes/rpc_lane'
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
      requestAIGatewayAPIKey: async request => aiGatewayKeyForTest(request.agent_uid, 'agent-key')
    })

    expect(access.model.selector).toBe('openrouter/z-ai/glm-5.2')
    expect(access.aiGateway.baseURL).toBe('https://control.test/api/v1/ai-gateway')
    await expect(access.model.responseWebSocket?.authorization()).resolves.toBe('Bearer agent-key')
  })

  it('rejects AIGateway access acquisition when the key response is rejected', async () => {
    await expect(
      acquireTurnAIGatewayAccess(turnStartForTest(), {
        requestAIGatewayAPIKey: async request => ({
          request_id: request.request_id,
          agent_uid: request.agent_uid,
          code: 'missing_agent_uid',
          message: 'agent uid is required'
        })
      })
    ).rejects.toThrow('AIGateway API key rejected: missing_agent_uid agent uid is required')
  })

  it('rejects refreshed AIGateway keys that no longer match the turn agent', async () => {
    const originalFetch = globalThis.fetch
    const refreshOptions: Array<{ forceRefresh?: boolean } | undefined> = []
    let keyRequests = 0

    globalThis.fetch = (async () => new Response('revoked', { status: 401 })) as unknown as typeof fetch

    try {
      const access = await acquireTurnAIGatewayAccess(turnStartForTest(), {
        requestAIGatewayAPIKey: async (request, options) => {
          refreshOptions.push(options)
          keyRequests += 1

          return keyRequests === 1
            ? aiGatewayKeyForTest(request.agent_uid, 'old-key')
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
      {
        request_id: 'key-1',
        agent_uid: 'agent-1',
        api_key: 'agent-key',
        token_type: 'Bearer',
        expires_at: Math.floor(Date.now() / 1000) + 3_600,
        expires_in: 3_600,
        scope: 'ai_gateway',
        base_url: 'https://control.test/api/v1/ai-gateway/'
      }
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
    }) as typeof fetch

    try {
      const model = modelConfigFromAIGatewayAPIKey(
        {
          profile: 'primary',
          provider_id: 'ai_gateway',
          model: 'primary'
        },
        {
          request_id: 'key-old',
          agent_uid: 'agent-1',
          api_key: 'old-key',
          token_type: 'Bearer',
          expires_at: Math.floor(Date.now() / 1000) + 3_600,
          expires_in: 3_600,
          scope: 'ai_gateway',
          base_url: 'https://control.test/api/v1/ai-gateway'
        },
        async options => {
          refreshOptions.push(options)
          return {
            request_id: 'key-new',
            agent_uid: 'agent-1',
            api_key: 'new-key',
            token_type: 'Bearer',
            expires_at: Math.floor(Date.now() / 1000) + 3_600,
            expires_in: 3_600,
            scope: 'ai_gateway',
            base_url: 'https://control.test/api/v1/ai-gateway'
          }
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
      {
        request_id: 'key-old',
        agent_uid: 'agent-1',
        api_key: 'old-key',
        token_type: 'Bearer',
        expires_at: Math.floor(Date.now() / 1000) + 3_600,
        expires_in: 3_600,
        scope: 'ai_gateway',
        base_url: 'https://control.test/api/v1/ai-gateway'
      },
      async options => {
        refreshOptions.push(options)
        return {
          request_id: 'key-new',
          agent_uid: 'agent-1',
          api_key: 'new-key',
          token_type: 'Bearer',
          expires_at: Math.floor(Date.now() / 1000) + 3_600,
          expires_in: 3_600,
          scope: 'ai_gateway',
          base_url: 'https://control.test/api/v1/ai-gateway'
        }
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
      kind: 'noop_completed',
      reason: 'schedule_silent_success'
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

  it('prepends actor event environment info as a separate user message part', () => {
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
          'room: Ops',
          'speaker: Alice',
          'speaker_role: user',
          '</agent_environment_info>'
        ].join('\n')
      },
      { type: 'text', text: 'Deploy status?' }
    ])
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
      expect(imagePart).toMatchObject({ mimeType: 'image/png' })
      expect(typeof imagePart.image).toBe('string')
      const imageURL = imagePart.image as string
      expect(imageURL).toMatch(/^data:image\/png;base64,[A-Za-z0-9+/]+=*$/)
      expect([...Buffer.from(imageURL.slice('data:image/png;base64,'.length), 'base64').subarray(0, 8)]).toEqual([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a
      ])
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
})

function aiGatewayKeyForTest(agentUID: string, apiKey: string): AIGatewayAPIKeyResponse {
  return {
    request_id: `key-${apiKey}`,
    agent_uid: agentUID,
    api_key: apiKey,
    token_type: 'Bearer',
    expires_at: Math.floor(Date.now() / 1000) + 3_600,
    expires_in: 3_600,
    scope: 'ai_gateway',
    base_url: 'https://control.test/api/v1/ai-gateway/'
  }
}
