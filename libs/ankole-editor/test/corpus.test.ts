import { expect, test } from 'bun:test'
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { parseMarkdown, printMarkdown } from '../src/document/markdown'
import { textOf, type Element, type Node } from '../src/document/tree'
import { ruleOf } from '../src/document/vocabulary'

/*
 * Real documents from the Ankole repository at commit 458cbba. Each one
 * contains text that a page reader must keep as text: times, ratios,
 * `key:value` pairs, Erlang atoms and URLs.
 */
const directory = join(import.meta.dir, 'corpus')
const samples: Record<string, string[]> = {
  'automation-jobs.md': ['14:00'],
  'design-template.md': ['4.5:1', '3:1'],
  'elixir-data-structures.md': [':queue'],
  'lark-approval-get.md': ['approval:read'],
  'codex-base-instructions.md': ['src/app.ts:42'],
  'ambient-intervention-zh.md': ['18:00'],
  'poster-infographic.md': ['9:16', '3:4']
}

function unknownElements(node: Node, found = new Set<string>()) {
  if (node.type === 'element') {
    if (!ruleOf(node.name)) found.add(node.name)
    node.children.forEach(child => unknownElements(child, found))
  }
  return found
}

test.each(readdirSync(directory).filter(name => name.endsWith('.md')))('%s', name => {
  const source = readFileSync(join(directory, name), 'utf8')
  const page: Element = parseMarkdown(source)
  expect([...unknownElements(page)]).toEqual([])
  const content = textOf(page)
  for (const sample of samples[name] ?? []) expect(content).toContain(sample)
  const printed = printMarkdown(page)
  expect(printMarkdown(parseMarkdown(printed))).toBe(printed)
})

test('constructs outside the dialect are rejected with a repair', () => {
  expect(() => parseMarkdown('<!-- BEGIN:rules -->')).toThrow('请删除这段注释')
  expect(() => parseMarkdown('see <https://example.com>')).toThrow('请改用 [文字](网址)')
  expect(() => parseMarkdown('report for <job_id>, see above')).toThrow('如果这里是文字，请把 < 写成 &lt;')
})
