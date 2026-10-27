import { expect, test } from 'bun:test'
import { completionAt, insertCompletionTrigger } from '../chat/composer-completion'
import { hasDraftMention } from './chat'
import { removePageMention } from '../chat/composer'

test('inline mentions replace the query at the caret and preserve the following text', () => {
  const text = 'Please ask @文档 then continue'
  const caret = text.indexOf(' then')
  const completion = completionAt(text, caret)!
  expect(completion).toEqual({ kind: 'mention', start: 11, end: caret, query: '文档' })
  expect(`${text.slice(0, completion.start)}@Researcher ${text.slice(completion.end)}`).toBe(
    'Please ask @Researcher  then continue'
  )
})

test('CJK mentions open without a separating space and removing a Page chip removes its plain text mention', () => {
  expect(completionAt('请@文档', 4)).toEqual({ kind: 'mention', start: 1, end: 4, query: '文档' })
  expect(completionAt('请查看：@计划', 7)).toEqual({ kind: 'mention', start: 4, end: 7, query: '计划' })
  expect(removePageMention('Ask @Q4 plan to continue', 'Q4 plan')).toBe('Ask to continue')
  expect(removePageMention('Read @C++ plan. Keep @C++ planner', 'C++ plan')).toBe('Read . Keep @C++ planner')
})

test('email addresses, completed mentions and selected text do not open an inline picker', () => {
  for (const text of ['name@example.com', '@Researcher ', 'word@name', '@one@two']) {
    expect(completionAt(text, text.length)).toBeUndefined()
  }
  expect(completionAt('@Researcher', 0, 11)).toBeUndefined()
})

test('slash completion follows a query at the beginning of a line', () => {
  expect(completionAt('/ren', 4)).toEqual({ kind: 'slash', start: 0, end: 4, query: 'ren' })
  expect(completionAt('Existing draft\n/pa', 18)).toEqual({ kind: 'slash', start: 15, end: 18, query: 'pa' })
  expect(completionAt('Discuss /rename', 15)).toBeUndefined()
  expect(completionAt('/rename title', 13)).toBeUndefined()
})

test('a toolbar-opened picker can query at its explicit insertion point', () => {
  const active = { kind: 'slash' as const, start: 6, end: 7, query: '' }
  expect(completionAt('Draft /ren', 10, 10, active)).toEqual({ ...active, end: 10, query: 'ren' })
  expect(completionAt('Draft /ren ', 11, 11, active)).toBeUndefined()
})

test('a selected mention needs its complete visible name rather than a prefix or email fragment', () => {
  expect(hasDraftMention('Ask @Alice, please.', 'Alice')).toBe(true)
  expect(hasDraftMention('请 @文档同事：处理', '文档同事')).toBe(true)
  expect(hasDraftMention('Ask @C++ Agent.', 'C++ Agent')).toBe(true)
  for (const text of ['Ask @Alicia', 'Ask @Alice2', 'name@Alice', 'Ask Alice', '请 @Alice计划处理']) {
    expect(hasDraftMention(text, 'Alice')).toBe(false)
  }
})

test('an open mention search accepts spaces in colleague names and Page titles without reopening a chosen mention', () => {
  const active = { kind: 'mention' as const, start: 4, end: 9, query: 'Chat' }
  expect(completionAt('Use @Chat ', 10, 10, active)).toEqual({ ...active, end: 10, query: 'Chat ' })
  expect(completionAt('Use @Chat workspace', 19, 19, active)).toEqual({
    ...active,
    end: 19,
    query: 'Chat workspace'
  })
  expect(completionAt('Use @Chat workspace ', 20)).toBeUndefined()
  expect(completionAt('Use @Chat\nworkspace', 19, 19, active)).toBeUndefined()
})

test('toolbar trigger insertion separates word tokens so chosen mentions remain valid', () => {
  const afterWord = insertCompletionTrigger('Hello', 5, 5, 'mention')
  expect(afterWord).toEqual({
    value: 'Hello @',
    completion: { kind: 'mention', start: 6, end: 7, query: '' },
    cursor: 7
  })
  expect(completionAt(afterWord.value, afterWord.cursor, afterWord.cursor, afterWord.completion)).toEqual(
    afterWord.completion
  )
  expect(hasDraftMention(`${afterWord.value.slice(0, afterWord.completion.start)}@Alice `, 'Alice')).toBe(true)

  const afterCJK = insertCompletionTrigger('请查看', 3, 3, 'page')
  expect(afterCJK).toEqual({
    value: '请查看 @',
    completion: { kind: 'page', start: 4, end: 5, query: '' },
    cursor: 5
  })
  expect(hasDraftMention(`${afterCJK.value.slice(0, afterCJK.completion.start)}@季度计划 `, '季度计划')).toBe(true)

  expect(insertCompletionTrigger('请查看：', 4, 4, 'mention')).toEqual({
    value: '请查看：@',
    completion: { kind: 'mention', start: 4, end: 5, query: '' },
    cursor: 5
  })
  expect(insertCompletionTrigger('Draft', 5, 5, 'slash')).toEqual({
    value: 'Draft /',
    completion: { kind: 'slash', start: 6, end: 7, query: '' },
    cursor: 7
  })
  expect(insertCompletionTrigger('Line 1\n', 7, 7, 'slash')).toEqual({
    value: 'Line 1\n/',
    completion: { kind: 'slash', start: 7, end: 8, query: '' },
    cursor: 8
  })
})
