import { unwrapMathDelimiters } from '@ankole/block-editor/document'
import { materializePeleSvg } from '@ankole/uikit/viz/svg-export'
import { rasterizeSvgToPngBlob, type VizThemePalette } from '@ankole/uikit/viz/theme'
import { PeleError } from 'pele/core'
import { renderAsync } from 'pele/lazy'
import { podPublicOrigin } from '../../common/browser-context'
import { InternalAPIError } from '../../common/internal-api-client'
import {
  DIAGRAM_HOST_FONT_MONO,
  DIAGRAM_HOST_FONT_SANS,
  MERMAID_PALETTES,
  resolveChatMermaidPalette
} from '../chat/mermaid/mermaid-renderer'
import { SCREENSHOT_MAX_PIXELS, SCREENSHOT_MAX_SIDE, planScreenshotPixelRatio } from '../chat/screenshot-budget'
import { fileURL } from '../content-api'
import { assetFilePath, readerAssetURL, readerURL } from './document-export'

export type CodeSpan = {
  text: string
  color?: string
  bold?: boolean
  italic?: boolean
}

export type DiagramRasterResult =
  | {
      kind: 'ok'
      bytes: Uint8Array
      widthPt: number
      heightPt: number
    }
  | {
      kind: 'error'
      message: string
    }

const MIN_COLUMN_WIDTH_PT = 48
const MAX_DISPLAY_IMAGE_HEIGHT_PT = 560
const TARGET_PRINT_DPI = 300
const MAX_DIRECT_IMAGE_BYTES = 2 * 1024 * 1024
const MAX_DIRECT_IMAGE_SIDE_PX = 2048
const MAX_HIGHLIGHT_CHARS = 120_000

function cleanReaderHref(rawUrl: string): string | undefined {
  const trimmed = rawUrl.trim()
  if (!trimmed) return undefined
  if (trimmed.startsWith('#')) return trimmed
  try {
    const resolved = new URL(trimmed, podPublicOrigin())
    if (resolved.protocol !== 'http:' && resolved.protocol !== 'https:' && resolved.protocol !== 'mailto:') {
      return undefined
    }
    return readerURL(resolved.href)
  } catch {
    return undefined
  }
}

export function resolveExportLinkHref(pageID: string, rawHref: string): string | undefined {
  const trimmed = rawHref.trim()
  if (!trimmed || trimmed.startsWith('ankole:page/')) return undefined
  if (trimmed.startsWith('ankole:asset/')) {
    return readerAssetURL(pageID, trimmed)
  }
  if (
    trimmed.startsWith('/') ||
    /^https?:\/\//i.test(trimmed) ||
    /^mailto:/i.test(trimmed) ||
    trimmed.startsWith('#')
  ) {
    return cleanReaderHref(trimmed)
  }
  return undefined
}

export function resolvePageAssetFetchUrl(
  pageID: string,
  rawSrc: string
): { fetchUrl: string; readerHref?: string } | undefined {
  const trimmed = rawSrc.trim()
  if (!trimmed) return undefined
  if (trimmed.startsWith('ankole:asset/')) {
    const path = fileURL(pageID, assetFilePath(trimmed))
    const fetchUrl =
      typeof window !== 'undefined' && window.location?.href ? new URL(path, window.location.href).href : path
    return { fetchUrl, readerHref: readerURL(path) }
  }
  if (/^https?:\/\//i.test(trimmed) || trimmed.startsWith('/')) {
    const fetchUrl =
      typeof window !== 'undefined' && window.location?.href ? new URL(trimmed, window.location.href).href : trimmed
    return { fetchUrl, readerHref: cleanReaderHref(trimmed) }
  }
  return undefined
}

function isPngBytes(bytes: Uint8Array): boolean {
  return (
    bytes.byteLength >= 24 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47 &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  )
}

function isJpegBytes(bytes: Uint8Array): boolean {
  return bytes.byteLength >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff
}

function readPngDimensions(bytes: Uint8Array): { width: number; height: number } | undefined {
  if (!isPngBytes(bytes)) return undefined
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const width = view.getUint32(16, false)
  const height = view.getUint32(20, false)
  return width > 0 && height > 0 ? { width, height } : undefined
}

