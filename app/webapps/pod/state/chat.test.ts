import { describe, expect, test } from 'bun:test'
import { InternalAPIError } from '../../common/internal-api-client'
import type { ConversationMessage, ConversationStatus } from '../api'
import { ChatModel, chatCommandPolicy, mergeMessages, shouldSendOnEnter } from './chat'

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
  links: [],
  attachments: [],
  text,
  createdAt: '2026-10-14T00:00:00Z',
  replyToMessageID: null,
  signalID: null
})

test('composer, retry and message actions share command eligibility without blocking stop during model selection', () => {
  const ready = {
    sending: false,
    queuePending: false,
    modelSaving: false,
    available: true,
    working: false,
    hasQueued: false,
    hasSubmission: true
  }
  expect(chatCommandPolicy(ready).canSubmit).toBe(true)
  for (const state of [{ sending: true }, { queuePending: true }, { available: false }]) {
    const policy = chatCommandPolicy({ ...ready, ...state })
    expect(policy.canSubmit).toBe(false)
    expect(policy.canRetryLast).toBe(false)
    for (const action of ['edit', 'edit_last', 'regenerate', 'stop', 'resume'] as const) {
      expect(policy.canQueue(action)).toBe(false)
    }
  }
  const saving = chatCommandPolicy({ ...ready, modelSaving: true })
  expect(saving.canSubmit).toBe(false)
  expect(saving.canQueue('edit_last')).toBe(false)
  expect(saving.canQueue('regenerate')).toBe(false)
  expect(saving.canQueue('stop')).toBe(true)
  expect(saving.canQueue('edit')).toBe(true)
  expect(chatCommandPolicy({ ...ready, working: true }).canRetryLast).toBe(false)
  expect(chatCommandPolicy({ ...ready, hasQueued: true }).canRetryLast).toBe(false)
  expect(chatCommandPolicy({ ...ready, hasSubmission: false }).canSubmit).toBe(false)
})

test('edit commands keep the captured queue version and retry ID until deliberate conflict recovery', () => {
  const model = new ChatModel()
  model.draft.value = 'Unsent follow-up'
  model.beginEdit('message', 'Saved', 'v1', 'last')
  model.draft.value = 'Edited'
  const first = model.editCommand()!
  expect(first).toMatchObject({
    action: 'edit_last',
    messageID: 'message',
    text: 'Edited',
    expectedVersion: 'v1',
    expectedText: 'Saved'
  })
  expect(model.editCommand()).toEqual(first)
  expect(model.rebaseEdit('message', 'Remote edit', 'v2')).toBe(false)
  expect(model.editCommand()).toEqual(first)
  model.rebaseEdit('message', 'Remote edit', 'v2', true)
  const recovered = model.editCommand()!
  expect(recovered).toMatchObject({ text: 'Remote edit', expectedVersion: 'v2', expectedText: 'Remote edit' })
  expect(recovered.commandID).not.toBe(first.commandID)
  model.editSaved('message', 'Remote edit')
  expect(model.draft.value).toBe('Unsent follow-up')
  expect(model.editCommand()).toBeUndefined()
  model.beginEdit('queued', 'Queued', 'q1')
  expect(model.editCommand()).toEqual({ action: 'edit', messageID: 'queued', text: 'Queued', expectedVersion: 'q1' })
})

