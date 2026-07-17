import { describe, expect, it } from 'bun:test'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { z } from 'zod'
import { runAgentLoop } from '../../src/core/agent-loop'
import { callModel, createModel } from '../../src/core/llm'
import { classifyLLMError, isLocallyRetryableLLMError } from '../../src/core/llm-error-classifier'
import { statefulTruncationFromActorEventPayload } from '../../src/core/turns/actor_event_text'
import { FakeResponseSocket, fakeResponseSocket, testResponseSocket } from '../support/llm'

describe('@ankole/agent-computer llm helpers: AIGateway WebSocket retry and overflow', () => {
  it('retries AIGateway WebSocket close before open without sending a duplicate request', async () => {
    const sentPayloads: JSONObject[] = []
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
            return testResponseSocket(socket)
          }

          return fakeResponseSocket(init, data => {
            sentPayloads.push(JSON.parse(data) as JSONObject)
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
        actorEventID: '00000000-0000-0000-0000-000000000010',
        conversationID: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      },
      maxModelIterations: 1
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'retried after open close' }])
    expect(final.outcome).toBe('loop_finished')
    expect(attempts).toBe(2)
    expect(sentPayloads).toHaveLength(1)
  })

  it('retries AIGateway WebSocket close after response.create was sent from the stable anchor', async () => {
    const sentPayloads: JSONObject[] = []
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
            sentPayloads.push(JSON.parse(data) as JSONObject)
            queueMicrotask(() => socket.emitClose('gateway restart after response.create'))
            return []
          })
      }
    })

    try {
      await runAgentLoop({
        model,
        maxModelIterations: 90,
        messages: [{ role: 'user', content: 'do not duplicate after send' }],
        stateful: {
          actorEventID: '00000000-0000-0000-0000-000000000011',
          conversationID: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        }
      })
    } catch (error) {
      caught = error
    }

    expect(caught).toBeInstanceOf(Error)
    expect((caught as Error).message).toContain('AIGateway WebSocket closed before response.completed')
    expect(classifyLLMError(caught)).toMatchObject({ kind: 'timeout', retryable: true })
    expect(isLocallyRetryableLLMError(caught)).toBe(true)
    expect(sentPayloads).toHaveLength(3)
    expect(sentPayloads.every(payload => payload.conversation === 'conv_bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')).toBe(
      true
    )
  })

  it('retries AIGateway WebSocket errors after response.create was sent', async () => {
    const sentPayloads: JSONObject[] = []
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
            sentPayloads.push(JSON.parse(data) as JSONObject)
            queueMicrotask(() => socket.emitError())
            return []
          })
      }
    })

    try {
      await runAgentLoop({
        model,
        maxModelIterations: 90,
        messages: [{ role: 'user', content: 'do not duplicate after send error' }],
        stateful: {
          actorEventID: '00000000-0000-0000-0000-000000000015',
          conversationID: 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        }
      })
    } catch (error) {
      caught = error
    }

    expect(caught).toBeInstanceOf(Error)
    expect((caught as Error).message).toContain('AIGateway WebSocket transport error')
    expect(classifyLLMError(caught)).toMatchObject({ kind: 'timeout', retryable: true })
    expect(isLocallyRetryableLLMError(caught)).toBe(true)
    expect(sentPayloads).toHaveLength(3)
  })

  it('retries retryable AIGateway WebSocket open errors in the agent loop', async () => {
    const sentPayloads: JSONObject[] = []
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
            sentPayloads.push(JSON.parse(data) as JSONObject)

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
      maxModelIterations: 1,
      messages: [{ role: 'user', content: 'retry rate limit' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000006',
        conversationID: '66666666-6666-6666-6666-666666666666'
      }
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'retried after 429' }])
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
    const sentPayloads: JSONObject[] = []
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
            sentPayloads.push(JSON.parse(data) as JSONObject)

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
      maxModelIterations: 90,
      messages: [{ role: 'user', content: 'retry terminal rate limit' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000007',
        conversationID: '77777777-7777-7777-7777-777777777777'
      }
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'retried after terminal 429' }])
    expect(sentPayloads).toHaveLength(2)
    expect(sentPayloads[1]).toMatchObject({
      store: true,
      conversation: 'conv_77777777-7777-7777-7777-777777777777'
    })
  })

  it('retries an upstream-closed partial call from the stable anchor without executing it', async () => {
    const sentPayloads: JSONObject[] = []
    let executions = 0
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
            sentPayloads.push(JSON.parse(data) as JSONObject)

            if (sentPayloads.length === 1) {
              return [
                {
                  type: 'response.incomplete',
                  response: {
                    id: 'resp_partial_call',
                    status: 'incomplete',
                    incomplete_details: { reason: 'upstream_stream_closed' },
                    output: [
                      {
                        type: 'function_call',
                        status: 'incomplete',
                        id: 'fc_partial',
                        call_id: 'call_partial',
                        name: 'write_report',
                        arguments: '{"path":"/tmp/repor'
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
                  id: 'resp_after_partial_retry',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'recovered without side effects' }]
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
      maxModelIterations: 1,
      messages: [{ role: 'user', content: 'write a report' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000018',
        previousResponseID: 'resp_stable_anchor'
      },
      tools: [
        {
          name: 'write_report',
          description: 'Writes the report.',
          schema: z.object({ path: z.string() }),
          isReadOnly: false,
          isDestructive: true,
          describeActivity: () => '测试写入报告',
          execute: async () => {
            executions += 1
            return { content: [{ type: 'text' as const, text: 'written' }], details: {} }
          }
        }
      ]
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'recovered without side effects' }])
    expect(executions).toBe(0)
    expect(sentPayloads).toHaveLength(2)
    expect(sentPayloads.map(payload => payload.previous_response_id)).toEqual([
      'resp_stable_anchor',
      'resp_stable_anchor'
    ])
    expect(classifyLLMError(new Error('AIGateway response incomplete reason=upstream_stream_closed'))).toMatchObject({
      kind: 'timeout',
      retryable: true
    })
  })

  it('throws a non-retryable incomplete terminal instead of returning it as a normal answer', async () => {
    let attempts = 0
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'primary',
      responseWebSocket: {
        kind: 'aigateway-websocket',
        url: 'ws://aigateway.invalid/api/v1/ai-gateway/responses',
        authorization: () => 'Bearer agent-key',
        createWebSocket: (_url, init) =>
          fakeResponseSocket(init, () => {
            attempts += 1
            return [
              {
                type: 'response.incomplete',
                response: {
                  id: 'resp_content_filter_terminal',
                  status: 'incomplete',
                  incomplete_details: { reason: 'content_filter' },
                  output: []
                }
              }
            ]
          })
      }
    })

    await expect(
      runAgentLoop({
        model,
        maxModelIterations: 1,
        messages: [{ role: 'user', content: 'unsafe request' }],
        stateful: {
          actorEventID: '00000000-0000-0000-0000-000000000019',
          conversationID: '19191919-1919-1919-1919-191919191919'
        }
      })
    ).rejects.toThrow('AIGateway response incomplete reason=content_filter')
    expect(attempts).toBe(1)
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
          actorEventID: '00000000-0000-0000-0000-000000000003',
          conversationID: '33333333-3333-3333-3333-333333333333'
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
      expect(classifyLLMError(error).kind).toBe('overflow')
      expect(classifyLLMError(error).shouldCompress).toBe(true)
    }
  })

  it('sends truncation auto for overflow retry actor events', async () => {
    const sentPayloads: JSONObject[] = []
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
            sentPayloads.push(JSON.parse(data) as JSONObject)
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
        actorEventID: '00000000-0000-0000-0000-000000000004',
        conversationID: '44444444-4444-4444-4444-444444444444',
        truncation
      }
    })

    expect(sentPayloads[0]).toMatchObject({
      truncation: 'auto'
    })
  })
})
