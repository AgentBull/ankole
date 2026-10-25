import { describe, expect, test } from 'bun:test'
import { InternalAPIError } from '../../common/internal-api-client'
import type { ConversationDetail, ConversationMessage, ConversationPendingInput } from '../api'
import {
  ChatModel,
  chatCommandPolicy,
  chatRecipientAvailable,
  mergeMessages,
  shouldSendOnEnter,
  type ChatEditSnapshot
} from './chat'

function editSnapshot(
  text: string,
  links: ChatEditSnapshot['links'] = [],
  mentions: ChatEditSnapshot['mentions'] = []
): ChatEditSnapshot {
  return { text, links, mentions }
}
function editContext(
  messageID: string,
  text: string,
  queueVersion: string,
  changes: Partial<Parameters<InstanceType<typeof ChatModel>['beginEdit']>[0]> = {}
): Parameters<InstanceType<typeof ChatModel>['beginEdit']>[0] {
  return {
    messageID,
    ...editSnapshot(text),
    queueVersion,
    kind: 'queue',
    hasAttachments: false,
    agentUID: 'agent',
    ...changes
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
  authorDisplayName: authorType,
  authorArchived: false,
  mentions: [],
  savedPages: [],
  authorUID: authorType === 'human' ? 'person' : 'agent',
  kind: 'message',
  links: [],
  attachments: [],
  text,
  createdAt: '2026-10-14T00:00:00Z',
  replyToMessageID: null,
  signalID: null
})

test('an explicit recipient must remain a callable active member while team discussion stays selectable', () => {
  const members = [{ uid: 'agent', active: true }]
  expect(chatRecipientAvailable('agent', members, ['agent'])).toBe(true)
  expect(chatRecipientAvailable('agent', [], ['agent'])).toBe(false)
  expect(chatRecipientAvailable('agent', members, [])).toBe(false)
  expect(chatRecipientAvailable('agent', [{ uid: 'agent', active: false }], ['agent'])).toBe(false)
  expect(chatRecipientAvailable('', [], [])).toBe(true)
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
  model.beginEdit(editContext('message', 'Saved', 'v1', { kind: 'last' }))
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
  expect(model.rebaseEdit('message', editSnapshot('Remote edit'), 'v2')).toBe(false)
  expect(model.editCommand()).toEqual(first)
  model.rebaseEdit('message', editSnapshot('Remote edit'), 'v2', true)
  const recovered = model.editCommand()!
  expect(recovered).toMatchObject({ text: 'Remote edit', expectedVersion: 'v2', expectedText: 'Remote edit' })
  expect(recovered.commandID).not.toBe(first.commandID)
  model.editSaved('message', 'Remote edit')
  expect(model.draft.value).toBe('Unsent follow-up')
  expect(model.editCommand()).toBeUndefined()
  model.beginEdit(editContext('queued', 'Queued', 'q1'))
  expect(model.editCommand()).toEqual({
    action: 'edit',
    agentUID: 'agent',
    messageID: 'queued',
    text: 'Queued',
    links: [],
    mentions: [],
    expectedVersion: 'q1'
  })
})

test('editing captures message references and restores the independent draft on cancel or save', () => {
  const model = new ChatModel()
  const draftLinks = [{ kind: 'page' as const, id: 'independent-page' }]
  const messageLinks = [{ kind: 'message' as const, id: 'quoted-message', quote: 'The quoted requirement.' }]
  model.draft.value = 'Independent draft'
  model.links.value = draftLinks
  model.beginEdit(editContext('message', 'Saved request', 'v1', { hasAttachments: true, links: messageLinks }))
  expect(model.links.value).toEqual(messageLinks)
  expect(model.editCommand()?.links).toEqual(messageLinks)
  expect(model.editing.value?.hasAttachments).toBe(true)
  model.cancelEdit()
  expect(model.draft.value).toBe('Independent draft')
  expect(model.links.value).toEqual(draftLinks)
  model.beginEdit(
    editContext('message', 'Saved request', 'v2', { kind: 'last', hasAttachments: true, links: messageLinks })
  )
  expect(model.editCommand()?.expectedLinks).toEqual(messageLinks)
  model.editSaved('message', 'Saved request', messageLinks)
  expect(model.editing.value).toBeUndefined()
  expect(model.links.value).toEqual(draftLinks)
})

