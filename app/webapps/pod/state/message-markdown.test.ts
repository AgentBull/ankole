import { expect, test } from 'bun:test'
import { parseMarkdown, printXml } from '@ankole/block-editor/document'
import type { ConversationMessage } from '../api'
import { messageMarkdown, selectionToMarkdown } from '../chat/export-markdown'
import { ChatModel } from './chat'

test('saving a Composer message preserves its structured quotation and resolvable Page reference', () => {
  const id = '019a0000-0000-7000-8000-000000000001'
  const body = messageMarkdown({
    text: 'Review @Project report before sharing the conclusion.',
    links: [
      {
        kind: 'message',
        id: '019a0000-0000-7000-8000-000000000002',
        quote: 'Keep the source intact.\nCheck both figures.'
      },
      { kind: 'page', id }
    ]
  })
  const xml = printXml(parseMarkdown(body))
  expect(body).toContain('Review @Project report before sharing the conclusion.')
  expect(body).toContain('> Keep the source intact.\n> Check both figures.')
  expect(xml).toContain('<blockquote>')
  expect(xml).toContain('Keep the source intact.')
  expect(xml).toContain('Check both figures.')
  expect(xml).toContain(`href="ankole:page/${id}"`)
})

test('an authored inline Page reference is not repeated and plain content stays unchanged', () => {
  const id = '019a0000-0000-7000-8000-000000000001'
  const text = `The [Project report](ankole:page/${id}) contains the result.`
  expect(messageMarkdown({ text, links: [{ kind: 'page', id }] }).match(/ankole:page\//g)).toHaveLength(1)
  expect(messageMarkdown({ text: 'An ordinary answer.', links: [] }).trimEnd()).toBe('An ordinary answer.')
})

test('selectionToMarkdown orders selected messages by seq and preserves speaker, quotes, and attachments', () => {
  const m2 = {
    id: 'msg-2',
    seq: 20,
    kind: 'message',
    authorType: 'agent',
    authorDisplayName: 'Research Agent',
    createdAt: '2026-10-31T10:02:00Z',
    text: 'Here is the synthesized table.',
    links: [{ kind: 'message', id: 'msg-1', quote: 'Compare Q3 and Q4' }],
    attachments: [{ name: 'q4-summary.csv', position: 0 }]
  } as unknown as ConversationMessage

  const m1 = {
    id: 'msg-1',
    seq: 10,
    kind: 'message',
    authorType: 'human',
    authorDisplayName: 'Alice',
    createdAt: '2026-10-31T10:00:00Z',
    text: 'Compare Q3 and Q4.',
    links: [],
    attachments: []
  } as unknown as ConversationMessage

  const markdown = selectionToMarkdown([m2, m1], { title: 'Quarterly Review' })
  expect(markdown.indexOf('## Alice')).toBeLessThan(markdown.indexOf('## Research Agent'))
  expect(markdown).toContain('# Quarterly Review')
  expect(markdown).toContain('> Compare Q3 and Q4')
  expect(markdown).toContain('- q4-summary.csv')
})

test('selectionToMarkdown preserves blank lines inside quoted code', () => {
  const text = '```python\nvalue = """first\n\n\nlast"""\n```'
  const message = {
    id: 'code-message',
    seq: 1,
    kind: 'message',
    authorType: 'agent',
    authorDisplayName: 'Agent',
    text,
    links: [],
    attachments: []
  } as unknown as ConversationMessage

  expect(selectionToMarkdown([message])).toContain(text)
})

test('ChatModel tracks multi-select message IDs cleanly and resets on clear or markGone', () => {
  const chat = new ChatModel()
  expect(chat.selectingMessages.value).toBe(false)
  chat.startSelectingMessages('m-1')
  expect(chat.selectingMessages.value).toBe(true)
  expect(chat.selectedMessageIDs.value).toEqual(['m-1'])
  expect(chat.selectedMessageCount.value).toBe(1)

  chat.toggleSelectedMessage('m-2')
  expect(chat.selectedMessageIDs.value).toEqual(['m-1', 'm-2'])
  chat.toggleSelectedMessage('m-1')
  expect(chat.selectedMessageIDs.value).toEqual(['m-2'])

  chat.clearMessageSelection()
  expect(chat.selectingMessages.value).toBe(false)
  expect(chat.selectedMessageIDs.value).toEqual([])

  chat.startSelectingMessages('m-3')
  chat.markGone()
  expect(chat.selectingMessages.value).toBe(false)
  expect(chat.selectedMessageIDs.value).toEqual([])
})
