import { readFileSync } from 'node:fs'
import path from 'node:path'
import { afterEach, beforeAll, beforeEach, describe, expect, test } from 'bun:test'
import { ExportAssets, PageExportSession, initSync } from '@ankole/kernel/word-wasm'
import { QueryClient } from '@tanstack/react-query'
import { strFromU8, unzipSync } from 'fflate'
import { loadLocale } from '../../common/i18n'
import { podPagePath } from '../../common/pod-url'
import { client as podClient } from '../api/generated/client.gen'
import type { PageDetail } from '../content-api'
import { resolveOfficeFontBlobs, type OfficeFontManifestEntry } from '../office/office-fonts'
import type { EngineRequest, EngineResponse, ExportFontNeeds, WorkerExportAsset } from '../word/word-worker'
import { isColorEmojiGrapheme, prerenderPageForExport } from './document-export-prerender'
import { downloadDocumentAsOffice } from './document-office-export'

const ONE_BY_ONE_PNG = new Uint8Array([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00, 0x0a, 0x49,
  0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82
])

const TEST_FONT_MANIFEST: OfficeFontManifestEntry[] = [
  {
    family: 'IBM Plex Sans SC',
    aliases: ['Microsoft YaHei', 'Noto Sans SC'],
    file: 'IBMPlexSansSC-Regular.ttf'
  },
  {
    family: 'IBMPlexMonoSCHalf',
    aliases: ['IBM Plex Mono SC'],
    file: 'IBMPlexMonoSCHalf-Regular.ttf'
  }
]

const docID = '00112233-4455-6677-8899-aabbccddeeff'
const allowedPageID = '11111111-2222-3333-4444-555555555555'
const restrictedPageID = '22222222-3333-4444-5555-666666666666'
const restrictedMetaPageID = '33333333-4444-5555-6666-777777777777'

const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
const previousDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')
const previousWorker = Object.getOwnPropertyDescriptor(globalThis, 'Worker')
const previousFetch = globalThis.fetch
const previousCreateObjectURL = URL.createObjectURL
const previousRevokeObjectURL = URL.revokeObjectURL

let downloads: Array<{ filename: string; blob: Blob }>
let objectBlobs: Map<string, Blob>
let workerTransferLog: Array<{ method: string; transferCount: number }>

function pageURL(id: string, title?: string): string {
  return new URL(podPagePath(id, title), 'https://ankole.test').href
}

function pageDetail(id: string, title: string, type: PageDetail['page']['type']): PageDetail {
  return {
    bindings: {},
    bindings_digest: '',
    page: {
      id,
      name: title,
      title,
      icon: null,
      type,
      position: 'a0',
      inherit_permissions: true,
      metadata: {},
      revision: 1,
      children_view: {},
      created_at: '2026-10-30T10:00:00Z',
      updated_at: '2026-10-30T10:00:00Z',
      deleted_at: null,
      actions: ['node_view'],
      role: 'view'
    },
    ancestors: [],
    actions: ['node_view'],
    role: 'view',
    child_count: 0
  }
}

/**
 * In-process `Worker` implementation backed by the real `ankole_word_wasm` module that executes
 * `structuredClone(message, { transfer })` on every `postMessage` so transferred `ArrayBuffer`s
 * genuinely detach just like a browser Web Worker.
 */
class RealWasmExportWorker {
  onmessage: ((event: MessageEvent<EngineResponse>) => void) | null = null
  onerror: ((event: ErrorEvent) => void) | null = null
  private session: PageExportSession | undefined
  private terminated = false

  postMessage(rawMessage: EngineRequest, transfer: Transferable[] = []): void {
    if (this.terminated) return
    workerTransferLog.push({ method: rawMessage.method, transferCount: transfer.length })
    const message = structuredClone(rawMessage, { transfer })
    queueMicrotask(() => {
      if (this.terminated) return
      try {
        const ok = this.dispatch(message)
        this.onmessage?.({ data: { id: message.id, ok } } as MessageEvent<EngineResponse>)
      } catch (error) {
        const errMessage = error instanceof Error ? error.message : String(error)
        this.onmessage?.({ data: { id: message.id, error: { message: errMessage } } } as MessageEvent<EngineResponse>)
      }
    })
  }

