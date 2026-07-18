import { describe, expect, it } from 'bun:test'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { createModel } from '../src/core/llm'
import { recognizeAmbientIntervention } from '../src/core/turns/ambient_recognizer'
import type { TurnStart } from '../src/lanes/actor_lane'
import { create } from '@bufbuild/protobuf'
import { AgentConversationContextResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { AgentConversationContextResponse } from '../src/lanes/rpc_lane'
import { turnStartForTest } from './support/llm'

describe('ambient intervention recognizer', () => {
  it('uses the execution time instead of the queued event time', async () => {
    const bodies: JSONObject[] = []
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'light',
      fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
        const request = input instanceof Request ? input : new Request(input, init)
        bodies.push(JSON.parse(await request.text()) as JSONObject)

        return new Response(
          JSON.stringify({
            id: 'resp_ambient_time',
            object: 'response',
            status: 'completed',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [
                  {
                    type: 'output_text',
                    text: '{"reason":"quiet","should_proactively_speak":false}'
                  }
                ]
              }
            ]
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        )
      }) as unknown as typeof fetch
    })

    const base = turnStartForTest()
    const turnStart = {
      ...base,
      actor_event: {
        ...base.actor_event,
        type: 'im.message.may_intervene',
        payload_json: {
          time: '2020-01-01T00:00:00Z',
          data: {
            channel: { name: 'Ops' },
            observed_messages: [
              {
                signal_channel_id: 'lark:chat:ops',
                source_entry_id: 'message-1',
                sent_at: '2026-07-18T12:00:00Z',
                speaker: 'Alice',
                text: 'Should we change the benchmark?'
              }
            ]
          }
        }
      }
    } as TurnStart

    const context: AgentConversationContextResponse = create(AgentConversationContextResponseSchema, {
      agent: { displayName: 'Research Agent' },
      conversation: { timezone: 'Asia/Singapore' }
    })

    await recognizeAmbientIntervention(
      {
        turnStart,
        model,
        historyMessages: [],
        agentConversationContext: context
      },
      { currentTime: new Date('2026-07-18T12:34:00Z') }
    )

    expect(bodies[0]!.instructions).toContain('current_time: 2026-07-18 20:34')
    expect(bodies[0]!.instructions).not.toContain('2020-01-01')
    expect(JSON.stringify(bodies[0]!.input)).toContain('20:00 [human] Alice')
  })
})
