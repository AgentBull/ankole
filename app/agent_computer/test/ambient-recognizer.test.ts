import { describe, expect, it } from 'bun:test'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { createModel } from '../src/core/llm'
import {
  recognizeAmbientIntervention,
  resolveAskedBy,
  type TranscriptMessage
} from '../src/core/turns/ambient_recognizer'
import { canonicalAmbientRoute } from '../src/core/turns/ambient_turn'
import type { TurnStart } from '../src/lanes/actor_lane'
import { create } from '@bufbuild/protobuf'
import { AgentConversationContextResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { AgentConversationContextResponse } from '../src/lanes/rpc_lane'
import { turnStartForTest } from './support/llm'

function ambientModel(decision: string, bodies?: JSONObject[]) {
  return createModel({
    apiKey: 'unused',
    baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
    selector: 'light',
    fetch: (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      if (bodies) {
        const request = input instanceof Request ? input : new Request(input, init)
        bodies.push(JSON.parse(await request.text()) as JSONObject)
      }

      return new Response(
        JSON.stringify({
          id: 'resp_ambient_test',
          object: 'response',
          status: 'completed',
          output: [
            {
              type: 'message',
              role: 'assistant',
              content: [{ type: 'output_text', text: decision }]
            }
          ]
        }),
        { status: 200, headers: { 'content-type': 'application/json' } }
      )
    }) as unknown as typeof fetch
  })
}

function ambientTurnStart(data: JSONObject, requestContext?: JSONObject): TurnStart {
  const base = turnStartForTest()
  return {
    ...base,
    ...(requestContext ? { request_context: requestContext } : {}),
    actor_event: {
      ...base.actor_event,
      type: 'im.message.may_intervene',
      payload_json: { data }
    }
  } as TurnStart
}