test('conflict recovery detects changed references and explicitly loads the saved references', () => {
  const model = new ChatModel()
  const original = [{ kind: 'page' as const, id: 'page-original' }]
  const saved = [{ kind: 'page' as const, id: 'page-other-tab' }]
  model.beginEdit(editContext('message', 'Same text', 'v1', { links: original }))
  model.links.value = []
  expect(model.savedEditChanged(editSnapshot('Same text', original))).toBe(false)
  expect(model.savedEditChanged(editSnapshot('Same text', saved))).toBe(true)
  expect(model.savedEditChanged(editSnapshot('Changed text', original))).toBe(true)
  expect(model.rebaseEdit('message', editSnapshot('Same text', saved), 'v2')).toBe(false)
  expect(model.links.value).toEqual([])
  expect(model.editing.value?.queueVersion).toBe('v1')
  expect(model.rebaseEdit('message', editSnapshot('Same text', saved), 'v2', true)).toBe(true)
  expect(model.savedEditChanged(editSnapshot('Same text', saved))).toBe(false)
  expect(model.links.value).toEqual(saved)
  expect(model.editCommand()?.links).toEqual(saved)
  model.links.value = []
  model.editSaved('message', 'Same text', saved)
  expect(model.editing.value).toBeDefined()
})

test('edits prune removed Human mentions, keep fixed Agents, and preserve the independent draft', () => {
  const model = new ChatModel()
  const independent = [{ type: 'human' as const, uid: 'alice', displayName: 'Alice' }]
  const captured = [
    { type: 'agent' as const, uid: 'writer', displayName: 'Writer' },
    { type: 'human' as const, uid: 'bob', displayName: 'Bob' },
    { type: 'human' as const, uid: 'legacy-person' }
  ]
  model.draft.value = 'Ask @Alice later'
  model.mentions.value = independent
  model.beginEdit(editContext('queued', '@Writer ask @Bob', 'q1', { agentUID: 'writer', mentions: captured }))
  model.draft.value = 'Review the result'
  expect(model.editCommand()?.mentions).toEqual([captured[0]!, captured[2]!])
  expect(model.mentions.value).toEqual(independent)
  model.cancelEdit()
  expect(model.draft.value).toBe('Ask @Alice later')
  expect(model.mentions.value).toEqual(independent)

  model.beginEdit(
    editContext('completed', '@Writer ask @Bob', 'q2', { kind: 'last', agentUID: 'writer', mentions: captured })
  )
  model.draft.value = 'Review the result'
  expect(model.editCommand()?.expectedMentions).toEqual(captured)
  model.editSaved('completed', 'Review the result')
  expect(model.mentions.value).toEqual(independent)
  expect(model.draft.value).toBe('Ask @Alice later')
})

test('mention-only remote edits require explicit recovery and load the captured references', () => {
  const model = new ChatModel()
  const original = [{ type: 'human' as const, uid: 'bob', displayName: 'Bob' }]
  model.beginEdit(editContext('message', 'Same text', 'v1', { kind: 'last', mentions: original }))
  expect(model.savedEditChanged(editSnapshot('Same text'))).toBe(true)
  expect(model.rebaseEdit('message', editSnapshot('Same text'), 'v2')).toBe(false)
  expect(model.editing.value?.originalMentions).toEqual(original)
  expect(model.rebaseEdit('message', editSnapshot('Same text'), 'v2', true)).toBe(true)
  expect(model.editCommand()?.expectedMentions).toEqual([])
})

