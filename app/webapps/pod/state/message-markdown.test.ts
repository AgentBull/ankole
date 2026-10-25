import { expect, test } from 'bun:test'
import { parseMarkdown, printXml } from '@ankole/block-editor/document'
import { messageMarkdown } from '../chat/export-markdown'

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
