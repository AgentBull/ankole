import { parallel } from '@agentbull/active-support'
import { parseXml, unwrapMathDelimiters } from '@ankole/block-editor/document'
import { metadataFileURL } from '../content-api'
import { isCustomEmojiIcon, pageIcon } from '../page-icon-value'
import type { WorkerExportAsset } from '../word/word-engine'
import {
  defaultHighlightCode,
  defaultRasterizeDiagram,
  defaultRasterizeEmoji,
  defaultValidateMath,
  fetchImageBytes,
  resolveExportLinkHref,
  resolvePageAssetFetchUrl,
  type CodeSpan,
  type DiagramRasterResult
} from './document-export-media'
import type { DocumentElement } from './document-tools'

export type { CodeSpan, DiagramRasterResult }
export type PrerenderFormat = 'docx' | 'pdf'

export type ExportNode =
  | {
      type: 'element'
      name: string
      attrs?: Record<string, string>
      children?: ExportNode[]
    }
  | {
      type: 'text'
      value: string
    }
  | {
      type: 'emojiImage'
      asset_key: string
      alt: string
    }
  | {
      type: 'codeLine'
      runs: CodeSpan[]
    }

export type PrerenderHooks = {
  rasterizeDiagram?: (
    kind: 'mermaid' | 'infographic',
    source: string,
    netWidthPt: number
  ) => Promise<DiagramRasterResult | undefined>
  rasterizeEmoji?: (cluster: string) => Promise<Uint8Array | undefined>
  highlightCode?: (source: string, language?: string) => Promise<CodeSpan[][] | undefined>
  validateMath?: (latex: string, displayMode?: boolean) => Promise<boolean>
}

export type PrerenderPageInput = {
  pageID: string
  xml: string | DocumentElement
  icon?: string | null
  format: PrerenderFormat
  hooks?: PrerenderHooks
}

export type PrerenderPageResult = {
  root: ExportNode
  assets: WorkerExportAsset[]
  iconText?: string
  iconAssetKey?: string
}

const ROOT_CONTENT_WIDTH_PT = 475.28
const MIN_CONTAINER_WIDTH_PT = 72
const INDENT_STEP_PT = 18
const LIST_STEP_PT = 20
const COLUMN_GUTTER_PT = 12
const MIN_COLUMN_WIDTH_PT = 48
const CALLOUT_ICON_COL_PT = 26
const PRERENDER_CONCURRENCY = 4

const graphemeSegmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' })

/**
 * Identifies Unicode TR#51 color-emoji grapheme clusters while keeping monochrome text symbols
 * (`☐`, `☑`, `©`, `®`, `™`, `#`, `*`, digits, arrows, bullets) on vector font paths unless an
 * explicit emoji variation selector (`U+FE0F`) or keycap (`U+20E3`) is present.
 */
export function isColorEmojiGrapheme(cluster: string): boolean {
  if (!cluster || cluster.includes('\uFE0E')) return false
  if (cluster.includes('\u20E3')) return true
  if (/\p{Regional_Indicator}/u.test(cluster)) return true
  if (cluster.includes('\uFE0F') && /\p{Emoji}/u.test(cluster)) return true
  return /\p{Emoji_Presentation}/u.test(cluster)
}

type ParsedChild = DocumentElement['children'][number]

function extractPlainText(children: readonly ParsedChild[]): string {
  let text = ''
  const visit = (node: ParsedChild) => {
    if (node.type === 'text') {
      text += node.value
      return
    }
    if (node.name === 'br') {
      text += '\n'
      return
    }
    for (const child of node.children) visit(child)
  }
  for (const child of children) visit(child)
  return text
}

