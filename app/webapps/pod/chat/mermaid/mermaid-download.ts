import { blobToDataUrl, downloadBlob } from '../../../common/browser-files'
import { planScreenshotPixelRatio } from '../screenshot-budget'
import { injectStandaloneSvgTheme, MERMAID_PALETTES, type MermaidThemeMode } from './mermaid-renderer'

export function svgToDataUrl(svg: string, theme: MermaidThemeMode): string {
  const themed = injectStandaloneSvgTheme(svg, theme)
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(themed)}`
}

export async function svgToPngDataUrl(
  svg: string,
  width: number,
  height: number,
  theme: MermaidThemeMode
): Promise<string> {
  const blob = await svgToPngBlob(svg, width, height, theme)
  return blobToDataUrl(blob)
}

export async function svgToPngBlob(svg: string, width: number, height: number, theme: MermaidThemeMode): Promise<Blob> {
  const safeWidth = Math.max(1, Math.ceil(width))
  const safeHeight = Math.max(1, Math.ceil(height))
  const plan = planScreenshotPixelRatio(safeWidth, safeHeight)
  if (plan.kind === 'needsPagination') throw new Error('Diagram is too large to export as PNG')
  const ratio = Math.min(2, plan.pixelRatio)
  const outWidth = safeWidth * ratio
  const outHeight = safeHeight * ratio
  const url = svgToDataUrl(svg, theme)

  const img = await new Promise<HTMLImageElement>((resolve, reject) => {
    const el = new Image()
    el.decoding = 'async'
    el.onload = () => resolve(el)
    el.onerror = () => reject(new Error('Failed to decode Mermaid SVG'))
    el.src = url
  })

  const canvas = document.createElement('canvas')
  canvas.width = outWidth
  canvas.height = outHeight
  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('Canvas 2D context unavailable')
  ctx.fillStyle = MERMAID_PALETTES[theme].bg
  ctx.fillRect(0, 0, outWidth, outHeight)
  ctx.drawImage(img, 0, 0, outWidth, outHeight)

  return new Promise<Blob>((resolve, reject) => {
    canvas.toBlob(blob => {
      if (blob) resolve(blob)
      else reject(new Error('PNG encoding failed'))
    }, 'image/png')
  })
}

/**
 * Copies the rendered Mermaid diagram as PNG using a synchronous `ClipboardItem`
 * promise wrapper so Safari preserves transient user activation across rasterization.
 */
export async function copyMermaidPng(
  svg: string,
  width: number,
  height: number,
  theme: MermaidThemeMode
): Promise<void> {
  if (typeof ClipboardItem === 'undefined' || !navigator.clipboard?.write) {
    throw new Error('Image clipboard unsupported')
  }
  const pngPromise = svgToPngBlob(svg, width, height, theme)
  const item = new ClipboardItem({ 'image/png': pngPromise })
  await navigator.clipboard.write([item])
}

export async function downloadMermaidPng(
  svg: string,
  width: number,
  height: number,
  theme: MermaidThemeMode,
  filename = 'ankole-diagram.png'
): Promise<void> {
  const blob = await svgToPngBlob(svg, width, height, theme)
  downloadBlob(blob, filename)
}