function readJpegDimensions(bytes: Uint8Array): { width: number; height: number } | undefined {
  if (!isJpegBytes(bytes)) return undefined
  let offset = 2
  while (offset + 8 < bytes.byteLength) {
    if (bytes[offset] !== 0xff) {
      offset += 1
      continue
    }
    while (offset < bytes.byteLength && bytes[offset] === 0xff) offset += 1
    if (offset >= bytes.byteLength) break
    const marker = bytes[offset]!
    offset += 1
    if (marker === 0xd9 || marker === 0xda) break
    if (offset + 2 > bytes.byteLength) break
    const segLen = (bytes[offset]! << 8) | bytes[offset + 1]!
    if (segLen < 2 || offset + segLen > bytes.byteLength) break
    const isSof =
      (marker >= 0xc0 && marker <= 0xc3) ||
      (marker >= 0xc5 && marker <= 0xc7) ||
      (marker >= 0xc9 && marker <= 0xcb) ||
      (marker >= 0xcd && marker <= 0xcf)
    if (isSof && offset + 7 <= bytes.byteLength) {
      const height = (bytes[offset + 3]! << 8) | bytes[offset + 4]!
      const width = (bytes[offset + 5]! << 8) | bytes[offset + 6]!
      return width > 0 && height > 0 ? { width, height } : undefined
    }
    offset += segLen
  }
  return undefined
}

async function normalizeRasterImageBytes(bytes: Uint8Array, mimeType: string): Promise<Uint8Array | undefined> {
  if (bytes.byteLength === 0) return undefined
  const dims = readPngDimensions(bytes) ?? readJpegDimensions(bytes)
  if (
    dims &&
    bytes.byteLength <= MAX_DIRECT_IMAGE_BYTES &&
    dims.width <= MAX_DIRECT_IMAGE_SIDE_PX &&
    dims.height <= MAX_DIRECT_IMAGE_SIDE_PX
  ) {
    return bytes
  }

  if (typeof createImageBitmap !== 'function' || typeof document === 'undefined') {
    return isPngBytes(bytes) || isJpegBytes(bytes) ? bytes : undefined
  }

  try {
    const sourceBlob = new Blob([bytes as BlobPart], { type: mimeType || 'application/octet-stream' })
    const bitmap = await createImageBitmap(sourceBlob)
    try {
      const maxSide = Math.max(bitmap.width, bitmap.height, 1)
      const ratio = maxSide > MAX_DIRECT_IMAGE_SIDE_PX ? MAX_DIRECT_IMAGE_SIDE_PX / maxSide : 1
      const width = Math.max(1, Math.round(bitmap.width * ratio))
      const height = Math.max(1, Math.round(bitmap.height * ratio))
      const canvas = document.createElement('canvas')
      canvas.width = width
      canvas.height = height
      const ctx = canvas.getContext('2d')
      if (!ctx) return isPngBytes(bytes) || isJpegBytes(bytes) ? bytes : undefined
      ctx.drawImage(bitmap, 0, 0, width, height)
      const preferJpeg = isJpegBytes(bytes) || /image\/jpe?g/i.test(mimeType)
      const encoded = await new Promise<Blob | null>(resolve =>
        canvas.toBlob(resolve, preferJpeg ? 'image/jpeg' : 'image/png', preferJpeg ? 0.9 : undefined)
      )
      if (!encoded) return isPngBytes(bytes) || isJpegBytes(bytes) ? bytes : undefined
      return new Uint8Array(await encoded.arrayBuffer())
    } finally {
      bitmap.close()
    }
  } catch {
    return isPngBytes(bytes) || isJpegBytes(bytes) ? bytes : undefined
  }
}

export async function fetchImageBytes(fetchUrl: string): Promise<Uint8Array | undefined> {
  if (typeof fetch !== 'function') return undefined
  try {
    const isSameOrigin =
      !fetchUrl.startsWith('http') ||
      (typeof window !== 'undefined' &&
        window.location?.origin !== undefined &&
        new URL(fetchUrl, window.location.href).origin === window.location.origin)
    const response = await fetch(fetchUrl, { credentials: isSameOrigin ? 'same-origin' : 'omit' })
    if (response.status === 403 || response.status === 404) return undefined
    if (!response.ok) {
      if (isSameOrigin) throw new InternalAPIError(response.status, response.statusText, {})
      return undefined
    }
    const contentType = response.headers.get('content-type') ?? ''
    if (contentType && !contentType.toLowerCase().startsWith('image/') && contentType !== 'application/octet-stream') {
      return undefined
    }
    const raw = new Uint8Array(await response.arrayBuffer())
    return normalizeRasterImageBytes(raw, contentType)
  } catch (error) {
    if (error instanceof InternalAPIError) throw error
    return undefined
  }
}

