import { describe, expect, it } from 'bun:test'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { z } from 'zod'
import { runAgentLoop } from '../../src/core/agent-loop'
import type { ReplyPresentationEvent } from '../../src/core/types'
import { createModel } from '../../src/core/llm'
import { fakeResponseSocket, parallelReadTool, toolResultsRecordedFrame } from '../support/llm'

describe('@ankole/agent-computer llm helpers: tool execution scheduling and guards', () => {
  it('keeps a hosted image tool beside local tools and the default PTC declaration', async () => {
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
                  id: 'resp_hosted_image_turn',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'generated' }]
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
      messages: [{ role: 'user', content: 'draw a diagram' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000004',
        conversationID: '44444444-4444-4444-4444-444444444444'
      },
      hostedTools: [{ type: 'image_generation' }],
      tools: [
        {
          name: 'lookup',
          description: 'Look up facts',
          schema: z.object({ q: z.string() }),
          describeActivity: () => '测试查询',
          execute: async () => ({
            content: [{ type: 'text', text: 'unused' }],
            details: {}
          })
        }
      ]
    })

    expect(sentPayloads).toHaveLength(1)
    expect(sentPayloads[0]!.tools).toEqual([
      expect.objectContaining({ type: 'function', name: 'lookup', allowed_callers: ['direct'] }),
      { type: 'programmatic_tool_calling' },
      { type: 'image_generation' }
    ])
  })

  it('feeds invalid tool arguments back as function_call_output instead of executing the tool', async () => {
    const sentPayloads: JSONObject[] = []
    const presentation: ReplyPresentationEvent[] = []
    let activityDescriptions = 0
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
                      content: [
                        {
                          type: 'output_text',
                          text: 'I corrected the tool input.'
                        }
                      ]
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
      messages: [{ role: 'user', content: 'look this up' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000005',
        conversationID: '55555555-5555-5555-5555-555555555555'
      },
      tools: [
        {
          name: 'lookup',
          description: 'Look up facts',
          schema: z.object({ q: z.string() }),
          describeActivity: () => {
            activityDescriptions += 1
            return '查询资料'
          },
          execute: async () => {
            toolExecutions += 1
            return {
              content: [{ type: 'text', text: 'should not run' }],
              details: { ok: false }
            }
          }
        }
      ],
      onPresentationEvent: event => {
        presentation.push(event)
      }
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'I corrected the tool input.' }])
    expect(toolExecutions).toBe(0)
    expect(activityDescriptions).toBe(0)
    expect(presentation.filter(event => event.kind === 'tool.activity')).toEqual([])
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
    const output = (sentPayloads[1]!.input as Array<JSONObject>)[0]!.output
    expect(output).toContain('Invalid arguments for tool lookup')
    expect(output).toContain('expected string')
    expectWrappedToolOutput(output)
    expect(sentPayloads[2]).toMatchObject({
      type: 'response.create',
      previous_response_id: 'resp_bad_args_results',
      input: []
    })
  })

  it('executes schema-valid arguments recovered by the bounded punctuation repair ladder', async () => {
    const sentPayloads: JSONObject[] = []
    const activities: string[] = []
    let executedQuery: string | undefined
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
              return [toolResultsRecordedFrame('resp_repaired_args_results')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_repaired_args',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        status: 'completed',
                        id: 'fc_repaired_args',
                        call_id: 'call_repaired_args',
                        name: 'lookup',
                        arguments: '{"q":"weather",'
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
                  id: 'resp_after_repaired_args',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'sunny' }]
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
      messages: [{ role: 'user', content: 'look up the weather' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000022',
        conversationID: '22222222-2222-2222-2222-222222222223'
      },
      tools: [
        {
          name: 'lookup',
          description: 'Look up facts.',
          schema: z.object({ q: z.string() }).strict(),
          describeActivity: () => '测试查询',
          execute: async (_callID, args) => {
            executedQuery = (args as { q: string }).q
            return {
              content: [{ type: 'text' as const, text: 'sunny' }],
              details: {}
            }
          }
        }
      ],
      onActivity: description => {
        if (description) activities.push(description)
      }
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'sunny' }])
    expect(executedQuery).toBe('weather')
    expect(activities).toContain('tool_arguments_repaired:incomplete_container')
  })

  it('does not execute tools without structured function_call items', async () => {
    const sentPayloads: JSONObject[] = []
    let toolExecutions = 0
    const leakedText =
      '[{"name":"lookup","arguments":{"q":"should not execute"}}]\nassistant to=functions.lookup {"q":"also not executable"}'
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

            return [
              {
                type: 'response.completed',
                response: {
                  id: 'resp_text_tool_leak',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: leakedText }]
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
      messages: [{ role: 'user', content: 'look this up' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000021',
        conversationID: '21212121-2121-2121-2121-212121212121'
      },
      tools: [
        {
          name: 'lookup',
          description: 'Look up facts',
          schema: z.object({ q: z.string() }),
          describeActivity: () => '测试查询',
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

    expect(final.message.content.length).toBeGreaterThan(0)
    expect(toolExecutions).toBe(0)
    expect(sentPayloads.map(payload => payload.type)).toEqual(['response.create'])
  })

  it('does not count tool execution against model inactivity tracking', async () => {
    const sentPayloads: JSONObject[] = []
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
            const payload = JSON.parse(data) as JSONObject
            sentPayloads.push(payload)

            if (payload.type === 'response.tool_results.record') {
              return [toolResultsRecordedFrame('resp_suspended_tool_results')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_suspended_tool',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_suspended_tool',
                        call_id: 'call_suspended_tool',
                        name: 'slow_tool',
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
                  id: 'resp_after_suspended_tool',
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
      messages: [{ role: 'user', content: 'run a slow tool' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000022',
        conversationID: '22222222-2222-2222-2222-222222222222'
      },
      tools: [
        {
          name: 'slow_tool',
          description: 'Slow tool',
          schema: z.object({}),
          describeActivity: () => '测试慢工具',
          execute: async () => {
            events.push('tool_execute')
            return {
              content: [{ type: 'text', text: 'tool result' }],
              details: {}
            }
          }
        }
      ],
      onActivity: description => {
        if (description) events.push(description)
      },
      withActivitySuspended: async (description, fn) => {
        events.push(`suspend:${description}:start`)
        try {
          return await fn()
        } finally {
          events.push(`suspend:${description}:end`)
        }
      }
    })

    expect(events.indexOf('suspend:tool_execution:start')).toBeLessThan(events.indexOf('tool_execute'))
    expect(events.indexOf('tool_execute')).toBeLessThan(events.indexOf('suspend:tool_execution:end'))
    expect(events.indexOf('suspend:tool_execution:end')).toBeLessThan(events.indexOf('tool_results_record_start'))
  })

  it('executes pure read-only tool batches in parallel while preserving result order', async () => {
    const sentPayloads: JSONObject[] = []
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
            const payload = JSON.parse(data) as JSONObject
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
      maxModelIterations: 90,
      messages: [{ role: 'user', content: 'read both' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000017',
        conversationID: '17171717-1717-1717-1717-171717171717'
      },
      tools: [parallelReadTool('read_a', events, 20, 'A'), parallelReadTool('read_b', events, 1, 'B')]
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'read results handled' }])
    expect(events.indexOf('read_b:start')).toBeLessThan(events.indexOf('read_a:end'))
    expect(sentPayloads[1]).toMatchObject({
      type: 'response.tool_results.record',
      input: [
        { type: 'function_call_output', call_id: 'call_read_a' },
        { type: 'function_call_output', call_id: 'call_read_b' }
      ]
    })
    const outputs = sentPayloads[1]!.input as Array<JSONObject>
    expect(outputs[0]!.output).toContain('A')
    expect(outputs[1]!.output).toContain('B')
    expectWrappedToolOutput(outputs[0]!.output)
    expectWrappedToolOutput(outputs[1]!.output)
  })

  it('keeps mixed side-effecting tool batches sequential', async () => {
    const sentPayloads: JSONObject[] = []
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
            const payload = JSON.parse(data) as JSONObject
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
      maxModelIterations: 90,
      messages: [{ role: 'user', content: 'read then write' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000018',
        conversationID: '18181818-1818-1818-1818-181818181818'
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
          describeActivity: () => '测试写入',
          execute: async () => {
            events.push('write_second:start')
            events.push('write_second:end')
            return { content: [{ type: 'text', text: 'write' }], details: {} }
          }
        }
      ]
    })

    expect(final.message.content).toEqual([{ type: 'text', text: 'mixed handled' }])
    expect(events.indexOf('write_second:start')).toBeGreaterThan(events.indexOf('read_first:end'))
  })

  it('emits revisioned semantic tool activity without leaking raw names or arguments', async () => {
    const sentPayloads: JSONObject[] = []
    const presentation: ReplyPresentationEvent[] = []
    const logs: Array<{ level: 'info' | 'warning'; event: string; fields?: JSONObject }> = []
    let describedParams: { password: string } | undefined
    const secretAdminSchema = z.object({ password: z.string() })
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
              return [toolResultsRecordedFrame('resp_presentation_results')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_presentation_tool',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_presentation_tool',
                        call_id: 'call_presentation_tool',
                        name: 'secret_admin_shell',
                        arguments: '{"password":"do-not-leak"}'
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
                  id: 'resp_after_presentation_tool',
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
      messages: [{ role: 'user', content: 'perform the operation' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000023',
        conversationID: '23232323-2323-2323-2323-232323232323'
      },
      tools: [
        {
          name: 'secret_admin_shell',
          description: 'Internal test tool',
          schema: secretAdminSchema,
          isDestructive: true,
          describeActivity: params => {
            describedParams = secretAdminSchema.parse(params)
            return '执行维护任务'
          },
          describeCompletedActivity: (_params, details) => (details.ok === true ? '完成维护任务：配置已更新' : null),
          execute: async () => ({
            content: [{ type: 'text', text: 'sensitive raw output' }],
            details: { ok: true },
            presentation: [
              {
                kind: 'effect.receipt',
                payload: {
                  operation_id: 'call_presentation_tool',
                  phase: 'confirmed',
                  summary: '已确认外部变更'
                }
              }
            ]
          })
        }
      ],
      logger: {
        info: (event, _message, fields) => logs.push({ level: 'info', event, fields }),
        warning: (event, _message, fields) => logs.push({ level: 'warning', event, fields })
      },
      onPresentationEvent: event => {
        presentation.push(event)
      }
    })

    expect(presentation.map(event => event.kind)).toEqual([
      'turn.phase',
      'tool.activity',
      'effect.receipt',
      'tool.activity',
      'turn.phase'
    ])
    expect(describedParams).toEqual({ password: 'do-not-leak' })
    expect(presentation[1]).toMatchObject({
      kind: 'tool.activity',
      payload: {
        operation_id: 'call_presentation_tool',
        label: '执行维护任务',
        phase: 'running',
        consequential: true
      }
    })
    expect(presentation[3]).toMatchObject({
      kind: 'tool.activity',
      payload: { label: '完成维护任务：配置已更新', phase: 'completed' }
    })
    const activityRevisions = presentation
      .filter(event => event.kind === 'tool.activity')
      .map(event => Number((event.payload as { revision?: number }).revision))
    expect(activityRevisions.every(revision => Number.isFinite(revision))).toBe(true)
    expect(activityRevisions).toEqual([...activityRevisions].sort((a, b) => a - b))
    expect(new Set(activityRevisions).size).toBe(activityRevisions.length)
    expect(JSON.stringify(presentation)).not.toContain('secret_admin_shell')
    expect(JSON.stringify(presentation)).not.toContain('do-not-leak')
    expect(JSON.stringify(presentation)).not.toContain('sensitive raw output')

    expect(logs.find(log => log.event === 'worker.tool_call_started')).toMatchObject({
      level: 'info',
      fields: {
        actor_event_id: '00000000-0000-0000-0000-000000000023',
        tool_name: 'secret_admin_shell',
        tool_call_id: 'call_presentation_tool',
        destructive: true
      }
    })
    expect(logs.find(log => log.event === 'worker.tool_call_completed')).toMatchObject({
      level: 'info',
      fields: {
        tool_name: 'secret_admin_shell',
        tool_call_id: 'call_presentation_tool',
        terminate: false
      }
    })
    expect(logs.find(log => log.event === 'worker.tool_results_record_started')).toMatchObject({
      level: 'info',
      fields: {
        actor_event_id: '00000000-0000-0000-0000-000000000023',
        attempt: 1,
        tool_result_count: 1
      }
    })
    expect(logs.find(log => log.event === 'worker.tool_results_record_completed')).toMatchObject({
      level: 'info',
      fields: {
        response_id: 'resp_presentation_results'
      }
    })
    expect(JSON.stringify(logs)).not.toContain('do-not-leak')
    expect(JSON.stringify(logs)).not.toContain('sensitive raw output')
  })

  it('lets a tool suppress activity and falls back safely when description fails', async () => {
    const sentPayloads: JSONObject[] = []
    const presentation: ReplyPresentationEvent[] = []
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
              return [toolResultsRecordedFrame('resp_activity_policy_results')]
            }

            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_activity_policy_tools',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_quiet_tool',
                        call_id: 'call_quiet_tool',
                        name: 'quiet_tool',
                        arguments: '{}'
                      },
                      {
                        type: 'function_call',
                        id: 'fc_fallback_tool',
                        call_id: 'call_fallback_tool',
                        name: 'fallback_tool',
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
                  id: 'resp_after_activity_policy',
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

    const result = await runAgentLoop({
      model,
      maxModelIterations: 90,
      messages: [{ role: 'user', content: 'perform quiet work' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000024',
        conversationID: '24242424-2424-2424-2424-242424242424'
      },
      tools: [
        {
          name: 'quiet_tool',
          description: 'Does not need user-facing progress',
          schema: z.object({}),
          describeActivity: () => null,
          execute: async () => {
            executed.push('quiet')
            return { content: [{ type: 'text', text: 'quiet' }], details: {} }
          }
        },
        {
          name: 'fallback_tool',
          description: 'Falls back when its optional summary fails',
          schema: z.object({}),
          describeActivity: () => {
            throw new Error('description failed')
          },
          describeCompletedActivity: () => {
            throw new Error('completed description failed')
          },
          execute: async () => {
            executed.push('fallback')
            return {
              content: [{ type: 'text', text: 'fallback' }],
              details: {}
            }
          }
        }
      ],
      onPresentationEvent: event => {
        presentation.push(event)
      }
    })

    expect(result.message.content).toEqual([{ type: 'text', text: 'done' }])
    expect(executed).toEqual(['quiet', 'fallback'])
    expect(presentation.filter(event => event.kind === 'tool.activity').map(event => event.payload)).toEqual([
      expect.objectContaining({
        operation_id: 'call_fallback_tool',
        label: '处理请求',
        phase: 'running'
      }),
      expect.objectContaining({
        operation_id: 'call_fallback_tool',
        label: '处理请求',
        phase: 'completed'
      })
    ])
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
        maxModelIterations: 90,
        messages: [{ role: 'user', content: 'hello' }],
        stateful: {
          actorEventID: '00000000-0000-0000-0000-000000000006',
          conversationID: '66666666-6666-6666-6666-666666666666'
        },
        tools: [
          {
            name: 'duplicate',
            description: 'first',
            schema: z.object({}),
            describeActivity: () => '测试重复工具',
            execute: async () => ({
              content: [{ type: 'text', text: 'first' }],
              details: {}
            })
          },
          {
            name: 'duplicate',
            description: 'second',
            schema: z.object({}),
            describeActivity: () => '测试重复工具',
            execute: async () => ({
              content: [{ type: 'text', text: 'second' }],
              details: {}
            })
          }
        ]
      })
    ).rejects.toThrow('duplicate tool name: duplicate')
  })
})

function expectWrappedToolOutput(output: unknown): void {
  expect(String(output)).toMatch(
    /^<ankole_untrusted_tool_output nonce="[0-9a-f]{16}">\n[\s\S]*\n<\/ankole_untrusted_tool_output nonce="[0-9a-f]{16}">$/
  )
}
