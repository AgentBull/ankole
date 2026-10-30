import { expect, test } from 'bun:test'
import { documentChanges, documentComparisonSource, versionTime } from './document-history'

test('a delayed checkpoint is labelled with the time its content was edited', () => {
  const version = { created_at: '2026-10-29T02:00:00Z', document_updated_at: '2026-10-28T01:01:00Z' }
  expect(versionTime({ ...version, reason: 'checkpoint' })).toBe(version.document_updated_at)
  expect(versionTime({ ...version, reason: 'restored' })).toBe(version.created_at)
})

test('comparison preserves the selected and current document, including independent changes', () => {
  const before = '# 计划\n\n第一段\n\n旧结论\n\n[预算](https://example.test/budget)\n'
  const current = '# 计划\n\n第一段补充\n\n新结论\n\n[预算](https://example.test/budget)\n'
  const changes = documentChanges(before, current)
  expect(
    changes
      .filter(part => part.kind !== 'added')
      .map(part => part.text)
      .join('')
  ).toBe(before)
  expect(
    changes
      .filter(part => part.kind !== 'removed')
      .map(part => part.text)
      .join('')
  ).toBe(current)
  expect(changes.some(part => part.kind === 'removed' && part.text.includes('旧结论'))).toBe(true)
  expect(changes.some(part => part.kind === 'added' && part.text.includes('新结论'))).toBe(true)
  expect(changes.some(part => part.kind === 'unchanged' && part.text.includes('[预算]'))).toBe(true)
})

test('history distinguishes native layout and callout styles with the same visible text', () => {
  const plain = documentComparisonSource('<page><p>Left</p><p>Right</p></page>', 'Plan')
  const columns = documentComparisonSource(
    '<page><columns widths="50,50"><column><p>Left</p></column><column><p>Right</p></column></columns></page>',
    'Plan'
  )
  expect(documentChanges(plain, columns).some(change => change.kind !== 'unchanged')).toBe(true)
  const info = documentComparisonSource('<page><callout kind="info"><p>Note</p></callout></page>', 'Plan')
  const warning = documentComparisonSource('<page><callout kind="warning"><p>Note</p></callout></page>', 'Plan')
  expect(info).not.toBe(warning)
})