function lightPrintMermaidPalette(): VizThemePalette {
  const base = resolveChatMermaidPalette('light')
  return {
    ...base,
    fontSans: DIAGRAM_HOST_FONT_SANS,
    fontMono: DIAGRAM_HOST_FONT_MONO
  }
}

function computeDiagramPrintPlacement(
  svgWidthPx: number,
  svgHeightPx: number,
  netWidthPt: number
): { displayWidthPt: number; displayHeightPt: number; rasterScale: number } {
  const safeSvgW = Math.max(1, svgWidthPx)
  const safeSvgH = Math.max(1, svgHeightPx)
  const naturalWidthPt = safeSvgW * 0.75
  let displayWidthPt = Math.min(naturalWidthPt, Math.max(MIN_COLUMN_WIDTH_PT, netWidthPt))
  let displayHeightPt = displayWidthPt * (safeSvgH / safeSvgW)
  if (displayHeightPt > MAX_DISPLAY_IMAGE_HEIGHT_PT) {
    const shrink = MAX_DISPLAY_IMAGE_HEIGHT_PT / displayHeightPt
    displayWidthPt *= shrink
    displayHeightPt = MAX_DISPLAY_IMAGE_HEIGHT_PT
  }

  const targetPixelW = Math.ceil(displayWidthPt * (TARGET_PRINT_DPI / 72))
  let desiredScale = Math.max(2, targetPixelW / safeSvgW)
  const outW = Math.ceil(safeSvgW * desiredScale)
  const outH = Math.ceil(safeSvgH * desiredScale)
  if (outW > SCREENSHOT_MAX_SIDE || outH > SCREENSHOT_MAX_SIDE || outW * outH > SCREENSHOT_MAX_PIXELS) {
    const budget = planScreenshotPixelRatio(safeSvgW, safeSvgH)
    if (budget.kind === 'ok') {
      desiredScale = budget.pixelRatio
    } else {
      const sideCap = Math.min(SCREENSHOT_MAX_SIDE / safeSvgW, SCREENSHOT_MAX_SIDE / safeSvgH)
      const areaCap = Math.sqrt(SCREENSHOT_MAX_PIXELS / (safeSvgW * safeSvgH))
      desiredScale = Math.max(0.25, Math.min(sideCap, areaCap))
    }
  }

  return {
    displayWidthPt: Math.round(displayWidthPt * 100) / 100,
    displayHeightPt: Math.round(displayHeightPt * 100) / 100,
    rasterScale: desiredScale
  }
}

