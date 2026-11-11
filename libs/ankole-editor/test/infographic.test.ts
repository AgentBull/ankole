import { describe, expect, test } from 'bun:test'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { validateInfographicSyntax } from '@ankole/uikit/viz/infographic'
import { Leaf, type Plot } from '../src/core/doc'
import { undoDepth } from '../src/core/history'
import { undo } from '../src/editor/commands'
import * as T from '../src/core/types'
import { insertEmbed } from '../src/blocks/embed'
import {
  applyInfographicTemplate,
  InfographicBlock,
  infographicTemplates,
  InfographicTheme,
  InfographicView,
  setInfographicTheme,
  setInfographicView
} from '../src/blocks/infographic'
import { parseMarkdown, printMarkdown } from '../src/document/markdown'
import { normalizeTree } from '../src/document/normalize'
import { element, text } from '../src/document/tree'
import { parseXml, printXml } from '../src/document/xml'
import { markSet } from '../src/editor/attributes'
import { applyBlockType, blockTypeAt, canTurnInto, insertBesideBlock, turnBlockInto } from '../src/editor/block-actions'
import { blockOptions, filterBlockOptions } from '../src/editor/block-catalog'
import { readTree as treeOf } from '../src/editor/convert'
import { headlessState } from '../src/editor/extension'
import { hostExtension } from '../src/editor/host'
import { knowledgeExtension } from '../src/editor/knowledge'
import { expectReopens, exportMarkdown, open, openWithHost, press, readTree, typeText } from './helpers'

const page = (...children: ReturnType<typeof element>[]) => element('page', {}, children)
const sampleDsl = [
  'infographic sequence-timeline-simple',
  'data',
  '  title Product Roadmap',
  '  sequences',
  '    - label Q1',
  '      desc Foundation'
].join('\n')
const fence = (value: string) => `\`\`\`infographic\n${value}\n\`\`\``

