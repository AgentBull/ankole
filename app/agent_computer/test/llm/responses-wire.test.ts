import { describe, expect, it } from 'bun:test'
import type { JsonObject } from '@pleisto/active-support'
import { runAgentLoop } from '../../src/core/agent-loop'
import { callModel, createModel } from '../../src/core/llm'
import { classifyLlmError, isLocallyRetryableLlmError } from '../../src/core/llm-error-classifier'

import { fakeResponseSocket } from '../support/llm'

describe('@ankole/agent-computer llm helpers: Responses HTTP and WebSocket wire shape', () => {
  it('passes image input through as Responses input_image content', async () => {
    const bodies: JsonObject[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        const request = input instanceof Request ? input : new Request(input, init)
        bodies.push(JSON.parse(await request.text()) as JsonObject)

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
    const bodies: JsonObject[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        const request = input instanceof Request ? input : new Request(input, init)
        bodies.push(JSON.parse(await request.text()) as JsonObject)

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

    const input = bodies[0]!.input as Array<{ content: Array<JsonObject> }>
    const imageUrl = input[0]!.content[1]!.image_url

    expect(typeof imageUrl).toBe('string')
    expect(imageUrl).toMatch(/^data:image\/png;base64,[A-Za-z0-9+/]+=*$/)
    expect([
      ...Buffer.from((imageUrl as string).slice('data:image/png;base64,'.length), 'base64').subarray(0, 8)
    ]).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  })

  it('passes Responses structured output text format through HTTP calls', async () => {
    const bodies: JsonObject[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        const request = input instanceof Request ? input : new Request(input, init)
        bodies.push(JSON.parse(await request.text()) as JsonObject)

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

  it('omits max_output_tokens unless the agent runtime policy provides one', async () => {
    const bodies: JsonObject[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        const request = input instanceof Request ? input : new Request(input, init)
        bodies.push(JSON.parse(await request.text()) as JsonObject)

        return new Response(
          JSON.stringify({
            id: `resp_${bodies.length}`,
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
    })

    await callModel(model, {
      messages: [{ role: 'user', content: 'uncapped' }]
    })
    await callModel(model, {
      messages: [{ role: 'user', content: 'capped' }],
      maxOutputTokens: 12_000
    })

    expect(Object.hasOwn(bodies[0]!, 'max_output_tokens')).toBe(false)
    expect(bodies[1]!.max_output_tokens).toBe(12_000)
  })

  it('reads normalized usage details from AIGateway Responses results', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      fetch: (async () =>
        new Response(
          JSON.stringify({
            id: 'resp_usage',
            object: 'response',
            status: 'completed',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [{ type: 'output_text', text: 'seen' }]
              }
            ],
            usage: {
              input_tokens: 17,
              output_tokens: 5,
              total_tokens: 22,
              input_tokens_details: { cached_tokens: 3 },
              output_tokens_details: { reasoning_tokens: 2 }
            }
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        )) as unknown as typeof fetch
    })

    const result = await callModel(model, {
      messages: [{ role: 'user', content: 'measure' }]
    })

    expect(result.message.usage).toEqual({
      inputTokens: 17,
      outputTokens: 5,
      reasoningTokens: 2,
      cachedInputTokens: 3
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

  it('classifies incomplete terminal reason fallbacks without retrying blindly', () => {
    expect(classifyLlmError(new Error('AIGateway response incomplete reason=content_filter'))).toMatchObject({
      kind: 'content_filter',
      retryable: false,
      shouldCompress: false,
      shouldFallbackProvider: false
    })
    expect(classifyLlmError(new Error('max_output_tokens'))).toMatchObject({
      kind: 'overflow',
      retryable: false,
      shouldCompress: true,
      shouldFallbackProvider: false
    })
  })

  it('sends stateful response.create over AIGateway WebSocket', async () => {
    const sentPayloads: JsonObject[] = []
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
            sentPayloads.push(JSON.parse(data) as JsonObject)
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
    const sentPayloads: JsonObject[] = []
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
            sentPayloads.push(JSON.parse(data) as JsonObject)
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
    const sentPayloads: JsonObject[] = []
    const server = Bun.serve({
      port: 0,
      fetch(request, server) {
        if (server.upgrade(request)) return
        return new Response('not found', { status: 404 })
      },
      websocket: {
        message(ws, message) {
          const text = typeof message === 'string' ? message : new TextDecoder().decode(message as BufferSource)
          sentPayloads.push(JSON.parse(text) as JsonObject)
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

  it('maps max_output_tokens response.incomplete terminals to length while preserving output', async () => {
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
    expect(result.message.stopReason).toBe('length')
    expect(result.message.errorMessage).toBeUndefined()
  })

  it('maps content_filter response.incomplete terminals to an error assistant message', async () => {
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
                id: 'resp_content_filter',
                status: 'incomplete',
                incomplete_details: { reason: 'content_filter' },
                output: [
                  {
                    type: 'message',
                    role: 'assistant',
                    content: [{ type: 'output_text', text: 'filtered partial answer' }]
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
        actorEventId: '00000000-0000-0000-0000-000000000016',
        conversationId: '16161616-1616-1616-1616-161616161616'
      }
    })

    expect(result.responseId).toBe('resp_content_filter')
    expect(result.message.content).toEqual([{ type: 'text', text: 'filtered partial answer' }])
    expect(result.message.stopReason).toBe('error')
    expect(result.message.errorMessage).toBe('AIGateway response incomplete reason=content_filter')
  })

  it('lets the agent loop return max_output_tokens incomplete output as a bounded partial answer', async () => {
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
                id: 'resp_loop_incomplete',
                status: 'incomplete',
                incomplete_details: { reason: 'max_output_tokens' },
                output: [
                  {
                    type: 'message',
                    role: 'assistant',
                    content: [{ type: 'output_text', text: 'partial loop answer' }]
                  }
                ]
              }
            }
          ])
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'write a long answer' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000017',
        conversationId: '17171717-1717-1717-1717-171717171717'
      }
    })

    expect(final.content).toEqual([{ type: 'text', text: 'partial loop answer' }])
    expect(final.stopReason).toBe('length')
    expect(final.errorMessage).toBeUndefined()
  })
})