export async function defaultRasterizeDiagram(
  kind: 'mermaid' | 'infographic',
  source: string,
  netWidthPt: number
): Promise<DiagramRasterResult | undefined> {
  const trimmed = source.trim()
  if (!trimmed || typeof document === 'undefined' || typeof Image === 'undefined') {
    return undefined
  }

  if (kind === 'mermaid') {
    try {
      const rendered = await renderAsync(trimmed, {
        links: false,
        images: false,
        responsive: true
      })
      const artifact = materializePeleSvg(rendered.svg, lightPrintMermaidPalette(), {
        safetyPaddingPx: 8,
        injectBackgroundRect: true
      })
      const { displayWidthPt, displayHeightPt, rasterScale } = computeDiagramPrintPlacement(
        artifact.width,
        artifact.height,
        netWidthPt
      )
      const blob = await rasterizeSvgToPngBlob(artifact.svg, {
        width: artifact.width,
        height: artifact.height,
        scale: rasterScale,
        background: MERMAID_PALETTES.light.bg
      })
      return {
        kind: 'ok',
        bytes: new Uint8Array(await blob.arrayBuffer()),
        widthPt: displayWidthPt,
        heightPt: displayHeightPt
      }
    } catch (error) {
      if (error instanceof PeleError) {
        return { kind: 'error', message: error.message }
      }
      return undefined
    }
  }

  const { mountInfographicAsync, validateInfographicSyntax } = await import('@ankole/uikit/viz/infographic')
  const validation = validateInfographicSyntax(trimmed)
  if (!validation.ok) {
    return { kind: 'error', message: validation.errors[0] ?? 'Invalid Infographic syntax' }
  }
  if (!document.body) return undefined

  const containerCssPx = Math.min(840, Math.max(260, Math.round(netWidthPt * (96 / 72))))
  const host = document.createElement('div')
  host.setAttribute('data-theme', 'light')
  host.style.cssText = `position:fixed;left:-9999px;top:0;width:${containerCssPx}px;visibility:hidden;pointer-events:none;`
  document.body.appendChild(host)
  try {
    const mounted = await mountInfographicAsync(host, trimmed, {
      theme: 'light',
      width: containerCssPx,
      zoom: false
    })
    try {
      const artifact = await mounted.exportSVG()
      const { displayWidthPt, displayHeightPt, rasterScale } = computeDiagramPrintPlacement(
        artifact.width,
        artifact.height,
        netWidthPt
      )
      const blob = await rasterizeSvgToPngBlob(artifact.svg, {
        width: artifact.width,
        height: artifact.height,
        scale: rasterScale,
        background: '#ffffff'
      })
      return {
        kind: 'ok',
        bytes: new Uint8Array(await blob.arrayBuffer()),
        widthPt: displayWidthPt,
        heightPt: displayHeightPt
      }
    } finally {
      mounted.destroy()
    }
  } catch (error) {
    return { kind: 'error', message: error instanceof Error ? error.message : String(error) }
  } finally {
    host.remove()
  }
}

export async function defaultRasterizeEmoji(cluster: string): Promise<Uint8Array | undefined> {
  if (typeof document === 'undefined') return undefined
  try {
    const canvas = document.createElement('canvas')
    if (typeof canvas.getContext !== 'function') return undefined
    const size = 64
    canvas.width = size
    canvas.height = size
    const ctx = canvas.getContext('2d')
    if (!ctx) return undefined
    ctx.clearRect(0, 0, size, size)
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.font = '52px "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", sans-serif'
    ctx.fillText(cluster, size / 2, Math.round(size * 0.54))
    const blob = await new Promise<Blob | null>(resolve => canvas.toBlob(resolve, 'image/png'))
    if (!blob) return undefined
    const bytes = new Uint8Array(await blob.arrayBuffer())
    return bytes.byteLength > 0 ? bytes : undefined
  } catch {
    return undefined
  }
}

function plainCodeLines(source: string): CodeSpan[][] {
  return source
    .replace(/\r\n?/g, '\n')
    .split('\n')
    .map(line => (line ? [{ text: line }] : []))
}

export async function defaultHighlightCode(source: string, language?: string): Promise<CodeSpan[][] | undefined> {
  const trimmedLang = language?.trim().toLowerCase()
  if (!trimmedLang || ['text', 'txt', 'plaintext', 'plain'].includes(trimmedLang)) {
    return plainCodeLines(source)
  }
  const normalized = source.replace(/\r\n?/g, '\n')
  if (normalized.length > MAX_HIGHLIGHT_CHARS) {
    return plainCodeLines(normalized)
  }
  try {
    const shiki = await import('shiki')
    const tokenized = await shiki.codeToTokens(normalized, {
      lang: trimmedLang as keyof typeof shiki.bundledLanguages,
      theme: 'github-light'
    })
    return tokenized.tokens.map(line =>
      line.map(tok => ({
        text: tok.content,
        ...(tok.color ? { color: tok.color } : {}),
        ...(tok.fontStyle !== undefined && (tok.fontStyle & 2) !== 0 ? { bold: true } : {}),
        ...(tok.fontStyle !== undefined && (tok.fontStyle & 1) !== 0 ? { italic: true } : {})
      }))
    )
  } catch {
    return plainCodeLines(normalized)
  }
}

export async function defaultValidateMath(latex: string, displayMode = true): Promise<boolean> {
  const trimmed = unwrapMathDelimiters(latex).trim()
  if (!trimmed) return true
  try {
    const katexModule = await import('katex')
    const katex = katexModule.default ?? katexModule
    katex.renderToString(trimmed, {
      displayMode,
      throwOnError: true,
      strict: false
    })
    return true
  } catch {
    return false
  }
}
