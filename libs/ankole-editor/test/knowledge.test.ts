import { describe, expect, test } from 'bun:test'
import { Slice } from '../src/core/doc'
import { Wordgard } from '../src/core/editor'
import * as T from '../src/core/types'
import { InfographicBlock, InfographicTheme, InfographicView } from '../src/blocks/infographic'
import { MermaidBlock, MermaidTheme, MermaidView, setMermaidTheme, setMermaidView } from '../src/blocks/mermaid'
import { parseMarkdown, printMarkdown, parseXml, printXml, validateKnowledge } from '../src/document'
import { codeNodes, markSet } from '../src/editor/attributes'
import { downgradeKnowledgeSlice } from '../src/editor/clipboard'
import { knowledgeExtension } from '../src/editor/knowledge'
import { PageSession } from '../src/editor/page-session'
import { changeTable, editableTable } from '../src/editor/tables'
import corpus from '../corpus/knowledge.json'
import { open, readTree, select } from './helpers'

describe('knowledge vocabulary shared with the native codec', () => {
  for (const fixture of corpus) {
    test(fixture.name, () => {
      const tree = validateKnowledge(parseXml(fixture.xml))
      expect(printXml(parseMarkdown(printMarkdown(tree, 'knowledge'), 'knowledge'))).toBe(printXml(tree))
    })
  }

  test('accepts plain <mermaid> and round-trips through knowledge Markdown and PageSession', () => {
    for (const xml of [
      '<page><mermaid>flowchart TD\n  A[开始] --&gt; B[结束]</mermaid></page>',
      '<page><mermaid /></page>'
    ]) {
      const tree = validateKnowledge(parseXml(xml))
      const md = printMarkdown(tree, 'knowledge')
      expect(printXml(parseMarkdown(md, 'knowledge'))).toBe(xml)
    }

    const editor = open('```mermaid\nflowchart LR\n  A --> B\n```', knowledgeExtension)
    expect(editor.state.doc.content[0]!.type).toBe(MermaidBlock.type)
    setMermaidView(editor, 0, 'code')
    setMermaidTheme(editor, 0, 'dark')
    expect(editor.state.doc.content[0]!.marks).toHaveLength(0)

    const session = new PageSession(editor)
    expect(session.read().markdown).toBe('```mermaid\nflowchart LR\n  A --> B\n```')
    const applied = session.apply({
      revision: session.revision,
      format: 'markdown',
      source: '```mermaid\nflowchart TD\n  X --> Y\n```\n\n```infographic\ninfographic compare-swot\n  data\n```'
    })
    expect(applied.xml).toBe(
      '<page><mermaid>flowchart TD\n  X --&gt; Y</mermaid><pre lang="infographic">infographic compare-swot\n  data</pre></page>'
    )
  })

  test('rejects doc-only layout, infographic, Mermaid display attributes, comments, and cell styling', () => {
    for (const xml of [
      '<page><columns><column><p>A</p></column><column><p>B</p></column></columns></page>',
      '<page><embed ref="019a0000-0000-7000-8000-000000000001"/></page>',
      '<page><table><tr><th background="#123456"><p>A</p></th></tr></table></page>',
      '<page><infographic>infographic compare-swot</infographic></page>',
      '<page><infographic view="diagram">infographic compare-swot</infographic></page>',
      '<page><mermaid view="code">flowchart LR</mermaid></page>',
      '<page><mermaid theme="dark">flowchart LR</mermaid></page>'
    ]) {
      expect(() => validateKnowledge(parseXml(xml))).toThrow()
    }
  })

  test('cross-page paste into a knowledge editor strips MermaidView/MermaidTheme and downgrades InfographicBlock to CodeBlock(lang="infographic")', () => {
    const target = open('Intro', knowledgeExtension)
    const mermaidNode = MermaidBlock.withMarks(markSet([MermaidView.of('code'), MermaidTheme.of('dark')])).create(
      codeNodes('flowchart TD\n  A --> B')
    )
    const infographicNode = InfographicBlock.withMarks(
      markSet([InfographicView.of('diagram'), InfographicTheme.of('light')])
    ).create(codeNodes('infographic compare-swot\n  data'))

    const rawSlice = Slice.of([mermaidNode, infographicNode])
    const downgraded = downgradeKnowledgeSlice(rawSlice)
    expect(downgraded.content[0]).toMatchObject({ type: MermaidBlock.type, marks: [] })
    expect(downgraded.content[1]).toMatchObject({ type: T.CodeBlock.type })

    let filtered = rawSlice
    for (const filter of target.state.facet(Wordgard.clipboardInputFilter)) {
      filtered = filter(filtered, target.state)
    }
    const end = target.state.doc.length
    expect(() => target.dispatch({ changes: { from: end, to: end, insert: filtered } })).not.toThrow()
    expect(printXml(readTree(target))).toBe(
      '<page><p>Intro</p><mermaid>flowchart TD\n  A --&gt; B</mermaid><pre lang="infographic">infographic compare-swot\n  data</pre></page>'
    )

    let parsedTextSlice: Slice | null = null
    for (const parser of target.state.facet(Wordgard.clipboardTextParser)) {
      parsedTextSlice = parser(
        ' Lead\n\n```infographic\ninfographic sequence-funnel-simple\n  data\n```\n\nTail',
        target.state
      )
      if (parsedTextSlice) break
    }
    expect(parsedTextSlice).not.toBeNull()
    expect(() =>
      target.dispatch({
        changes: { correct: [{ from: 6, to: 6, insert: parsedTextSlice!, fit: true }], local: true }
      })
    ).not.toThrow()
    expect(printXml(readTree(target))).toContain(
      '<pre lang="infographic">infographic sequence-funnel-simple\n  data</pre>'
    )
  })
})

test('knowledge table insertion and deletion keep exactly one header row', () => {
  const editor = open('| Header |\n| --- |\n| First |\n| Second |', knowledgeExtension)
  let position = 0
  editor.state.doc.iterate((node, pos) => {
    if (node.isText && node.param === 'Header') position = pos
  })
  select(editor, position)
  expect(changeTable(editor, 'row_before', 'row')).toBe(true)
  expect(() => validateKnowledge(readTree(editor))).not.toThrow()
  expect(printXml(readTree(editor))).toContain('<tr><th><p /></th></tr><tr><td><p>Header</p></td></tr>')
  expect(changeTable(editor, 'delete_row', 'row')).toBe(true)
  expect(printXml(readTree(editor))).toContain('<tr><th><p>Header</p></th></tr>')
  expect(editableTable(editor.state)?.map.height).toBe(3)
  expect(changeTable(editor, 'merge', 'table')).toBe(false)
})
