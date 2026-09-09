import { describe, expect, it } from 'bun:test'
import type { JsonObject } from '@agentbull/active-support'
import { runAgentLoop } from '../../src/core/agent-loop'
import { assistantText, createModel } from '../../src/core/llm'
import { parseScheduledReply, scheduledReplyFormat } from '../../src/core/turns/scheduled_reply'
import { textTurnReplyRepair, textTurnResultFromAssistantReply } from '../../src/core/turns/text_turn'
import { fakeResponseSocket, turnStartForTest } from '../support/llm'

describe('scheduled reply protocol', () => {
  it('validates the outcome and payload without interpreting text markers', () => {
    for (const text of [
      '<sাইলent_success/>',
      '<silent_success/>',
      'ordinary raw text',
      '{"outcome":"silnet_success","reply":null}',
      '{"outcome":"silent_success","reply":"failed"}',
      '{"outcome":"reply","reply":null}',
      '{"outcome":"reply","reply":" "}',
      '{"outcome":"reply","reply":"hi","extra":true}'
    ]) {
      expect(parseScheduledReply(text, true)).toBeUndefined()
    }
    const silent = '{"outcome":"silent_success","reply":null}'
    expect(parseScheduledReply(silent, false)).toBeUndefined()
    expect(parseScheduledReply(silent, true)?.outcome).toBe('silent_success')
    expect(parseScheduledReply('{"outcome":"reply","reply":"发送失败。"}', false)?.reply).toBe('发送失败。')
  })

  it.each([
    { allowed: true, second: '{"outcome":"silent_success","reply":null}', kind: 'noop_completed' },
    { allowed: false, second: '{"outcome":"reply","reply":"发送失败。"}', kind: 'turn_completed' },
    { allowed: true, second: '<sাইলent_success/>', kind: 'turn_completed' },
    { allowed: false, second: '{"outcome":"silent_success","reply":null}', kind: 'turn_completed' }
  ])('requests structured output and bounds invalid-result repair: %j', async ({ allowed, second, kind }) => {
    const base = turnStartForTest()
    const turnStart = {
      ...base,
      actor_event: { ...base.actor_event, type: 'cron.fire' },
      request_context: { silent_success_allowed: allowed, schedule_origin: { payload: {} } }
    }
    const sent: JsonObject[] = []
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
            sent.push(payload)
            const index = sent.filter(item => item.type === 'response.create').length
            return [
              {
                type: 'response.completed',
                response: {
                  id: `resp_schedule_${index}`,
                  status: 'completed',
                  output: [
                    {
                      type: 'message',
                      role: 'assistant',
                      content: [{ type: 'output_text', text: index === 1 ? '<sাইলent_success/>' : second }]
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
      messages: [{ role: 'user', content: 'Check delivery status.' }],
      stateful: {
        actorEventID: '00000000-0000-0000-0000-000000000024',
        conversationID: '24242424-2424-2424-2424-242424242424'
      },
      maxModelIterations: 10,
      text: scheduledReplyFormat(),
      repairFinalResponse: message => textTurnReplyRepair(turnStart, assistantText(message)),
      repairTools: [],
      repairHostedTools: [],
      nudgeEmptyAfterTools: false
    })
    const creates = sent.filter(item => item.type === 'response.create')
    expect(creates).toHaveLength(2)
    expect(creates[0]!.text).toMatchObject({
      format: { type: 'json_schema', name: 'scheduled_turn_result', strict: true }
    })
    expect(final.responseID).toBe('resp_schedule_2')
    expect(
      textTurnResultFromAssistantReply(turnStart, assistantText(final.message), final.responseID, final.outcome).kind
    ).toBe(kind)
  })
})
