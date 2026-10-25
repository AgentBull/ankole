import { describe, expect, test } from 'bun:test'
import type { PodActivity } from '../api'
import { ChatModel } from './chat'

export const activity = (changes: Partial<PodActivity> = {}): PodActivity => ({
  conversationID: 'conversation',
  agentUID: 'agent',
  sessionID: 'conversation:conversation',
  signalID: 'signal',
  responseID: 'response',
  epoch: 1,
  revision: 1,
  state: 'active',
  phase: { operation_id: 'turn', label_key: 'conversations.delivery.reply.activity.computer_busy' },
  tools: [],
  ...changes
})

describe('current Pod activity', () => {
  test('late snapshot restores the current wait and reconnect can restore the same revision', () => {
    const model = new ChatModel()
    model.observeActivity(activity())
    expect(model.activities.value.agent?.phase?.label_key).toEndWith('computer_busy')
    model.disconnected()
    expect(model.activities.value.agent).toBeUndefined()
    model.connected()
    model.observeActivity(activity())
    expect(model.activities.value.agent?.phase?.label_key).toEndWith('computer_busy')
  })

  test('older epoch or revision cannot replace newer work; a settled epoch cannot reopen', () => {
    const model = new ChatModel()
    model.observeActivity(activity({ epoch: 3, revision: 7 }))
    model.observeActivity(activity({ epoch: 2, revision: 99 }))
    model.observeActivity(activity({ epoch: 3, revision: 6, responseID: 'old-response' }))
    expect(model.activities.value.agent?.revision).toBe(7)
    model.observeActivity(activity({ epoch: 3, revision: 8, state: 'settled', phase: null }))
    model.observeActivity(activity({ epoch: 3, revision: 99 }))
    expect(model.activities.value.agent).toMatchObject({ state: 'settled', revision: 8 })
    model.observeActivity(activity({ epoch: 4, revision: 1, signalID: 'new-signal' }))
    model.observeActivity(activity({ epoch: 3, state: 'settled' }))
    expect(model.activities.value.agent?.signalID).toBe('new-signal')
  })

  test('diagnostic unavailability clears the display without lowering its revision barrier', () => {
    const model = new ChatModel()
    model.observeActivity(activity({ epoch: 3, revision: 7 }))
    const oldRead = model.activityRead()
    model.observeActivity(activity({ epoch: 3, revision: 0, state: 'unavailable' }))
    expect(model.activities.value.agent?.state).toBe('unavailable')
    model.observeActivity(activity({ epoch: 3, revision: 7 }))
    expect(model.activities.value.agent?.state).toBe('unavailable')
    model.observeActivity(activity({ epoch: 3, revision: 7 }), oldRead)
    expect(model.activities.value.agent?.state).toBe('unavailable')
    model.observeActivity(activity({ epoch: 3, revision: 7 }), model.activityRead())
    expect(model.activities.value.agent?.revision).toBe(7)
    model.observeActivity(activity({ epoch: 3, revision: 8 }))
    expect(model.activities.value.agent?.revision).toBe(8)
    model.observeActivity(activity({ epoch: 0, revision: 0, state: 'unavailable' }))
    expect(model.activities.value.agent?.state).toBe('unavailable')
    model.observeActivity(activity({ epoch: 3, revision: 7 }))
    expect(model.activities.value.agent?.state).toBe('unavailable')
  })

  test('parallel tools remain independent and terminal or unavailable snapshots clear them', () => {
    const model = new ChatModel()
    const tools = [
      { operation_id: 'one', label: 'Read' },
      { operation_id: 'two', label: 'Search' }
    ]
    model.observeActivity(activity({ tools }))
    expect(model.activities.value.agent?.tools).toHaveLength(2)
    model.observeActivity(activity({ revision: 2, tools: [tools[1]!] }))
    expect(model.activities.value.agent?.tools.map(tool => tool.operation_id)).toEqual(['two'])
    model.observeActivity(activity({ revision: 3, state: 'unavailable', phase: null, tools: [] }))
    expect(model.activities.value.agent?.state).toBe('unavailable')
    model.markGone()
    model.observeActivity(activity({ epoch: 2 }))
    expect(model.activities.value.agent).toBeUndefined()
  })
})

test('Agent activity ordering is independent and reconnect keeps each revision barrier', () => {
  const model = new ChatModel()
  model.observeActivity(activity({ agentUID: 'a', epoch: 8, revision: 10 }))
  model.observeActivity(activity({ agentUID: 'b', epoch: 1, revision: 1 }))
  expect(Object.keys(model.activities.value)).toEqual(['a', 'b'])
  model.disconnected()
  model.connected()
  model.observeActivity(activity({ agentUID: 'a', epoch: 7, revision: 99 }))
  expect(model.activities.value.a).toBeUndefined()
  model.observeActivity(activity({ agentUID: 'a', epoch: 8, revision: 11 }))
  expect(model.activities.value.a?.revision).toBe(11)
  model.observeActivity(activity({ agentUID: 'b', epoch: 1, revision: 2 }))
  expect(model.activities.value.b?.revision).toBe(2)
})
