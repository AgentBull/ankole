import { shouldIsolateFromCommandRoot } from '@ankole/uikit'
import { describe, expect, it } from 'bun:test'
import { buildSearchableTextIndex, collectRangesFromTextIndex, shouldHandlePageFindShortcut } from './find-bar'
import {
  buildSearchResultHref,
  collectNormalizedSpanOffsets,
  collectRawMatchSpans,
  encodeSearchTarget,
  extractXmlPreview,
  findOfficeSearchMatch,
  normalizeSearchQuery,
  normalizeSearchText,
  parseSearchTarget,
  resolveFindNeedleSets,
  splitHighlightSegments
} from './search-targets'

it('prefers the indexed Office page even when an earlier query term matches elsewhere', async () => {
  const match = { page: 2 }
  const result = await findOfficeSearchMatch(
    '"another result" Ｔarget',
    2,
    async term => (term === 'target' ? [match] : [{ page: 0 }]),
    item => item.page
  )
  expect(result).toEqual({ needle: 'target', matches: [match], index: 0 })
})

type MiniNode = MiniElement | MiniText

type MiniRange = {
  startContainer: MiniText | null
  startOffset: number
  endContainer: MiniText | null
  endOffset: number
  setStart(node: MiniText, offset: number): void
  setEnd(node: MiniText, offset: number): void
  toString(): string
}

class MiniText {
  readonly nodeType = 3
  parentElement: MiniElement | null = null
  nextSibling: MiniNode | null = null
  readonly ownerDocument: MiniDocument
  readonly textContent: string
  readonly length: number

  constructor(ownerDocument: MiniDocument, text: string) {
    this.ownerDocument = ownerDocument
    this.textContent = text
    this.length = text.length
  }
}

class MiniElement {
  readonly nodeType = 1
  readonly tagName: string
  parentElement: MiniElement | null = null
  firstChild: MiniNode | null = null
  nextSibling: MiniNode | null = null
  isConnected = true
  open = false
  readonly ownerDocument: MiniDocument
  private readonly attrs = new Map<string, string>()
  private readonly classes = new Set<string>()
  private readonly childrenList: MiniNode[] = []

  constructor(ownerDocument: MiniDocument, tagName: string, attrs: Record<string, string> = {}) {
    this.ownerDocument = ownerDocument
    this.tagName = tagName.toUpperCase()
    for (const [key, value] of Object.entries(attrs)) {
      this.attrs.set(key, value)
      if (key === 'class') {
        for (const token of value.split(/\s+/).filter(Boolean)) this.classes.add(token)
      }
      if (key === 'open') this.open = true
    }
  }

  append(...nodes: Array<MiniNode | string>): this {
    for (const item of nodes) {
      const child = typeof item === 'string' ? new MiniText(this.ownerDocument, item) : item
      child.parentElement = this
      const prev = this.childrenList[this.childrenList.length - 1]
      if (prev) prev.nextSibling = child
      else this.firstChild = child
      this.childrenList.push(child)
    }
    return this
  }

  hasAttribute(name: string): boolean {
    return this.attrs.has(name)
  }

  getAttribute(name: string): string | null {
    return this.attrs.get(name) ?? null
  }

  contains(other: unknown): boolean {
    let cur = other as { parentElement?: MiniElement | null } | null
    while (cur) {
      if (cur === this) return true
      cur = cur.parentElement ?? null
    }
    return false
  }

  matches(selectorGroup: string): boolean {
    return selectorGroup
      .split(',')
      .map(part => part.trim())
      .filter(Boolean)
      .some(selector => this.matchesSingle(selector))
  }

  closest(selectorGroup: string): MiniElement | null {
    if (this.matches(selectorGroup)) return this
    return this.parentElement?.closest(selectorGroup) ?? null
  }

  querySelectorAll(): MiniElement[] {
    const out: MiniElement[] = []
    const walk = (el: MiniElement) => {
      for (const child of el.childrenList) {
        if (child.nodeType === 1) {
          out.push(child)
          walk(child)
        }
      }
    }
    walk(this)
    return out
  }