test('taking back one Agent input restores the named colleague without replaying other Agent recipients', () => {
  const model = new ChatModel()
  const input: ConversationPendingInput = {
    messageID: 'queued-message',
    agentUID: 'agent-a',
    authorUID: 'person',
    text: '@Bob review this with @Writer',
    modelProfile: 'primary',
    deliveryMode: 'queue',
    mentions: [
      { type: 'human', uid: 'bob', displayName: 'Bob' },
      { type: 'agent', uid: 'agent-b', displayName: 'Writer' }
    ],
    links: [{ kind: 'page', id: 'referenced-page' }],
    attachments: []
  }
  model.restoreQueuedInput(input, 'agent-a')
  const submission = model.submit('room', 'agent-a', () => 'new-message')
  expect(submission).toMatchObject({
    text: input.text,
    targetAgentUID: 'agent-a',
    mentions: [{ type: 'human', uid: 'bob', displayName: 'Bob' }],
    links: input.links
  })

  const occupied = new ChatModel()
  occupied.draft.value = 'Ask @Alice first'
  occupied.targetAgentUID.value = 'agent-c'
  occupied.mentions.value = [{ type: 'human', uid: 'alice', displayName: 'Alice' }]
  occupied.links.value = [{ kind: 'page', id: 'independent-page' }]
  occupied.restoreQueuedInput(input, 'agent-a')
  expect(occupied.draft.value).toBe(`Ask @Alice first\n\n${input.text}`)
  expect(occupied.targetAgentUID.value).toBe('agent-c')
  expect(occupied.mentions.value).toEqual([
    { type: 'human', uid: 'alice', displayName: 'Alice' },
    { type: 'human', uid: 'bob', displayName: 'Bob' }
  ])
  expect(occupied.links.value).toEqual([
    { kind: 'page', id: 'independent-page' },
    { kind: 'page', id: 'referenced-page' }
  ])
})

test('a confirmed answer clears its captured references while preserving changed draft work', () => {
  const model = new ChatModel()
  const sent = [{ kind: 'page' as const, id: 'answer-evidence' }]
  model.draft.value = 'Use the referenced page.'
  model.links.value = sent
  model.startAnswer('question')
  model.answerAccepted('question', { text: 'Use the referenced page.', links: sent, mentions: [] })
  expect(model.draft.value).toBe('')
  expect(model.links.value).toEqual([])
  expect(model.answeringInteractionID.value).toBeUndefined()

  model.draft.value = 'Use the referenced page.'
  model.links.value = [{ kind: 'page', id: 'different-evidence' }]
  model.answerAccepted('question', { text: 'Use the referenced page.', links: sent, mentions: [] })
  expect(model.draft.value).toBe('Use the referenced page.')
  expect(model.links.value).toEqual([{ kind: 'page', id: 'different-evidence' }])

  model.draft.value = 'An independent follow-up.'
  model.links.value = sent
  model.answerAccepted('question', { text: 'Use the referenced page.', links: sent, mentions: [] })
  expect(model.draft.value).toBe('An independent follow-up.')
  expect(model.links.value).toEqual(sent)
})

