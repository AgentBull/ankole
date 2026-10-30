import { describe, expect, test } from 'bun:test'
import { insertText } from '../src/core/command/commands'
import { Leaf } from '../src/core/doc'
import { history, undo } from '../src/core/history'
import { GardSelection, Transaction, type GardState } from '../src/core/state'
import { parseMarkdown, parseXml, printMarkdown, printXml } from '../src/document'
import { DocumentError } from '../src/document/tree'
import { blockChange } from '../src/editor/block-actions'
import { filterBlockOptions } from '../src/editor/block-catalog'
import { commentRanges, commentSelection } from '../src/editor/comments'
import { readTree } from '../src/editor/convert'
import { editorExtension, headlessState, initialState } from '../src/editor/extension'
import { hostExtension } from '../src/editor/host'
import {
  commitMentionSpec,
  dismissMentionEffect,
  insertMentionSpec,
  mentionField,
  reportMentionMatchesEffect,
  setMentionCategoryEffect
} from '../src/editor/mention'

const PAGE_ID = '019a2b00-0000-7000-8000-000000000101'
const PRINCIPAL_ID = 'usr_alice_001'

const markdown = (state: GardState) => printMarkdown(readTree(state.doc))
const xml = (state: GardState) => printXml(readTree(state.doc))

const at = (source: string, pos: number) => headlessState(source).update({ selection: GardSelection.cursor(pos) }).state

function type(state: GardState, text: string): GardState {
  for (const char of text) {
    const { from, to } = state.selection
    const spec = insertText({ state }, { from, to, insert: char, userEvent: 'input.type' })
    if (!spec) throw new Error('Typing failed')
    state = Transaction.append(state.update(spec)).at(-1)!.state
  }
  return state
}

const undone = (state: GardState) => state.update(undo({ state }, null) as Transaction.Spec).state

describe('canonical mention document codecs', () => {
  test('round-trips page and principal mentions across Markdown, XML, and editor document', () => {
    const source = [
      `请 <mention principal="${PRINCIPAL_ID}" /> 审阅 **<mention page="${PAGE_ID}" />**。`,
      '',
      `## 章节 <mention page="${PAGE_ID}" />`
    ].join('\n')

    const parsed = parseMarkdown(source)
    const xmlOut = printXml(parsed)
    expect(xmlOut).toContain(`<mention principal="${PRINCIPAL_ID}" />`)
    expect(xmlOut).toContain(`<strong><mention page="${PAGE_ID}" /></strong>`)
    expect(printXml(parseXml(xmlOut))).toBe(xmlOut)
    expect(printMarkdown(parsed)).toBe(source)

    const state = headlessState(source)
    expect(markdown(state)).toBe(source)
    expect(xml(state)).toBe(xmlOut)
  })

  test('rejects invalid mention elements with missing, dual, or child content', () => {
    expect(() => parseXml('<page><p><mention/></p></page>')).toThrow(DocumentError)
    expect(() => parseXml(`<page><p><mention page="${PAGE_ID}" principal="${PRINCIPAL_ID}"/></p></page>`)).toThrow(
      DocumentError
    )
    expect(() => parseXml(`<page><p><mention page="${PAGE_ID}">Title</mention></p></page>`)).toThrow(DocumentError)
    expect(() => parseMarkdown('<mention />')).toThrow(DocumentError)
  })
})

