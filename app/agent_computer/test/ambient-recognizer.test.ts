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
          source: 'signal://lark/ops',
          time: '2020-01-01T00:00:00Z',
          data: {
            channel: { id: 'lark:chat:ops', kind: 'im_group', name: 'Ops' },
            observed_messages: [
              {
                signal_channel_id: 'lark:chat:ops',
                source_entry_id: 'message-1',
                sent_at: '2026-07-18T12:00:00Z',
                author: { id: '019f0000-0000-7000-8000-000000000041' },
                text: 'Should we change the benchmark?'
              }
            ]
          }
        }
      }
    } as TurnStart

    const context: AgentConversationContextResponse = create(AgentConversationContextResponseSchema, {
      agent: { displayName: 'Research Agent' },
      conversation: { timezone: 'Asia/Singapore' },
      soul: 'Be calm and exact.',
      mission: 'Help the group make sound decisions.',
      brainSnapshot: {
        channelEntry: { residentText: 'The group prefers evidence before action.', truncated: false }
      }
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

    const instructions = String(bodies[0]!.instructions)
    const modelInput = JSON.stringify(bodies[0]!.input)

    expect(instructions).toContain('<display_name>Research Agent</display_name>')
    expect(instructions).toContain('Be calm and exact.')
    expect(instructions).toContain('Help the group make sound decisions.')
    expect(instructions.match(/Research Agent/g)).toHaveLength(1)
    expect(instructions.match(/Decide whether/g)).toHaveLength(1)
    expect(instructions).not.toContain('current_time:')
    expect(instructions).not.toContain('group_name:')
    expect(instructions).not.toContain('The group prefers evidence before action.')
    expect(instructions).not.toContain('should_proactively_speak')
    expect(instructions).not.toContain('2020-01-01')
    expect(modelInput).toContain('current_time: 2026-07-18 20:34')
    expect(modelInput).toContain('platform: Lark / Feishu')
    expect(modelInput).toContain('group_name: Ops')
    expect(modelInput).toContain('The group prefers evidence before action.')
    expect(modelInput).toContain('20:00 [human] Unknown')
    expect(modelInput).not.toContain('019f0000-0000-7000-8000-000000000041')
    expect(modelInput).not.toContain('Decide whether')
  })
})