test('answering is an explicit draft context that can be left and restored after a saved-message edit', () => {
  const model = new ChatModel()
  model.draft.value = 'An ordinary group comment'
  expect(model.answeringInteractionID.value).toBeUndefined()
  expect(model.startAnswer('question')).toBe(true)
  expect(model.draft.value).toBe('An ordinary group comment')
  model.startAnswer('question', 'An answer started in the card')
  expect(model.draft.value).toBe('An ordinary group comment\n\nAn answer started in the card')
  model.draft.value = 'An ordinary group comment'
  model.cancelAnswer()
  expect(model.answeringInteractionID.value).toBeUndefined()
  expect(model.draft.value).toBe('An ordinary group comment')
  model.startAnswer('question')
  model.beginEdit(editContext('previous', 'Saved request', 'version'))
  expect(model.answeringInteractionID.value).toBeUndefined()
  expect(model.startAnswer('another-question')).toBe(false)
  model.cancelEdit()
  expect(model.answeringInteractionID.value).toBe('question')
  expect(model.draft.value).toBe('An ordinary group comment')
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
    expect(retry.deliveryMode).toBe('queue')
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

  test('POST and SSE confirmations preserve references selected after sending the same text', () => {
    for (const confirmation of ['post', 'sse'] as const) {
      for (const changed of ['links', 'mentions'] as const) {
        const model = new ChatModel()
        model.draft.value = 'Review this'
        model.links.value = [{ kind: 'page', id: 'sent-page' }]
        const submission = model.submit('conversation', 'agent', () => 'message')
        const nextLinks = [{ kind: 'message' as const, id: 'new-quote', quote: 'Check this requirement.' }]
        const nextMentions = [{ type: 'human' as const, uid: 'colleague', displayName: 'Colleague' }]
        if (changed === 'links') model.links.value = nextLinks
        else model.mentions.value = nextMentions
        if (confirmation === 'post') model.accepted(submission)
        else model.reconcile([message(submission.messageID, 1)])
        expect(model.pending.value).toBeUndefined()
        expect(model.draft.value).toBe('Review this')
        expect(model.links.value).toEqual(changed === 'links' ? nextLinks : submission.links!)
        expect(model.mentions.value).toEqual(changed === 'mentions' ? nextMentions : [])
      }
    }
  })

  test('a confirmation clears the unchanged captured draft with its references and mentions', () => {
    const model = new ChatModel()
    model.draft.value = 'Review this'
    model.links.value = [{ kind: 'page', id: 'sent-page' }]
    model.mentions.value = [{ type: 'human', uid: 'colleague', displayName: 'Colleague' }]
    const submission = model.submit('conversation', 'agent', () => 'message')
    model.accepted(submission)
    expect(model.draft.value).toBe('')
    expect(model.links.value).toEqual([])
    expect(model.mentions.value).toEqual([])
  })

  test('new model responses replace the prior partial text; disconnect discards it', () => {
    const model = new ChatModel()
    model.started('response-1', ['signal-1'], 'agent')
    model.delta('response-1', 'first ', ['signal-1'], 'agent')
    model.delta('response-1', 'response', ['signal-1'], 'agent')
    expect(model.liveStreams.value.agent?.text).toBe('first response')
    model.started('response-2', ['signal-2'], 'agent')
    model.delta('response-1', 'late old delta', ['signal-1'], 'agent')
    model.delta('response-2', 'replacement', ['signal-2'], 'agent')
    expect(model.liveStreams.value.agent).toEqual({
      text: 'replacement',
      responseID: 'response-2',
      signalIDs: ['signal-2'],
      agentUID: 'agent',
      agentName: undefined,
      startedAt: undefined,
      thinkingSummary: ''
    })
    model.disconnected()
    expect(model.liveStreams.value.agent).toBeUndefined()
    expect(model.connecting.value).toBe(true)
    model.connected()
    expect(model.connecting.value).toBe(false)
    model.delta('response-2', 'resumed tail', ['signal-2'], 'agent')
    expect(model.liveStreams.value.agent?.text).toBe('resumed tail')
  })

  test('a missed started event still displays only subsequently received text and clears on the matching reply', () => {
    const model = new ChatModel()
    model.delta('response-1', 'received tail ', ['signal-1'], 'agent')
    model.delta('response-1', 'continues', ['signal-1'], 'agent')
    expect(model.liveStreams.value.agent).toEqual({
      responseID: 'response-1',
      signalIDs: ['signal-1'],
      text: 'received tail continues',
      agentUID: 'agent',
      thinkingSummary: ''
    })
    model.reconcile([{ ...message('old reply', 99, 'agent'), signalID: 'old-signal' }])
    expect(model.liveStreams.value.agent?.text).toBe('received tail continues')
    model.reconcile([{ ...message('complete reply', 100, 'agent'), signalID: 'signal-1' }])
    expect(model.liveStreams.value.agent).toBeUndefined()
  })

  test('committed replies and idle silent turns clear live text; follow-ups retain it', () => {
    const model = new ChatModel()
    model.started('response-1', ['signal-1', 'steer-signal'], 'agent')
    model.delta('response-1', 'partial', ['signal-1'], 'agent')
    model.reconcile([message('follow-up', 2)])
    expect(model.liveStreams.value.agent?.text).toBe('partial')
    model.reconcile([{ ...message('reply', 3, 'agent'), signalID: 'steer-signal' }])
    expect(model.liveStreams.value.agent).toBeUndefined()
    model.started('response-2', ['signal-2'], 'agent')
    model.delta('response-2', 'silent partial', ['signal-2'], 'agent')
    model.settled('response-2', 'agent')
    expect(model.liveStreams.value.agent).toBeUndefined()
  })

  test('a late prior reply and prior idle result cannot clear a newer Response', () => {
    const model = new ChatModel()
    model.started('response-2', ['signal-2'], 'agent')
    model.delta('response-2', 'new partial', ['signal-2'], 'agent')
    model.reconcile([{ ...message('late old reply', 99, 'agent'), signalID: 'signal-1' }])
    model.settled('response-1', 'agent')
    expect(model.liveStreams.value.agent?.text).toBe('new partial')
    model.reconcile([])
    expect(model.liveStreams.value.agent?.text).toBe('new partial')
  })

  test('terminal removal closes the live state and marks the page unavailable', () => {
    const model = new ChatModel()
    model.started('response-1', ['signal-1'], 'agent')
    model.delta('response-1', 'private partial', ['signal-1'], 'agent')
    model.disconnected()
    model.markGone()
    model.started('late-response', ['late-signal'], 'agent')
    model.delta('late-response', 'late private text', ['late-signal'], 'agent')
    model.disconnected()
    expect(model.gone.value).toBe(true)
    expect(model.liveStreams.value.agent).toBeUndefined()
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
    expect(mergeMessages(committed, pending).map(item => item.type)).toEqual(['committed', 'pending'])
    expect(mergeMessages([...committed, message('pending', 2)], pending).map(item => item.type)).toEqual([
      'committed',
      'committed'
    ])
    expect(committed).toHaveLength(1)
  })

  test('a committed notice replaces the failed live reply', () => {
    const model = new ChatModel()
    model.started('response-2', ['signal-2'], 'agent')
    model.delta('response-2', 'partial', ['signal-2'], 'agent')
    const notice = { ...message('notice', 3, 'system'), kind: 'notice' as const, signalID: 'signal-2' }
    model.reconcile([notice])
    expect(model.liveStreams.value.agent).toBeUndefined()
    expect(mergeMessages([notice], model.pending.value)).toEqual([{ type: 'committed', message: notice }])
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

  test('an active edit keeps its unsaved work until saved or cancelled before another edit starts', () => {
    const model = new ChatModel()
    model.draft.value = 'Independent next request'
    model.beginEdit(editContext('first', 'First saved message', 'queue-version-a'))
    model.draft.value = 'Locally edited first message'
    model.beginEdit(editContext('second', 'Second saved message', 'queue-version-b'))
    expect(model.editing.value).toEqual({
      agentUID: 'agent',
      messageID: 'first',
      previousDraft: 'Independent next request',
      previousLinks: [],
      queueVersion: 'queue-version-a',
      kind: 'queue',
      originalText: 'First saved message',
      originalLinks: [],
      originalMentions: [],
      hasAttachments: false
    })
    expect(model.draft.value).toBe('Locally edited first message')
    model.editSaved('first', 'Locally edited first message')
    expect(model.draft.value).toBe('Independent next request')
    model.beginEdit(editContext('second', 'Second saved message', 'queue-version-b'))
    expect(model.editing.value?.messageID).toBe('second')
    expect(model.draft.value).toBe('Second saved message')
    model.editSaved('second', 'Second saved message')
    expect(model.editing.value).toBeUndefined()
    expect(model.draft.value).toBe('Independent next request')
  })

  test('an edit acknowledgement cannot discard text typed after the edit was submitted', () => {
    const model = new ChatModel()
    model.beginEdit(editContext('queued', 'Saved text', 'version'))
    model.draft.value = 'Submitted edit'
    model.draft.value = 'New local text'
    model.editSaved('queued', 'Submitted edit')
    expect(model.draft.value).toBe('New local text')
    expect(model.editing.value?.messageID).toBe('queued')
  })

  test('explicit refresh rebases an unrelated queue change while preserving the local edit and independent draft', () => {
    const model = new ChatModel()
    model.draft.value = 'Independent next request'
    model.beginEdit(editContext('queued', 'Original saved message', 'old-version'))
    model.draft.value = 'My edited message'
    expect(model.rebaseEdit('queued', editSnapshot('Original saved message'), 'fresh-version')).toBe(true)
    expect(model.editing.value?.queueVersion).toBe('fresh-version')
    expect(model.draft.value).toBe('My edited message')
    model.cancelEdit()
    expect(model.draft.value).toBe('Independent next request')
  })

  test('refresh cannot overwrite a collaborator edit; loading the displayed saved version is explicit', () => {
    const model = new ChatModel()
    model.beginEdit(editContext('queued', 'Original saved message', 'old-version', { kind: 'last' }))
    const firstCommand = model.editing.value?.commandID
    model.draft.value = 'My unsaved changes'
    expect(model.rebaseEdit('queued', editSnapshot('Saved by another tab'), 'fresh-version')).toBe(false)
    expect(model.draft.value).toBe('My unsaved changes')
    expect(model.editing.value?.queueVersion).toBe('old-version')
    expect(model.rebaseEdit('queued', editSnapshot('Saved by another tab'), 'fresh-version', true)).toBe(true)
    expect(model.draft.value).toBe('Saved by another tab')
    expect(model.editing.value?.queueVersion).toBe('fresh-version')
    expect(model.editing.value?.commandID).not.toBe(firstCommand)
  })
})

test('a committed clarification clears its Agent stream while another Agent and queued input remain', () => {
  const model = new ChatModel()
  model.started('response-a', ['signal-a'], 'agent-a', 'Analyst')
  model.started('response-b', ['signal-b'], 'agent-b', 'Writer')
  model.delta('response-a', 'Reasoning A', ['signal-a'], 'agent-a', true)
  model.delta('response-a', 'Answer A', ['signal-a'], 'agent-a')
  model.delta('response-b', 'Answer B', ['signal-b'], 'agent-b')
  expect(model.liveStreams.value['agent-a']?.thinkingSummary).toBe('Reasoning A')
  expect(model.liveStreams.value['agent-a']?.text).toBe('Answer A')
  expect(model.liveStreams.value['agent-b']?.text).toBe('Answer B')
  const clarify = {
    ...message('question', 3, 'agent'),
    authorUID: 'agent-a',
    signalID: 'signal-a',
    richContent: { clarify: { question: 'Choose', state: 'pending' } }
  }
  const queued = message('queued-input', 4)
  const queues: ConversationDetail['pendingQueues'] = [
    {
      agentUID: 'agent-a',
      queueVersion: 'queued',
      paused: false,
      workStatus: { state: 'running' },
      inputs: [
        {
          agentUID: 'agent-a',
          messageID: queued.id,
          text: queued.text,
          attachments: [],
          links: [],
          mentions: [],
          deliveryMode: 'queue',
          modelProfile: 'default'
        }
      ]
    }
  ]
  model.reconcile([clarify, queued])
  expect(queues[0]!.inputs).toHaveLength(1)
  expect(
    mergeMessages([clarify, queued], undefined, queues).map(item =>
      item.type === 'committed' ? item.message.id : item.message.messageID
    )
  ).toEqual(['question'])
  expect(Object.keys(model.liveStreams.value)).toEqual(['agent-b'])
  model.reconcile([clarify, { ...message('final-a', 4, 'agent'), authorUID: 'agent-a', signalID: 'signal-a' }])
  expect(Object.keys(model.liveStreams.value)).toEqual(['agent-b'])
  model.delta('old-response-b', 'stale', ['signal-old'], 'agent-b')
  expect(model.liveStreams.value['agent-b']?.text).toBe('Answer B')
  model.settled('response-b', 'agent-b')
  expect(model.liveStreams.value).toEqual({})
})

test('queued inputs appear only in the strip for one human, and carry a timeline badge for shared or answered turns', () => {
  const queued = message('queued', 2)
  const queues: ConversationDetail['pendingQueues'] = [
    {
      agentUID: 'agent',
      queueVersion: 'queue',
      paused: true,
      workStatus: { state: 'idle' },
      inputs: [
        {
          agentUID: 'agent',
          messageID: queued.id,
          text: queued.text,
          attachments: [],
          links: [],
          mentions: [],
          deliveryMode: 'queue',
          modelProfile: 'default'
        }
      ]
    }
  ]
  expect(mergeMessages([queued], undefined, queues, 1)).toEqual([])
  expect(mergeMessages([queued], undefined, queues, 2)).toEqual([{ type: 'committed', message: queued, queued: true }])
  const reply = message('other-agent-reply', 3, 'agent')
  expect(mergeMessages([queued, reply], undefined, queues, 1)).toEqual([
    { type: 'committed', message: queued, queued: true },
    { type: 'committed', message: reply }
  ])
  const clarify = { ...reply, richContent: { clarify: { state: 'pending' } } }
  expect(mergeMessages([queued, clarify], undefined, queues, 1)[0]).toMatchObject({ queued: true })
  expect(mergeMessages([queued], undefined, [], 1)).toEqual([{ type: 'committed', message: queued }])
})

test('a stream snapshot replaces its Agent prefix and subsequent deltas append once', () => {
  const model = new ChatModel()
  model.started('response-a', ['signal-a'], 'agent-a', 'Agent A', '2026-10-25T00:00:00Z')
  model.delta('response-a', 'partial old prefix', ['signal-a'], 'agent-a')
  model.delta('response-a', 'partial old thought', ['signal-a'], 'agent-a', true)
  model.started('response-b', ['signal-b'], 'agent-b')
  model.delta('response-b', 'Agent B stays intact', ['signal-b'], 'agent-b')
  const other = model.liveStreams.value['agent-b']
  const snapshot = {
    agentUID: 'agent-a',
    agentName: 'Agent A',
    responseID: 'response-a',
    signalIDs: ['signal-a'],
    text: 'Full answer prefix',
    thinkingSummary: 'Earlier round thinking. Current round thinking.',
    startedAt: '2026-10-25T00:00:00Z'
  }
  model.snapshot(snapshot)
  model.snapshot(snapshot)
  model.started('response-a', ['signal-a'], 'agent-a')
  model.delta('response-a', ' and a new delta', ['signal-a'], 'agent-a')
  model.delta('response-a', ' More thought.', ['signal-a'], 'agent-a', true)
  expect(model.liveStreams.value['agent-a']).toEqual({
    ...snapshot,
    text: 'Full answer prefix and a new delta',
    thinkingSummary: 'Earlier round thinking. Current round thinking. More thought.'
  })
  expect(model.liveStreams.value['agent-b']).toEqual(other)
})

test('reconnecting restores current work while old responses and revoked streams cannot replace it', () => {
  const model = new ChatModel()
  const old = {
    agentUID: 'agent-a',
    responseID: 'old-response',
    signalIDs: ['old-signal'],
    text: 'Cached old response',
    thinkingSummary: 'Old thought.'
  }
  const current = {
    agentUID: 'agent-a',
    responseID: 'current-response',
    signalIDs: ['current-signal'],
    text: 'Full current prefix',
    thinkingSummary: 'Full current thought.'
  }
  model.snapshot(old)
  model.connected()
  expect(model.liveStreams.value).toEqual({})
  model.snapshot(current)
  model.snapshot(old)
  model.delta('old-response', ' late old delta', ['old-signal'], 'agent-a')
  expect(model.liveStreams.value['agent-a']).toEqual(current)
  model.disconnected()
  expect(model.liveStreams.value).toEqual({})
  model.connected()
  model.snapshot(current)
  expect(model.liveStreams.value['agent-a']).toEqual(current)
  model.started('next-response', ['next-signal'], 'agent-a')
  model.snapshot(current)
  expect(model.liveStreams.value['agent-a']?.text).toBe('')
  expect(model.liveStreams.value['agent-a']?.responseID).toBe('next-response')
  model.markGone()
  model.snapshot(current)
  expect(model.liveStreams.value).toEqual({})
})