  private matchesSingle(selector: string): boolean {
    const notMatch = /^(.+):not\(\[([a-z0-9-]+)\]\)$/i.exec(selector)
    if (notMatch) {
      return this.matchesSingle(notMatch[1]!) && !this.attrs.has(notMatch[2]!)
    }
    if (selector.startsWith('.')) return this.classes.has(selector.slice(1))
    const attrEq = /^\[([a-z0-9-]+)="([^"]*)"\]$/i.exec(selector)
    if (attrEq) return this.attrs.get(attrEq[1]!) === attrEq[2]!
    const attrHas = /^\[([a-z0-9-]+)\]$/i.exec(selector)
    if (attrHas) return this.attrs.has(attrHas[1]!)
    const tagAttr = /^([a-z0-9]+)\[([a-z0-9-]+)\]$/i.exec(selector)
    if (tagAttr) return this.tagName === tagAttr[1]!.toUpperCase() && this.attrs.has(tagAttr[2]!)
    return this.tagName === selector.toUpperCase()
  }
}

class MiniDocument {
  readonly documentElement: MiniElement
  readonly body: MiniElement

  constructor() {
    this.documentElement = new MiniElement(this, 'html')
    this.body = new MiniElement(this, 'body')
    this.documentElement.append(this.body)
  }

  el(tagName: string, attrs: Record<string, string> = {}, ...children: Array<MiniNode | string>): MiniElement {
    return new MiniElement(this, tagName, attrs).append(...children)
  }

  querySelector(selectorGroup: string): MiniElement | null {
    for (const candidate of this.documentElement.querySelectorAll()) {
      if (candidate.matches(selectorGroup)) return candidate
    }
    return null
  }

  createRange(): MiniRange {
    const rootElement = this.documentElement
    return {
      startContainer: null,
      startOffset: 0,
      endContainer: null,
      endOffset: 0,
      setStart(node, offset) {
        this.startContainer = node
        this.startOffset = offset
      },
      setEnd(node, offset) {
        this.endContainer = node
        this.endOffset = offset
      },
      toString() {
        if (!this.startContainer || !this.endContainer) return ''
        if (this.startContainer === this.endContainer) {
          return this.startContainer.textContent.slice(this.startOffset, this.endOffset)
        }
        const texts: MiniText[] = []
        const collect = (node: MiniNode) => {
          if (node.nodeType === 3) texts.push(node)
          else {
            for (let child = node.firstChild; child; child = child.nextSibling) collect(child)
          }
        }
        collect(rootElement)
        const from = texts.indexOf(this.startContainer)
        const to = texts.indexOf(this.endContainer)
        if (from < 0 || to < 0 || from > to) return ''
        let out = this.startContainer.textContent.slice(this.startOffset)
        for (let i = from + 1; i < to; i++) out += texts[i]!.textContent
        out += this.endContainer.textContent.slice(0, this.endOffset)
        return out
      }
    }
  }
}

