import { describe, expect, test } from 'bun:test'
import type { ConversationMessage, ConversationStatus } from '../api'
import { ChatModel, mergeMessages, shouldSendOnEnter } from './chat'

const idle: ConversationStatus = {
  state: 'idle',
  retryAt: null,
  activity: {
    conversationID: 'conversation',
    agentUID: 'agent',
    sessionID: 'conversation:conversation',
    signalID: null,
    responseID: null,
    epoch: 0,
    revision: 0,
    state: 'unavailable',
    phase: null,
    tools: []
  }
}
const message = (
  id: string,
  seq: number,
  authorType: ConversationMessage['authorType'] = 'human',
  text = id
): ConversationMessage => ({
  id,
  seq,
  authorType,
  authorUID: authorType === 'human' ? 'person' : 'agent',
  kind: 'message',
  text,
  createdAt: '2026-10-14T00:00:00Z',
  replyToMessageID: null,
  signalID: null
})

describe('Pod message lifecycle', () => {
  test('a failed create retains the exact text and both IDs for retry', () => {
    const model = new ChatModel()
    model.draft.value = '  Hello\n'
    let sequence = 0
    const id = () => `id-${++sequence}`
    const first = model.submit(undefined, 'agent', id)
    model.failed(new Error('Connection lost'))
    expect(model.draft.value).toBe('  Hello\n')
    const retry = model.submit(undefined, 'agent', id)
    expect(retry.conversationID).toBe(first.conversationID)
    expect(retry.messageID).toBe(first.messageID)
    expect(retry.text).toBe(first.text)
    expect(sequence).toBe(2)
    expect(model.error.value).toBeUndefined()
  })

  test('new text or recipient uses a new ID without changing a prior submission', () => {
    const model = new ChatModel()
    let sequence = 0
    const id = () => `id-${++sequence}`
    model.draft.value = 'first'
    const first = model.submit('conversation', 'agent', id)
    model.failed(new Error('Connection lost'))
    model.draft.value = 'second'
    const second = model.submit('conversation', 'agent', id)
    expect(second.messageID).not.toBe(first.messageID)
    expect(first.text).toBe('first')
    model.failed(new Error('Connection lost'))
    const third = model.submit('conversation', 'other-agent', id)
    expect(third.messageID).not.toBe(second.messageID)
  })

  test('SSE confirmation before POST failure clears the draft and does not display failure', () => {
    const model = new ChatModel()
    model.draft.value = 'Hello'
    const submission = model.submit('conversation', 'agent', () => 'message')
    model.reconcile([message(submission.messageID, 1)])
    model.failed(new Error('Response connection lost'))
    expect(model.pending.value).toBeUndefined()
    expect(model.draft.value).toBe('')
    expect(model.error.value).toBeUndefined()
  })

  test('a late confirmation preserves text edited after sending', () => {
    const model = new ChatModel()
    model.draft.value = 'Hello'
    const submission = model.submit('conversation', 'agent', () => 'message')
    model.draft.value = 'Follow-up'
    model.accepted(submission)
    expect(model.draft.value).toBe('Follow-up')
    expect(model.pending.value).toBeUndefined()
  })

  test('new model responses replace the prior partial text; disconnect discards it', () => {
    const model = new ChatModel()
    model.started('response-1', ['signal-1'])
    model.delta('response-1', 'first ', ['signal-1'])
    model.delta('response-1', 'response', ['signal-1'])
    expect(model.live.value?.text).toBe('first response')
    model.started('response-2', ['signal-2'])
    model.delta('response-1', 'late old delta', ['signal-1'])
    model.delta('response-2', 'replacement', ['signal-2'])
    expect(model.live.value).toEqual({ text: 'replacement', responseID: 'response-2', signalIDs: ['signal-2'] })
    model.disconnected()
    expect(model.live.value).toBeUndefined()
    expect(model.connecting.value).toBe(true)
    model.connected()
    expect(model.connecting.value).toBe(false)
    model.delta('response-2', 'resumed tail', ['signal-2'])
    expect(model.live.value?.text).toBe('resumed tail')
  })

  test('a missed started event still displays only subsequently received text and clears on the matching reply', () => {
    const model = new ChatModel()
    model.delta('response-1', 'received tail ', ['signal-1'])
    model.delta('response-1', 'continues', ['signal-1'])
    expect(model.live.value).toEqual({
      responseID: 'response-1',
      signalIDs: ['signal-1'],
      text: 'received tail continues'
    })
    model.reconcile([{ ...message('old reply', 99, 'agent'), signalID: 'old-signal' }])
    expect(model.live.value?.text).toBe('received tail continues')
    model.reconcile([{ ...message('complete reply', 100, 'agent'), signalID: 'signal-1' }])
    expect(model.live.value).toBeUndefined()
  })

  test('committed replies and idle silent turns clear live text; follow-ups retain it', () => {
    const model = new ChatModel()
    model.started('response-1', ['signal-1', 'steer-signal'])
    model.delta('response-1', 'partial', ['signal-1'])
    model.reconcile([message('follow-up', 2)])
    expect(model.live.value?.text).toBe('partial')
    model.reconcile([{ ...message('reply', 3, 'agent'), signalID: 'steer-signal' }])
    expect(model.live.value).toBeUndefined()
    model.started('response-2', ['signal-2'])
    model.delta('response-2', 'silent partial', ['signal-2'])
    model.reconcileStatus('response-2', idle)
    expect(model.live.value).toBeUndefined()
  })

  test('a late prior reply and prior idle result cannot clear a newer Response', () => {
    const model = new ChatModel()
    model.started('response-2', ['signal-2'])
    model.delta('response-2', 'new partial', ['signal-2'])
    model.reconcile([{ ...message('late old reply', 99, 'agent'), signalID: 'signal-1' }])
    model.reconcileStatus('response-1', idle)
    expect(model.live.value?.text).toBe('new partial')
    model.reconcile([])
    expect(model.live.value?.text).toBe('new partial')
  })

  test('terminal removal closes the live state and marks the page unavailable', () => {
    const model = new ChatModel()
    model.started('response-1', ['signal-1'])
    model.delta('response-1', 'private partial', ['signal-1'])
    model.disconnected()
    model.markGone()
    model.started('late-response', ['late-signal'])
    model.delta('late-response', 'late private text', ['late-signal'])
    model.disconnected()
    expect(model.gone.value).toBe(true)
    expect(model.live.value).toBeUndefined()
    expect(model.connecting.value).toBe(false)
  })
})