function waterfillWidths(weights: readonly number[], targetTotal: number, floor: number): number[] {
  const n = weights.length
  if (n === 0) return []
  const effectiveFloor = Math.max(1, Math.min(floor, targetTotal / n))
  const out = Array.from<number>({ length: n }).fill(0)
  const locked = Array.from<boolean>({ length: n }).fill(false)

  for (let iter = 0; iter <= n; iter += 1) {
    let lockedCount = 0
    let remWeight = 0
    for (let i = 0; i < n; i += 1) {
      if (locked[i]) lockedCount += 1
      else remWeight += Math.max(0.1, weights[i]!)
    }
    const remTotal = Math.max(0, targetTotal - lockedCount * effectiveFloor)
    if (remWeight <= 0) {
      for (let i = 0; i < n; i += 1) {
        if (!locked[i]) out[i] = effectiveFloor
      }
      break
    }
    let newlyLocked = false
    for (let i = 0; i < n; i += 1) {
      if (locked[i]) continue
      const share = remTotal * (Math.max(0.1, weights[i]!) / remWeight)
      if (share < effectiveFloor - 1e-3) {
        out[i] = effectiveFloor
        locked[i] = true
        newlyLocked = true
      } else {
        out[i] = share
      }
    }
    if (!newlyLocked) break
  }
  return out
}

function estimateTableColumnWidths(
  rows: readonly DocumentElement[],
  declaredAttr: string | undefined,
  netWidthPt: number,
  forceFull = false
): number[] {
  let maxCols = 0
  const activeRowspans: number[] = []
  for (const row of rows) {
    let col = 0
    for (const cell of row.children) {
      if (cell.type !== 'element' || (cell.name !== 'td' && cell.name !== 'th')) continue
      while ((activeRowspans[col] ?? 0) > 0) {
        activeRowspans[col]!--
        col += 1
      }
      const colspan = Math.max(1, Math.min(63, Number.parseInt(cell.attrs.colspan ?? '1', 10) || 1))
      const rowspan = Math.max(1, Number.parseInt(cell.attrs.rowspan ?? '1', 10) || 1)
      if (rowspan > 1) {
        for (let k = 0; k < colspan; k += 1) {
          activeRowspans[col + k] = Math.max(activeRowspans[col + k] ?? 0, rowspan - 1)
        }
      }
      col += colspan
    }
    while ((activeRowspans[col] ?? 0) > 0) {
      activeRowspans[col]!--
      col += 1
    }
    if (col > maxCols) maxCols = col
  }
  if (maxCols <= 0) return []

  const declaredPt = (declaredAttr ?? '')
    .split(',')
    .map(part => Number.parseInt(part.trim(), 10))
    .filter(px => Number.isFinite(px) && px > 0)
    .map(px => Math.min(9999, Math.max(1, px)) * 0.75)

  const weights = Array.from({ length: maxCols }, (_, idx) => declaredPt[idx] ?? Math.max(36, netWidthPt / maxCols))
  const totalDesired = weights.reduce((acc, w) => acc + w, 0)
  if (!forceFull && declaredPt.length > 0 && totalDesired <= netWidthPt) {
    return weights
  }
  return waterfillWidths(weights, netWidthPt, Math.min(28, netWidthPt / maxCols))
}

/**
 * Enriches a normalized `<page>` tree in-place with syntax-highlighted `codeLine` runs, KaTeX
 * validation, 300-DPI light-theme diagram PNGs sized to each container's net print width,
 * uploaded image assets, clean reader URLs, and (for PDF) rasterized color-emoji inline images.
 */