  private dispatch(message: EngineRequest): unknown {
    switch (message.method) {
      case 'openPageExport': {
        const [requestJson, assets, includeFontNeeds] = message.args as [string, WorkerExportAsset[], boolean]
        const staged = new ExportAssets()
        let consumed = false
        try {
          for (const asset of assets) {
            staged.put(asset.key, asset.bytes)
          }
          consumed = true
          const next = PageExportSession.from_page(requestJson, staged)
          this.session?.free()
          this.session = next
          return includeFontNeeds ? (JSON.parse(next.font_needs()) as ExportFontNeeds) : null
        } catch (error) {
          if (!consumed) staged.free()
          throw error
        }
      }
      case 'addExportFonts': {
        if (!this.session) throw new Error('The page export session is not open')
        const [fontBlobs] = message.args as [Uint8Array[]]
        for (const blob of fontBlobs) {
          PageExportSession.add_font(blob)
        }
        return JSON.parse(this.session.font_needs()) as ExportFontNeeds
      }
      case 'exportPageDocx': {
        if (!this.session) throw new Error('The page export session is not open')
        return this.session.export_docx()
      }
      case 'exportPagePdf': {
        if (!this.session) throw new Error('The page export session is not open')
        return this.session.export_pdf()
      }
      default:
        throw new Error(`Unsupported worker method in test: ${String(message.method)}`)
    }
  }

  terminate(): void {
    this.terminated = true
    this.session?.free()
    this.session = undefined
  }
}

beforeAll(async () => {
  await loadLocale('en-US')
  const wasmPath = path.resolve(import.meta.dir, '../../../kernel/dist/word-wasm/ankole_word_wasm_bg.wasm')
  initSync({ module: readFileSync(wasmPath) })
})

beforeEach(() => {
  downloads = []
  objectBlobs = new Map()
  workerTransferLog = []
  podClient.setConfig({ baseUrl: 'https://ankole.test' })
  URL.createObjectURL = (object: Blob | MediaSource) => {
    const url = `blob:ankole/${objectBlobs.size + 1}`
    if (object instanceof Blob) objectBlobs.set(url, object)
    return url
  }
  URL.revokeObjectURL = () => {}

  const fakeDocument = {
    compatMode: 'CSS1Compat',
    documentElement: { lang: 'en-US', dataset: { theme: 'dark' }, getAttribute: () => 'dark' },
    body: { appendChild() {} },
    querySelector: (selector: string) =>
      selector.includes('csrf-token')
        ? { content: 'csrf-test' }
        : selector.includes('ankole-authentication')
          ? { content: 'auth-1' }
          : null,
    createElement: (tag: string) => {
      if (tag === 'a') {
        const anchor = {
          href: '',
          download: '',
          remove() {},
          click() {
            const blob = objectBlobs.get(anchor.href)
            if (blob) downloads.push({ filename: anchor.download, blob })
          }
        }
        return anchor
      }
      if (tag === 'canvas') {
        return {
          width: 64,
          height: 64,
          getContext: () => ({
            clearRect() {},
            fillText() {},
            fillRect() {},
            drawImage() {},
            textAlign: 'center',
            textBaseline: 'middle',
            font: ''
          }),
          toBlob: (cb: (blob: Blob | null) => void) => cb(new Blob([ONE_BY_ONE_PNG], { type: 'image/png' }))
        }
      }
      throw new Error(`Unexpected element: ${tag}`)
    }
  }

  Object.defineProperty(globalThis, 'document', { configurable: true, value: fakeDocument })
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: {
      location: new URL(pageURL(docID)),
      document: fakeDocument
    }
  })
  Object.defineProperty(globalThis, 'Worker', {
    configurable: true,
    value: RealWasmExportWorker
  })
})

afterEach(() => {
  if (previousWindow) Object.defineProperty(globalThis, 'window', previousWindow)
  else Reflect.deleteProperty(globalThis, 'window')
  if (previousDocument) Object.defineProperty(globalThis, 'document', previousDocument)
  else Reflect.deleteProperty(globalThis, 'document')
  if (previousWorker) Object.defineProperty(globalThis, 'Worker', previousWorker)
  else Reflect.deleteProperty(globalThis, 'Worker')
  globalThis.fetch = previousFetch
  URL.createObjectURL = previousCreateObjectURL
  URL.revokeObjectURL = previousRevokeObjectURL
})