describe('Pod message view', () => {
  test('pending messages appear once and disappear when their ID is committed', () => {
    const pending = {
      conversationID: 'chat',
      agentUID: 'agent',
      messageID: 'pending',
      text: 'hello',
      state: 'sending' as const
    }
    const committed = [message('previous', 1)]
    expect(mergeMessages(committed, pending, undefined).map(item => item.type)).toEqual(['committed', 'pending'])
    expect(mergeMessages([...committed, message('pending', 2)], pending, undefined).map(item => item.type)).toEqual([
      'committed',
      'committed'
    ])
    expect(committed).toHaveLength(1)
  })

  test('old replies do not hide live text, and a committed new reply does', () => {
    const live = { text: 'new partial', responseID: 'response-2', signalIDs: ['signal-2'] }
    const committed = [{ ...message('old reply', 10, 'agent'), signalID: 'signal-1' }, message('question', 2)]
    expect(mergeMessages(committed, undefined, live).at(-1)).toEqual({ type: 'live', text: 'new partial' })
    expect(
      mergeMessages([...committed, { ...message('new reply', 3, 'agent'), signalID: 'signal-2' }], undefined, live).at(
        -1
      )?.type
    ).toBe('committed')
    expect(mergeMessages(committed, undefined, { ...live, text: '' })).toHaveLength(2)
  })

  test('a committed notice replaces the failed live reply', () => {
    const notice = { ...message('notice', 3, 'system'), kind: 'notice' as const, signalID: 'signal-2' }
    expect(
      mergeMessages([notice], undefined, { text: 'partial', responseID: 'response-2', signalIDs: ['signal-2'] })
    ).toEqual([{ type: 'committed', message: notice }])
  })

  test('Enter sends, while Shift+Enter and IME confirmation do not', () => {
    const enter = { key: 'Enter', shiftKey: false, isComposing: false, keyCode: 13 }
    expect(shouldSendOnEnter(enter)).toBe(true)
    expect(shouldSendOnEnter({ ...enter, shiftKey: true })).toBe(false)
    expect(shouldSendOnEnter({ ...enter, isComposing: true })).toBe(false)
    expect(shouldSendOnEnter({ ...enter, keyCode: 229 })).toBe(false)
    expect(shouldSendOnEnter({ ...enter, key: 'a' })).toBe(false)
  })
})