export async function prerenderPageForExport(input: PrerenderPageInput): Promise<PrerenderPageResult> {
  const { pageID, xml, icon, format, hooks } = input
  const parsedRoot = typeof xml === 'string' ? parseXml(xml) : xml

  const rasterizeDiagram = hooks?.rasterizeDiagram ?? defaultRasterizeDiagram
  const rasterizeEmoji = hooks?.rasterizeEmoji ?? defaultRasterizeEmoji
  const highlightCode = hooks?.highlightCode ?? defaultHighlightCode
  const validateMath = hooks?.validateMath ?? defaultValidateMath

  const assets: WorkerExportAsset[] = []
  const imageUrlKeyCache = new Map<string, Promise<string | undefined>>()
  const emojiKeyCache = new Map<string, Promise<string | undefined>>()
  const tasks: Array<() => Promise<void>> = []
  let nextAssetSeq = 0

  const registerAsset = (prefix: string, bytes: Uint8Array): string => {
    const key = `${prefix}_${++nextAssetSeq}`
    const owned =
      bytes.buffer instanceof ArrayBuffer && bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength
        ? bytes
        : bytes.slice()
    assets.push({ key, bytes: owned })
    return key
  }

  const fetchAndRegisterImage = (fetchUrl: string, prefix: string): Promise<string | undefined> => {
    let cached = imageUrlKeyCache.get(fetchUrl)
    if (!cached) {
      cached = fetchImageBytes(fetchUrl).then(bytes => (bytes ? registerAsset(prefix, bytes) : undefined))
      imageUrlKeyCache.set(fetchUrl, cached)
    }
    return cached
  }

  const resolveEmojiAssetKey = (cluster: string): Promise<string | undefined> => {
    let cached = emojiKeyCache.get(cluster)
    if (!cached) {
      cached = rasterizeEmoji(cluster).then(bytes => (bytes ? registerAsset('emoji', bytes) : undefined))
      emojiKeyCache.set(cluster, cached)
    }
    return cached
  }

  const buildExportMathElement = (
    node: Extract<ParsedChild, { type: 'element' }>,
    displayMode: boolean
  ): ExportNode & { type: 'element' } => {
    const source = unwrapMathDelimiters(extractPlainText(node.children))
    const mathAttrs: Record<string, string> = { ...node.attrs }
    const outNode: ExportNode & { type: 'element' } = {
      type: 'element',
      name: displayMode ? 'math' : 'inline-math',
      ...(Object.keys(mathAttrs).length > 0 ? { attrs: mathAttrs } : {}),
      children: source ? [{ type: 'text', value: source }] : []
    }
    if (source.trim()) {
      tasks.push(async () => {
        if (!(await validateMath(source, displayMode))) {
          outNode.attrs = { ...outNode.attrs, _export_invalid: 'true' }
        }
      })
    }
    return outNode
  }

  const appendInlineChildren = (children: readonly ParsedChild[], netWidthPt: number, out: ExportNode[]): void => {
    for (const child of children) {
      if (child.type === 'text') {
        if (!child.value) continue
        if (format !== 'pdf') {
          out.push({ type: 'text', value: child.value })
          continue
        }
        let plainBuffer = ''
        for (const seg of graphemeSegmenter.segment(child.value)) {
          if (isColorEmojiGrapheme(seg.segment)) {
            if (plainBuffer) {
              out.push({ type: 'text', value: plainBuffer })
              plainBuffer = ''
            }
            const placeholder: ExportNode = { type: 'text', value: seg.segment }
            const slotIndex = out.length
            out.push(placeholder)
            const cluster = seg.segment
            tasks.push(async () => {
              const key = await resolveEmojiAssetKey(cluster)
              if (key) {
                out[slotIndex] = { type: 'emojiImage', asset_key: key, alt: cluster }
              }
            })
          } else {
            plainBuffer += seg.segment
          }
        }
        if (plainBuffer) {
          out.push({ type: 'text', value: plainBuffer })
        }
        continue
      }

      if (child.name === 'comment') {
        appendInlineChildren(child.children, netWidthPt, out)
        continue
      }

      if (child.name === 'inline-math') {
        out.push(buildExportMathElement(child, false))
        continue
      }

      const attrs: Record<string, string> = { ...child.attrs }
      if (child.name === 'a' && attrs.href) {
        const cleanHref = resolveExportLinkHref(pageID, attrs.href)
        if (cleanHref) attrs._export_href = cleanHref
      }

      const converted: ExportNode & { type: 'element' } = {
        type: 'element',
        name: child.name,
        ...(Object.keys(attrs).length > 0 ? { attrs } : {}),
        children: convertInlineChildren(child.children, netWidthPt)
      }

      if (child.name === 'img' && attrs.src) {
        const resolved = resolvePageAssetFetchUrl(pageID, attrs.src)
        if (resolved) {
          tasks.push(async () => {
            const key = await fetchAndRegisterImage(resolved.fetchUrl, 'img')
            if (key) {
              converted.attrs = { ...converted.attrs, _export_asset: key }
            }
          })
        }
      }

      out.push(converted)
    }
  }

  const convertInlineChildren = (children: readonly ParsedChild[], netWidthPt: number): ExportNode[] => {
    const out: ExportNode[] = []
    appendInlineChildren(children, netWidthPt, out)
    return out
  }

  const convertBlock = (node: DocumentElement, netWidthPt: number): ExportNode => {
    const attrs: Record<string, string> = { ...node.attrs }

    if (node.name === 'p' || /^h[1-6]$/.test(node.name)) {
      const indentLevels = Math.max(0, Math.min(16, Number.parseInt(attrs.indent ?? '0', 10) || 0))
      const effectiveWidth = Math.max(MIN_CONTAINER_WIDTH_PT, netWidthPt - indentLevels * INDENT_STEP_PT)
      return {
        type: 'element',
        name: node.name,
        ...(Object.keys(attrs).length > 0 ? { attrs } : {}),
        children: convertInlineChildren(node.children, effectiveWidth)
      }
    }

    if (node.name === 'pre') {
      const source = extractPlainText(node.children)
      const lang = attrs.lang
      const outNode: ExportNode & { type: 'element' } = {
        type: 'element',
        name: 'pre',
        ...(Object.keys(attrs).length > 0 ? { attrs } : {}),
        children: source ? [{ type: 'text', value: source }] : []
      }
      tasks.push(async () => {
        const lines = await highlightCode(source, lang)
        if (lines) {
          outNode.children = lines.map(runs => ({ type: 'codeLine', runs }))
        }
      })
      return outNode
    }

    if (node.name === 'mermaid' || node.name === 'infographic') {
      const kind = node.name
      const source = extractPlainText(node.children)
      const view = attrs.view ?? 'both'
      const showDiagram = view === 'diagram' || view === 'both'
      const showCode = view === 'code' || view === 'both'
      const outNode: ExportNode & { type: 'element' } = {
        type: 'element',
        name: kind,
        ...(Object.keys(attrs).length > 0 ? { attrs } : {}),
        children: source ? [{ type: 'text', value: source }] : []
      }
      tasks.push(async () => {
        let diagramRendered = false
        if (showDiagram && source.trim()) {
          const result = await rasterizeDiagram(kind, source, netWidthPt)
          if (result?.kind === 'ok') {
            const key = registerAsset(kind, result.bytes)
            outNode.attrs = {
              ...outNode.attrs,
              _export_asset: key,
              _export_w_pt: String(result.widthPt),
              _export_h_pt: String(result.heightPt)
            }
            diagramRendered = true
          } else if (result?.kind === 'error') {
            outNode.attrs = { ...outNode.attrs, _export_error: result.message }
            diagramRendered = true
          }
        }
        if ((showCode || (showDiagram && !diagramRendered)) && source) {
          const lines = await highlightCode(source, kind === 'mermaid' ? 'mermaid' : 'yaml')
          if (lines) {
            outNode.children = lines.map(runs => ({ type: 'codeLine', runs }))
          }
        }
      })
      return outNode
    }

    if (node.name === 'math') {
      return buildExportMathElement(node, true)
    }

    if (node.name === 'media') {
      const kind = attrs.kind ?? 'image'
      const view = attrs.view ?? 'preview'
      const outNode: ExportNode & { type: 'element' } = {
        type: 'element',
        name: 'media',
        ...(Object.keys(attrs).length > 0 ? { attrs } : {}),
        children: []
      }
      if (attrs.src) {
        const resolved = resolvePageAssetFetchUrl(pageID, attrs.src)
        if (resolved?.readerHref) {
          outNode.attrs = { ...outNode.attrs, _export_href: resolved.readerHref }
        }
        if (kind === 'image' && (view === 'preview' || view === '') && resolved) {
          tasks.push(async () => {
            const key = await fetchAndRegisterImage(resolved.fetchUrl, 'media')
            if (key) {
              outNode.attrs = { ...outNode.attrs, _export_asset: key }
            }
          })
        }
      }
      return outNode
    }

    if (node.name === 'embed') {
      if (!attrs.ref && attrs.href) {
        const cleanHref = resolveExportLinkHref(pageID, attrs.href)
        if (cleanHref) attrs._export_href = cleanHref
      }
      return {
        type: 'element',
        name: 'embed',
        ...(Object.keys(attrs).length > 0 ? { attrs } : {}),
        children: []
      }
    }

    if (node.name === 'callout') {
      const iconColPt = Math.min(CALLOUT_ICON_COL_PT, netWidthPt * 0.25)
      const bodyWidthPt = Math.max(40, netWidthPt - iconColPt - 14)
      const outNode: ExportNode & { type: 'element' } = {
        type: 'element',
        name: 'callout',
        ...(Object.keys(attrs).length > 0 ? { attrs } : {}),
        children: convertBlockChildren(node.children, bodyWidthPt)
      }
      const rawIcon = attrs.icon?.trim()
      if (format === 'pdf' && rawIcon && isColorEmojiGrapheme(rawIcon)) {
        tasks.push(async () => {
          const key = await resolveEmojiAssetKey(rawIcon)
          if (key) {
            outNode.attrs = { ...outNode.attrs, _export_icon_asset: key }
          }
        })
      }
      return outNode
    }

    if (node.name === 'blockquote') {
      return {
        type: 'element',
        name: 'blockquote',
        ...(Object.keys(attrs).length > 0 ? { attrs } : {}),
        children: convertBlockChildren(node.children, Math.max(MIN_CONTAINER_WIDTH_PT, netWidthPt - 14))
      }
    }

    if (node.name === 'block') {
      const elementChildren = node.children.filter((c): c is DocumentElement => c.type === 'element')
      return {
        type: 'element',
        name: 'block',
        ...(Object.keys(attrs).length > 0 ? { attrs } : {}),
        children: elementChildren.map((child, idx) =>
          convertBlock(child, idx === 0 ? netWidthPt : Math.max(MIN_CONTAINER_WIDTH_PT, netWidthPt - INDENT_STEP_PT))
        )
      }
    }

    if (node.name === 'columns') {
      const cols = node.children.filter((c): c is DocumentElement => c.type === 'element' && c.name === 'column')
      const count = cols.length
      const gutterTotal = count > 1 ? COLUMN_GUTTER_PT * (count - 1) : 0
      const distributable = Math.max(count * 24, netWidthPt - gutterTotal)
      const weights = cols.map(col => {
        const parsed = Number.parseInt(col.attrs.width ?? '', 10)
        return Number.isFinite(parsed) && parsed > 0 ? Math.min(9999, Math.max(1, parsed)) : 1000
      })
      const colNetWidths = waterfillWidths(weights, distributable, MIN_COLUMN_WIDTH_PT)
      return {
        type: 'element',
        name: 'columns',
        ...(Object.keys(attrs).length > 0 ? { attrs } : {}),
        children: cols.map((col, index) => ({
          type: 'element',
          name: 'column',
          ...(Object.keys(col.attrs).length > 0 ? { attrs: { ...col.attrs } } : {}),
          children: convertBlockChildren(col.children, colNetWidths[index] ?? MIN_COLUMN_WIDTH_PT)
        }))
      }
    }

    if (node.name === 'ul' || node.name === 'ol') {
      const itemWidth = Math.max(MIN_CONTAINER_WIDTH_PT, netWidthPt - LIST_STEP_PT)
      return {
        type: 'element',
        name: node.name,
        ...(Object.keys(attrs).length > 0 ? { attrs } : {}),
        children: node.children
          .filter((c): c is DocumentElement => c.type === 'element' && c.name === 'li')
          .map(li => ({
            type: 'element',
            name: 'li',
            ...(Object.keys(li.attrs).length > 0 ? { attrs: { ...li.attrs } } : {}),
            children: convertBlockChildren(li.children, itemWidth)
          }))
      }
    }

    if (node.name === 'table') {
      const trElements = node.children.filter((c): c is DocumentElement => c.type === 'element' && c.name === 'tr')
      const colWidths = estimateTableColumnWidths(trElements, attrs.widths, netWidthPt, attrs.layout === 'full')
      const activeRowspans: number[] = []
      const convertedRows: ExportNode[] = trElements.map(tr => {
        let col = 0
        const convertedCells: ExportNode[] = []
        for (const cell of tr.children) {
          if (cell.type !== 'element' || (cell.name !== 'td' && cell.name !== 'th')) continue
          while ((activeRowspans[col] ?? 0) > 0) {
            activeRowspans[col]!--
            col += 1
          }
          const colspan = Math.max(1, Math.min(63, Number.parseInt(cell.attrs.colspan ?? '1', 10) || 1))
          const rowspan = Math.max(1, Number.parseInt(cell.attrs.rowspan ?? '1', 10) || 1)
          if (rowspan > 1) {
            for (let k = 0; k < colspan; k += 1) {
              activeRowspans[col + k] = Math.max(activeRowspans[col + k] ?? 0, rowspan - 1)
            }
          }
          let spanWidth = 0
          for (let k = 0; k < colspan; k += 1) {
            spanWidth += colWidths[col + k] ?? 36
          }
          const cellNetWidth = Math.max(24, spanWidth - 12)
          convertedCells.push({
            type: 'element',
            name: cell.name,
            ...(Object.keys(cell.attrs).length > 0 ? { attrs: { ...cell.attrs } } : {}),
            children: convertBlockChildren(cell.children, cellNetWidth)
          })
          col += colspan
        }
        return {
          type: 'element',
          name: 'tr',
          ...(Object.keys(tr.attrs).length > 0 ? { attrs: { ...tr.attrs } } : {}),
          children: convertedCells
        }
      })
      return {
        type: 'element',
        name: 'table',
        ...(Object.keys(attrs).length > 0 ? { attrs } : {}),
        children: convertedRows
      }
    }

    return {
      type: 'element',
      name: node.name,
      ...(Object.keys(attrs).length > 0 ? { attrs } : {}),
      children: convertBlockChildren(node.children, netWidthPt)
    }
  }

  const convertBlockChildren = (children: readonly ParsedChild[], netWidthPt: number): ExportNode[] => {
    const out: ExportNode[] = []
    for (const child of children) {
      if (child.type === 'text') {
        if (child.value.trim()) {
          out.push(...convertInlineChildren([child], netWidthPt))
        }
        continue
      }
      if (child.name === 'comment') {
        out.push(...convertBlockChildren(child.children, netWidthPt))
        continue
      }
      out.push(convertBlock(child, netWidthPt))
    }
    return out
  }

  const root: ExportNode = {
    type: 'element',
    name: 'page',
    children: convertBlockChildren(parsedRoot.children, ROOT_CONTENT_WIDTH_PT)
  }

  let iconText: string | undefined
  let iconAssetKey: string | undefined
  const resolvedIcon = pageIcon(icon)
  if (resolvedIcon) {
    if (isCustomEmojiIcon(resolvedIcon)) {
      const iconPath = metadataFileURL(resolvedIcon)
      const fetchUrl =
        typeof window !== 'undefined' && window.location?.href ? new URL(iconPath, window.location.href).href : iconPath
      tasks.push(async () => {
        iconAssetKey = await fetchAndRegisterImage(fetchUrl, 'page_icon')
      })
    } else if (format === 'pdf' && isColorEmojiGrapheme(resolvedIcon)) {
      iconText = resolvedIcon
      tasks.push(async () => {
        iconAssetKey = await resolveEmojiAssetKey(resolvedIcon)
      })
    } else {
      iconText = resolvedIcon
    }
  }

  if (tasks.length > 0) {
    await parallel(PRERENDER_CONCURRENCY, tasks, task => task())
  }

  return {
    root,
    assets,
    ...(iconText ? { iconText } : {}),
    ...(iconAssetKey ? { iconAssetKey } : {})
  }
}