describe('Infographic document, editor, templates, and conversions', () => {
  test('an infographic fence becomes an Infographic block and round-trips through XML, Markdown, and editor', () => {
    const tree = parseMarkdown(fence(sampleDsl))
    expect(tree).toEqual(page(element('infographic', {}, [text(sampleDsl)])))
    expect(printMarkdown(tree)).toBe(fence(sampleDsl))
    expect(printXml(tree)).toBe(`<page><infographic>${sampleDsl}</infographic></page>`)
    expect(printMarkdown(parseXml(printXml(tree)))).toBe(fence(sampleDsl))
    expect(treeOf(headlessState(tree).doc)).toEqual(tree)

    const editor = open(fence(sampleDsl))
    expect(blockTypeAt(editor.state, 0)).toBe('infographic')
    expectReopens(editor)
  })

  test('an Infographic block carries view and theme through XML, Markdown tags, and editor marks', () => {
    const tagged = `<infographic theme="dark" view="code">\n  \`\`\`infographic\n  ${sampleDsl.replaceAll('\n', '\n  ')}\n  \`\`\`\n</infographic>`
    const tree = parseMarkdown(tagged)
    expect(tree).toEqual(page(element('infographic', { theme: 'dark', view: 'code' }, [text(sampleDsl)])))
    expect(printXml(tree)).toBe(`<page><infographic theme="dark" view="code">${sampleDsl}</infographic></page>`)
    expect(printMarkdown(tree)).toBe(tagged)

    const editor = open(tree)
    const node = editor.state.doc.content[0]!
    expect(node.type).toBe(InfographicBlock.type)
    expect(node.mark(InfographicView)).toBe('code')
    expect(node.mark(InfographicTheme)).toBe('dark')

    setInfographicView(editor, 0, 'diagram')
    setInfographicTheme(editor, 0, 'light')
    expect(printXml(readTree(editor))).toBe(
      `<page><infographic theme="light" view="diagram">${sampleDsl}</infographic></page>`
    )

    setInfographicView(editor, 0, 'both')
    setInfographicTheme(editor, 0, 'auto')
    expect(printXml(readTree(editor))).toBe(`<page><infographic>${sampleDsl}</infographic></page>`)
  })

  test('default view and theme are omitted and empty Infographic blocks stay empty', () => {
    const normalized = normalizeTree(page(element('infographic', { view: 'both', theme: 'auto' }, [text(sampleDsl)])))
    expect(normalized).toEqual(page(element('infographic', {}, [text(sampleDsl)])))

    const empty = parseMarkdown('```infographic\n```')
    expect(empty).toEqual(page(element('infographic', {})))
    expect(printMarkdown(empty)).toBe('```infographic\n```')
    expect(printXml(empty)).toBe('<page><infographic /></page>')
    expect(treeOf(headlessState(empty).doc)).toEqual(empty)
  })

  test('Infographic blocks hold text only, strip inline marks, and preserve carriage returns', () => {
    expect(() => normalizeTree(page(element('infographic', {}, [element('strong', {}, [text('x')])])))).toThrow(
      '<infographic> 只能包含文字'
    )

    const state = headlessState(parseXml('<page><infographic>infographic compare-swot</infographic></page>'))
    const marked = state.update({ changes: { from: 1, to: 8, add: T.Strong } }).state
    expect(printXml(treeOf(marked.doc))).toBe('<page><infographic>infographic compare-swot</infographic></page>')

    const marks = markSet([T.Strong, T.Emphasis])
    const inserted = state.update({
      changes: { from: 1, to: 25, insert: [Leaf.text('infographic compare-swot', marks)] }
    }).state
    expect(printXml(treeOf(inserted.doc))).toBe('<page><infographic>infographic compare-swot</infographic></page>')

    const crXml = '<page><infographic>infographic compare-swot&#13;\n  data</infographic></page>'
    expect(printXml(treeOf(headlessState(parseXml(crXml)).doc))).toBe(crXml)
  })

  test('every curated starter template passes UIKit syntax validation and applies cleanly', () => {
    expect(infographicTemplates.map(template => template.id)).toEqual([
      'process',
      'timeline',
      'funnel',
      'swot',
      'kpi',
      'hierarchy'
    ])
    for (const template of infographicTemplates) {
      const validation = validateInfographicSyntax(template.source)
      expect(validation).toEqual({ ok: true })
      expect(template.source).toMatch(/^\s*title\s+\S+/m)
      expect(template.source).toMatch(/^\s*-\s+label\s+\S+/m)
    }

    const editor = open('')
    expect(applyBlockType(editor, 'infographic')).toBe(true)
    expect(editor.state.doc.content[0]!.type).toBe(InfographicBlock.type)
    expect((editor.state.doc.content[0] as Plot).textContent()).toBe('')

    applyInfographicTemplate(editor, 0, infographicTemplates[3]!.source)
    expect((editor.state.doc.content[0] as Plot).textContent()).toBe(infographicTemplates[3]!.source)
    expectReopens(editor)
  })

  test('turnBlockInto converts code blocks, paragraphs, and Mermaid blocks to Infographic and back', () => {
    const editor = open('```text\ninfographic compare-swot\n  data\n```')
    expect(canTurnInto(editor.state, 0)).toBe(true)
    expect(turnBlockInto(editor, 0, 'infographic')).toBe(true)
    expect(blockTypeAt(editor.state, 0)).toBe('infographic')
    expect(exportMarkdown(editor)).toBe('```infographic\ninfographic compare-swot\n  data\n```')

    expect(canTurnInto(editor.state, 0)).toBe(true)
    expect(turnBlockInto(editor, 0, 'code')).toBe(true)
    expect(blockTypeAt(editor.state, 0)).toBe('code')
    expect(exportMarkdown(editor)).toBe('```\ninfographic compare-swot\n  data\n```')

    expect(turnBlockInto(editor, 0, 'paragraph')).toBe(true)
    expect(blockTypeAt(editor.state, 0)).toBe('paragraph')
    expect(turnBlockInto(editor, 0, 'infographic')).toBe(true)
    expect(blockTypeAt(editor.state, 0)).toBe('infographic')
  })

  test('typing ```infographic + Enter creates an InfographicBlock in doc pages and a CodeBlock in knowledge pages', () => {
    const docEditor = open('')
    typeText(docEditor, '```infographic')
    expect(press(docEditor, 'Enter')).toBe(true)
    expect(docEditor.state.doc.content[0]!.type).toBe(InfographicBlock.type)

    const knowledgeEditor = open('', knowledgeExtension)
    typeText(knowledgeEditor, '```infographic')
    expect(press(knowledgeEditor, 'Enter')).toBe(true)
    expect(knowledgeEditor.state.doc.content[0]!.type).toBe(T.CodeBlock.type)
    expect(printXml(readTree(knowledgeEditor))).toBe('<page><pre lang="infographic" /></page>')
  })
})

