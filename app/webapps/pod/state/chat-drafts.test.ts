import { describe, expect, test } from 'bun:test'
import { ChatDrafts } from './chat-drafts'

describe('Pod conversation drafts', () => {
  test('an unconfirmed standalone create releases New but retains its owner, attachments and retry IDs', () => {
    const drafts = new ChatDrafts()
    const first = drafts.get()
    first.draft.value = 'First create'
    let id = 0
    const submission = first.submit(undefined, 'agent', () => `id-${++id}`)
    drafts.remember(first, submission.conversationID)
    expect(first.conversationID.value).toBeUndefined()
    const next = drafts.get()
    next.draft.value = 'Separate draft'
    expect(next).not.toBe(first)
    first.failed(new Error('Response lost'), submission.messageID)
    expect(drafts.unconfirmedStandalone().map(entry => entry.id)).toEqual([submission.conversationID])
    const restored = drafts.get(submission.conversationID)
    expect(restored).toBe(first)
    expect(restored.attachments).toBe(first.attachments)
    const retry = restored.submit(undefined, 'agent', () => `id-${++id}`)
    expect(retry.conversationID).toBe(submission.conversationID)
    expect(retry.messageID).toBe(submission.messageID)
    restored.accepted(retry)
    drafts.remember(restored, retry.conversationID)
    expect(drafts.unconfirmedStandalone()).toEqual([])
    expect(drafts.get()).toBe(next)
    expect(next.draft.value).toBe('Separate draft')
    const page = drafts.get(undefined, 'page')
    page.submit(undefined, 'agent', () => `id-${++id}`)
    expect(drafts.unconfirmedStandalone()).toEqual([])
    expect(drafts.get(undefined, 'page')).toBe(page)
  })
  test('closing, changing views, and returning to a page keep one draft owner', () => {
    const drafts = new ChatDrafts()
    const report = drafts.get('chat-1', 'report')
    report.draft.value = 'Keep this requested change'
    drafts.get('chat-2', 'other-page').draft.value = 'Another change'
    expect(drafts.get('chat-1')).toBe(report)
    expect(drafts.get('chat-1', 'report').draft.value).toBe('Keep this requested change')
    expect(drafts.unfinishedPageConversation('report')).toBe('chat-1')
    expect(drafts.unfinishedPageConversation('other-page')).toBe('chat-2')
    expect(new ChatDrafts().hasUnsentWork()).toBe(false)
    expect(drafts.hasUnsentWork()).toBe(true)
  })

  test('a failed first request keeps exact IDs across closing and finding its committed conversation', () => {
    const drafts = new ChatDrafts()
    const model = drafts.get(undefined, 'report')
    model.draft.value = 'Update this report'
    let id = 0
    const first = model.submit(undefined, 'agent', () => String(++id))
    model.failed(new Error('The response was lost'), first.messageID)
    expect(drafts.unfinishedPageConversation('report')).toBe('new')
    const reopened = drafts.get(undefined, 'report')
    const retry = reopened.submit(undefined, 'agent', () => String(++id))
    expect(retry.conversationID).toBe(first.conversationID)
    expect(retry.messageID).toBe(first.messageID)
    expect(id).toBe(2)
    expect(drafts.get(first.conversationID, 'report')).toBe(model)
    model.accepted(retry)
    drafts.remember(model, first.conversationID)
    expect(drafts.get(first.conversationID)).toBe(model)
    expect(drafts.get(undefined, 'report')).not.toBe(model)
    expect(drafts.hasUnsentWork()).toBe(false)
  })

  test('new page drafts stay separate and pending requests protect document unload', () => {
    const drafts = new ChatDrafts()
    const first = drafts.get(undefined, 'first')
    const second = drafts.get(undefined, 'second')
    expect(first).not.toBe(second)
    expect(first).not.toBe(drafts.get())
    expect(drafts.hasUnsentWork()).toBe(false)
    first.draft.value = 'First request'
    const request = first.submit(undefined, 'agent', () => 'pending')
    first.draft.value = ''
    expect(drafts.hasUnsentWork()).toBe(true)
    first.accepted(request)
    drafts.remember(first, request.conversationID)
    expect(drafts.hasUnsentWork()).toBe(false)
  })

  test('access-loss recovery exposes only this page locally authored text across its chats', () => {
    const drafts = new ChatDrafts()
    const first = drafts.get('first-chat', 'report')
    first.draft.value = 'First unsent request'
    const second = drafts.get('second-chat', 'report')
    second.draft.value = 'Unconfirmed request'
    second.submit('second-chat', 'agent', () => 'pending')
    second.draft.value = 'Newer draft'
    drafts.get('elsewhere', 'private-page').draft.value = 'Unrelated private draft'
    expect(drafts.localPageDrafts('report').map(draft => draft.text)).toEqual([
      'First unsent request',
      'Newer draft',
      'Unconfirmed request'
    ])
    expect(drafts.localPageDrafts('missing')).toEqual([])
  })

  test('an existing conversation is associated only with the page confirmed by the server', () => {
    const drafts = new ChatDrafts()
    const model = drafts.get('chat')
    model.draft.value = 'A locally authored request'
    expect(drafts.localPageDrafts('unconfirmed-page')).toEqual([])
    drafts.remember(model, 'chat', 'confirmed-page')
    expect(drafts.localPageDrafts('confirmed-page').map(draft => draft.text)).toEqual(['A locally authored request'])
    expect(drafts.localPageDrafts('unconfirmed-page')).toEqual([])
  })
})
