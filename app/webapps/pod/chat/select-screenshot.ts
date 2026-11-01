import { getCaptureSnapshotAttr, resolveCaptureSnapshotsInSubtree, type CaptureSnapshot } from './dom-capture-snapshot'
import { planScreenshotPixelRatio, validateScreenshotPng } from './screenshot-budget'

export type CaptureSelectedMessagesResult =
  | {
      kind: 'ok'
      blob: Blob
      dataUrl: string
      width: number
      height: number
      pixelRatio: number
    }
  | {
      kind: 'needsPagination'
      cssWidth: number
      cssHeight: number
    }

const STRIP_SELECTORS = [
  '.pod-chat-message-actions',
  '[data-select-ignore]',
  'button[aria-expanded]',
  'iframe',
  'script',
  'video',
  'audio'
].join(',')

const INLINE_COMPUTED_PROPERTIES = [
  'display',
  'visibility',
  'position',
  'top',
  'right',
  'bottom',
  'left',
  'box-sizing',
  'overflow',
  'overflow-x',
  'overflow-y',
  'clip',
  'clip-path',
  'flex-direction',
  'flex-wrap',
  'flex-grow',
  'flex-shrink',
  'flex-basis',
  'align-items',
  'align-self',
  'justify-content',
  'gap',
  'row-gap',
  'column-gap',
  'margin-top',
  'margin-right',
  'margin-bottom',
  'margin-left',
  'padding-top',
  'padding-right',
  'padding-bottom',
  'padding-left',
  'border-top-width',
  'border-right-width',
  'border-bottom-width',
  'border-left-width',
  'border-top-style',
  'border-right-style',
  'border-bottom-style',
  'border-left-style',
  'border-top-color',
  'border-right-color',
  'border-bottom-color',
  'border-left-color',
  'border-radius',
  'background-color',
  'color',
  'font-family',
  'font-size',
  'font-weight',
  'font-style',
  'line-height',
  'letter-spacing',
  'text-align',
  'text-decoration',
  'vertical-align',
  'white-space',
  'word-break',
  'overflow-wrap',
  'object-fit',
  'max-width',
  'min-width',
  'max-height',
  'min-height',
  'opacity'
]

function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result ?? ''))
    reader.onerror = () => reject(reader.error ?? new Error('Failed to read blob'))
    reader.readAsDataURL(blob)
  })
}

async function inlineImageElement(liveImg: HTMLImageElement, clonedImg: HTMLImageElement): Promise<void> {
  const src = liveImg.currentSrc || liveImg.getAttribute('src') || ''
  if (!src) {
    clonedImg.remove()
    return
  }
  if (src.startsWith('data:')) {
    clonedImg.setAttribute('src', src)
    return
  }
  try {
    const response = await fetch(src, { credentials: 'same-origin' })
    if (!response.ok) {
      clonedImg.remove()
      return
    }
    const blob = await response.blob()
    const dataUrl = await blobToDataUrl(blob)
    clonedImg.setAttribute('src', dataUrl)
    clonedImg.removeAttribute('srcset')
  } catch {
    clonedImg.remove()
  }
}

function shouldCopyDimensions(source: Element, computed: CSSStyleDeclaration): boolean {
  const tag = source.tagName.toUpperCase()
  if (tag === 'IMG' || tag === 'SVG' || source instanceof SVGElement) return true
  const pos = computed.getPropertyValue('position')
  if (pos === 'absolute' || pos === 'fixed') return true
  if (typeof source.closest === 'function' && source.closest('.katex')) return true
  const w = Number.parseFloat(computed.getPropertyValue('width'))
  const h = Number.parseFloat(computed.getPropertyValue('height'))
  if (
    Number.isFinite(w) &&
    Number.isFinite(h) &&
    w > 0 &&
    w <= 64 &&
    h > 0 &&
    h <= 64 &&
    source.children.length <= 1 &&
    (tag === 'SPAN' || tag === 'BUTTON')
  ) {
    return true
  }
  return false
}