describe('Pod message lifecycle', () => {
  test('a failed create retains the exact text and both IDs for retry', () => {
    const model = new ChatModel()
    model.draft.value = '  Hello\n'
    let sequence = 0
    const id = () => `id-${++sequence}`
    const first = model.submit(undefined, 'agent', id)
    model.failed(new Error('Connection lost'), first.messageID)
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
    model.failed(new Error('Connection lost'), first.messageID)
    model.draft.value = 'second'
    const second = model.submit('conversation', 'agent', id)
    expect(second.messageID).not.toBe(first.messageID)
    expect(first.text).toBe('first')
    model.failed(new Error('Connection lost'), second.messageID)
    const third = model.submit('conversation', 'other-agent', id)
    expect(third.messageID).not.toBe(second.messageID)
  })

  test('SSE confirmation before POST failure clears the draft and does not display failure', () => {
    const model = new ChatModel()
    model.draft.value = 'Hello'
    const submission = model.submit('conversation', 'agent', () => 'message')
    model.reconcile([message(submission.messageID, 1)])
    model.failed(new Error('Response connection lost'), submission.messageID)
    expect(model.pending.value).toBeUndefined()
    expect(model.draft.value).toBe('')
    expect(model.error.value).toBeUndefined()
  })

  test('a prior request cannot fail or clear a newer submission after remote confirmation', () => {
    const model = new ChatModel()
    let sequence = 0
    const id = () => `id-${++sequence}`
    model.draft.value = 'Same text'
    const first = model.submit(undefined, 'agent', id)
    model.reconcile([message(first.messageID, 1)])
    model.draft.value = first.text
    model.attachments.files.value = [
      {
        id: 'new-file',
        file: new File(['new'], 'new.txt'),
        url: 'blob:new',
        state: 'ready',
        receipt: 'new-receipt'
      }
    ]
    const second = model.submit(first.conversationID, 'agent', id)
    const lateFailure = new InternalAPIError(422, 'Expired', { error: 'attachment_expired' })
    model.failed(lateFailure, first.messageID)
    expect(model.pending.value).toMatchObject({ messageID: second.messageID, state: 'sending' })
    expect(model.error.value).toBeUndefined()
    expect(model.attachments.files.value[0]).toMatchObject({ state: 'ready', receipt: 'new-receipt' })
    const secondFailure = new Error('Second response lost')
    model.failed(secondFailure, second.messageID)
    model.accepted(first)
    expect(model.pending.value).toMatchObject({ messageID: second.messageID, state: 'failed' })
    expect(model.error.value).toBe(secondFailure)
    expect(model.draft.value).toBe(second.text)
    expect(model.attachments.capture()).toEqual({ attachments: ['new-receipt'], attachmentIDs: ['new-file'] })
    expect(model.submit(first.conversationID, 'agent', id)).toMatchObject({ messageID: second.messageID })
    model.attachments.dispose()
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
    expect(shouldSendOnEnter({ ...enter, shiftKey: true, ctrlKey: true })).toBe(true)
    expect(shouldSendOnEnter({ ...enter, shiftKey: true, metaKey: true })).toBe(true)
    expect(shouldSendOnEnter({ ...enter, shiftKey: true, metaKey: true, isComposing: true })).toBe(false)
    expect(shouldSendOnEnter({ ...enter, shiftKey: true, ctrlKey: true, keyCode: 229 })).toBe(false)
  })

  test('changing follow-up mode cannot reuse a failed submission under different delivery semantics', () => {
    const model = new ChatModel()
    model.draft.value = 'Apply this after the current reply'
    let sequence = 0
    const id = () => `id-${++sequence}`
    const queued = model.submit('conversation', 'agent', id, 'queue')
    model.failed(new Error('Lost connection'), queued.messageID)
    const retry = model.submit('conversation', 'agent', id, 'queue')
    expect(retry.messageID).toBe(queued.messageID)
    model.failed(new Error('Lost connection'), queued.messageID)
    const steer = model.submit('conversation', 'agent', id, 'steer')
    expect(steer.messageID).not.toBe(queued.messageID)
    expect(queued.deliveryMode).toBe('queue')
    expect(steer.deliveryMode).toBe('steer')
  })

  test('editing remote queued text captures its version and restores the independent composer draft', () => {
    const model = new ChatModel()
    model.draft.value = 'Independent next request'
    model.beginEdit('first', 'First saved message', 'queue-version-a')
    model.draft.value = 'Locally edited first message'
    model.beginEdit('second', 'Second saved message', 'queue-version-b')
    expect(model.editing.value).toEqual({
      messageID: 'second',
      previousDraft: 'Independent next request',
      queueVersion: 'queue-version-b',
      kind: 'queue',
      originalText: 'Second saved message',
      hasAttachments: false
    })
    model.editSaved('first', 'Locally edited first message')
    expect(model.draft.value).toBe('Second saved message')
    model.editSaved('second', 'Second saved message')
    expect(model.editing.value).toBeUndefined()
    expect(model.draft.value).toBe('Independent next request')
  })

  test('an edit acknowledgement cannot discard text typed after the edit was submitted', () => {
    const model = new ChatModel()
    model.beginEdit('queued', 'Saved text', 'version')
    model.draft.value = 'Submitted edit'
    model.draft.value = 'New local text'
    model.editSaved('queued', 'Submitted edit')
    expect(model.draft.value).toBe('New local text')
    expect(model.editing.value?.messageID).toBe('queued')
  })

  test('explicit refresh rebases an unrelated queue change while preserving the local edit and independent draft', () => {
    const model = new ChatModel()
    model.draft.value = 'Independent next request'
    model.beginEdit('queued', 'Original saved message', 'old-version')
    model.draft.value = 'My edited message'
    expect(model.rebaseEdit('queued', 'Original saved message', 'fresh-version')).toBe(true)
    expect(model.editing.value?.queueVersion).toBe('fresh-version')
    expect(model.draft.value).toBe('My edited message')
    model.cancelEdit()
    expect(model.draft.value).toBe('Independent next request')
  })

  test('refresh cannot overwrite a collaborator edit; loading the displayed saved version is explicit', () => {
    const model = new ChatModel()
    model.beginEdit('queued', 'Original saved message', 'old-version', 'last')
    const firstCommand = model.editing.value?.commandID
    model.draft.value = 'My unsaved changes'
    expect(model.rebaseEdit('queued', 'Saved by another tab', 'fresh-version')).toBe(false)
    expect(model.draft.value).toBe('My unsaved changes')
    expect(model.editing.value?.queueVersion).toBe('old-version')
    expect(model.rebaseEdit('queued', 'Saved by another tab', 'fresh-version', true)).toBe(true)
    expect(model.draft.value).toBe('Saved by another tab')
    expect(model.editing.value?.queueVersion).toBe('fresh-version')
    expect(model.editing.value?.commandID).not.toBe(firstCommand)
  })
})
