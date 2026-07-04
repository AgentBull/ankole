import { describe, expect, it } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { z } from 'zod'
import { runAgentLoop } from '../src/core/agent-loop'
import { callModel, createModel, zodToJSONSchema, type ContentPart, type ResponseWebSocketLike } from '../src/core/llm'
import { classifyLlmError, isLocallyRetryableLlmError } from '../src/core/llm-error-classifier'
import { actorEventUserContent } from '../src/core/turns/actor_event_content'
import { statefulTruncationFromActorEventPayload } from '../src/core/turns/actor_event_text'
import {
  actorEventEnvironmentInfoLines,
  prependEnvironmentInfoLinesToUserMessage
} from '../src/core/turns/message_context'
import { runtimeModelFromAIGatewayApiKey } from '../src/core/turns/model_runtime'
import { textTurnResultFromAssistantReply } from '../src/core/turns/text_turn'
import { steeringMessages } from '../src/core/turns/turn_control'

describe('@ankole/agent-computer llm helpers', () => {
  it('builds the AIGateway runtime model from the control-plane key response', async () => {
    const model = runtimeModelFromAIGatewayApiKey(
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
      const model = runtimeModelFromAIGatewayApiKey(
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
    const sentPayloads: Record<string, unknown>[] = []
    let attempts = 0

    const model = runtimeModelFromAIGatewayApiKey(
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
      seenAuthorization.push(init.headers.authorization)

      if (attempts === 1) {
        const socket = new FakeResponseSocket(init, () => {
          throw new Error('request should not be sent before open')
        })
        queueMicrotask(() => socket.emitClose('revoked key'))
        return socket as unknown as ResponseWebSocketLike
      }

      return fakeResponseSocket(init, data => {
        sentPayloads.push(JSON.parse(data) as Record<string, unknown>)
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
      messages: [{ role: 'user', content: 'retry websocket auth' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000401',
        conversationId: '40140140-1401-4014-0140-140140140140'
      }
    })

    expect(final.content).toEqual([{ type: 'text', text: 'retried with refreshed key' }])
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

  it('maps schedule silent-success replies to noop completion only when allowed', () => {
    const scheduledTurnStart = {
      ...turnStartForTest(),
      request_context: { silent_success_allowed: true }
    }

    expect(textTurnResultFromAssistantReply(scheduledTurnStart, '<silent_success/>')).toEqual({
      kind: 'noop_completed',
      reason: 'schedule_silent_success'
    })
    expect(textTurnResultFromAssistantReply(scheduledTurnStart, '   ')).toEqual({
      kind: 'noop_completed',
      reason: 'schedule_silent_success'
    })
    expect(textTurnResultFromAssistantReply(turnStartForTest(), '<silent_success/>')).toEqual({
      kind: 'aigateway_response'
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
      const imageUrl = imagePart.image as string
      expect(imageUrl).toMatch(/^data:image\/png;base64,[A-Za-z0-9+/]+=*$/)
      expect([...Buffer.from(imageUrl.slice('data:image/png;base64,'.length), 'base64').subarray(0, 8)]).toEqual([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a
      ])
    })
  })

  it('summarizes actor-event images through vision fallback for text-only models', async () => {
    await withImageWorkspace(async (workspaceRoot, imagePath) => {
      const fallbackBodies: Record<string, unknown>[] = []
      const fallbackModel = fallbackModelForTest('A small image with visible text.', fallbackBodies)

      const content = await actorEventUserContent(
        imageActorEventPayload(imagePath),
        'im.message.addressed',
        modelRefForTest(['text']),
        { workspaceRoot, visionFallbackModel: fallbackModel }
      )

      expect(typeof content).toBe('string')
      expect(content).toContain('<image_summary>')
      expect(content).toContain('Automatic visual description of the user')
      expect(content).toContain('A small image with visible text.')
      expect(content).toContain('</image_summary>')
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
      expect(content).not.toContain('<image_summary>')
      expect(content).not.toContain('data:image/png;base64,')
    })
  })

  it('keeps sticker actor-event content deterministic and does not call vision fallback', async () => {
    const fallbackBodies: Record<string, unknown>[] = []
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

  it('passes image input through as Responses input_image content', async () => {
    const bodies: Record<string, unknown>[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        const request = input instanceof Request ? input : new Request(input, init)
        bodies.push(JSON.parse(await request.text()) as Record<string, unknown>)

        return new Response(
          JSON.stringify({
            id: 'resp_image',
            object: 'response',
            status: 'completed',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [{ type: 'output_text', text: 'seen' }]
              }
            ]
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        )
      }) as unknown as typeof fetch
    })

    await callModel(model, {
      messages: [
        {
          role: 'user',
          content: [
            { type: 'text', text: 'look' },
            { type: 'image', image: 'data:image/png;base64,AAA=' }
          ]
        }
      ]
    })

    expect(bodies[0]!.input).toEqual([
      {
        role: 'user',
        content: [
          { type: 'input_text', text: 'look' },
          { type: 'input_image', image_url: 'data:image/png;base64,AAA=', detail: 'auto' }
        ]
      }
    ])
  })

  it('encodes binary PNG image input as a base64 PNG data URL', async () => {
    const bodies: Record<string, unknown>[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        const request = input instanceof Request ? input : new Request(input, init)
        bodies.push(JSON.parse(await request.text()) as Record<string, unknown>)

        return new Response(
          JSON.stringify({
            id: 'resp_binary_image',
            object: 'response',
            status: 'completed',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [{ type: 'output_text', text: 'seen' }]
              }
            ]
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        )
      }) as unknown as typeof fetch
    })

    const pngBytes = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
      'base64'
    )

    await callModel(model, {
      messages: [
        {
          role: 'user',
          content: [
            { type: 'text', text: 'look' },
            { type: 'image', mimeType: 'image/png', image: pngBytes }
          ]
        }
      ]
    })

    const input = bodies[0]!.input as Array<{ content: Array<Record<string, unknown>> }>
    const imageUrl = input[0]!.content[1]!.image_url

    expect(typeof imageUrl).toBe('string')
    expect(imageUrl).toMatch(/^data:image\/png;base64,[A-Za-z0-9+/]+=*$/)
    expect([
      ...Buffer.from((imageUrl as string).slice('data:image/png;base64,'.length), 'base64').subarray(0, 8)
    ]).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  })

  it('passes Responses structured output text format through HTTP calls', async () => {
    const bodies: Record<string, unknown>[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        const request = input instanceof Request ? input : new Request(input, init)
        bodies.push(JSON.parse(await request.text()) as Record<string, unknown>)

        return new Response(
          JSON.stringify({
            id: 'resp_structured',
            object: 'response',
            status: 'completed',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [{ type: 'output_text', text: '{"intervene":false,"reason":"quiet"}' }]
              }
            ]
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        )
      }) as unknown as typeof fetch
    })

    await callModel(model, {
      messages: [{ role: 'user', content: 'decide' }],
      text: {
        format: {
          type: 'json_schema',
          name: 'ambient_intervention_decision',
          strict: true,
          schema: {
            type: 'object',
            properties: {
              intervene: { type: 'boolean' },
              reason: { type: 'string' }
            },
            required: ['intervene', 'reason'],
            additionalProperties: false
          }
        }
      }
    })

    expect(bodies[0]!.text).toEqual({
      format: expect.objectContaining({
        type: 'json_schema',
        name: 'ambient_intervention_decision'
      })
    })
  })

  it('passes abortSignal through HTTP Responses calls', async () => {
    const controller = new AbortController()
    let fetchCalled = false
    let requestSignalAborted = false
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        fetchCalled = true
        const requestSignal = init?.signal ?? (input instanceof Request ? input.signal : undefined)
        if (!requestSignal) throw new Error('missing abort signal')

        queueMicrotask(() => controller.abort(new DOMException('operator stop', 'AbortError')))

        return await new Promise<Response>((_resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('abort signal did not fire')), 50)
          requestSignal.addEventListener(
            'abort',
            () => {
              clearTimeout(timer)
              requestSignalAborted = true
              reject(new Error('request signal aborted'))
            },
            { once: true }
          )
        })
      }) as unknown as typeof fetch
    })

    let rejected = false
    try {
      await callModel(model, {
        messages: [{ role: 'user', content: 'wait' }],
        abortSignal: controller.signal
      })
    } catch {
      rejected = true
    }

    expect(rejected).toBe(true)
    expect(fetchCalled).toBe(true)
    expect(requestSignalAborted).toBe(true)
  })

  it('classifies AIGateway WebSocket transport failures as retryable timeouts', () => {
    const beforeOpen = Object.assign(new Error('AIGateway WebSocket closed before open'), {
      details: { local_retryable: true }
    })
    const afterSend = Object.assign(new Error('AIGateway WebSocket closed before response.completed'), {
      details: { local_retryable: false }
    })

    for (const error of [
      beforeOpen,
      afterSend,
      new Error('AIGateway WebSocket transport error'),
      new Error('LLM provider call aborted')
    ]) {
      expect(classifyLlmError(error)).toMatchObject({ kind: 'timeout', retryable: true })
    }

    expect(isLocallyRetryableLlmError(beforeOpen)).toBe(true)
    expect(isLocallyRetryableLlmError(afterSend)).toBe(false)
  })

  it('sends stateful response.create over AIGateway WebSocket', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            sentPayloads.push(JSON.parse(data) as Record<string, unknown>)
            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_message_1',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'hello' }]
                    }
                  ],
                  usage: { input_tokens: 3, output_tokens: 2 }
                }
              }
            ]
          })
      }
    })

    const result = await callModel(model, {
      instructions: 'system prompt',
      messages: [{ role: 'user', content: 'hi' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000001',
        conversationId: '11111111-1111-1111-1111-111111111111'
      }
    })

    expect(result.responseId).toBe('resp_message_1')
    expect(result.message.content).toEqual([{ type: 'text', text: 'hello' }])
    expect(sentPayloads).toHaveLength(1)
    expect(sentPayloads[0]).toMatchObject({
      type: 'response.create',
      model: 'primary',
      instructions: 'system prompt',
      store: true,
      conversation: 'conv_11111111-1111-1111-1111-111111111111',
      metadata: { actor_event_id: '00000000-0000-0000-0000-000000000001' },
      input: [{ role: 'user', content: 'hi' }]
    })
    expect(JSON.stringify(sentPayloads[0]!.input)).not.toContain('system prompt')
  })

  it('keeps user text parts as Responses input_text parts', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            sentPayloads.push(JSON.parse(data) as Record<string, unknown>)
            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_message_parts',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'ok' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    await callModel(model, {
      messages: [
        {
          role: 'user',
          content: [
            { type: 'text', text: '<agent_environment_info>\nroom: Ops\n</agent_environment_info>' },
            { type: 'text', text: 'Deploy status?' }
          ]
        }
      ],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000701',
        conversationId: '77777777-7777-7777-7777-777777777777'
      }
    })

    expect(sentPayloads[0]).toMatchObject({
      input: [
        {
          role: 'user',
          content: [
            { type: 'input_text', text: '<agent_environment_info>\nroom: Ops\n</agent_environment_info>' },
            { type: 'input_text', text: 'Deploy status?' }
          ]
        }
      ]
    })
  })

  it('uses the native WebSocket constructor when no test socket factory is injected', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const server = Bun.serve({
      port: 0,
      fetch(request, server) {
        if (server.upgrade(request)) return
        return new Response('not found', { status: 404 })
      },
      websocket: {
        message(ws, message) {
          const text = typeof message === 'string' ? message : new TextDecoder().decode(message as BufferSource)
          sentPayloads.push(JSON.parse(text) as Record<string, unknown>)
          ws.send(
            JSON.stringify({
              type: 'response.completed',
              response: {
                id: 'resp_native_ws',
                status: 'completed',
                output: [
                  {
                    type: 'message',
                    role: 'assistant',
                    content: [{ type: 'output_text', text: 'native websocket ok' }]
                  }
                ]
              }
            })
          )
        }
      }
    })

    try {
      const model = createModel({
        apiKey: 'unused',
        baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
        selector: 'primary',
        responseWebSocket: {
          kind: 'aigateway-websocket',
          url: `ws://127.0.0.1:${server.port}/responses`,
          authorization: () => 'Bearer agent-key'
        }
      })

      const result = await callModel(model, {
        messages: [{ role: 'user', content: 'hi' }],
        stateful: {
          actorEventId: '00000000-0000-0000-0000-000000000012',
          conversationId: 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        }
      })

      expect(result.responseId).toBe('resp_native_ws')
      expect(result.message.content).toEqual([{ type: 'text', text: 'native websocket ok' }])
      expect(sentPayloads).toHaveLength(1)
      expect(sentPayloads[0]).toMatchObject({
        type: 'response.create',
        conversation: 'conv_cccccccc-cccc-cccc-cccc-cccccccccccc'
      })
    } finally {
      server.stop(true)
    }
  })

  it('uses output_item.done items when a terminal WebSocket frame has empty output', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, () => [
            {
              type: 'response.output_item.done',
              item: {
                type: 'message',
                role: 'assistant',
                content: [{ type: 'output_text', text: 'stable item text' }]
              }
            },
            {
              type: 'response.completed',
              response: {
                id: 'resp_empty_terminal_output',
                status: 'completed',
                output: []
              }
            }
          ])
      }
    })

    const result = await callModel(model, {
      messages: [{ role: 'user', content: 'hi' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000013',
        conversationId: 'dddddddd-dddd-dddd-dddd-dddddddddddd'
      }
    })

    expect(result.responseId).toBe('resp_empty_terminal_output')
    expect(result.message.content).toEqual([{ type: 'text', text: 'stable item text' }])
    expect(result.message.stopReason).toBe('stop')
  })

  it('maps response.incomplete WebSocket terminals to an error assistant message', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, () => [
            {
              type: 'response.incomplete',
              response: {
                id: 'resp_incomplete',
                status: 'incomplete',
                incomplete_details: { reason: 'max_output_tokens' },
                output: [
                  {
                    type: 'message',
                    role: 'assistant',
                    content: [{ type: 'output_text', text: 'partial answer' }]
                  }
                ]
              }
            }
          ])
      }
    })

    const result = await callModel(model, {
      messages: [{ role: 'user', content: 'hi' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000014',
        conversationId: 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
      }
    })

    expect(result.responseId).toBe('resp_incomplete')
    expect(result.message.content).toEqual([{ type: 'text', text: 'partial answer' }])
    expect(result.message.stopReason).toBe('error')
    expect(result.message.errorMessage).toBe('max_output_tokens')
  })

  it('retries AIGateway WebSocket close before open without sending a duplicate request', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    let attempts = 0
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) => {
          attempts += 1
          if (attempts === 1) {
            const socket = new FakeResponseSocket(init, () => {
              throw new Error('request should not be sent before open')
            })
            queueMicrotask(() => socket.emitClose('gateway restart before open'))
            return socket as unknown as ResponseWebSocketLike
          }

          return fakeResponseSocket(init, data => {
            sentPayloads.push(JSON.parse(data) as Record<string, unknown>)
            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_after_before_open_close',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'retried after open close' }]
                    }
                  ]
                }
              }
            ]
          })
        }
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'retry after websocket close before open' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000010',
        conversationId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      }
    })

    expect(final.content).toEqual([{ type: 'text', text: 'retried after open close' }])
    expect(attempts).toBe(2)
    expect(sentPayloads).toHaveLength(1)
  })

  it('does not locally retry AIGateway WebSocket close after response.create was sent', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    let caught: unknown
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, (data, socket) => {
            sentPayloads.push(JSON.parse(data) as Record<string, unknown>)
            queueMicrotask(() => socket.emitClose('gateway restart after response.create'))
            return []
          })
      }
    })

    try {
      await runAgentLoop({
        model,
        messages: [{ role: 'user', content: 'do not duplicate after send' }],
        stateful: {
          actorEventId: '00000000-0000-0000-0000-000000000011',
          conversationId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        }
      })
    } catch (error) {
      caught = error
    }

    expect(caught).toBeInstanceOf(Error)
    expect((caught as Error).message).toContain('AIGateway WebSocket closed before response.completed')
    expect(classifyLlmError(caught)).toMatchObject({ kind: 'timeout', retryable: true })
    expect(isLocallyRetryableLlmError(caught)).toBe(false)
    expect(sentPayloads).toHaveLength(1)
  })

  it('does not locally retry AIGateway WebSocket error after response.create was sent', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    let caught: unknown
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, (data, socket) => {
            sentPayloads.push(JSON.parse(data) as Record<string, unknown>)
            queueMicrotask(() => socket.emitError())
            return []
          })
      }
    })

    try {
      await runAgentLoop({
        model,
        messages: [{ role: 'user', content: 'do not duplicate after send error' }],
        stateful: {
          actorEventId: '00000000-0000-0000-0000-000000000015',
          conversationId: 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        }
      })
    } catch (error) {
      caught = error
    }

    expect(caught).toBeInstanceOf(Error)
    expect((caught as Error).message).toContain('AIGateway WebSocket transport error')
    expect(classifyLlmError(caught)).toMatchObject({ kind: 'timeout', retryable: true })
    expect(isLocallyRetryableLlmError(caught)).toBe(false)
    expect(sentPayloads).toHaveLength(1)
  })

  it('retries retryable AIGateway WebSocket open errors in the agent loop', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            sentPayloads.push(JSON.parse(data) as Record<string, unknown>)

            if (sentPayloads.length === 1) {
              return [
                {
                  type: 'error',
                  status: 429,
                  error: {
                    code: 'upstream_response_failed',
                    message: 'provider rate limit',
                    details_json: {
                      stage: 'socket_open',
                      upstream_status: 429,
                      retryable: true
                    }
                  }
                }
              ]
            }

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_after_429',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'retried after 429' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'retry rate limit' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000006',
        conversationId: '66666666-6666-6666-6666-666666666666'
      }
    })

    expect(final.content).toEqual([{ type: 'text', text: 'retried after 429' }])
    expect(sentPayloads).toHaveLength(2)
    expect(sentPayloads[0]).toMatchObject({
      store: true,
      conversation: 'conv_66666666-6666-6666-6666-666666666666'
    })
    expect(sentPayloads[1]).toMatchObject({
      store: true,
      conversation: 'conv_66666666-6666-6666-6666-666666666666'
    })
    expect(sentPayloads[1]!.previous_response_id).toBeUndefined()
  })

  it('retries retryable terminal response.failed results in the agent loop', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            sentPayloads.push(JSON.parse(data) as Record<string, unknown>)

            if (sentPayloads.length === 1) {
              return [
                {
                  type: 'response.failed',
                  response: {
                    id: 'resp_failed_429',
                    status: 'failed',
                    error: {
                      code: 'upstream_response_failed',
                      status: 429,
                      message: 'transient upstream response failed'
                    },
                    output: []
                  }
                }
              ]
            }

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_after_failed_429',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'retried after terminal 429' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'retry terminal rate limit' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000007',
        conversationId: '77777777-7777-7777-7777-777777777777'
      }
    })

    expect(final.content).toEqual([{ type: 'text', text: 'retried after terminal 429' }])
    expect(sentPayloads).toHaveLength(2)
    expect(sentPayloads[1]).toMatchObject({
      store: true,
      conversation: 'conv_77777777-7777-7777-7777-777777777777'
    })
  })

  it('preserves structured AIGateway WebSocket error details for overflow classification', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, () => [
            {
              type: 'error',
              status: 422,
              error: {
                code: 'context_overflow',
                message: 'AIGateway stateful input exceeds the configured context budget.',
                details_json: {
                  reason: 'no_compaction_candidate',
                  truncation: 'disabled'
                }
              }
            }
          ])
      }
    })

    try {
      await callModel(model, {
        messages: [{ role: 'user', content: 'hi' }],
        stateful: {
          actorEventId: '00000000-0000-0000-0000-000000000003',
          conversationId: '33333333-3333-3333-3333-333333333333'
        }
      })
      throw new Error('expected callModel to reject')
    } catch (error) {
      expect(error).toMatchObject({
        code: 'context_overflow',
        status: 422,
        details: {
          reason: 'no_compaction_candidate',
          truncation: 'disabled'
        }
      })
      expect(classifyLlmError(error).kind).toBe('overflow')
      expect(classifyLlmError(error).shouldCompress).toBe(true)
    }
  })

  it('sends truncation auto for overflow retry actor events', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            sentPayloads.push(JSON.parse(data) as Record<string, unknown>)
            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_truncated_retry',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'retried' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    const truncation = statefulTruncationFromActorEventPayload({
      data: {
        entry: {
          text: 'retry me',
          retry_reason: 'overflow_retry'
        }
      }
    })

    await callModel(model, {
      messages: [{ role: 'user', content: 'retry me' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000004',
        conversationId: '44444444-4444-4444-4444-444444444444',
        truncation
      }
    })

    expect(sentPayloads[0]).toMatchObject({
      truncation: 'auto'
    })
  })

  it('anchors stateful tool-loop continuations without replaying local transcript', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const sockets: FakeResponseSocket[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) => {
          const socket = new FakeResponseSocket(init, data => {
            const payload = JSON.parse(data) as Record<string, unknown>
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_tool_results_1')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_first',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_1',
                        call_id: 'call_1',
                        name: 'lookup',
                        arguments: '{"q":"weather"}'
                      }
                    ]
                  }
                }
              ]
            }

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_second',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'done' }]
                    }
                  ]
                }
              }
            ]
          })
          sockets.push(socket)
          queueMicrotask(() => socket.emitOpen())
          return socket as unknown as ResponseWebSocketLike
        }
      }
    })

    const final = await runAgentLoop({
      model,
      systemPrompt: 'system prompt',
      messages: [{ role: 'user', content: 'what is the weather?' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000002',
        conversationId: '22222222-2222-2222-2222-222222222222'
      },
      tools: [
        {
          name: 'lookup',
          description: 'Look up facts',
          schema: z.object({ q: z.string() }),
          execute: async () => ({
            content: [{ type: 'text', text: 'sunny' }],
            details: { ok: true }
          })
        }
      ]
    })

    expect(final.content).toEqual([{ type: 'text', text: 'done' }])
    expect(sockets).toHaveLength(1)
    expect(sockets[0]!.closeCount).toBe(1)
    expect(sentPayloads).toHaveLength(3)
    expect(sentPayloads[0]).toMatchObject({
      type: 'response.create',
      store: true,
      conversation: 'conv_22222222-2222-2222-2222-222222222222',
      input: [{ role: 'user', content: 'what is the weather?' }]
    })
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      store: true,
      previous_response_id: 'resp_first',
      input: [{ type: 'function_call_output', call_id: 'call_1', output: 'sunny' }]
    })
    expect(sentPayloads[1]!.conversation).toBeUndefined()
    expect(JSON.stringify(sentPayloads[1]!.input)).not.toContain('what is the weather?')
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      store: true,
      previous_response_id: 'resp_tool_results_1',
      input: []
    })
    expect(sentPayloads[2]!.conversation).toBeUndefined()
  })

  it('preserves function_call_output pairing and adds tool image follow-up for vision models', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            const payload = JSON.parse(data) as Record<string, unknown>
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_tool_image_results')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_tool_image',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_image',
                        call_id: 'call_image',
                        name: 'screenshot',
                        arguments: '{}'
                      }
                    ]
                  }
                }
              ]
            }

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_after_image',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'image handled' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'take a screenshot' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000010',
        conversationId: '10101010-1010-1010-1010-101010101010'
      },
      modelInputModalities: ['text', 'image'],
      tools: [
        {
          name: 'screenshot',
          description: 'Capture a screenshot',
          schema: z.object({}),
          execute: async () => ({
            content: [
              { type: 'text', text: 'screenshot ready' },
              { type: 'image', image: 'data:image/png;base64,AAA=' }
            ],
            details: { ok: true }
          })
        }
      ]
    })

    expect(final.content).toEqual([{ type: 'text', text: 'image handled' }])
    expect(sentPayloads).toHaveLength(3)
    const continuation = sentPayloads[1]!.input as Array<Record<string, unknown>>
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      previous_response_id: 'resp_tool_image'
    })
    expect(continuation[0]).toMatchObject({ type: 'function_call_output', call_id: 'call_image' })
    expect(continuation[0]!.output).toContain('screenshot ready')
    expect(continuation[0]!.output).toContain('[1 image result attached as follow-up user input]')
    expect(continuation[1]).toEqual({
      role: 'user',
      content: [
        { type: 'input_text', text: 'Tool returned image content.' },
        { type: 'input_image', image_url: 'data:image/png;base64,AAA=', detail: 'auto' }
      ]
    })
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_tool_image_results',
      input: []
    })
  })

  it('preserves function_call_output pairing and adds tool image summary for text-only models', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const fallbackBodies: Record<string, unknown>[] = []
    const fallbackModel = fallbackModelForTest('The tool image shows a dashboard.', fallbackBodies)
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            const payload = JSON.parse(data) as Record<string, unknown>
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_tool_summary_results')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_tool_summary',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_summary',
                        call_id: 'call_summary',
                        name: 'screenshot',
                        arguments: '{}'
                      }
                    ]
                  }
                }
              ]
            }

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_after_summary',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'summary handled' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'take a screenshot' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000011',
        conversationId: '11111111-1111-1111-1111-111111111112'
      },
      modelInputModalities: ['text'],
      visionFallbackModel: fallbackModel,
      tools: [
        {
          name: 'screenshot',
          description: 'Capture a screenshot',
          schema: z.object({}),
          execute: async () => ({
            content: [
              { type: 'text', text: 'screenshot ready' },
              { type: 'image', image: 'data:image/png;base64,AAA=' }
            ],
            details: { ok: true }
          })
        }
      ]
    })

    expect(final.content).toEqual([{ type: 'text', text: 'summary handled' }])
    expect(sentPayloads).toHaveLength(3)
    const continuation = sentPayloads[1]!.input as Array<Record<string, unknown>>
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      previous_response_id: 'resp_tool_summary'
    })
    expect(continuation[0]).toMatchObject({ type: 'function_call_output', call_id: 'call_summary' })
    expect(continuation[0]!.output).toContain('screenshot ready')
    expect(continuation[1]!.role).toBe('user')
    expect(continuation[1]!.content).toContain('<image_summary>')
    expect(continuation[1]!.content).toContain('The tool image shows a dashboard.')
    expect(continuation[1]!.content).not.toContain('data:image/png;base64,')
    expect(fallbackBodies).toHaveLength(1)
    expect(JSON.stringify(fallbackBodies[0]!.input)).toContain('"type":"input_image"')
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_tool_summary_results',
      input: []
    })
  })

  it('safely stringifies non-JSON tool result details for function_call_output fallback', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            const payload = JSON.parse(data) as Record<string, unknown>
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_tool_bigint_results')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_tool_bigint',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_bigint',
                        call_id: 'call_bigint',
                        name: 'lookup',
                        arguments: '{"q":"weather"}'
                      }
                    ]
                  }
                }
              ]
            }

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_after_bigint',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'done' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'what is the weather?' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000006',
        conversationId: '66666666-6666-6666-6666-666666666666'
      },
      tools: [
        {
          name: 'lookup',
          description: 'Look up facts',
          schema: z.object({ q: z.string() }),
          execute: async () => ({
            content: [],
            details: 1n
          })
        }
      ]
    })

    expect(final.content).toEqual([{ type: 'text', text: 'done' }])
    expect(sentPayloads).toHaveLength(3)
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      previous_response_id: 'resp_tool_bigint',
      input: [{ type: 'function_call_output', call_id: 'call_bigint', output: '1' }]
    })
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_tool_bigint_results',
      input: []
    })
  })

  it('aborts runaway tool loops before executing another tool round', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    let toolExecutions = 0
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            const payload = JSON.parse(data) as Record<string, unknown>
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_loop_results_1')]
            }

            const index = sentPayloads.filter(sent => sent.type === 'response.create').length

            return [
              {
                type: 'response.completed',
                response: {
                  id: `resp_loop_${index}`,
                  status: 'completed',
                  output: [
                    {
                      type: 'function_call',
                      id: `fc_loop_${index}`,
                      call_id: `call_loop_${index}`,
                      name: 'loop',
                      arguments: '{}'
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    await expect(
      runAgentLoop({
        model,
        messages: [{ role: 'user', content: 'loop forever' }],
        stateful: {
          actorEventId: '00000000-0000-0000-0000-000000000016',
          conversationId: '16161616-1616-1616-1616-161616161616'
        },
        maxToolRounds: 1,
        tools: [
          {
            name: 'loop',
            description: 'Loop forever',
            schema: z.object({}),
            execute: async () => {
              toolExecutions += 1
              return { content: [{ type: 'text', text: 'again' }], details: {} }
            }
          }
        ]
      })
    ).rejects.toThrow('agent loop exceeded max tool rounds (1)')

    expect(sentPayloads).toHaveLength(3)
    expect(sentPayloads[1]).toMatchObject({ type: 'response.tool_results.record' })
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_loop_results_1',
      input: []
    })
    expect(toolExecutions).toBe(1)
  })

  it('drains steering updates after tool results before the next stateful model call', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            const payload = JSON.parse(data) as Record<string, unknown>
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_tool_before_steer_results')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_tool_before_steer',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_steer_boundary',
                        call_id: 'call_steer_boundary',
                        name: 'lookup',
                        arguments: '{"q":"first"}'
                      }
                    ]
                  }
                }
              ]
            }

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_after_steer',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'steered' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    let steeringDrained = false

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'use a tool, then wait' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000008',
        conversationId: '88888888-8888-8888-8888-888888888888'
      },
      tools: [
        {
          name: 'lookup',
          description: 'Look up facts',
          schema: z.object({ q: z.string() }),
          execute: async () => ({
            content: [{ type: 'text', text: 'tool complete' }],
            details: { ok: true }
          })
        }
      ],
      getSteeringMessages: async () => {
        if (steeringDrained) return []
        steeringDrained = true
        return [{ role: 'user', content: 'Runtime note: steer now' }]
      }
    })

    expect(final.content).toEqual([{ type: 'text', text: 'steered' }])
    expect(sentPayloads).toHaveLength(3)
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      previous_response_id: 'resp_tool_before_steer',
      input: [{ type: 'function_call_output', call_id: 'call_steer_boundary', output: 'tool complete' }]
    })
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_tool_before_steer_results',
      input: [{ role: 'user', content: 'Runtime note: steer now' }]
    })
  })

  it('does not start another stateful run when steering arrives after a final response', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            sentPayloads.push(JSON.parse(data) as Record<string, unknown>)

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_final_before_steer',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'final answer' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'answer directly' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000009',
        conversationId: '99999999-9999-9999-9999-999999999999'
      },
      getSteeringMessages: async () => [{ role: 'user', content: 'Runtime note: steer too late' }]
    })

    expect(final.content).toEqual([{ type: 'text', text: 'final answer' }])
    expect(sentPayloads).toHaveLength(1)
    expect(sentPayloads[0]).toMatchObject({
      store: true,
      conversation: 'conv_99999999-9999-9999-9999-999999999999',
      input: [{ role: 'user', content: 'answer directly' }]
    })
  })

  it('feeds invalid tool arguments back as function_call_output instead of executing the tool', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    let toolExecutions = 0
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            const payload = JSON.parse(data) as Record<string, unknown>
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_bad_args_results')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_bad_args',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_bad_args',
                        call_id: 'call_bad_args',
                        name: 'lookup',
                        arguments: '{"q":123}'
                      }
                    ]
                  }
                }
              ]
            }

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_after_bad_args',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'I corrected the tool input.' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'look this up' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000005',
        conversationId: '55555555-5555-5555-5555-555555555555'
      },
      tools: [
        {
          name: 'lookup',
          description: 'Look up facts',
          schema: z.object({ q: z.string() }),
          execute: async () => {
            toolExecutions += 1
            return {
              content: [{ type: 'text', text: 'should not run' }],
              details: { ok: false }
            }
          }
        }
      ]
    })

    expect(final.content).toEqual([{ type: 'text', text: 'I corrected the tool input.' }])
    expect(toolExecutions).toBe(0)
    expect(sentPayloads).toHaveLength(3)
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      previous_response_id: 'resp_bad_args',
      input: [
        {
          type: 'function_call_output',
          call_id: 'call_bad_args'
        }
      ]
    })
    const output = (sentPayloads[1]!.input as Array<Record<string, unknown>>)[0]!.output
    expect(output).toContain('Invalid arguments for tool lookup')
    expect(output).toContain('expected string')
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_bad_args_results',
      input: []
    })
  })

  it('executes pure read-only tool batches in parallel while preserving result order', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const events: string[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            const payload = JSON.parse(data) as Record<string, unknown>
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_parallel_read_results')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_parallel_read',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_read_a',
                        call_id: 'call_read_a',
                        name: 'read_a',
                        arguments: '{}'
                      },
                      {
                        type: 'function_call',
                        id: 'fc_read_b',
                        call_id: 'call_read_b',
                        name: 'read_b',
                        arguments: '{}'
                      }
                    ]
                  }
                }
              ]
            }

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_after_parallel_read',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'read results handled' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'read both' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000017',
        conversationId: '17171717-1717-1717-1717-171717171717'
      },
      tools: [parallelReadTool('read_a', events, 20, 'A'), parallelReadTool('read_b', events, 1, 'B')]
    })

    expect(final.content).toEqual([{ type: 'text', text: 'read results handled' }])
    expect(events.indexOf('read_b:start')).toBeLessThan(events.indexOf('read_a:end'))
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      input: [
        { type: 'function_call_output', call_id: 'call_read_a', output: 'A' },
        { type: 'function_call_output', call_id: 'call_read_b', output: 'B' }
      ]
    })
  })

  it('keeps mixed side-effecting tool batches sequential', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const events: string[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            const payload = JSON.parse(data) as Record<string, unknown>
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_mixed_tools_results')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_mixed_tools',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_read_first',
                        call_id: 'call_read_first',
                        name: 'read_first',
                        arguments: '{}'
                      },
                      {
                        type: 'function_call',
                        id: 'fc_write_second',
                        call_id: 'call_write_second',
                        name: 'write_second',
                        arguments: '{}'
                      }
                    ]
                  }
                }
              ]
            }

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_after_mixed_tools',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'mixed handled' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'read then write' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000018',
        conversationId: '18181818-1818-1818-1818-181818181818'
      },
      tools: [
        parallelReadTool('read_first', events, 20, 'read'),
        {
          name: 'write_second',
          description: 'Write something',
          schema: z.object({}),
          executionMode: 'sequential',
          isReadOnly: false,
          isDestructive: true,
          execute: async () => {
            events.push('write_second:start')
            events.push('write_second:end')
            return { content: [{ type: 'text', text: 'write' }], details: {} }
          }
        }
      ]
    })

    expect(final.content).toEqual([{ type: 'text', text: 'mixed handled' }])
    expect(events.indexOf('write_second:start')).toBeGreaterThan(events.indexOf('read_first:end'))
  })

  it('nudges once when the model returns an empty final response after tool results', async () => {
    const sentPayloads: Record<string, unknown>[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, data => {
            const payload = JSON.parse(data) as Record<string, unknown>
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_empty_after_tools_results')]
            }

            const createCount = sentPayloads.filter(sent => sent.type === 'response.create').length
            if (createCount === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_tool_before_empty',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_lookup_empty',
                        call_id: 'call_lookup_empty',
                        name: 'lookup',
                        arguments: '{}'
                      }
                    ]
                  }
                }
              ]
            }

            if (createCount === 2) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_empty_after_tools',
                    status: 'completed',
                    output: [{ type: 'message', role: 'assistant', content: [] }]
                  }
                }
              ]
            }

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_after_empty_nudge',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'handled after nudge' }]
                    }
                  ]
                }
              }
            ]
          })
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'use a tool then answer' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000019',
        conversationId: '19191919-1919-1919-1919-191919191919'
      },
      tools: [
        {
          name: 'lookup',
          description: 'Look up facts',
          schema: z.object({}),
          execute: async () => ({ content: [{ type: 'text', text: 'tool facts' }], details: {} })
        }
      ]
    })

    expect(final.content).toEqual([{ type: 'text', text: 'handled after nudge' }])
    expect(sentPayloads).toHaveLength(4)
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_empty_after_tools_results',
      input: []
    })
    expect(sentPayloads[3]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_empty_after_tools'
    })
    expect(JSON.stringify(sentPayloads[3]!.input)).toContain('returned an empty response')
  })

  it('rejects duplicate tool names before exposing tools to the model', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary'
    })

    await expect(
      runAgentLoop({
        model,
        messages: [{ role: 'user', content: 'hello' }],
        stateful: {
          actorEventId: '00000000-0000-0000-0000-000000000006',
          conversationId: '66666666-6666-6666-6666-666666666666'
        },
        tools: [
          {
            name: 'duplicate',
            description: 'first',
            schema: z.object({}),
            execute: async () => ({ content: [{ type: 'text', text: 'first' }], details: {} })
          },
          {
            name: 'duplicate',
            description: 'second',
            schema: z.object({}),
            execute: async () => ({ content: [{ type: 'text', text: 'second' }], details: {} })
          }
        ]
      })
    ).rejects.toThrow('duplicate tool name: duplicate')
  })
})