describe('Injective <pre lang="mermaid"> and <pre lang="infographic"> Markdown round-trips', () => {
  test('explicit <pre lang="mermaid"> and <pre lang="infographic"> round-trip without colliding in doc mode', () => {
    for (const xml of [
      '<page><pre lang="mermaid">flowchart LR</pre></page>',
      '<page><pre lang="mermaid" /><p>After</p></page>',
      '<page><pre lang="infographic">infographic compare-swot\n  data</pre></page>',
      '<page><pre lang="infographic" /></page>'
    ]) {
      const tree = parseXml(xml)
      const md = printMarkdown(tree, 'doc')
      expect(md.startsWith('```mermaid')).toBe(false)
      expect(md.startsWith('```infographic')).toBe(false)
      expect(printXml(parseMarkdown(md, 'doc'))).toBe(xml)
    }

    const withMeta = parseXml('<page><pre lang="infographic" meta="title=&quot;raw&quot;">data</pre></page>')
    const printedMeta = printMarkdown(withMeta, 'doc')
    expect(printedMeta).toBe('```infographic title="raw"\ndata\n```')
    expect(parseMarkdown(printedMeta, 'doc')).toEqual(withMeta)
  })

  test('in knowledge mode, <pre lang="mermaid"> prints as <pre> while ```infographic stays a normal fence', () => {
    for (const xml of [
      '<page><pre lang="mermaid">flowchart LR\n  A --&gt; B</pre></page>',
      '<page><pre lang="mermaid" /></page>'
    ]) {
      const tree = parseXml(xml)
      const md = printMarkdown(tree, 'knowledge')
      expect(md.startsWith('```mermaid')).toBe(false)
      expect(printXml(parseMarkdown(md, 'knowledge'))).toBe(xml)
    }

    const infoTree = parseMarkdown('```infographic\ninfographic compare-swot\n  data\n```', 'knowledge')
    expect(printXml(infoTree)).toBe('<page><pre lang="infographic">infographic compare-swot\n  data</pre></page>')
    expect(printMarkdown(infoTree, 'knowledge')).toBe('```infographic\ninfographic compare-swot\n  data\n```')
  })
})

