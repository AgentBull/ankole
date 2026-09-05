import { describe, expect, it } from 'bun:test'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { z } from 'zod'
import { runAgentLoop } from '../../src/core/agent-loop'
import { createModel } from '../../src/core/llm'
import { defineWorkerTool } from '../../src/core'
import type { TurnStart } from '../../src/lanes/actor_lane'
import { configureWorkerTracing, forceFlushWorkerTracing, workerTurnTrace } from '../../src/observability/turn-tracing'
import { fakeResponseSocket, toolResultsRecordedFrame, turnStartForTest } from '../support/llm'

describe('Main Agent tool observations', () => {
  it('exports the concrete Skill input and model-visible result without internal result details', async () => {
    const secret = 'sk-model-visible-secret-1234567890'
    const exports: Uint8Array[] = []
    const sentPayloads: JSONObject[] = []
    configureWorkerTracing(async payload => {
      exports.push(payload)
    })

    const turnStart = turnStartForTest() as TurnStart
    turnStart.request_context = {
      ...turnStart.request_context,
      traceparent: '00-11111111111111111111111111111111-1111111111111111-01'
    }
    const turnTrace = workerTurnTrace(turnStart)
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
              return [toolResultsRecordedFrame('resp_skill_results')]
            }
            if (sentPayloads.filter(sent => sent.type === 'response.create').length === 1) {
              return [
                {
                  type: 'response.completed',
                  response: {
                    id: 'resp_skill_call',
                    status: 'completed',
                    output: [
                      {
                        type: 'function_call',
                        id: 'fc_skill_view',
                        call_id: 'call_skill_view',
                        name: 'skill_view',
                        arguments: '{"name":"pdf"}'
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
                  id: 'resp_skill_done',
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: 'Skill loaded.' }]
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
      messages: [{ role: 'user', content: 'load the PDF skill' }],
      stateful: {
        actorEventID: turnStart.turn.actor_event_id,
        conversationID: turnStart.turn.actor.session_id
      },
      turnTrace,
      tools: [
        defineWorkerTool({
          executionMode: 'sequential',
          name: 'skill_view',
          description: 'Load one Skill',
          schema: z.object({ name: z.string() }),
          describeActivity: params => `Load ${params.name}`,
          execute: async (_callID, params) => ({
            content: [{ type: 'text', text: `loaded ${params.name} skill; token=${secret}` }],
            details: { name: params.name, path: '/internal/skill/path' }
          })
        })
      ]
    })
    await forceFlushWorkerTracing()

    const wireText = exports.map(payload => new TextDecoder().decode(payload)).join('\n')
    expect(wireText).toContain('execute_tool skill_view')
    expect(wireText).toContain('gen_ai.tool.call.arguments')
    expect(wireText).toContain('gen_ai.tool.call.result')
    expect(wireText).toContain('"name":"pdf"')
    expect(wireText).toContain('loaded pdf skill')
    expect(wireText).not.toContain(secret)
    expect(wireText).toContain('[REDACTED]')
    expect(JSON.stringify(sentPayloads.find(payload => payload.type === 'response.tool_results.record'))).toContain(
      secret
    )
    expect(wireText).not.toContain('/internal/skill/path')
    expect(wireText).not.toContain('ankole.worker.input')
    expect(wireText).not.toContain('ankole.worker.output')
    expect(wireText).not.toContain('langfuse.')
    expect(wireText).not.toContain('langsmith.')
  })
})