function parallelReadTool(name: string, events: string[], delayMs: number, text: string) {
  return {
    name,
    description: `Read ${name}`,
    schema: z.object({}),
    executionMode: 'parallel' as const,
    isReadOnly: true,
    isDestructive: false,
    execute: async () => {
      events.push(`${name}:start`)
      await sleep(delayMs)
      events.push(`${name}:end`)
      return { content: [{ type: 'text' as const, text }], details: {} }
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

function turnStartForTest() {
  return {
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
      type: 'check_back_later.wakeup',
      source_event_id: 'schedule-1',
      payload_json: {}
    },
    model_ref: { profile: 'primary', provider_id: 'openrouter', model: 'z-ai/glm-5.2' }
  }
}

async function withImageWorkspace(run: (workspaceRoot: string, imagePath: string) => Promise<void>): Promise<void> {
  const workspaceRoot = mkdtempSync(join(tmpdir(), 'ankole-agent-computer-vision-'))
  const relativePath = join('user-files', 'inbox', 'lark', 'photo.png')
  const filePath = join(workspaceRoot, relativePath)
  mkdirSync(join(workspaceRoot, 'user-files', 'inbox', 'lark'), { recursive: true })
  writeFileSync(
    filePath,
    Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
      'base64'
    )
  )

  try {
    await run(workspaceRoot, `/workspace/${relativePath.replaceAll('\\', '/')}`)
  } finally {
    rmSync(workspaceRoot, { recursive: true, force: true })
  }
}

function imageActorEventPayload(imagePath: string) {
  return {
    data: {
      entry: {
        text: 'Please inspect this.',
        attachments: [
          {
            name: 'photo.png',
            resource_type: 'image',
            agent_computer_path: imagePath
          }
        ]
      }
    }
  }
}

function modelRefForTest(inputModalities: string[]) {
  return {
    profile: 'primary',
    provider_id: 'openai-main',
    model: 'test-model',
    provider_kind: 'openai',
    input_modalities: inputModalities
  }
}

function fallbackModelForTest(summary: string, bodies: Record<string, unknown>[]) {
  return createModel({
    apiKey: 'unused',
    baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
    selector: 'vision_fallback',
    fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      const request = input instanceof Request ? input : new Request(input, init)
      bodies.push(JSON.parse(await request.text()) as Record<string, unknown>)

      return new Response(
        JSON.stringify({
          id: 'resp_fallback_summary',
          object: 'response',
          status: 'completed',
          output: [
            {
              type: 'message',
              role: 'assistant',
              content: [{ type: 'output_text', text: summary }]
            }
          ]
        }),
        { status: 200, headers: { 'content-type': 'application/json' } }
      )
    }) as unknown as typeof fetch
  })
}