function ambientContext(): AgentConversationContextResponse {
  return create(AgentConversationContextResponseSchema, {
    agent: { displayName: 'Ops Agent' },
    conversation: { timezone: 'UTC' }
  })
}

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
                    text: '{"action":"NOOP","authority":"NONE","handoff_job_id":null,"asked_by":null,"reason":"quiet"}'
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
            channel: { id: 'lark:chat:ops', kind: 'im_group' },
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
      conversation: {
        timezone: 'Asia/Singapore',
        originChannel: { adapter: 'lark', kind: 'im_group', label: 'Ops' }
      },
      soul: 'Be calm and exact.',
      mission: 'Help the group make sound decisions.'
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

    const modelInput = JSON.stringify(bodies[0]!.input)

    expect(modelInput).toContain('current_time: 2026-07-18 20:34')
    expect(modelInput).toContain('platform: Lark / Feishu')
    expect(modelInput).toContain('group_name: Ops')
    expect(modelInput).toContain('20:00 [human] Unknown')
    expect(modelInput).not.toContain('019f0000-0000-7000-8000-000000000041')
  })

  it('renders standing orders, backdrop, id tags, and unreplied pressure', async () => {
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
            id: 'resp_ambient_asked',
            object: 'response',
            status: 'completed',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [
                  {
                    type: 'output_text',
                    text: '{"action":"FOREGROUND_REPLY","authority":"NONE","handoff_job_id":null,"asked_by":"msg-2","reason":"Bob is asking the agent"}'
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
          time: '2026-07-18T12:00:00Z',
          data: {
            channel: {
              id: 'lark:chat:ops',
              kind: 'im_group',
              standing_orders: 'Only speak when CI turns red.'
            },
            backdrop_messages: [
              {
                signal_channel_id: 'lark:chat:ops',
                source_entry_id: 'msg-0',
                sent_at: '2026-07-18T11:00:00Z',
                speaker: 'Alice',
                role: 'human',
                text: 'Yesterday the deploy went fine.'
              }
            ],
            observed_messages: [
              {
                signal_channel_id: 'lark:chat:ops',
                source_entry_id: 'msg-2',
                sent_at: '2026-07-18T12:00:00Z',
                speaker: 'Bob',
                role: 'human',
                text: 'Bot, is CI red right now?'
              }
            ],
            unreplied_messages: [{ source_entry_id: 'msg-2', text: 'Bot, is CI red right now?' }]
          }
        }
      }
    } as TurnStart

    const context: AgentConversationContextResponse = create(AgentConversationContextResponseSchema, {
      agent: { displayName: 'Ops Agent' },
      conversation: { timezone: 'UTC', originChannel: { adapter: 'lark', kind: 'im_group', label: 'Ops' } },
      soul: '',
      mission: ''
    })

    const result = await recognizeAmbientIntervention(
      { turnStart, model, historyMessages: [], agentConversationContext: context },
      { currentTime: new Date('2026-07-18T12:05:00Z') }
    )

    const modelInput = JSON.stringify(bodies[0]!.input)
    expect(modelInput).toContain('Only speak when CI turns red.')
    expect(modelInput).toContain('Yesterday the deploy went fine.')
    expect(modelInput).toContain('[id:msg-2]')
    expect(modelInput).not.toContain('[id:msg-0]')

    expect(result.decision.action).toBe('FOREGROUND_REPLY')
    expect(result.decision.authority).toBe('NONE')
    expect(result.decision.askedBy).toEqual({
      state: 'accepted',
      sourceEntryID: 'msg-2',
      speaker: 'Bob',
      text: 'Bot, is CI red right now?'
    })
  })

  it('routes an update only to an exact control-plane candidate', async () => {
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
            id: 'resp_ambient_handoff',
            object: 'response',
            status: 'completed',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [
                  {
                    type: 'output_text',
                    text: '{"action":"HANDOFF","authority":"NONE","handoff_job_id":"1001","asked_by":null,"reason":"The log updates the deploy investigation."}'
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
      request_context: {
        ambient_work_candidates: {
          complete: true,
          jobs: [
            {
              job_id: '1001',
              title: 'Investigate deploy failure',
              status: 'running',
              task_excerpt: 'Find the cause of the failed production deploy.'
            }
          ]
        }
      },
      actor_event: {
        ...base.actor_event,
        type: 'im.message.may_intervene',
        payload_json: {
          data: {
            observed_messages: [
              {
                signal_channel_id: 'lark:chat:ops',
                source_entry_id: 'msg-log',
                sent_at: '2026-07-18T12:00:00Z',
                speaker: 'Alice',
                role: 'human',
                text: 'The failed pod says database timeout.'
              }
            ]
          }
        }
      }
    } as TurnStart

    const context: AgentConversationContextResponse = create(AgentConversationContextResponseSchema, {
      agent: { displayName: 'Ops Agent' },
      conversation: { timezone: 'UTC', originChannel: { adapter: 'lark', kind: 'im_group', label: 'Ops' } }
    })

    const result = await recognizeAmbientIntervention(
      { turnStart, model, historyMessages: [], agentConversationContext: context },
      { currentTime: new Date('2026-07-18T12:05:00Z') }
    )

    expect(result.decision).toMatchObject({
      action: 'HANDOFF',
      authority: 'NONE',
      handoffJobID: '1001',
      askedBy: { state: 'none' }
    })

    const request = bodies[0]!
    expect(JSON.stringify(request.input)).toContain('Investigate deploy failure')
    expect(JSON.stringify(request.text)).toContain('1001')
  })

  it('fails closed when HANDOFF names a job outside the candidate set', async () => {
    const model = createModel({
      apiKey: 'unused',
      baseURL: 'http://aigateway.invalid/api/v1/ai-gateway',
      selector: 'light',
      fetch: (async () =>
        new Response(
          JSON.stringify({
            id: 'resp_ambient_invalid_handoff',
            object: 'response',
            status: 'completed',
            output: [
              {
                type: 'message',
                role: 'assistant',
                content: [
                  {
                    type: 'output_text',
                    text: '{"action":"HANDOFF","authority":"NONE","handoff_job_id":"9999","asked_by":null,"reason":"update"}'
                  }
                ]
              }
            ]
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        )) as unknown as typeof fetch
    })

    const base = turnStartForTest()
    const turnStart = {
      ...base,
      request_context: {
        ambient_work_candidates: {
          complete: true,
          jobs: [{ job_id: '1001', title: 'Known job', status: 'running' }]
        }
      },
      actor_event: {
        ...base.actor_event,
        type: 'im.message.may_intervene',
        payload_json: {
          data: {
            observed_messages: [
              {
                source_entry_id: 'msg-1',
                sent_at: '2026-07-18T12:00:00Z',
                speaker: 'Alice',
                role: 'human',
                text: 'new evidence'
              }
            ]
          }
        }
      }
    } as TurnStart
    const context: AgentConversationContextResponse = create(AgentConversationContextResponseSchema, {
      agent: { displayName: 'Ops Agent' },
      conversation: { timezone: 'UTC' }
    })

    const result = await recognizeAmbientIntervention(
      { turnStart, model, historyMessages: [], agentConversationContext: context },
      { currentTime: new Date('2026-07-18T12:05:00Z') }
    )

    expect(result.decision).toMatchObject({ action: 'NOOP', authority: 'NONE' })
    expect(result.decision.handoffJobID).toBeUndefined()
  })

  it('enforces the dynamic structured route schema', async () => {
    const bodies: JSONObject[] = []
    const turnStart = ambientTurnStart({
      observed_messages: [
        {
          source_entry_id: 'msg-1',
          sent_at: '2026-07-18T12:00:00Z',
          speaker: 'Alice',
          role: 'human',
          text: 'Please investigate the deploy.'
        }
      ]
    })

    const unavailableAuthority = await recognizeAmbientIntervention(
      {
        turnStart,
        model: ambientModel(
          '{"action":"NEW_WORK","authority":"STANDING_ORDER","handoff_job_id":null,"asked_by":null,"reason":"Start work."}',
          bodies
        ),
        historyMessages: [],
        agentConversationContext: ambientContext()
      },
      { currentTime: new Date('2026-07-18T12:05:00Z') }
    )

    expect(unavailableAuthority.decision).toMatchObject({
      action: 'NOOP',
      authority: 'NONE',
      reason: 'The structured ambient route was invalid, so the Agent stayed silent.'
    })
    expect(JSON.stringify(bodies[0]!.text)).not.toContain('"STANDING_ORDER"')
    expect(JSON.stringify(bodies[0]!.text)).toContain('"minLength":1')
    expect(JSON.stringify(bodies[0]!.text)).toContain('"maxLength":300')

    const unknownField = await recognizeAmbientIntervention(
      {
        turnStart,
        model: ambientModel(
          '{"action":"NOOP","authority":"NONE","handoff_job_id":null,"asked_by":null,"reason":"Stay quiet.","unexpected":true}'
        ),
        historyMessages: [],
        agentConversationContext: ambientContext()
      },
      { currentTime: new Date('2026-07-18T12:05:00Z') }
    )

    expect(unknownField.decision.reason).toBe('The structured ambient route was invalid, so the Agent stayed silent.')

    const blankReason = await recognizeAmbientIntervention(
      {
        turnStart,
        model: ambientModel(
          '{"action":"NOOP","authority":"NONE","handoff_job_id":null,"asked_by":null,"reason":"   "}'
        ),
        historyMessages: [],
        agentConversationContext: ambientContext()
      },
      { currentTime: new Date('2026-07-18T12:05:00Z') }
    )

    expect(blankReason.decision.reason).toBe('The structured ambient route was invalid, so the Agent stayed silent.')
  })

  it('discards authority that a provider attaches to a bounded reply', async () => {
    const turnStart = ambientTurnStart({
      observed_messages: [
        {
          source_entry_id: 'msg-1',
          sent_at: '2026-07-18T12:00:00Z',
          speaker: 'Alice',
          role: 'human',
          text: 'What is 17 times 19?'
        }
      ]
    })

    const result = await recognizeAmbientIntervention(
      {
        turnStart,
        model: ambientModel(
          '{"action":"FOREGROUND_REPLY","authority":"EXPLICIT_REQUEST","handoff_job_id":null,"asked_by":"msg-1","reason":"Alice asked a bounded question."}'
        ),
        historyMessages: [],
        agentConversationContext: ambientContext()
      },
      { currentTime: new Date('2026-07-18T12:05:00Z') }
    )

    expect(result.decision).toMatchObject({
      action: 'FOREGROUND_REPLY',
      authority: 'NONE',
      reason: 'Alice asked a bounded question.',
      askedBy: {
        state: 'accepted',
        sourceEntryID: 'msg-1',
        speaker: 'Alice',
        text: 'What is 17 times 19?'
      }
    })
  })

  it('removes explicit authority when the attributed speaker is no longer latest', async () => {
    const turnStart = ambientTurnStart({
      observed_messages: [
        {
          source_entry_id: 'msg-1',
          sent_at: '2026-07-18T12:00:00Z',
          speaker: 'Alice',
          role: 'human',
          text: 'Bot, investigate the deploy.'
        },
        {
          source_entry_id: 'msg-2',
          sent_at: '2026-07-18T12:01:00Z',
          speaker: 'Bob',
          role: 'human',
          text: 'We are moving on to lunch.'
        }
      ]
    })

    const result = await recognizeAmbientIntervention(
      {
        turnStart,
        model: ambientModel(
          '{"action":"NEW_WORK","authority":"EXPLICIT_REQUEST","handoff_job_id":null,"asked_by":"msg-1","reason":"Alice asked for the work."}'
        ),
        historyMessages: [],
        agentConversationContext: ambientContext()
      },
      { currentTime: new Date('2026-07-18T12:05:00Z') }
    )

    expect(result.decision).toEqual({
      action: 'NEW_WORK',
      authority: 'NONE',
      reason: 'The proposed authorization source was not present in the current ambient observation.',
      askedBy: { state: 'degraded', sourceEntryID: 'msg-1' }
    })
  })

  it('keeps incomplete payload candidates as context but disables HANDOFF', async () => {
    const bodies: JSONObject[] = []
    const turnStart = ambientTurnStart(
      {
        unreplied_messages: [
          {
            source_entry_id: 'msg-1',
            sent_at: '2026-07-18T12:00:00Z',
            speaker: 'Alice',
            role: 'human',
            text: 'The failed pod says database timeout.'
          }
        ]
      },
      {
        ambient_work_candidates: {
          complete: true,
          jobs: [{ job_id: '1001', title: 'Investigate deploy failure', status: 'running' }]
        }
      }
    )

    const result = await recognizeAmbientIntervention(
      {
        turnStart,
        model: ambientModel(
          '{"action":"HANDOFF","authority":"NONE","handoff_job_id":"1001","asked_by":null,"reason":"Update the existing work."}',
          bodies
        ),
        historyMessages: [],
        agentConversationContext: ambientContext()
      },
      { currentTime: new Date('2026-07-18T12:05:00Z') }
    )

    expect(result.decision).toMatchObject({ action: 'NOOP', authority: 'NONE' })
    expect(JSON.stringify(bodies[0]!.input)).toContain(
      'The list is incomplete; HANDOFF is unavailable. Use these rows only to avoid duplicating known work.'
    )
    expect(JSON.stringify(bodies[0]!.input)).toContain('Investigate deploy failure')
    expect(JSON.stringify(bodies[0]!.text)).not.toContain('"HANDOFF"')
  })
})

describe('canonicalAmbientRoute', () => {
  it('requires a canonical action and authority pair from the control plane', () => {
    expect(canonicalAmbientRoute({ status: 'ok', action: 'FOREGROUND_REPLY', authority: 'NONE' })).toEqual({
      action: 'FOREGROUND_REPLY',
      authority: 'NONE'
    })

    expect(() => canonicalAmbientRoute({ status: 'ok', action: 'HANDOFF' })).toThrow(
      'ambient judgment response is missing a canonical action or authority'
    )
    expect(() => canonicalAmbientRoute({ status: 'ok', action: 'NOOP', authority: 'EXPLICIT_REQUEST' })).toThrow(
      'ambient judgment response returned authority for a non-NEW_WORK action'
    )
    expect(canonicalAmbientRoute({ status: 'ok', action: 'HANDOFF', authority: 'NONE' })).toEqual({
      action: 'HANDOFF',
      authority: 'NONE'
    })
  })
})

describe('resolveAskedBy', () => {
  const message = (overrides: Partial<TranscriptMessage>): TranscriptMessage => ({
    index: 0,
    key: 'key',
    role: 'human',
    sortTime: 0,
    speaker: 'Alice',
    text: 'hello',
    time: '12:00',
    ...overrides
  })

  it('accepts the newest human speaker and tolerates an echoed id tag', () => {
    const delta = [message({ sourceEntryID: 'msg-1', speaker: 'Alice', text: 'Bot, help?' })]
    expect(resolveAskedBy('[id:msg-1]', delta)).toEqual({
      state: 'accepted',
      sourceEntryID: 'msg-1',
      speaker: 'Alice',
      text: 'Bot, help?'
    })
  })

  it('returns none without a proposal', () => {
    expect(resolveAskedBy(undefined, [])).toEqual({ state: 'none' })
    expect(resolveAskedBy('   ', [])).toEqual({ state: 'none' })
  })

  it('degrades an id outside the judged batch', () => {
    const delta = [message({ sourceEntryID: 'msg-1' })]
    expect(resolveAskedBy('msg-404', delta)).toEqual({ state: 'degraded', sourceEntryID: 'msg-404' })
  })

  it('degrades an agent-authored id', () => {
    const delta = [message({ sourceEntryID: 'msg-1', role: 'agent' })]
    expect(resolveAskedBy('msg-1', delta)).toEqual({ state: 'degraded', sourceEntryID: 'msg-1' })
  })

  it('degrades an ask whose author is no longer the latest human speaker', () => {
    const delta = [
      message({ index: 0, key: 'a', sourceEntryID: 'msg-1', speaker: 'Alice', text: 'Bot, help?' }),
      message({ index: 1, key: 'b', sourceEntryID: 'msg-2', speaker: 'Bob', text: 'moving on to lunch' })
    ]
    expect(resolveAskedBy('msg-1', delta)).toEqual({ state: 'degraded', sourceEntryID: 'msg-1' })
  })

  it('accepts an older message of the still-latest speaker', () => {
    const delta = [
      message({ index: 0, key: 'a', sourceEntryID: 'msg-1', speaker: 'Alice', text: 'Bot, can you check CI?' }),
      message({ index: 1, key: 'b', sourceEntryID: 'msg-2', speaker: 'Alice', text: 'it looks red to me' })
    ]
    expect(resolveAskedBy('msg-1', delta)).toEqual({
      state: 'accepted',
      sourceEntryID: 'msg-1',
      speaker: 'Alice',
      text: 'Bot, can you check CI?'
    })
  })
})
