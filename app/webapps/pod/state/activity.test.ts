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
    expect(model.activity.value?.phase?.label_key).toEndWith('computer_busy')
    model.disconnected()
    expect(model.activity.value).toBeUndefined()
    model.connected()
    model.observeActivity(activity())
    expect(model.activity.value?.phase?.label_key).toEndWith('computer_busy')
  })

  test('older epoch or revision cannot replace newer work; a settled epoch cannot reopen', () => {
    const model = new ChatModel()
    model.observeActivity(activity({ epoch: 3, revision: 7 }))
    model.observeActivity(activity({ epoch: 2, revision: 99 }))
    model.observeActivity(activity({ epoch: 3, revision: 6, responseID: 'old-response' }))
    expect(model.activity.value?.revision).toBe(7)
    model.observeActivity(activity({ epoch: 3, revision: 8, state: 'settled', phase: null }))
    model.observeActivity(activity({ epoch: 3, revision: 99 }))
    expect(model.activity.value).toBeUndefined()
    model.observeActivity(activity({ epoch: 4, revision: 1, signalID: 'new-signal' }))
    model.observeActivity(activity({ epoch: 3, state: 'settled' }))
    expect(model.activity.value?.signalID).toBe('new-signal')
  })

  test('diagnostic unavailability clears the display without lowering its revision barrier', () => {
    const model = new ChatModel()
    model.observeActivity(activity({ epoch: 3, revision: 7 }))
    const oldRead = model.activityRead()
    model.observeActivity(activity({ epoch: 3, revision: 0, state: 'unavailable' }))
    expect(model.activity.value).toBeUndefined()
    model.observeActivity(activity({ epoch: 3, revision: 7 }))
    expect(model.activity.value).toBeUndefined()
    model.observeActivity(activity({ epoch: 3, revision: 7 }), oldRead)
    expect(model.activity.value).toBeUndefined()
    model.observeActivity(activity({ epoch: 3, revision: 7 }), model.activityRead())
    expect(model.activity.value?.revision).toBe(7)
    model.observeActivity(activity({ epoch: 3, revision: 8 }))
    expect(model.activity.value?.revision).toBe(8)
    model.observeActivity(activity({ epoch: 0, revision: 0, state: 'unavailable' }))
    expect(model.activity.value).toBeUndefined()
    model.observeActivity(activity({ epoch: 3, revision: 7 }))
    expect(model.activity.value).toBeUndefined()
  })

  test('parallel tools remain independent and terminal or unavailable snapshots clear them', () => {
    const model = new ChatModel()
    const tools = [
      { operation_id: 'one', label: 'Read' },
      { operation_id: 'two', label: 'Search' }
    ]
    model.observeActivity(activity({ tools }))
    expect(model.activity.value?.tools).toHaveLength(2)
    model.observeActivity(activity({ revision: 2, tools: [tools[1]!] }))
    expect(model.activity.value?.tools.map(tool => tool.operation_id)).toEqual(['two'])
    model.observeActivity(activity({ revision: 3, state: 'unavailable', phase: null, tools: [] }))
    expect(model.activity.value).toBeUndefined()
    model.markGone()
    model.observeActivity(activity({ epoch: 2 }))
    expect(model.activity.value).toBeUndefined()
  })
})
