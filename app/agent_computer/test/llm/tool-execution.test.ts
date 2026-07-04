import { describe, expect, it } from 'bun:test'
import { tmpdir } from 'node:os'
import { z } from 'zod'
import { runAgentLoop } from '../../src/core/agent-loop'
import {
  callModel,
  createModel,
  zodToJSONSchema,
  type ContentPart,
  type ResponseWebSocketLike
} from '../../src/core/llm'
import { classifyLlmError, isLocallyRetryableLlmError } from '../../src/core/llm-error-classifier'
import { actorEventUserContent } from '../../src/core/turns/actor_event_content'
import { statefulTruncationFromActorEventPayload } from '../../src/core/turns/actor_event_text'
import {
  actorEventEnvironmentInfoLines,
  prependEnvironmentInfoLinesToUserMessage
} from '../../src/core/turns/message_context'
import { runtimeModelFromAIGatewayApiKey } from '../../src/core/turns/model_runtime'
import { textTurnResultFromAssistantReply } from '../../src/core/turns/text_turn'
import { steeringMessages } from '../../src/core/turns/turn_control'
import {
  FakeResponseSocket,
  fakeResponseSocket,
  fallbackModelForTest,
  imageActorEventPayload,
  modelRefForTest,
  parallelReadTool,
  toolResultsRecordedFrame,
  turnStartForTest,
  withImageWorkspace
} from '../support/llm'

describe('@ankole/agent-computer llm helpers: tool execution scheduling and guards', () => {
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
    expect(output).toContain('Analyze the error above and try a different approach.')
    expectWrappedToolOutput(output)
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
        { type: 'function_call_output', call_id: 'call_read_a' },
        { type: 'function_call_output', call_id: 'call_read_b' }
      ]
    })
    const outputs = sentPayloads[1]!.input as Array<Record<string, unknown>>
    expect(outputs[0]!.output).toContain('A')
    expect(outputs[1]!.output).toContain('B')
    expectWrappedToolOutput(outputs[0]!.output)
    expectWrappedToolOutput(outputs[1]!.output)
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

  it('nudges the model after the same hard tool failure repeats', async () => {
    const sentPayloads: Record<string, unknown>[] = []
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
            const payload = JSON.parse(data) as Record<string, unknown>
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              recordCount += 1
              return [toolResultsRecordedFrame(`resp_repeated_failure_results_${recordCount}`)]
            }

            const createCount = sentPayloads.filter(sent => sent.type === 'response.create').length
            if (createCount <= 2) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: `resp_repeated_failure_${createCount}`,
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: `fc_repeated_failure_${createCount}`,
                        call_id: `call_repeated_failure_${createCount}`,
                        name: 'lookup',
                        arguments: '{"q":123,"request_id":"volatile"}'
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
                  id: 'resp_after_repeated_failure_nudge',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'I changed route after repeated failure.' }]
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
        actorEventId: '00000000-0000-0000-0000-000000000020',
        conversationId: '20202020-2020-2020-2020-202020202020'
      },
      tools: [
        {
          name: 'lookup',
          description: 'Look up facts',
          schema: z.object({ q: z.string() }),
          execute: async () => {
            throw new Error('should not run with invalid args')
          }
        }
      ]
    })

    expect(final.content).toEqual([{ type: 'text', text: 'I changed route after repeated failure.' }])
    const secondRecord = sentPayloads.find(
      payload =>
        payload.type === 'response.tool_results.record' && JSON.stringify(payload.input).includes('failed repeatedly')
    )
    expect(secondRecord).toBeDefined()
    expect(JSON.stringify(secondRecord!.input)).toContain('failed_tool=lookup')
  })
})

function expectWrappedToolOutput(output: unknown): void {
  expect(String(output)).toMatch(
    /^<ankole_untrusted_tool_output nonce="[0-9a-f]{16}">\n[\s\S]*\n<\/ankole_untrusted_tool_output nonce="[0-9a-f]{16}">$/
  )
}