describe('/infographic and /chart block catalog and host callback', () => {
  test('filterBlockOptions exposes /infographic in doc mode only and /chart only when host.insertChart is provided in doc mode', () => {
    const plainDoc = open('')
    expect(filterBlockOptions(plainDoc.state, 'infographic').map(option => option.type)).toContain('infographic')
    expect(filterBlockOptions(plainDoc.state, '信息图').map(option => option.type)).toContain('infographic')
    expect(filterBlockOptions(plainDoc.state, 'swot').map(option => option.type)).toContain('infographic')
    expect(filterBlockOptions(plainDoc.state, 'chart').map(option => option.type)).not.toContain('chart')
    expect(applyBlockType(plainDoc, 'chart')).toBe(false)

    const docWithChart = openWithHost('', { insertChart: () => {} })
    for (const query of ['chart', 'bar', 'scatter', '图表', '柱状图', '多维表图表']) {
      expect(filterBlockOptions(docWithChart.state, query).map(option => option.type)).toContain('chart')
    }
    expect(blockOptions.find(option => option.type === 'chart')?.turnInto).toBe(false)

    const knowledgeWithChart = open('', [knowledgeExtension, hostExtension({ insertChart: () => {} })])
    expect(filterBlockOptions(knowledgeWithChart.state, '').map(option => option.type)).toContain('mermaid')
    expect(filterBlockOptions(knowledgeWithChart.state, '').map(option => option.type)).not.toContain('infographic')
    expect(filterBlockOptions(knowledgeWithChart.state, '').map(option => option.type)).not.toContain('chart')
    expect(applyBlockType(knowledgeWithChart, 'chart')).toBe(false)
    expect(applyBlockType(knowledgeWithChart, 'infographic')).toBe(false)
  })

  test('applyBlockType and insertBesideBlock invoke host.insertChart for both synchronous and dialog-driven insertion', () => {
    const editor = openWithHost('Summary /chart', {
      insertChart: target => {
        insertEmbed(target, { ref: 'base_sales', table: 'tbl_q1', view: 'viw_chart' })
      }
    })
    const to = editor.state.selection.head
    expect(applyBlockType(editor, 'chart', { from: to - 6, to })).toBe(true)
    expect(exportMarkdown(editor)).toBe(
      'Summary&#x20;\n\n<embed ref="base_sales" table="tbl_q1" view="viw_chart" />\n\n<p />'
    )
    expect(undoDepth(editor.state)).toBe(1)
    expect(undo(editor)).toBe(true)
    expect(exportMarkdown(editor)).toBe('Summary /chart')

    let deferredEditor: typeof editor | undefined
    const asyncEditor = openWithHost('First /chart', {
      insertChart: target => {
        deferredEditor = target
      }
    })
    const asyncTo = asyncEditor.state.selection.head
    expect(applyBlockType(asyncEditor, 'chart', { from: asyncTo - 6, to: asyncTo })).toBe(true)
    expect(deferredEditor).toBe(asyncEditor)
    expect(exportMarkdown(asyncEditor)).toBe('First&#x20;')

    const besideCalls: number[] = []
    const besideEditor = openWithHost('First\n\nSecond', {
      insertChart: target => {
        besideCalls.push(target.state.selection.head)
      }
    })
    expect(insertBesideBlock(besideEditor, 0, 'chart')).toBe(true)
    expect(besideCalls).toHaveLength(1)
    expect(exportMarkdown(besideEditor)).toBe('First\n\n<p />\n\nSecond')
  })
})

describe('Lazy visualization bundle isolation', () => {
  const forbiddenInAllEntries = new Set(['@ankole/uikit/viz/infographic', '@antv/infographic'])

  function resolveLocal(fromFile: string, specifier: string): string | null {
    if (!specifier.startsWith('.')) return null
    const base = resolve(dirname(fromFile), specifier)
    for (const candidate of [
      base,
      `${base}.ts`,
      `${base}.tsx`,
      resolve(base, 'index.ts'),
      resolve(base, 'index.tsx')
    ]) {
      if (existsSync(candidate) && statSync(candidate).isFile()) return candidate
    }
    return null
  }

  function staticRuntimeImports(source: string): string[] {
    const clean = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1')
    const out: string[] = []
    const re = /\b(?:import|export)\s+(?!type\b)([\s\S]*?)\s+from\s+['"]([^'"]+)['"]/g
    for (const match of clean.matchAll(re)) {
      const clause = match[1]!.trim()
      if (clause.startsWith('{') && clause.endsWith('}')) {
        const parts = clause
          .slice(1, -1)
          .split(',')
          .map(part => part.trim())
          .filter(Boolean)
        if (parts.length > 0 && parts.every(part => part.startsWith('type '))) continue
      }
      out.push(match[2]!)
    }
    return out
  }

  test('public entry points never statically import Infographic runtime and reader never statically imports pele', () => {
    const checkClosure = (entryRel: string, extraForbidden: readonly string[] = []) => {
      const visited = new Set<string>()
      const queue = [resolve(import.meta.dir, entryRel)]
      while (queue.length > 0) {
        const file = queue.shift()!
        if (visited.has(file)) continue
        visited.add(file)
        for (const spec of staticRuntimeImports(readFileSync(file, 'utf8'))) {
          expect(forbiddenInAllEntries.has(spec)).toBe(false)
          expect(extraForbidden.includes(spec)).toBe(false)
          const local = resolveLocal(file, spec)
          if (local && !visited.has(local)) queue.push(local)
        }
      }
    }
    checkClosure('../src/index.ts')
    checkClosure('../src/document/index.ts', ['pele', 'pele/lazy'])
    checkClosure('../src/editor/index.ts')
    checkClosure('../src/reader.ts', ['pele', 'pele/lazy'])
  })
})
