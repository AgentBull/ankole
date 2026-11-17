import type { AppletRevision } from '@ankole/applet-sdk/types'
import { clampCommentQuote } from './file-comment-anchors'

export type AppletElementAnchor = {
  kind: 'applet_element'
  revision: number
  source: string
  component: string
  selector: string
  text_fingerprint: string
}
export type AppletElementSelection = { anchor: AppletElementAnchor; quote: string }

export function parseAppletElementAnchor(raw: Record<string, unknown>): AppletElementAnchor | null {
  if (raw.kind !== 'applet_element' || !Number.isSafeInteger(raw.revision) || Number(raw.revision) < 0) return null
  if (!['source', 'component', 'selector', 'text_fingerprint'].every(key => typeof raw[key] === 'string')) return null
  return raw as AppletElementAnchor
}

function componentChain(element: Element): string {
  type Fiber = { type?: { displayName?: string; name?: string } | string; return?: Fiber }
  let node: Element | null = element
  while (node) {
    const fiberEntry = Object.entries(node).find(([key]) => key.startsWith('__reactFiber$'))
    if (fiberEntry) {
      let fiber: Fiber | undefined = fiberEntry[1] as Fiber | undefined
      const names: string[] = []
      while (fiber && names.length < 12) {
        const type = fiber.type
        const name = typeof type === 'function' || typeof type === 'object' ? type?.displayName || type?.name : null
        if (name) names.unshift(name)
        fiber = fiber.return
      }
      return names.join(' > ').slice(-120)
    }
    node = node.parentElement
  }
  return ''
}

const MAX_ANCHOR_BYTES = 1024
const INTERACTIVE_OR_ANNOTATED_SELECTOR =
  'button, a, input, select, textarea, summary, [role="button"], [role="link"], [role="tab"], [role="menuitem"], [role="checkbox"], [role="switch"], [data-ankole-src]'

function isHtmlElement(node: Element): node is HTMLElement {
  const view = node.ownerDocument?.defaultView
  if (view?.HTMLElement) return node instanceof view.HTMLElement
  if (typeof HTMLElement !== 'undefined') return node instanceof HTMLElement
  return (
    node.namespaceURI !== 'http://www.w3.org/2000/svg' &&
    !/^(?:svg|path|g|circle|rect|line|polyline|polygon|use|defs|clippath)$/i.test(node.tagName)
  )
}

function toHtmlElement(node: Element | null): HTMLElement | null {
  let current = node
  while (current) {
    if (isHtmlElement(current)) return current
    current = current.parentElement
  }
  return null
}

function eventElement(target: EventTarget | null, doc: Document): Element | null {
  if (!target || typeof target !== 'object') return null
  const view = doc.defaultView
  if (view?.Element) {
    if (target instanceof view.Element) return target
    if (view.Node && target instanceof view.Node) return target.parentElement
    return null
  }
  if (typeof Element !== 'undefined' && target instanceof Element) return target
  if ('tagName' in target && typeof target.tagName === 'string') return target as Element
  return null
}

function resolvePickTarget(element: Element): HTMLElement | null {
  const htmlElement = toHtmlElement(element)
  if (!htmlElement) return null
  const matched = htmlElement.closest(INTERACTIVE_OR_ANNOTATED_SELECTOR)
  return (matched ? toHtmlElement(matched) : null) ?? htmlElement
}

function trimAnchorFieldToBudget(
  anchor: AppletElementAnchor,
  key: 'text_fingerprint' | 'component' | 'source',
  encoder: TextEncoder
) {
  if (encoder.encode(JSON.stringify(anchor)).length <= MAX_ANCHOR_BYTES || !anchor[key]) return
  const points = Array.from(anchor[key])
  let low = 0
  let high = points.length
  while (low < high) {
    const mid = Math.ceil((low + high) / 2)
    anchor[key] = points.slice(0, mid).join('')
    if (encoder.encode(JSON.stringify(anchor)).length <= MAX_ANCHOR_BYTES) {
      low = mid
    } else {
      high = mid - 1
    }
  }
  anchor[key] = points.slice(0, low).join('')
}

