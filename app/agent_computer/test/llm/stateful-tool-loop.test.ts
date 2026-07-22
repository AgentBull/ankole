import { describe, expect, it } from 'bun:test'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { z } from 'zod'
import { runAgentLoop } from '../../src/core/agent-loop'
import { createModel } from '../../src/core/llm'
import { createClarifyTool } from '../../src/tools/clarify/clarify-tool'
import {
  FakeResponseSocket,
  fakeResponseSocket,
  fallbackModelForTest,
  testResponseSocket,
  toolResultsRecordedFrame
} from '../support/llm'

const toolImageDataURL =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII='

describe('@ankole/agent-computer llm helpers: stateful tool-loop continuations', () => {
  it('records a turn-ending clarify result without making another empty model call', async () => {
    const sentPayloads: JSONObject[] = []
    let sideEffectCalls = 0
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
            const payload = JSON.parse(data) as JSONObject
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_clarify_result')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length > 1) {
              throw new Error('clarify must not trigger another model call')
            }

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_clarify_call',
                  status: 'completed',
                  output: [
                    {
                      type: 'function_call',
                      id: 'fc_clarify',
                      call_id: 'call_clarify',
                      name: 'clarify',
                      arguments: '{"question":"Which market?","choices":["A shares","US stocks"]}'
                    },
                    {
                      type: 'function_call',
                      id: 'fc_after_clarify',
                      call_id: 'call_after_clarify',
                      name: 'side_effect',
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
      maxModelIterations: 90,
      messages: [{ role: 'user', content: 'analyze the market' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000012',
        conversationID: '12121212-1212-1212-1212-121212121212'
      },
      tools: [
        createClarifyTool(),
        {
          name: 'side_effect',
          description: 'A side effect that must not run after a turn-ending result.',
          schema: z.object({}),
          executionMode: 'sequential',
          isReadOnly: false,
          isDestructive: true,
          describeActivity: () => '测试副作用',
          execute: async () => {
            sideEffectCalls += 1
            return { content: [{ type: 'text' as const, text: 'changed' }], details: { ok: true } }
          }
        }
      ]
    })

    expect(final.responseID).toBe('resp_clarify_result')
    expect(sideEffectCalls).toBe(0)
    expect(sentPayloads.map(payload => payload.type)).toEqual(['response.create', 'response.tool_results.record'])
    expect(sentPayloads[1]).toMatchObject({
      previous_response_id: 'resp_clarify_call',
      input: [{ type: 'function_call_output', call_id: 'call_clarify' }]
    })
    expect(sentPayloads[1]!.input).toHaveLength(1)
  })

  it('anchors stateful tool-loop continuations without replaying local transcript', async () => {
    const sentPayloads: JSONObject[] = []
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
            const payload = JSON.parse(data) as JSONObject
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
      maxModelIterations: 90,
      systemPrompt: 'system prompt',
      messages: [{ role: 'user', content: 'what is the weather?' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000002',
        conversationID: '22222222-2222-2222-2222-222222222222'
      },
      tools: [
        {
          name: 'lookup',
          description: 'Look up facts',
          schema: z.object({ q: z.string() }),
          describeActivity: () => '测试查询',
          execute: async () => ({
            content: [{ type: 'text', text: 'sunny' }],
            details: { ok: true }
          })
        }
      ]
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'done' }])
    expect(final.outcome).toBe('loop_finished')
    expect(final.responseID).toBe('resp_second')
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
    expect((sentPayloads[1]!.input as Array<JSONObject>)[0]!.output).toContain('sunny')
    expectWrappedToolOutput((sentPayloads[1]!.input as Array<JSONObject>)[0]!.output)
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

  it('sends completed actor event IDs only on the tool-result journal frame', async () => {
    const completedActorEventID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
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
            const payload = JSON.parse(data) as JSONObject
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_handoff_results')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_handoff_call',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_handoff',
                        call_id: 'call_handoff',
                        name: 'handoff',
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
                  id: 'resp_handoff_done',
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

    await runAgentLoop({
      model,
      maxModelIterations: 90,
      messages: [{ role: 'user', content: 'wait for the background job' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000003',
        conversationID: '33333333-3333-3333-3333-333333333333'
      },
      tools: [
        {
          name: 'handoff',
          description: 'Return a background job result.',
          schema: z.object({}),
          describeActivity: () => '测试事件交接',
          execute: async () => ({
            content: [{ type: 'text', text: 'background job replied' }],
            details: { ok: true },
            completeActorEventIDs: [completedActorEventID, completedActorEventID]
          })
        }
      ]
    })

    expect(sentPayloads).toHaveLength(3)
    expect(sentPayloads[0]!.complete_actor_event_ids).toBeUndefined()
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      complete_actor_event_ids: [completedActorEventID]
    })
    expect(JSON.stringify(sentPayloads[1]!.input)).not.toContain(completedActorEventID)
    expect(sentPayloads[2]!.complete_actor_event_ids).toBeUndefined()
  })

  it('preserves function_call_output pairing and adds tool image follow-up for vision models', async () => {
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
            const payload = JSON.parse(data) as JSONObject
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
      maxModelIterations: 90,
      messages: [{ role: 'user', content: 'take a screenshot' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000010',
        conversationID: '10101010-1010-1010-1010-101010101010'
      },
      modelInputModalities: ['text', 'image'],
      tools: [
        {
          name: 'screenshot',
          description: 'Capture a screenshot',
          schema: z.object({}),
          describeActivity: () => '测试截图',
          execute: async () => ({
            content: [
              { type: 'text', text: 'screenshot ready' },
              { type: 'image', image: toolImageDataURL }
            ],
            details: { ok: true }
          })
        }
      ]
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'image handled' }])
    expect(sentPayloads).toHaveLength(3)
    const continuation = sentPayloads[1]!.input as Array<JSONObject>
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      previous_response_id: 'resp_tool_image'
    })
    expect(continuation[0]).toMatchObject({ type: 'function_call_output', call_id: 'call_image' })
    expect(continuation[0]!.output).toContain('screenshot ready')
    expect(continuation[0]!.output).toContain('[1 image result attached as follow-up user input]')
    expect(continuation[0]!.output).not.toContain('data:image/')
    expect(continuation[1]).toEqual({
      role: 'user',
      content: [
        { type: 'input_text', text: 'Tool returned image content.' },
        { type: 'input_image', image_url: expect.stringMatching(/^data:image\/webp;base64,/), detail: 'auto' }
      ]
    })
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_tool_image_results',
      input: []
    })
  })

  it('preserves function_call_output pairing and adds tool image summary for text-only models', async () => {
    const sentPayloads: JSONObject[] = []
    const fallbackBodies: JSONObject[] = []
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
            const payload = JSON.parse(data) as JSONObject
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
      maxModelIterations: 90,
      messages: [{ role: 'user', content: 'take a screenshot' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000011',
        conversationID: '11111111-1111-1111-1111-111111111112'
      },
      modelInputModalities: ['text'],
      visionFallbackModel: fallbackModel,
      tools: [
        {
          name: 'screenshot',
          description: 'Capture a screenshot',
          schema: z.object({}),
          describeActivity: () => '测试截图',
          execute: async () => ({
            content: [
              { type: 'text', text: 'screenshot ready' },
              { type: 'image', image: toolImageDataURL }
            ],
            details: { ok: true }
          })
        }
      ]
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'summary handled' }])
    expect(sentPayloads).toHaveLength(3)
    const continuation = sentPayloads[1]!.input as Array<JSONObject>
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      previous_response_id: 'resp_tool_summary'
    })
    expect(continuation[0]).toMatchObject({ type: 'function_call_output', call_id: 'call_summary' })
    expect(continuation[0]!.output).toContain('screenshot ready')
    expect(continuation[0]!.output).toContain('[1 image result attached as follow-up user input]')
    expect(continuation[0]!.output).not.toContain('data:image/')
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
            const payload = JSON.parse(data) as JSONObject
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
      maxModelIterations: 90,
      messages: [{ role: 'user', content: 'what is the weather?' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000006',
        conversationID: '66666666-6666-6666-6666-666666666666'
      },
      tools: [
        {
          name: 'lookup',
          description: 'Look up facts',
          schema: z.object({ q: z.string() }),
          describeActivity: () => '测试查询',
          execute: async () => ({
            content: [],
            details: 1n
          })
        }
      ]
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'done' }])
    expect(sentPayloads).toHaveLength(3)
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      previous_response_id: 'resp_tool_bigint',
      input: [{ type: 'function_call_output', call_id: 'call_bigint' }]
    })
    expect((sentPayloads[1]!.input as Array<JSONObject>)[0]!.output).toContain('1')
    expectWrappedToolOutput((sentPayloads[1]!.input as Array<JSONObject>)[0]!.output)
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_tool_bigint_results',
      input: []
    })
  })

  it('counts post-tool empty-response nudges against the model iteration budget', async () => {
    const sentPayloads: JSONObject[] = []
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
            const payload = JSON.parse(data) as JSONObject
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
        actorEventID: '00000000-0000-0000-0000-000000000019',
        conversationID: '19191919-1919-1919-1919-191919191919'
      },
      maxModelIterations: 3,
      tools: [
        {
          name: 'loop',
          description: 'Loop forever',
          schema: z.object({}),
          describeActivity: () => '测试循环',
          execute: async () => {
            toolExecutions += 1
            return { content: [{ type: 'text', text: `again ${toolExecutions}` }], details: {} }
          }
        }
      ]
    })

    const responseCreates = sentPayloads.filter(payload => payload.type === 'response.create')
    expect(final.message.content).toEqual([{ type: 'text', text: 'summarized after iteration limit' }])
    expect(final.message.stopReason).toBe('stop')
    expect(final.outcome).toBe('iteration_exhausted')
    expect(final.responseID).toBe('resp_iteration_synthesis')
    expect(toolExecutions).toBe(2)
    expect(responseCreates).toHaveLength(4)
    expect(responseCreates[2]!.input).toEqual([
      expect.objectContaining({ role: 'user', content: expect.stringContaining('empty response') })
    ])
    expect(responseCreates[3]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_iteration_results_2'
    })
    expect(responseCreates[3]!.tools).toBeUndefined()
    expect(JSON.stringify(responseCreates[3]!.input)).toContain('maximum number of tool-calling iterations')
  })

  it('completes normally when the last allowed model iteration returns final text', async () => {
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
                  id: 'resp_last_allowed',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'finished on the limit' }]
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
      messages: [{ role: 'user', content: 'finish now' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000020',
        conversationID: '20202020-2020-2020-2020-202020202020'
      },
      maxModelIterations: 1
    })

    expect(final).toMatchObject({
      responseID: 'resp_last_allowed',
      outcome: 'loop_finished',
      message: {
        content: [{ type: 'text', text: 'finished on the limit' }],
        stopReason: 'stop'
      }
    })
    expect(sentPayloads).toHaveLength(1)
  })

  it('drains steering updates after tool results before the next stateful model call', async () => {
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
            const payload = JSON.parse(data) as JSONObject
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
      maxModelIterations: 90,
      messages: [{ role: 'user', content: 'use a tool, then wait' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000008',
        conversationID: '88888888-8888-8888-8888-888888888888'
      },
      tools: [
        {
          name: 'lookup',
          description: 'Look up facts',
          schema: z.object({ q: z.string() }),
          describeActivity: () => '测试查询',
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

    expect(final.message.content).toEqual([{ type: 'text', text: 'steered' }])
    expect(sentPayloads).toHaveLength(3)
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      previous_response_id: 'resp_tool_before_steer',
      input: [{ type: 'function_call_output', call_id: 'call_steer_boundary' }]
    })
    expect((sentPayloads[1]!.input as Array<JSONObject>)[0]!.output).toContain('tool complete')
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_tool_before_steer_results',
      input: [{ role: 'user', content: 'Runtime note: steer now' }]
    })
  })

  it('does not start another stateful run when steering arrives after a final response', async () => {
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
      maxModelIterations: 90,
      messages: [{ role: 'user', content: 'answer directly' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000009',
        conversationID: '99999999-9999-9999-9999-999999999999'
      },
      getSteeringMessages: async () => [{ role: 'user', content: 'Runtime note: steer too late' }]
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'final answer' }])
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
