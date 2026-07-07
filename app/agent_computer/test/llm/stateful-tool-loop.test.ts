import { describe, expect, it } from 'bun:test'
import type { JsonObject } from '@pleisto/active-support'
import { z } from 'zod'
import { runAgentLoop } from '../../src/core/agent-loop'
import { createModel } from '../../src/core/llm'
import {
  FakeResponseSocket,
  fakeResponseSocket,
  fallbackModelForTest,
  testResponseSocket,
  toolResultsRecordedFrame
} from '../support/llm'

describe('@ankole/agent-computer llm helpers: stateful tool-loop continuations', () => {
  it('anchors stateful tool-loop continuations without replaying local transcript', async () => {
    const sentPayloads: JsonObject[] = []
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
            const payload = JSON.parse(data) as JsonObject
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
          return testResponseSocket(socket)
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
      input: [{ type: 'function_call_output', call_id: 'call_1' }]
    })
    expect((sentPayloads[1]!.input as Array<JsonObject>)[0]!.output).toContain('sunny')
    expectWrappedToolOutput((sentPayloads[1]!.input as Array<JsonObject>)[0]!.output)
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
            const payload = JSON.parse(data) as JsonObject
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
    const continuation = sentPayloads[1]!.input as Array<JsonObject>
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
    const sentPayloads: JsonObject[] = []
    const fallbackBodies: JsonObject[] = []
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
            const payload = JSON.parse(data) as JsonObject
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
    const continuation = sentPayloads[1]!.input as Array<JsonObject>
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      previous_response_id: 'resp_tool_summary'
    })
    expect(continuation[0]).toMatchObject({ type: 'function_call_output', call_id: 'call_summary' })
    expect(continuation[0]!.output).toContain('screenshot ready')
    expect(continuation[1]!.role).toBe('user')
    expect(continuation[1]!.content).toContain("The tool result attached an image. Here's what it contains")
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
            const payload = JSON.parse(data) as JsonObject
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
      input: [{ type: 'function_call_output', call_id: 'call_bigint' }]
    })
    expect((sentPayloads[1]!.input as Array<JsonObject>)[0]!.output).toContain('1')
    expectWrappedToolOutput((sentPayloads[1]!.input as Array<JsonObject>)[0]!.output)
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_tool_bigint_results',
      input: []
    })
  })

  it('aborts runaway tool loops before executing another tool round', async () => {
    const sentPayloads: JsonObject[] = []
    let toolExecutions = 0
    let recordCount = 0
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
            const payload = JSON.parse(data) as JsonObject
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              recordCount += 1
              return [toolResultsRecordedFrame(`resp_loop_results_${recordCount}`)]
            }

            const index = sentPayloads.filter(sent => sent.type === 'response.create').length
            if (index === 3) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_loop_synthesis',
                    status: 'completed',
                    output: [
                      {
                        type: 'message',
                        role: 'assistant',
                        content: [{ type: 'output_text', text: 'summarized partial work' }]
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

    const final = await runAgentLoop({
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

    expect(final.content).toEqual([{ type: 'text', text: 'summarized partial work' }])
    expect(final.stopReason).toBe('length')
    expect(sentPayloads).toHaveLength(5)
    expect(sentPayloads[1]).toMatchObject({ type: 'response.tool_results.record' })
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_loop_results_1',
      input: []
    })
    expect(sentPayloads[3]).toMatchObject({ type: 'response.tool_results.record' })
    expect(JSON.stringify(sentPayloads[3]!.input)).toContain('Tool call was not executed')
    expect(sentPayloads[4]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_loop_results_2',
      input: []
    })
    expect(sentPayloads[4]!.tools).toBeUndefined()
    expect(toolExecutions).toBe(1)
  })

  it('counts post-tool empty-response nudges against the model iteration budget', async () => {
    const sentPayloads: JsonObject[] = []
    let toolExecutions = 0
    let recordCount = 0
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
            const payload = JSON.parse(data) as JsonObject
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              recordCount += 1
              return [toolResultsRecordedFrame(`resp_iteration_results_${recordCount}`)]
            }

            const index = sentPayloads.filter(sent => sent.type === 'response.create').length
            if (index === 1 || index === 3) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: `resp_iteration_tool_${index}`,
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: `fc_iteration_${index}`,
                        call_id: `call_iteration_${index}`,
                        name: 'loop',
                        arguments: '{}'
                      }
                    ]
                  }
                }
              ]
            }

            if (index === 2) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_iteration_empty',
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
                  id: 'resp_iteration_synthesis',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'summarized after iteration limit' }]
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
      messages: [{ role: 'user', content: 'loop with empty responses' }],
      stateful: {
        actorEventId: '00000000-0000-0000-0000-000000000019',
        conversationId: '19191919-1919-1919-1919-191919191919'
      },
      maxModelIterations: 3,
      tools: [
        {
          name: 'loop',
          description: 'Loop forever',
          schema: z.object({}),
          execute: async () => {
            toolExecutions += 1
            return { content: [{ type: 'text', text: `again ${toolExecutions}` }], details: {} }
          }
        }
      ]
    })

    const responseCreates = sentPayloads.filter(payload => payload.type === 'response.create')
    expect(final.content).toEqual([{ type: 'text', text: 'summarized after iteration limit' }])
    expect(final.stopReason).toBe('length')
    expect(toolExecutions).toBe(2)
    expect(responseCreates).toHaveLength(4)
    expect(responseCreates[2]!.input).toEqual([
      {
        role: 'user',
        content:
          'You just executed tool calls but returned an empty response. Please process the tool results above and continue with the task.'
      }
    ])
    expect(responseCreates[3]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_iteration_results_2'
    })
    expect(responseCreates[3]!.tools).toBeUndefined()
    expect(JSON.stringify(responseCreates[3]!.input)).toContain('maximum number of tool-calling iterations')
  })

  it('drains steering updates after tool results before the next stateful model call', async () => {
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
            const payload = JSON.parse(data) as JsonObject
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
      input: [{ type: 'function_call_output', call_id: 'call_steer_boundary' }]
    })
    expect((sentPayloads[1]!.input as Array<JsonObject>)[0]!.output).toContain('tool complete')
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_tool_before_steer_results',
      input: [{ role: 'user', content: 'Runtime note: steer now' }]
    })
  })

  it('does not start another stateful run when steering arrives after a final response', async () => {
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
})

function expectWrappedToolOutput(output: unknown): void {
  expect(String(output)).toMatch(
    /^<ankole_untrusted_tool_output nonce="[0-9a-f]{16}">\n[\s\S]*\n<\/ankole_untrusted_tool_output nonce="[0-9a-f]{16}">$/
  )
}