function escapeIdSelector(id: string): string {
  return typeof CSS !== 'undefined' && typeof CSS.escape === 'function'
    ? CSS.escape(id)
    : id.replace(/([^\w-])/g, '\\$1')
}

export function captureAppletElement(element: Element, revision: number): AppletElementSelection {
  const target = resolvePickTarget(element) ?? (element as HTMLElement)
  const rawSourceElement = target.closest('[data-ankole-src]')
  const sourceElement = rawSourceElement ? (toHtmlElement(rawSourceElement) ?? (rawSourceElement as HTMLElement)) : null
  const source = sourceElement?.getAttribute('data-ankole-src') ?? ''
  const targetTag = target.tagName.toLowerCase()
  // A JSX line can contain different tags; composite UIKit controls without their own data-ankole-src
  // scope their selector under the nearest annotated JSX parent so quotes and highlights stay tight.
  let selector = targetTag
  if (sourceElement && source) {
    const attr = `[data-ankole-src=${JSON.stringify(source)}]`
    selector =
      sourceElement === target ? `${targetTag}${attr}` : `${sourceElement.tagName.toLowerCase()}${attr} ${targetTag}`
  } else if (target.id) {
    selector = `#${escapeIdSelector(target.id)}`
  }
  const quote = clampCommentQuote(
    target.innerText ?? target.textContent ?? sourceElement?.innerText ?? sourceElement?.textContent ?? ''
  )
  const anchor: AppletElementAnchor = {
    kind: 'applet_element',
    revision,
    source,
    selector,
    component: componentChain(target),
    text_fingerprint: Array.from(quote.replace(/\s+/g, ' ')).slice(0, 100).join('')
  }
  // Match the durable comment anchor's byte budget without splitting UTF-16 surrogates or CSS selectors.
  const encoder = new TextEncoder()
  trimAnchorFieldToBudget(anchor, 'text_fingerprint', encoder)
  trimAnchorFieldToBudget(anchor, 'component', encoder)
  trimAnchorFieldToBudget(anchor, 'source', encoder)
  if (encoder.encode(JSON.stringify(anchor)).length > MAX_ANCHOR_BYTES) {
    anchor.selector = targetTag
    trimAnchorFieldToBudget(anchor, 'source', encoder)
  }
  return { anchor, quote }
}

export function revealAppletElement(
  doc: Document,
  anchor: AppletElementAnchor,
  revision: AppletRevision
): HTMLElement | null {
  if (anchor.revision !== revision) return null
  let candidates: HTMLElement[]
  try {
    candidates = Array.from(doc.querySelectorAll<HTMLElement>(anchor.selector)).filter(
      node =>
        node.getClientRects().length > 0 &&
        (node.innerText ?? node.textContent ?? '').replace(/\s+/g, ' ').includes(anchor.text_fingerprint)
    )
  } catch {
    return null
  }
  if (candidates.length !== 1) return null
  const node = candidates[0]!
  const reducedMotion = Boolean(doc.defaultView?.matchMedia('(prefers-reduced-motion: reduce)').matches)
  node.scrollIntoView({ block: 'center', behavior: reducedMotion ? 'auto' : 'smooth' })
  if (reducedMotion) {
    const prevOutline = node.style.outline
    const prevOffset = node.style.outlineOffset
    node.style.outline = '2px solid var(--primary, #2684ff)'
    node.style.outlineOffset = '3px'
    setTimeout(() => {
      node.style.outline = prevOutline
      node.style.outlineOffset = prevOffset
    }, 1200)
  } else {
    node.animate(
      [
        { outline: '2px solid var(--primary, #2684ff)', outlineOffset: '3px' },
        { outline: '2px solid transparent', outlineOffset: '3px' }
      ],
      { duration: 1600, easing: 'cubic-bezier(0.23, 1, 0.32, 1)' }
    )
  }
  return node
}