function copyComputedStyles(source: Element, target: Element): void {
  if (target instanceof HTMLElement || target instanceof SVGElement) {
    const computed = getComputedStyle(source)
    const declarations: string[] = []
    for (const prop of INLINE_COMPUTED_PROPERTIES) {
      const value = computed.getPropertyValue(prop)
      if (value) declarations.push(`${prop}:${value}`)
    }
    if (shouldCopyDimensions(source, computed)) {
      const width = computed.getPropertyValue('width')
      const height = computed.getPropertyValue('height')
      if (width) declarations.push(`width:${width}`)
      if (height) declarations.push(`height:${height}`)
    }
    if (declarations.length > 0) {
      const existing = target.getAttribute('style')
      target.setAttribute('style', existing ? `${declarations.join(';')};${existing}` : declarations.join(';'))
    }
  }
  const srcChildren = Array.from(source.children)
  const dstChildren = Array.from(target.children)
  const count = Math.min(srcChildren.length, dstChildren.length)
  for (let i = 0; i < count; i += 1) {
    copyComputedStyles(srcChildren[i]!, dstChildren[i]!)
  }
}

export function applyResolvedSnapshotsToClone(
  cloneRoot: ParentNode,
  snapshots: ReadonlyMap<string, CaptureSnapshot>,
  doc: Document = document
): void {
  const attr = getCaptureSnapshotAttr()
  const targets = Array.from(cloneRoot.querySelectorAll<HTMLElement>(`[${attr}]`))
  for (const el of targets) {
    const id = el.getAttribute(attr)
    const snap = id ? snapshots.get(id) : undefined
    if (!snap) continue
    const wrapper = doc.createElement('div')
    wrapper.style.cssText =
      'margin:12px 0;padding:12px;border:1px solid rgba(128,128,128,0.22);border-radius:6px;overflow:hidden;'
    const img = doc.createElement('img')
    img.src = snap.dataUrl
    img.alt = snap.alt || 'Diagram'
    img.style.cssText = `display:block;max-width:100%;height:auto;width:${Math.max(1, Math.round(snap.width))}px;margin:0 auto;`
    wrapper.appendChild(img)
    el.replaceWith(wrapper)
  }
}

export async function prepareClonedArticleImages(
  liveArticle: ParentNode,
  clone: ParentNode,
  snapshots: ReadonlyMap<string, CaptureSnapshot>,
  doc: Document = document,
  inlineImg: (liveImg: HTMLImageElement, clonedImg: HTMLImageElement) => Promise<void> = inlineImageElement
): Promise<void> {
  const liveImgs = Array.from(liveArticle.querySelectorAll('img'))
  const cloneImgs = Array.from(clone.querySelectorAll('img'))
  await Promise.all(
    cloneImgs.map((clonedImg, idx) => {
      const liveImg = liveImgs[idx]
      return liveImg ? inlineImg(liveImg, clonedImg) : Promise.resolve()
    })
  )

  applyResolvedSnapshotsToClone(clone, snapshots, doc)

  await Promise.all(
    Array.from(clone.querySelectorAll('img')).map(img =>
      typeof img.decode === 'function' ? img.decode().catch(() => {}) : Promise.resolve()
    )
  )
}