describe('search-targets', () => {
  it('encodes and parses typed search targets onto FileCommentAnchor and carrier targets', () => {
    expect(encodeSearchTarget({ kind: 'doc_section', heading: 'Overview', level: 2 })).toEqual({
      at: 'heading:Overview'
    })
    expect(encodeSearchTarget({ kind: 'md_section', heading: 'Install', level: 2, start_line: 14 })).toEqual({
      at: 'md:2:14:Install'
    })
    expect(encodeSearchTarget({ kind: 'lines', start_line: 42, end_line: 45 })).toEqual({
      at: 'lines:42-45'
    })
    expect(encodeSearchTarget({ kind: 'lines', start_line: 42, end_line: 42 })).toEqual({
      at: 'line:42'
    })
    expect(encodeSearchTarget({ kind: 'csv_rows', start_row: 7, end_row: 9 })).toEqual({
      at: 'rows:7-9'
    })
    expect(encodeSearchTarget({ kind: 'page_number', page: 3 })).toEqual({
      at: 'page:3'
    })
    expect(encodeSearchTarget({ kind: 'spreadsheet_cell', sheet_name: 'Q3 Revenue', cell: 'B12' })).toEqual({
      at: 'sheet:Q3 Revenue'
    })
    expect(
      encodeSearchTarget({ kind: 'base_table', table_id: 'tbl-1', view_id: 'viw-2', label: 'Deals / Active' })
    ).toEqual({
      at: 'table:tbl-1',
      view: 'viw-2'
    })

    expect(parseSearchTarget('heading:Overview')).toEqual({ kind: 'heading', heading: 'Overview' })
    expect(parseSearchTarget('md:2:14:Install')).toEqual({
      kind: 'file_anchor',
      anchor: { kind: 'md_section', heading: 'Install', level: 2, start_line: 14 }
    })
    expect(parseSearchTarget('line:14')).toEqual({
      kind: 'file_anchor',
      anchor: { kind: 'lines', start_line: 14, end_line: 14 }
    })
    expect(parseSearchTarget('lines:42-45')).toEqual({
      kind: 'file_anchor',
      anchor: { kind: 'lines', start_line: 42, end_line: 45 }
    })
    expect(parseSearchTarget('row:7')).toEqual({
      kind: 'file_anchor',
      anchor: { kind: 'csv_rows', start_row: 7, end_row: 7 }
    })
    expect(parseSearchTarget('rows:7-9')).toEqual({
      kind: 'file_anchor',
      anchor: { kind: 'csv_rows', start_row: 7, end_row: 9 }
    })
    expect(parseSearchTarget('page:3')).toEqual({ kind: 'page', page: 3 })
    expect(parseSearchTarget('sheet:Q3 Revenue')).toEqual({ kind: 'sheet', sheet: 'Q3 Revenue' })
    expect(parseSearchTarget('table:tbl-1', 'viw-2')).toEqual({
      kind: 'table',
      tableID: 'tbl-1',
      viewID: 'viw-2'
    })
    expect(parseSearchTarget('line:0')).toBeUndefined()
    expect(parseSearchTarget('lines:9-4')).toBeUndefined()
    expect(parseSearchTarget('unknown:1')).toBeUndefined()
  })

  it('builds destination URLs without opening an empty find bar for title-only jumps', () => {
    expect(buildSearchResultHref('/pages/weekly-report-abc', 'Weekly Report', null, ['title'])).toBe(
      '/pages/weekly-report-abc'
    )

    expect(
      buildSearchResultHref(
        '/pages/weekly-report-abc',
        'latency budget',
        { kind: 'doc_section', heading: 'SLOs', level: 2 },
        ['body']
      )
    ).toBe('/pages/weekly-report-abc?find=latency+budget&at=heading%3ASLOs')

    expect(
      buildSearchResultHref(
        '/pages/crm-abc',
        'Pipeline',
        { kind: 'base_table', table_id: 'tbl-9', view_id: 'viw-4', label: 'Pipeline' },
        ['meta']
      )
    ).toBe('/pages/crm-abc?at=table%3Atbl-9&view=viw-4')

    expect(buildSearchResultHref('/meta/brain?category=decisions', 'pricing', undefined, ['body'])).toBe(
      '/meta/brain?category=decisions&find=pricing'
    )
  })

  it('extracts preview headings and windows blocks around deep query matches', () => {
    const xml = `<page>
      <h1>Architecture</h1>
      <columns><column><p>Control plane owns durable state.</p></column></columns>
      <embed href="https://example.com" view="card" title="Runbook" description="Production checklist" />
      <media kind="image" title="Topology diagram" description="Region failover" />
      <pre>mix ecto.migrate</pre>
    </page>`
    const preview = extractXmlPreview(xml)
    expect(preview.headings).toEqual([{ level: 1, text: 'Architecture' }])
    expect(preview.excerptSkippedBefore).toBe(false)
    expect(preview.blocks.map(block => block.text)).toEqual([
      'Architecture',
      'Control plane owns durable state.',
      'Runbook — Production checklist',
      'Topology diagram — Region failover',
      'mix ecto.migrate'
    ])

    const longBlocks = Array.from({ length: 25 }, (_, idx) =>
      idx === 20 ? '<h2>Deep Section</h2><p>Target needle lives here.</p>' : `<p>Intro filler paragraph ${idx}</p>`
    ).join('')
    const windowed = extractXmlPreview(`<page><h1>Top</h1>${longBlocks}</page>`, 'Target needle')
    expect(windowed.headings).toEqual([
      { level: 1, text: 'Top' },
      { level: 2, text: 'Deep Section' }
    ])
    expect(windowed.excerptSkippedBefore).toBe(true)
    expect(windowed.blocks.some(block => block.text.includes('Target needle'))).toBe(true)
  })

  it('maps full NFKC expansions, contractions, and compatibility forms back to exact UTF-16 spans', () => {
    // Ligature expansion (ﬃ -> ffi), halfwidth voiced katakana contraction (ｶﾞﾗｽ -> ガラス),
    // circled digits (① -> 1), fullwidth ASCII (Ｑ４ -> q4), and combining accents (Cafe\u0301 -> café).
    const pairs: Array<[string, string, string]> = [
      ['Visit our oﬃce tomorrow', 'office', 'oﬃce'],
      ['Visit our office tomorrow', 'oﬃce', 'office'],
      ['強化ｶﾞﾗｽパネル', 'ガラス', 'ｶﾞﾗｽ'],
      ['強化ガラスパネル', 'ｶﾞﾗｽ', 'ガラス'],
      ['手順①を確認', '1', '①'],
      ['Review Ｑ４　targets', 'Q4', 'Ｑ４'],
      ['Meet at Cafe\u0301 Central', 'café', 'Cafe\u0301']
    ]

    for (const [raw, query, expectedHit] of pairs) {
      const normalized = normalizeSearchText(raw)
      const spans = collectRawMatchSpans(normalized, [normalizeSearchQuery(query)])
      expect(spans).toHaveLength(1)
      expect(raw.slice(spans[0]!.start, spans[0]!.end)).toBe(expectedHit)

      const segments = splitHighlightSegments(raw, query)
      expect(segments.filter(seg => seg.hit).map(seg => seg.text)).toEqual([expectedHit])
    }

    expect(resolveFindNeedleSets('History item 0001')).toEqual({
      primary: ['history item 0001'],
      fallback: []
    })
    expect(resolveFindNeedleSets('"status": "ready"')).toEqual({
      primary: ['"status": "ready"'],
      fallback: []
    })

    const quoted = resolveFindNeedleSets('"部署核查"', { searchSyntax: true })
    expect(quoted).toEqual({ primary: ['部署核查'], fallback: [] })

    const multi = resolveFindNeedleSets('部署 已就绪', { searchSyntax: true })
    expect(multi.primary).toEqual(['部署 已就绪'])
    expect(multi.fallback).toEqual(['已就绪', '部署'])

    const haystack = normalizeSearchQuery('第四季度部署清单目前均已就绪')
    expect(collectNormalizedSpanOffsets(haystack, multi.primary)).toEqual([])
    expect(collectNormalizedSpanOffsets(haystack, multi.fallback)).toEqual([
      { start: 4, end: 6 },
      { start: 11, end: 14 }
    ])
  })

  it('preserves block and line boundaries while concatenating inline markup in DOM text indexing', () => {
    const doc = new MiniDocument()
    const root = doc.el(
      'div',
      {},
      doc.el('p', {}, 'foo'),
      doc.el('p', {}, 'bar'),
      doc.el('p', {}, 'alpha', doc.el('br'), 'beta'),
      doc.el('h2', {}, 'Cust', doc.el('strong', {}, 'om'), ' Section'),
      doc.el('table', {}, doc.el('tr', {}, doc.el('td', {}, 'SKU-200'), doc.el('td', {}, 'EMEA'))),
      doc.el('p', {}, 'Back oﬃce team')
    )
    doc.body.append(root)

    const index = buildSearchableTextIndex(root as unknown as Element)

    // Adjacent blocks and <br> never produce false cross-boundary concatenated hits.
    expect(collectRangesFromTextIndex(index, 'foobar')).toHaveLength(0)
    expect(collectRangesFromTextIndex(index, 'alphabeta')).toHaveLength(0)

    // Phrase queries across block/cell boundaries match via inserted boundary whitespace.
    expect(collectRangesFromTextIndex(index, 'foo bar')).toHaveLength(1)
    expect(collectRangesFromTextIndex(index, 'SKU-200 EMEA')).toHaveLength(1)

    // Inline formatting inside a heading concatenates seamlessly and maps back to DOM text nodes.
    const inlineHit = collectRangesFromTextIndex(index, 'Custom Section')
    expect(inlineHit).toHaveLength(1)
    expect(inlineHit[0]!.toString()).toBe('Custom Section')

    // Length-changing NFKC ligature inside a DOM Text node maps to the exact Text slice.
    const ligatureHit = collectRangesFromTextIndex(index, 'office')
    expect(ligatureHit).toHaveLength(1)
    expect(ligatureHit[0]!.toString()).toBe('oﬃce')
  })

  it('scopes PageWorkspace Cmd/Ctrl+F away from PageChat, dialogs, and already-handled events', () => {
    const doc = new MiniDocument()
    const sidebarLink = doc.el('a', { href: '/pages/spec' }, 'Spec')
    const sidebar = doc.el('aside', { 'data-sidebar': 'sidebar' }, sidebarLink)
    const editorArea = doc.el('div', { class: 'pod-page-content' }, 'Body')
    const pageColumn = doc.el('div', { class: 'pod-page-main' }, editorArea)
    const chatInput = doc.el('textarea', {})
    const pageChat = doc.el('aside', { class: 'pod-page-chat' }, chatInput)
    doc.body.append(sidebar, pageColumn, pageChat)

    const makeEvent = (target: unknown, overrides: Partial<KeyboardEvent> = {}) =>
      ({
        key: 'f',
        metaKey: true,
        ctrlKey: false,
        shiftKey: false,
        altKey: false,
        isComposing: false,
        defaultPrevented: false,
        repeat: false,
        target,
        ...overrides
      }) as unknown as KeyboardEvent

    // Accepted when focused inside pageColumn, on document.body, or on a passive sidebar link.
    expect(
      shouldHandlePageFindShortcut(
        makeEvent(editorArea),
        pageColumn as unknown as HTMLElement,
        editorArea as unknown as Element
      )
    ).toBe(true)
    expect(
      shouldHandlePageFindShortcut(
        makeEvent(doc.body),
        pageColumn as unknown as HTMLElement,
        doc.body as unknown as Element
      )
    ).toBe(true)
    expect(
      shouldHandlePageFindShortcut(
        makeEvent(sidebarLink),
        pageColumn as unknown as HTMLElement,
        sidebarLink as unknown as Element
      )
    ).toBe(true)

    // Rejected when ChatPage already called preventDefault() or when focus is inside PageChat.
    expect(
      shouldHandlePageFindShortcut(
        makeEvent(chatInput, { defaultPrevented: true }),
        pageColumn as unknown as HTMLElement,
        chatInput as unknown as Element
      )
    ).toBe(false)
    expect(
      shouldHandlePageFindShortcut(
        makeEvent(chatInput),
        pageColumn as unknown as HTMLElement,
        chatInput as unknown as Element
      )
    ).toBe(false)

    // Rejected while any modal dialog (such as Cmd+K PodCommandMenu) is open.
    const dialogInput = doc.el('input', { 'cmdk-input': '' })
    const dialog = doc.el('div', { role: 'dialog', 'data-slot': 'dialog-content' }, dialogInput)
    doc.body.append(dialog)
    expect(
      shouldHandlePageFindShortcut(
        makeEvent(dialogInput),
        pageColumn as unknown as HTMLElement,
        dialogInput as unknown as Element
      )
    ).toBe(false)
    expect(
      shouldHandlePageFindShortcut(
        makeEvent(doc.body),
        pageColumn as unknown as HTMLElement,
        doc.body as unknown as Element
      )
    ).toBe(false)
  })

  it('isolates Enter and arrow keys on interactive buttons inside Command while preserving item selection and Escape', () => {
    const doc = new MiniDocument()
    const cmdkInput = doc.el('input', { 'cmdk-input': '' })
    const filterButton = doc.el('button', { type: 'button' }, 'Title only')
    const deleteIcon = doc.el('svg', {})
    const nestedDeleteButton = doc.el('button', { type: 'button' }, deleteIcon)
    const cmdkItem = doc.el('div', { 'cmdk-item': '', role: 'option' }, 'Recent query', nestedDeleteButton)
    doc.body.append(cmdkInput, filterButton, cmdkItem)

    // Toolbar buttons and buttons nested inside a CommandItem (or SVG children inside them) are isolated on Enter/Arrows.
    expect(
      shouldIsolateFromCommandRoot({ key: 'Enter', ctrlKey: false, target: filterButton as unknown as EventTarget })
    ).toBe(true)
    expect(
      shouldIsolateFromCommandRoot({
        key: 'Enter',
        ctrlKey: false,
        target: nestedDeleteButton as unknown as EventTarget
      })
    ).toBe(true)
    expect(
      shouldIsolateFromCommandRoot({ key: 'Enter', ctrlKey: false, target: deleteIcon as unknown as EventTarget })
    ).toBe(true)
    expect(
      shouldIsolateFromCommandRoot({ key: 'ArrowDown', ctrlKey: false, target: filterButton as unknown as EventTarget })
    ).toBe(true)

    // Escape still bubbles to close the hosting Dialog.
    expect(
      shouldIsolateFromCommandRoot({ key: 'Escape', ctrlKey: false, target: filterButton as unknown as EventTarget })
    ).toBe(false)

    // CommandInput and CommandItem themselves continue to drive cmdk navigation and selection.
    expect(
      shouldIsolateFromCommandRoot({ key: 'Enter', ctrlKey: false, target: cmdkInput as unknown as EventTarget })
    ).toBe(false)
    expect(
      shouldIsolateFromCommandRoot({ key: 'Enter', ctrlKey: false, target: cmdkItem as unknown as EventTarget })
    ).toBe(false)
  })
})