/** Capture in the same-origin frame, without invoking the Applet's own click handler. */
export function pickAppletElement(
  frame: HTMLIFrameElement,
  revision: number,
  picked: (selection: AppletElementSelection) => void,
  cancelled: () => void
) {
  const doc = frame.contentDocument
  if (!doc?.body) return () => {}
  const cursorStyle = doc.createElement('style')
  cursorStyle.dataset.ankolePicker = 'true'
  cursorStyle.textContent = '*, *::before, *::after { cursor: crosshair !important; }'
  doc.head.append(cursorStyle)

  const outline = doc.createElement('div')
  outline.style.cssText =
    'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid var(--primary, #2684ff);border-radius:4px;background:color-mix(in oklch, var(--primary, #2684ff) 12%, transparent);display:none'
  const badge = doc.createElement('div')
  badge.style.cssText =
    'position:fixed;pointer-events:none;z-index:2147483647;max-width:min(320px, calc(100vw - 16px));overflow:hidden;text-overflow:ellipsis;white-space:nowrap;border-radius:4px;padding:2px 6px;font:500 11px/1.4 var(--font-mono, ui-monospace, monospace);background:var(--primary, #2684ff);color:var(--primary-fg, #ffffff);display:none'
  doc.body.append(outline, badge)

  let pickActive = true
  const suppressPress = (event: Event) => {
    if (!pickActive) return
    event.preventDefault()
    event.stopImmediatePropagation()
  }
  const move = (event: MouseEvent) => {
    if (!pickActive) return
    const raw = eventElement(event.target, doc)
    const node = raw ? resolvePickTarget(raw) : null
    if (!node?.getBoundingClientRect) return
    const rect = node.getBoundingClientRect()
    Object.assign(outline.style, {
      display: 'block',
      left: `${rect.left}px`,
      top: `${rect.top}px`,
      width: `${rect.width}px`,
      height: `${rect.height}px`
    })
    const source = node.closest('[data-ankole-src]')?.getAttribute('data-ankole-src') ?? ''
    const leafComponent = componentChain(node).split(' > ').at(-1)
    const label = [leafComponent || node.tagName.toLowerCase(), source].filter(Boolean).join(' · ')
    if (label) {
      badge.textContent = label
      const top = rect.top >= 24 ? rect.top - 22 : Math.min(rect.bottom + 4, (doc.defaultView?.innerHeight ?? 800) - 24)
      const left = Math.max(8, Math.min(rect.left, (doc.defaultView?.innerWidth ?? 800) - 180))
      Object.assign(badge.style, {
        display: 'block',
        left: `${left}px`,
        top: `${top}px`
      })
    } else {
      badge.style.display = 'none'
    }
  }
  const click = (event: MouseEvent) => {
    if (!pickActive) return
    event.preventDefault()
    event.stopImmediatePropagation()
    const raw = eventElement(event.target, doc)
    const node = raw ? resolvePickTarget(raw) : null
    if (node?.tagName) {
      pickActive = false
      picked(captureAppletElement(node, revision))
    }
  }
  const key = (event: KeyboardEvent) => {
    if (event.key === 'Escape') {
      pickActive = false
      event.preventDefault()
      event.stopImmediatePropagation()
      cancelled()
    }
  }
  doc.addEventListener('pointerdown', suppressPress, true)
  doc.addEventListener('mousedown', suppressPress, true)
  doc.addEventListener('mousemove', move, true)
  doc.addEventListener('click', click, true)
  doc.addEventListener('keydown', key, true)
  window.addEventListener('keydown', key, true)
  return () => {
    pickActive = false
    cursorStyle.remove()
    outline.remove()
    badge.remove()
    doc.removeEventListener('pointerdown', suppressPress, true)
    doc.removeEventListener('mousedown', suppressPress, true)
    doc.removeEventListener('mousemove', move, true)
    doc.removeEventListener('click', click, true)
    doc.removeEventListener('keydown', key, true)
    window.removeEventListener('keydown', key, true)
  }
}
