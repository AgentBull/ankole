import { expect, test } from 'bun:test'
import { promoteExactName } from './command-menu'

const entry = (value: string, title: string) => ({ value, title })
const name = (item: { title: string }) => [item.title]

test('an exactly named conversation leads the list ahead of files that only mention the words', () => {
  const groups = [
    {
      kind: 'page',
      entries: ['咨询纪要.pdf', '咨询合同.pdf', '服务报价.pdf', '能力清单.pdf'].map(title =>
        entry(`page:${title}`, title)
      )
    },
    { kind: 'chat', entries: [entry('chat:other', '操作手册讨论'), entry('chat:exact', '自动化操作能力咨询')] },
    { kind: 'nav', entries: [entry('nav:space', '空间')] }
  ]

  const { groups: promoted, exact } = promoteExactName(groups, ' 自动化操作能力咨询  ', name)

  expect(exact?.value).toBe('chat:exact')
  expect(promoted.map(group => group.kind)).toEqual(['chat', 'page', 'nav'])
  expect(promoted[0]!.entries.map(item => item.value)).toEqual(['chat:exact', 'chat:other'])
  expect(promoted[1]).toBe(groups[0])
})

test('an exact name ignores case and repeated whitespace but not a missing space', () => {
  const groups = [
    { kind: 'page', entries: [entry('page:joined', '私募基金Demo'), entry('page:spaced', '私募基金 Demo')] }
  ]

  expect(promoteExactName(groups, '私募基金   demo', name).exact?.value).toBe('page:spaced')
  expect(promoteExactName(groups, '私募基金', name)).toEqual({ groups })
  expect(promoteExactName(groups, '  ', name)).toEqual({ groups })
})