describe('@ mention session trigger and dismissal', () => {
  test('opens on ASCII @ and fullwidth ＠ at start of line, after whitespace, CJK, and punctuation', () => {
    expect(type(at('<p />', 1), '@').field(mentionField)).toEqual({
      from: 1,
      to: 2,
      query: '',
      category: 'all',
      zeroMatchSinceLength: null
    })
    expect(type(at('<p />', 1), '＠').field(mentionField)).toEqual({
      from: 1,
      to: 2,
      query: '',
      category: 'all',
      zeroMatchSinceLength: null
    })
    expect(type(at('请看', 3), '@文档').field(mentionField)?.query).toBe('文档')
    expect(type(at('hello ', 7), '@alice').field(mentionField)?.query).toBe('alice')
    expect(type(at('(', 2), '@bob').field(mentionField)?.query).toBe('bob')
  })

  test('suppresses false triggers in emails, paths, @@, code blocks, inline code, links, and paste', () => {
    expect(type(at('user', 5), '@ankole.com').field(mentionField)).toBeNull()
    expect(type(at('https://x.com/', 15), '@handle').field(mentionField)).toBeNull()
    expect(type(at('<p />', 1), '@@').field(mentionField)).toBeNull()
    expect(type(at('```\n\n```', 1), '@alice').field(mentionField)).toBeNull()
    expect(type(at('`code`', 3), '@').field(mentionField)).toBeNull()
    expect(type(at('[link](https://example.com)', 3), '@').field(mentionField)).toBeNull()

    const pasted = at('<p />', 1).update({
      changes: { from: 1, to: 1, insert: [Leaf.text('@alice')] },
      selection: GardSelection.cursor(7),
      userEvent: 'input.paste'
    }).state
    expect(pasted.field(mentionField)).toBeNull()
  })

  test('retains multi-word queries with spaces, switches categories, and auto-dismisses >12 zero-match chars', () => {
    let state = type(at('<p />', 1), '@AI Agent 行业动态')
    expect(state.field(mentionField)?.query).toBe('AI Agent 行业动态')

    state = state.update({ effects: setMentionCategoryEffect.of('page') }).state
    expect(state.field(mentionField)?.category).toBe('page')

    // Report zero matches across all categories at length 13 ("AI Agent 行业动态")
    state = state.update({
      effects: reportMentionMatchesEffect.of({ query: 'AI Agent 行业动态', totalAllMatches: 0 })
    }).state
    expect(state.field(mentionField)?.zeroMatchSinceLength).toBe(13)

    // Typing 12 more characters stays open; the 13th character auto-dismisses into plain text.
    state = type(state, '123456789012')
    expect(state.field(mentionField)).not.toBeNull()
    state = type(state, '3')
    expect(state.field(mentionField)).toBeNull()
    expect(markdown(state)).toBe('@AI Agent 行业动态1234567890123')
  })

  test('Escape dismisses the active session while preserving literal @query text', () => {
    let state = type(at('<p />', 1), '@draft')
    expect(state.field(mentionField)?.query).toBe('draft')
    state = state.update({ effects: dismissMentionEffect.of(null) }).state
    expect(state.field(mentionField)).toBeNull()
    expect(markdown(state)).toBe('@draft')
  })
})

describe('slash catalogue and atomic commit / undo', () => {
  test('slash filter finds mention on @ and blockChange opens a mention session', () => {
    const empty = at('<p />', 1)
    const matches = filterBlockOptions(empty, '@')
    expect(matches.some(option => option.type === 'mention')).toBe(true)

    const spec = blockChange(empty, 'mention')
    expect(spec).not.toBeNull()
    const next = empty.update(spec!).state
    expect(markdown(next)).toBe('@')
    expect(next.field(mentionField)?.query).toBe('')

    // Preceded by ASCII word char inserts a leading space before @ so it opens cleanly.
    const afterWord = at('word', 5)
    const afterWordNext = afterWord.update(blockChange(afterWord, 'mention')!).state
    expect(markdown(afterWordNext)).toBe('word @')
    expect(afterWordNext.field(mentionField)?.from).toBe(6)
  })

  test('commitMentionSpec replaces @query atomically, inherits bold formatting, and undoes to @query', () => {
    let state = at('**粗体**', 3)
    state = type(state, '@报告')
    expect(state.field(mentionField)?.query).toBe('报告')

    const commit = commitMentionSpec(state, { page: PAGE_ID })
    expect(commit).not.toBeNull()
    state = state.update({ ...commit!, annotations: history.isolate.of(true) }).state
    expect(state.field(mentionField)).toBeNull()
    expect(markdown(state)).toBe(`**粗体<mention page="${PAGE_ID}" />**`)

    // Undo restores the typed @报告 query in one step.
    expect(markdown(undone(state))).toBe('**粗体@报告**')
  })

  test('insertMentionSpec inserts inline in textblocks and supports comment anchoring', () => {
    let state = initialState('<p />', [
      hostExtension({
        mentionText: target => ('page' in target ? '季度复盘' : '@Alice')
      }),
      editorExtension()
    ]).update({ selection: GardSelection.cursor(1) }).state

    const insert = insertMentionSpec(state, { principal: PRINCIPAL_ID })
    expect(insert).not.toBeNull()
    state = state.update({ ...insert!, annotations: history.isolate.of(true) }).state
    expect(markdown(state)).toBe(`<p><mention principal="${PRINCIPAL_ID}" /></p>`)

    // Select the standalone mention atom and verify commentSelection produces a valid anchor.
    const selState = state.update({ selection: GardSelection.range(1, 2) }).state
    const anchor = commentSelection({ state: selState })
    expect(anchor?.quote).toBe('@')

    const commented = headlessState(
      `<comment ids="019a2b00-0000-7000-8000-000000000001"><mention principal="${PRINCIPAL_ID}" /></comment>`
    )
    expect(commentRanges({ state: commented })).toEqual([
      { id: '019a2b00-0000-7000-8000-000000000001', from: 1, to: 2 }
    ])
  })
})