function toolResultsRecordedFrame(id: string): Record<string, unknown> {
  return {
    type: 'response.tool_results.recorded',
    response_id: id,
    response: {
      id,
      status: 'completed',
      output: []
    }
  }
}

function fakeResponseSocket(
  init: { headers: Record<string, string> },
  onSend: (data: string, socket: FakeResponseSocket) => Record<string, unknown>[]
): ResponseWebSocketLike {
  const socket = new FakeResponseSocket(init, onSend)
  queueMicrotask(() => socket.emitOpen())
  return socket as unknown as ResponseWebSocketLike
}

class FakeResponseSocket {
  readyState = 0
  closeCount = 0
  private listeners = new Map<string, Array<{ listener: (event: unknown) => void; once: boolean }>>()

  constructor(
    readonly init: { headers: Record<string, string> },
    private readonly onSend: (data: string, socket: FakeResponseSocket) => Record<string, unknown>[]
  ) {}

  send(data: string): void {
    if (!this.init.headers.authorization?.startsWith('Bearer ')) {
      throw new Error('missing authorization header')
    }

    for (const frame of this.onSend(data, this)) {
      this.emitMessage(frame)
    }
  }

  close(): void {
    this.closeCount += 1
    this.readyState = 3
  }

  addEventListener(type: string, listener: (event: unknown) => void, options?: { once?: boolean }): void {
    const listeners = this.listeners.get(type) ?? []
    listeners.push({ listener, once: options?.once ?? false })
    this.listeners.set(type, listeners)
  }

  removeEventListener(type: string, listener: (event: unknown) => void): void {
    const listeners = this.listeners.get(type) ?? []
    this.listeners.set(
      type,
      listeners.filter(entry => entry.listener !== listener)
    )
  }

  emitOpen(): void {
    this.readyState = 1
    this.emit('open', {})
  }

  emitClose(reason = ''): void {
    this.readyState = 3
    this.emit('close', { reason })
  }

  emitError(): void {
    this.emit('error', {})
  }

  private emitMessage(frame: Record<string, unknown>): void {
    this.emit('message', { data: JSON.stringify(frame) })
  }

  private emit(type: string, event: unknown): void {
    const listeners = this.listeners.get(type) ?? []
    this.listeners.set(
      type,
      listeners.filter(entry => {
        entry.listener(event)
        return !entry.once
      })
    )
  }
}