export async function captureSelectedMessages(options: {
  container: HTMLElement
  messageIds: string[]
  title?: string
  footerText?: string
  cardWidth?: number
}): Promise<CaptureSelectedMessagesResult> {
  const { container, messageIds, title, footerText = 'Ankole', cardWidth = 720 } = options
  const doc = container.ownerDocument
  const snapshots = await resolveCaptureSnapshotsInSubtree(container)
  const isDark = doc.documentElement.dataset.theme === 'dark'
  const cardBg = isDark ? '#18191a' : '#fffefd'
  const cardFg = isDark ? '#f4f4f2' : '#18191a'
  const cardMuted = isDark ? '#abaaa7' : '#636566'
  const cardBorder = isDark ? '#343637' : '#e5e4e1'

  const host = doc.createElement('div')
  host.setAttribute('aria-hidden', 'true')
  host.style.cssText = [
    'position:fixed',
    'left:-99999px',
    'top:0',
    `width:${cardWidth}px`,
    'pointer-events:none',
    'z-index:-1',
    `background:${cardBg}`,
    `color:${cardFg}`,
    'font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
    'box-sizing:border-box',
    'padding:28px 32px 24px',
    `border:1px solid ${cardBorder}`,
    'border-radius:12px'
  ].join(';')

  if (title?.trim()) {
    const header = doc.createElement('div')
    header.style.cssText = `padding-bottom:14px;margin-bottom:16px;border-bottom:1px solid ${cardBorder};font-size:15px;font-weight:600;line-height:1.4;color:${cardFg};`
    header.textContent = title.trim()
    host.appendChild(header)
  }

  const body = doc.createElement('div')
  body.style.cssText = 'display:flex;flex-direction:column;gap:16px;'

  for (const id of messageIds) {
    const liveWrapper = container.querySelector<HTMLElement>(`[data-chat-message-id="${CSS.escape(id)}"]`)
    if (!liveWrapper) continue
    const liveArticle = liveWrapper.querySelector('article') ?? liveWrapper
    const clone = liveArticle.cloneNode(true) as HTMLElement
    copyComputedStyles(liveArticle, clone)
    await prepareClonedArticleImages(liveArticle, clone, snapshots, doc)

    for (const stripped of Array.from(clone.querySelectorAll(STRIP_SELECTORS))) {
      stripped.remove()
    }
    clone.style.background = 'transparent'
    body.appendChild(clone)
  }

  host.appendChild(body)

  const footer = doc.createElement('div')
  footer.style.cssText = `margin-top:20px;padding-top:12px;border-top:1px solid ${cardBorder};display:flex;justify-content:space-between;align-items:center;font-size:12px;color:${cardMuted};`
  footer.textContent = footerText
  host.appendChild(footer)

  doc.body.appendChild(host)
  try {
    const rect = host.getBoundingClientRect()
    const cssWidth = Math.max(1, Math.ceil(rect.width || cardWidth))
    const cssHeight = Math.max(1, Math.ceil(rect.height || host.scrollHeight || 200))

    const plan = planScreenshotPixelRatio(cssWidth, cssHeight)
    if (plan.kind === 'needsPagination') {
      return plan
    }

    const serializedCard = new XMLSerializer().serializeToString(host)
    const cleanHostXml = serializedCard.replace(/left:\s*-99999px;?/g, 'position:static;')
    const svgMarkup = [
      `<svg xmlns="http://www.w3.org/2000/svg" width="${cssWidth}" height="${cssHeight}" viewBox="0 0 ${cssWidth} ${cssHeight}">`,
      `<foreignObject x="0" y="0" width="${cssWidth}" height="${cssHeight}">`,
      cleanHostXml,
      '</foreignObject>',
      '</svg>'
    ].join('')

    const svgDataUrl = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svgMarkup)}`
    const image = await new Promise<HTMLImageElement>((resolve, reject) => {
      const img = new Image()
      img.decoding = 'async'
      img.onload = () => resolve(img)
      img.onerror = () => reject(new Error('Failed to rasterize selection card'))
      img.src = svgDataUrl
    })

    const canvas = doc.createElement('canvas')
    canvas.width = plan.pixelWidth
    canvas.height = plan.pixelHeight
    const ctx = canvas.getContext('2d')
    if (!ctx) throw new Error('Canvas 2D context unavailable')
    ctx.fillStyle = cardBg
    ctx.fillRect(0, 0, plan.pixelWidth, plan.pixelHeight)
    ctx.scale(plan.pixelRatio, plan.pixelRatio)
    ctx.drawImage(image, 0, 0, cssWidth, cssHeight)

    const blob = await new Promise<Blob>((resolve, reject) => {
      canvas.toBlob(result => (result ? resolve(result) : reject(new Error('PNG encoding failed'))), 'image/png')
    })

    const bytes = new Uint8Array(await blob.arrayBuffer())
    const check = validateScreenshotPng(bytes)
    if (!check.valid) {
      throw new Error('Generated share card PNG failed validation')
    }

    const dataUrl = await blobToDataUrl(blob)
    return {
      kind: 'ok',
      blob,
      dataUrl,
      width: plan.pixelWidth,
      height: plan.pixelHeight,
      pixelRatio: plan.pixelRatio
    }
  } finally {
    host.remove()
  }
}
