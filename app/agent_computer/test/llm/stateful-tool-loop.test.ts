import { describe, expect, it } from 'bun:test'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
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

  it('settles every sequential program call before it resumes the program to a final answer', async () => {
    const sentPayloads: JSONObject[] = []
    const executed: string[] = []
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
              return [toolResultsRecordedFrame('resp_program_result')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 2) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_program_final',
                    status: 'completed',
                    output: [
                      {
                        type: 'message',
                        role: 'assistant',
                        content: [{ type: 'output_text', text: 'The program completed.' }]
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
                  id: 'resp_program_call',
                  status: 'completed',
                  output: [
                    {
                      type: 'function_call',
                      id: 'fc_program',
                      call_id: 'call_program',
                      namespace: 'mcp__finance',
                      name: 'stock_price',
                      arguments: '{"symbol":"600519"}',
                      caller: { type: 'program', caller_id: 'prog_1' }
                    },
                    {
                      type: 'function_call',
                      id: 'fc_program_name',
                      call_id: 'call_program_name',
                      namespace: 'mcp__finance',
                      name: 'company_name',
                      arguments: '{"symbol":"600519"}',
                      caller: { type: 'program', caller_id: 'prog_1' }
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
      messages: [{ role: 'user', content: 'find the stock price with a program' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000013',
        conversationID: '13131313-1313-1313-1313-131313131313'
      },
      tools: [
        {
          name: 'stock_price',
          namespace: 'mcp__finance',
          namespaceDescription: 'Financial market data',
          deferLoading: true,
          description: 'Get a stock price',
          schema: z.object({ symbol: z.string() }),
          allowedCallers: ['direct', 'programmatic'],
          executionMode: 'sequential',
          isReadOnly: true,
          isDestructive: false,
          describeActivity: () => '测试行情查询',
          execute: async (_toolCallID, params) => {
            executed.push(`price:${(params as JSONObject).symbol}`)
            return {
              content: [{ type: 'text', text: '{"price":123.45}' }],
              details: { ok: true },
              terminate: true
            }
          }
        },
        {
          name: 'company_name',
          namespace: 'mcp__finance',
          namespaceDescription: 'Financial market data',
          deferLoading: true,
          description: 'Get a company name',
          schema: z.object({ symbol: z.string() }),
          allowedCallers: ['direct', 'programmatic'],
          executionMode: 'sequential',
          isReadOnly: true,
          isDestructive: false,
          describeActivity: () => '测试公司查询',
          execute: async (_toolCallID, params) => {
            executed.push(`name:${(params as JSONObject).symbol}`)
            return {
              content: [{ type: 'text', text: '{"name":"Kweichow Moutai"}' }],
              details: { ok: true }
            }
          }
        }
      ]
    })

    expect(final.responseID).toBe('resp_program_final')
    expect(executed).toEqual(['price:600519', 'name:600519'])
    expect(sentPayloads).toHaveLength(3)
    expect(sentPayloads[0]!.tools).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: 'namespace',
          name: 'mcp__finance',
          tools: expect.arrayContaining([
            expect.objectContaining({
              type: 'function',
              name: 'stock_price',
              defer_loading: true,
              allowed_callers: ['direct', 'programmatic']
            })
          ])
        }),
        expect.objectContaining({ type: 'tool_search' }),
        { type: 'programmatic_tool_calling' }
      ])
    )
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      previous_response_id: 'resp_program_call',
      input: [
        {
          type: 'function_call_output',
          call_id: 'call_program',
          caller: { type: 'program', caller_id: 'prog_1' }
        },
        {
          type: 'function_call_output',
          call_id: 'call_program_name',
          caller: { type: 'program', caller_id: 'prog_1' }
        }
      ]
    })
    expect(((sentPayloads[1]!.input as JSONObject[])[0] as JSONObject).output).toBe('{"price":123.45}')
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_program_result',
      input: []
    })
  })

  it('rejects a forged program caller for a direct-only tool before execution', async () => {
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
            const payload = JSON.parse(data) as JSONObject
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_forged_caller_result')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_forged_caller',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_forged_caller',
                        call_id: 'call_forged_caller',
                        name: 'write_record',
                        arguments: '{"value":"changed"}',
                        caller: { type: 'program', caller_id: 'prog_forged' }
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
                  id: 'resp_after_forged_caller',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'The write was rejected.' }]
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
      messages: [{ role: 'user', content: 'write the record' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000027',
        conversationID: '27272727-2727-2727-2727-272727272727'
      },
      tools: [
        {
          name: 'write_record',
          description: 'Write one record.',
          schema: z.object({ value: z.string() }),
          allowedCallers: ['direct'],
          executionMode: 'sequential',
          isReadOnly: false,
          isDestructive: true,
          describeActivity: () => '测试写入',
          execute: async () => {
            executions += 1
            return { content: [{ type: 'text', text: 'changed' }], details: {} }
          }
        }
      ]
    })

    expect(final.responseID).toBe('resp_after_forged_caller')
    expect(executions).toBe(0)
    expect(sentPayloads.map(payload => payload.type)).toEqual([
      'response.create',
      'response.tool_results.record',
      'response.create'
    ])
    expect(sentPayloads[1]).toMatchObject({
      input: [
        {
          type: 'function_call_output',
          call_id: 'call_forged_caller',
          caller: { type: 'program', caller_id: 'prog_forged' }
        }
      ]
    })
    expect(String(((sentPayloads[1]!.input as JSONObject[])[0] as JSONObject).output)).toContain(
      'Caller programmatic is not allowed for tool write_record'
    )
  })

  it('executes a custom apply_patch call with raw input and records the matching output type', async () => {
    const sentPayloads: JSONObject[] = []
    const executedInputs: string[] = []
    const patch = '*** Begin Patch\n*** Add File: report.md\n+done\n*** End Patch\n'
    const grammar = 'start: "*** Begin Patch" LF "*** End Patch" LF?\n%import common.LF'
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
              return [toolResultsRecordedFrame('resp_apply_patch_result')]
            }

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_apply_patch_call',
                  status: 'completed',
                  output: [
                    {
                      type: 'custom_tool_call',
                      id: 'ctc_apply_patch',
                      call_id: 'call_apply_patch',
                      status: 'completed',
                      name: 'apply_patch',
                      input: patch
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
      messages: [{ role: 'user', content: 'create the report' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000022',
        conversationID: '22222222-2222-2222-2222-222222222222'
      },
      tools: [
        {
          name: 'apply_patch',
          description: 'Apply one patch.',
          schema: z.string(),
          inputFormat: {
            type: 'grammar',
            syntax: 'lark',
            definition: grammar
          },
          executionMode: 'sequential',
          isReadOnly: false,
          isDestructive: true,
          describeActivity: () => '测试更新文件',
          execute: async (_toolCallID, input) => {
            executedInputs.push(input as string)
            return {
              content: [{ type: 'text', text: 'Done!' }],
              details: { ok: true },
              terminate: true
            }
          }
        }
      ]
    })

    expect(final.responseID).toBe('resp_apply_patch_result')
    expect(executedInputs).toEqual([patch])
    expect(sentPayloads).toHaveLength(2)
    expect(sentPayloads[0]!.tools).toEqual([
      {
        type: 'custom',
        name: 'apply_patch',
        description: 'Apply one patch.',
        format: {
          type: 'grammar',
          syntax: 'lark',
          definition: grammar
        },
        allowed_callers: ['direct']
      }
    ])
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      previous_response_id: 'resp_apply_patch_call',
      input: [
        {
          type: 'custom_tool_call_output',
          call_id: 'call_apply_patch'
        }
      ]
    })
    expect(((sentPayloads[1]!.input as JSONObject[])[0] as JSONObject).output).toContain('Done!')
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

  it('salvages a tool call cut by the output limit with one described continuation', async () => {
    const sentPayloads: JSONObject[] = []
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
            const payload = JSON.parse(data) as JSONObject
            sentPayloads.push(payload)

            const index = sentPayloads.filter(sent => sent.type === 'response.create').length
            if (index === 1) {
              return [
                {
                  type: 'response.incomplete',
                  response: {
                    id: 'resp_cut',
                    status: 'incomplete',
                    incomplete_details: { reason: 'max_output_tokens' },
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_cut',
                        call_id: 'call_cut',
                        name: 'write_file',
                        status: 'in_progress',
                        arguments: '{"path": "report.md", "content": "# Report\\nThe first'
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
                  id: 'resp_after_salvage',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'done in smaller pieces' }]
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
      messages: [{ role: 'user', content: 'write the report' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000021',
        conversationID: '21212121-2121-2121-2121-212121212121'
      },
      maxModelIterations: 90,
      tools: [
        {
          name: 'write_file',
          description: 'Write one file',
          schema: z.object({ path: z.string(), content: z.string() }),
          describeActivity: () => '测试写文件',
          execute: async () => {
            toolExecutions += 1
            return { content: [{ type: 'text', text: 'written' }], details: {} }
          }
        }
      ]
    })

    const responseCreates = sentPayloads.filter(payload => payload.type === 'response.create')
    expect(final.message.content).toEqual([{ type: 'text', text: 'done in smaller pieces' }])
    expect(final.message.stopReason).toBe('stop')
    expect(final.responseID).toBe('resp_after_salvage')
    expect(toolExecutions).toBe(0)
    expect(responseCreates).toHaveLength(2)

    // The truncated response is not the anchor: the salvage continuation keeps
    // the conversation anchor, so the stored thread never ends on a function
    // call without an output.
    expect(responseCreates[1]!.previous_response_id).toBeUndefined()
    expect(responseCreates[1]!.conversation).toBe('conv_21212121-2121-2121-2121-212121212121')

    const salvageText = JSON.stringify(responseCreates[1]!.input)
    expect(salvageText).toContain('did not run')
    expect(salvageText).toContain('write_file')
    expect(salvageText).toContain('completed fields: path')
    expect(salvageText).toContain('stopped inside the value of')
  })

  it('breaks after a second output-limit cut instead of describing it again', async () => {
    const sentPayloads: JSONObject[] = []
    const cutFrame = (id: string) => ({
      type: 'response.incomplete',
      response: {
        id,
        status: 'incomplete',
        incomplete_details: { reason: 'max_output_tokens' },
        output: [
          {
            type: 'function_call',
            id: `fc_${id}`,
            call_id: `call_${id}`,
            name: 'write_file',
            status: 'in_progress',
            arguments: '{"path": "report.md", "content": "# Report'
          }
        ]
      }
    })
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
            const index = sentPayloads.filter(sent => sent.type === 'response.create').length
            return [cutFrame(index === 1 ? 'resp_cut_first' : 'resp_cut_second')]
          })
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'write the report' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000022',
        conversationID: '22222222-2222-2222-2222-222222222222'
      },
      maxModelIterations: 90,
      tools: [
        {
          name: 'write_file',
          description: 'Write one file',
          schema: z.object({ path: z.string(), content: z.string() }),
          describeActivity: () => '测试写文件',
          execute: async () => ({ content: [{ type: 'text', text: 'written' }], details: {} })
        }
      ]
    })

    const responseCreates = sentPayloads.filter(payload => payload.type === 'response.create')
    expect(responseCreates).toHaveLength(2)
    expect(final.message.stopReason).toBe('length')
    expect(final.message.toolCalls).toBeUndefined()
    expect(final.responseID).toBe('resp_cut_second')
  })

  it('repairs an empty final response once and accepts the second empty as final', async () => {
    const sentPayloads: JSONObject[] = []
    let repairCalls = 0
    const emptyFrame = (id: string) => ({
      type: 'response.completed',
      response: {
        id,
        status: 'completed',
        output: [{ type: 'message', role: 'assistant', content: [] }]
      }
    })
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
            const index = sentPayloads.filter(sent => sent.type === 'response.create').length
            return [emptyFrame(index === 1 ? 'resp_empty_first' : 'resp_empty_second')]
          })
      }
    })

    const final = await runAgentLoop({
      model,
      messages: [{ role: 'user', content: 'answer me' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000023',
        conversationID: '23232323-2323-2323-2323-232323232323'
      },
      maxModelIterations: 90,
      repairFinalResponse: () => {
        repairCalls += 1
        return { role: 'user', content: 'You must end this turn with a visible reply.' }
      }
    })

    const responseCreates = sentPayloads.filter(payload => payload.type === 'response.create')
    expect(repairCalls).toBe(1)
    expect(responseCreates).toHaveLength(2)
    expect(JSON.stringify(responseCreates[1]!.input)).toContain('visible reply')
    expect(final.responseID).toBe('resp_empty_second')
    expect(final.message.stopReason).toBe('stop')
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