describe('document-export-prerender & downloadDocumentAsOffice', () => {
  test('distinguishes color emoji graphemes from monochrome text/task symbols', () => {
    expect(isColorEmojiGrapheme('🚀')).toBe(true)
    expect(isColorEmojiGrapheme('👩‍💻')).toBe(true)
    expect(isColorEmojiGrapheme('❤️')).toBe(true)
    expect(isColorEmojiGrapheme('1️⃣')).toBe(true)
    expect(isColorEmojiGrapheme('🇨🇳')).toBe(true)

    expect(isColorEmojiGrapheme('☐')).toBe(false)
    expect(isColorEmojiGrapheme('☑')).toBe(false)
    expect(isColorEmojiGrapheme('©')).toBe(false)
    expect(isColorEmojiGrapheme('1')).toBe(false)
    expect(isColorEmojiGrapheme('#')).toBe(false)
  })

  test('propagates single-deduction net widths into narrow columns, tokenizes Shiki code, validates KaTeX, and unwraps comments', async () => {
    const observedWidths: Array<{ kind: string; widthPt: number }> = []
    const xml = `<page>
      <p>Lead <comment ids="01930000-0000-7000-8000-000000000001">annotated 🚀 text</comment>☐ and <inline-math>$x^2 + y^2$</inline-math> and <inline-math>\\frac{1}{</inline-math> and <a href="ankole:asset/spec.pdf">Spec</a> and <a href="/spaces/alpha?authentication_ref=secret-tok&amp;tab=1">Space</a></p>
      <mermaid view="diagram">graph TD\nA--&gt;B</mermaid>
      <columns>
        <column width="428"><infographic view="diagram">infographic list-row-simple-horizontal-arrow\ndata\n  items\n    - label Step 1</infographic></column>
        <column><pre lang="ts">const answer: number = 42</pre></column>
      </columns>
      <math>$\\begin{pmatrix}a &amp; b \\\\ c &amp; d\\end{pmatrix}$</math>
      <math>\\frac{1}{</math>
      <table layout="full" widths="100,100"><tr><td><mermaid view="diagram">graph LR\nX--&gt;Y</mermaid></td><td><p>Cell</p></td></tr></table>
    </page>`

    const result = await prerenderPageForExport({
      pageID: docID,
      xml,
      icon: '📌',
      format: 'pdf',
      hooks: {
        rasterizeDiagram: async (kind, _source, netWidthPt) => {
          observedWidths.push({ kind, widthPt: netWidthPt })
          return {
            kind: 'ok',
            bytes: ONE_BY_ONE_PNG,
            widthPt: Math.min(240, netWidthPt),
            heightPt: 90
          }
        }
      }
    })

    expect(result.iconAssetKey).toBeDefined()
    expect(observedWidths).toHaveLength(3)
    const rootMermaid = observedWidths.find(item => item.kind === 'mermaid' && item.widthPt > 400)!
    const fullTableMermaid = observedWidths.find(item => item.kind === 'mermaid' && item.widthPt < 400)!
    const narrowInfographic = observedWidths.find(item => item.kind === 'infographic')!
    expect(rootMermaid.widthPt).toBeCloseTo(475.28, 1)
    expect(fullTableMermaid.widthPt).toBeCloseTo(475.28 / 2 - 12, 1)
    expect(narrowInfographic.widthPt).toBeGreaterThan(120)
    expect(narrowInfographic.widthPt).toBeLessThan(145)

    expect(result.root.type).toBe('element')
    if (result.root.type !== 'element') throw new Error('expected root element')
    const children = result.root.children ?? []

    // Comment wrapper stripped and color emoji segmented into emojiImage while ☐ stays plain text.
    const firstPara = children[0]!
    expect(firstPara.type === 'element' && firstPara.name === 'p').toBe(true)
    if (firstPara.type === 'element') {
      const hasCommentTag = (firstPara.children ?? []).some(c => c.type === 'element' && c.name === 'comment')
      expect(hasCommentTag).toBe(false)
      const emojiNodes = (firstPara.children ?? []).filter(c => c.type === 'emojiImage')
      expect(emojiNodes).toHaveLength(1)
      const joinedText = (firstPara.children ?? [])
        .map(c => (c.type === 'text' ? c.value : c.type === 'emojiImage' ? c.alt : ''))
        .join('')
      expect(joinedText).toContain('Lead annotated 🚀 text☐')
      const linkNodes = (firstPara.children ?? []).filter(
        (c): c is Extract<typeof c, { type: 'element' }> => c.type === 'element' && c.name === 'a'
      )
      expect(linkNodes).toHaveLength(2)
      expect(linkNodes[0]!.attrs?._export_href).toContain(
        `/api/v2/pod/pages/${docID}/files/content?path=assets%2Fspec.pdf`
      )
      expect(linkNodes[0]!.attrs?._export_href).not.toContain('authentication_ref')
      expect(linkNodes[1]!.attrs?._export_href).toBe('https://ankole.test/spaces/alpha?tab=1')

      const inlineMathNodes = (firstPara.children ?? []).filter(
        (c): c is Extract<typeof c, { type: 'element' }> => c.type === 'element' && c.name === 'inline-math'
      )
      expect(inlineMathNodes).toHaveLength(2)
      expect(inlineMathNodes[0]!.attrs?._export_invalid).toBeUndefined()
      expect(inlineMathNodes[1]!.attrs?._export_invalid).toBe('true')
    }

    // Shiki github-light highlighting produces colored codeLine runs inside the 70% column.
    const columnsNode = children[2]!
    if (columnsNode.type !== 'element') throw new Error('expected columns')
    const rightCol = columnsNode.children?.[1]
    if (!rightCol || rightCol.type !== 'element') throw new Error('expected right column')
    const preNode = rightCol.children?.[0]
    if (!preNode || preNode.type !== 'element') throw new Error('expected pre')
    expect(preNode.children?.[0]?.type).toBe('codeLine')
    if (preNode.children?.[0]?.type === 'codeLine') {
      expect(preNode.children[0].runs.some(run => Boolean(run.color))).toBe(true)
    }

    // Valid matrix math stays unflagged; invalid `\frac{1}{` gets `_export_invalid = "true"`.
    const validMath = children[3]!
    const invalidMath = children[4]!
    if (validMath.type !== 'element' || invalidMath.type !== 'element') throw new Error('expected math elements')
    expect(validMath.attrs?._export_invalid).toBeUndefined()
    expect(invalidMath.attrs?._export_invalid).toBe('true')
  })

  test('exports print-ready .docx via real WASM kernel without font fetches and scrubs restricted targets and authentication_ref', async () => {
    const requestedUrls: string[] = []
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = new URL(input instanceof Request ? input.url : String(input), 'https://ankole.test')
      requestedUrls.push(url.pathname)
      if (url.pathname === `/api/v2/pod/pages/${allowedPageID}`) {
        return Response.json(pageDetail(allowedPageID, 'Approved Architecture Spec', 'doc'))
      }
      if (url.pathname === `/api/v2/pod/pages/${restrictedPageID}`) {
        return Response.json({ error: 'forbidden' }, { status: 403 })
      }
      if (url.pathname === '/api/v2/pod/mentions/resolve') {
        return Response.json({
          pages: [],
          principals: [
            { principal_uid: 'u_alice', access: 'ok', name: 'Alice Zhang' },
            { principal_uid: 'u_secret_exec', access: 'not_found', name: 'Top Secret CEO' }
          ]
        })
      }
      if (
        url.pathname === `/api/v2/pod/pages/${docID}/files/content` &&
        url.searchParams.get('path') === 'assets/diagram-ok.png'
      ) {
        return new Response(ONE_BY_ONE_PNG, {
          status: 200,
          headers: { 'content-type': 'image/png' }
        })
      }
      if (url.pathname.endsWith('/assets/private-403.png')) {
        return new Response('forbidden', { status: 403 })
      }
      throw new Error(`Unexpected fetch in .docx export: ${url.href}`)
    }) as unknown as typeof fetch

    const wideCells = Array.from({ length: 18 }, (_, idx) => `<td><p>C${idx + 1}</p></td>`).join('')
    const xml = `<page>
      <h1>Quarterly Review</h1>
      <p>Owner <mention principal="u_alice"/> and <mention principal="u_secret_exec"/> reviewing <mention page="${allowedPageID}"/> vs <mention page="${restrictedPageID}"/> and <a href="https://ankole.test/files/report.pdf?authentication_ref=leak-token-999&amp;v=2">External Link</a>.</p>
      <callout tone="warning" icon="⚠️"><p>Unacknowledged OT draft paragraph</p></callout>
      <table>
        <tr><th colspan="2"><p>Merged Header</p></th><th><p>Metric</p></th></tr>
        <tr><td rowspan="2"><p>Span Group</p></td><td><p>Q1</p></td><td><p>99.95%</p></td></tr>
        <tr><td><p>Q2</p></td><td><p>99.99%</p></td></tr>
      </table>
      <table><tr>${wideCells}</tr></table>
      <ul><li task="done"><p>Shipped kernel</p></li><li task="todo"><p>Verify Word</p></li></ul>
      <pre lang="ts">export const status = 'green'</pre>
      <p>Inline formula <inline-math>$E = mc^2$</inline-math> inside prose.</p>
      <math>$$\\sum_{i=1}^{n} x_i = 1$$</math>
      <media kind="image" src="ankole:asset/diagram-ok.png" title="Architecture"/>
      <media kind="image" src="https://ankole.test/assets/private-403.png?authentication_ref=img-secret-123" title="Fallback Image"/>
      <embed ref="${restrictedPageID}"/>
    </page>`

    const client = new QueryClient()
    await downloadDocumentAsOffice(
      client,
      {
        pageID: docID,
        xml,
        title: 'Live Draft Report',
        icon: '📄'
      },
      'docx'
    )

    // .docx branch must never request `/fonts/office/*`.
    expect(requestedUrls.some(p => p.startsWith('/fonts/office'))).toBe(false)
    // Freshly owned image buffer was transferred zero-copy into the Worker.
    expect(workerTransferLog.find(entry => entry.method === 'openPageExport')?.transferCount).toBeGreaterThan(0)

    expect(downloads).toHaveLength(1)
    expect(downloads[0]!.filename).toBe('Live-Draft-Report.docx')
    expect(downloads[0]!.blob.type).toBe('application/vnd.openxmlformats-officedocument.wordprocessingml.document')

    const archive = unzipSync(new Uint8Array(await downloads[0]!.blob.arrayBuffer()))
    const documentXml = strFromU8(archive['word/document.xml']!)
    const headerXml = strFromU8(archive['word/header1.xml']!)
    const footerXml = strFromU8(archive['word/footer1.xml']!)

    expect(documentXml).toContain('Unacknowledged OT draft paragraph')
    expect(documentXml).toContain('@Alice Zhang')
    expect(documentXml).toContain('Approved Architecture Spec')
    expect(documentXml).toContain('<m:oMath')
    expect(documentXml).toContain('w:gridSpan')
    expect(documentXml).toContain('w:vMerge')
    expect(documentXml).toContain('w:tblHeader')
    expect(headerXml).toContain('Live Draft Report')
    expect(footerXml).toContain('PAGE')
    expect(footerXml).toContain('NUMPAGES')
    expect(Object.keys(archive).some(name => name.startsWith('word/media/'))).toBe(true)
    // Pure lightweight OOXML: no multi-MB embedded font binaries inside `.docx`.
    expect(Object.keys(archive).some(name => name.startsWith('word/fonts/'))).toBe(false)

    // Audit every XML/rels file in the archive for zero credential or ACL metadata leakage.
    for (const [entryName, entryBytes] of Object.entries(archive)) {
      if (!entryName.endsWith('.xml') && !entryName.endsWith('.rels')) continue
      const text = strFromU8(entryBytes)
      expect(text).not.toContain('authentication_ref')
      expect(text).not.toContain('leak-token-999')
      expect(text).not.toContain('img-secret-123')
      expect(text).not.toContain('Top Secret CEO')
      expect(text).not.toContain('u_secret_exec')
      expect(text).not.toContain(restrictedPageID)
    }
  })

  test('exports Knowledge Page .pdf with metadata, converges fonts, and keeps cached font ArrayBuffers undetached across consecutive exports', async () => {
    const katexFontPath = path.resolve(
      import.meta.dir,
      '../../../../node_modules/katex/dist/fonts/KaTeX_SansSerif-Regular.ttf'
    )
    let realTtfBytes: Uint8Array
    try {
      realTtfBytes = new Uint8Array(readFileSync(katexFontPath))
    } catch {
      realTtfBytes = new Uint8Array([0x00, 0x01, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x80, 0x00, 0x03, 0x00, 0x20])
    }

    let fontFileFetchCount = 0
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = new URL(input instanceof Request ? input.url : String(input), 'https://ankole.test')
      if (url.pathname === '/fonts/office/manifest.json') {
        return Response.json({ fonts: TEST_FONT_MANIFEST })
      }
      if (url.pathname.startsWith('/fonts/office/')) {
        fontFileFetchCount += 1
        return new Response(realTtfBytes.slice(), { status: 200 })
      }
      if (url.pathname === `/api/v2/pod/pages/${allowedPageID}`) {
        return Response.json(pageDetail(allowedPageID, 'Public Customer Entity', 'knowledge'))
      }
      if (url.pathname === `/api/v2/pod/pages/${restrictedMetaPageID}`) {
        return Response.json({ error: 'forbidden' }, { status: 403 })
      }
      throw new Error(`Unexpected fetch in Knowledge PDF export: ${url.href}`)
    }) as unknown as typeof fetch

    const client = new QueryClient()
    const knowledgeInput = {
      pageID: docID,
      xml: '<page><h2>知识库中文导出 🚀</h2><p>支持结构化属性与跨页排版。</p></page>',
      title: 'Knowledge Handbook',
      icon: '🚀',
      metadata: {
        status: 'published',
        tags: ['architecture', 'print'],
        related_public: { page_id: allowedPageID },
        related_restricted: { page_id: restrictedMetaPageID }
      }
    }

    // Export #1
    await downloadDocumentAsOffice(client, knowledgeInput, 'pdf')
    expect(downloads).toHaveLength(1)
    expect(downloads[0]!.filename).toBe('Knowledge-Handbook.pdf')
    expect(downloads[0]!.blob.type).toBe('application/pdf')
    const firstPdfBytes = new Uint8Array(await downloads[0]!.blob.arrayBuffer())
    expect(new TextDecoder().decode(firstPdfBytes.subarray(0, 5))).toBe('%PDF-')
    expect(fontFileFetchCount).toBeGreaterThan(0)
    const fetchesAfterFirst = fontFileFetchCount

    // Verify `addExportFonts` NEVER put cached font buffers into `postMessage` transfer list!
    const addFontCalls = workerTransferLog.filter(entry => entry.method === 'addExportFonts')
    expect(addFontCalls.length).toBeGreaterThan(0)
    for (const call of addFontCalls) {
      expect(call.transferCount).toBe(0)
    }

    // Inspect cached font buffer directly via `resolveOfficeFontBlobs`: must remain non-detached!
    const cachedCheck = await resolveOfficeFontBlobs(['IBM Plex Sans SC'])
    expect(cachedCheck.blobs.length).toBeGreaterThan(0)
    for (const blob of cachedCheck.blobs) {
      expect(blob.byteLength).toBeGreaterThan(0)
      expect(blob.buffer.byteLength).toBeGreaterThan(0)
    }

    // Export #2: reuses module-level font cache with zero extra network fetches and succeeds cleanly.
    await downloadDocumentAsOffice(client, knowledgeInput, 'pdf')
    expect(downloads).toHaveLength(2)
    expect(fontFileFetchCount).toBe(fetchesAfterFirst)
    const secondPdfBytes = new Uint8Array(await downloads[1]!.blob.arrayBuffer())
    expect(new TextDecoder().decode(secondPdfBytes.subarray(0, 5))).toBe('%PDF-')

    const rawPdfLatin1 = new TextDecoder('latin1').decode(secondPdfBytes)
    expect(rawPdfLatin1).not.toContain('authentication_ref')
    expect(rawPdfLatin1).not.toContain(restrictedMetaPageID)
  })
})
