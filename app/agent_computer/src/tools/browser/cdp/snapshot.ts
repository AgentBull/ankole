import { SNAPSHOT_TEXT_MAX } from './constants'
import { redactText } from './utils'
import type { BrowserFindMatch, BrowserSnapshot, JsonObject } from './types'

/**
 * Formats a browser snapshot into compact text for the model.
 *
 * Interactive refs are listed first because later browser tools operate on
 * those stable ref ids rather than asking the model to write selectors.
 */
export function formatSnapshot(snapshot: BrowserSnapshot, opts: { full?: boolean } = {}): string {
  const lines = [`URL: ${snapshot.url}`, `Title: ${snapshot.title || '(untitled)'}`, '', 'Interactive elements:']
  if (snapshot.elements.length === 0) {
    lines.push('(none found)')
  } else {
    for (const element of snapshot.elements) {
      const disabled = element.disabled ? ' disabled' : ''
      const name = element.name ? ` "${element.name}"` : ''
      lines.push(`[${element.ref}] ${element.role || element.tag}${name}${disabled}`)
    }
  }

  const text = opts.full ? snapshot.text : snapshot.text.slice(0, SNAPSHOT_TEXT_MAX)
  if (text.trim()) {
    lines.push('', 'Page text:', text.trim())
    if (!opts.full && snapshot.text.length > SNAPSHOT_TEXT_MAX) lines.push('[truncated]')
  }

  return redactText(lines.join('\n'))
}

/**
 * Detects browser error pages that otherwise look like ordinary page text.
 */
export function browserNavigationFailureReason(snapshot: BrowserSnapshot): string | undefined {
  const text = snapshot.text.trim()
  if (text === 'Unprocessable Entity' && snapshot.title.trim() === '' && snapshot.elements.length === 0) {
    return 'browser returned a network error page: Unprocessable Entity'
  }
  if (!text.startsWith('Navigation failed')) return undefined
  const reason = text.match(/(?:^|\n)Reason:\s*([^\n]+)/)?.[1]?.trim()
  return reason || 'browser returned a navigation failure page'
}

/**
 * Returns the DOM-side script used to collect text and interactive element refs.
 *
 * The script is self-contained because it is stringified and evaluated inside
 * the page context, not imported as a browser bundle.
 */
export function snapshotScript(maxElements: number): BrowserSnapshot {
  const selectors = [
    'a[href]',
    'button',
    'input',
    'textarea',
    'select',
    'summary',
    '[role]',
    '[tabindex]',
    '[contenteditable="true"]'
  ].join(',')

  const elements = Array.from(document.querySelectorAll<Element>(selectors))
    .filter(isVisible)
    .slice(0, maxElements)
    .map((element, index) => ({
      ref: `e${index + 1}`,
      selector: cssPath(element),
      tag: element.tagName.toLowerCase(),
      role: elementRole(element),
      name: accessibleName(element),
      disabled: elementDisabled(element)
    }))

  return {
    url: location.href,
    title: document.title,
    text: document.body?.innerText || document.documentElement?.innerText || '',
    elements
  }

  function isVisible(element: Element): boolean {
    const style = getComputedStyle(element)
    if (style.visibility === 'hidden' || style.display === 'none') return false
    const rect = element.getBoundingClientRect()
    return rect.width > 0 && rect.height > 0
  }

  function elementRole(element: Element): string {
    const explicit = element.getAttribute('role')
    if (explicit) return explicit
    const tag = element.tagName.toLowerCase()
    if (tag === 'a') return 'link'
    if (tag === 'button') return 'button'
    if (tag === 'select') return 'combobox'
    if (tag === 'textarea') return 'textbox'
    if (tag === 'input') {
      const type = (element.getAttribute('type') || 'text').toLowerCase()
      if (type === 'checkbox') return 'checkbox'
      if (type === 'radio') return 'radio'
      if (type === 'submit' || type === 'button') return 'button'
      return 'textbox'
    }
    return tag
  }

  function accessibleName(element: Element): string {
    const labelledBy = element.getAttribute('aria-labelledby')
    const labelledText = labelledBy
      ?.split(/\s+/)
      .map(id => textFromElement(document.getElementById(id)))
      .join(' ')
      .trim()
    const label =
      element.getAttribute('aria-label') ||
      labelledText ||
      labelText(element) ||
      element.getAttribute('alt') ||
      element.getAttribute('placeholder') ||
      valueText(element) ||
      textFromElement(element) ||
      ''
    return label.replace(/\s+/g, ' ').trim().slice(0, 180)
  }

  function textFromElement(element: Element | null): string {
    if (!element) return ''
    try {
      if (element instanceof HTMLElement) return element.innerText || element.textContent || ''
    } catch {
      return element.textContent || ''
    }
    return element.textContent || ''
  }

  function labelText(element: Element): string {
    if (
      element instanceof HTMLInputElement ||
      element instanceof HTMLTextAreaElement ||
      element instanceof HTMLSelectElement
    ) {
      return textFromElement(element.labels?.[0] ?? null)
    }
    return ''
  }

  function valueText(element: Element): string {
    if (
      element instanceof HTMLInputElement ||
      element instanceof HTMLTextAreaElement ||
      element instanceof HTMLButtonElement
    ) {
      return element.value || ''
    }
    return ''
  }

  function elementDisabled(element: Element): boolean {
    if (
      element instanceof HTMLButtonElement ||
      element instanceof HTMLInputElement ||
      element instanceof HTMLSelectElement ||
      element instanceof HTMLTextAreaElement ||
      element instanceof HTMLOptionElement ||
      element instanceof HTMLOptGroupElement
    ) {
      return element.disabled || element.getAttribute('aria-disabled') === 'true'
    }
    return element.getAttribute('aria-disabled') === 'true'
  }

  function cssPath(element: Element): string {
    if (element.id) {
      const idSelector = `#${cssEscape(element.id)}`
      if (document.querySelectorAll(idSelector).length === 1) return idSelector
    }

    const parts: string[] = []
    let current: Element | null = element
    while (current && current.nodeType === Node.ELEMENT_NODE && current !== document.body) {
      const parent: Element | null = current.parentElement
      const tag = current.tagName.toLowerCase()
      if (!parent) {
        parts.unshift(tag)
        break
      }
      const currentTag = current.tagName
      const siblings = Array.from(parent.children).filter((child): child is Element => child.tagName === currentTag)
      const index = siblings.indexOf(current) + 1
      parts.unshift(`${tag}:nth-of-type(${index})`)
      current = parent
    }
    return `body > ${parts.join(' > ')}`
  }

  function cssEscape(value: string): string {
    return value.replace(/[^a-zA-Z0-9_-]/g, char => `\\${char}`)
  }
}

/**
 * Maps a user-friendly key name to the CDP keyboard event fields.
 */
export function keyDefinition(key: string): JsonObject {
  const normalized = key.length === 1 ? key : key.toLowerCase()
  const special: Record<string, { key: string; code: string; windowsVirtualKeyCode: number }> = {
    enter: { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 },
    tab: { key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 },
    escape: { key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 },
    backspace: { key: 'Backspace', code: 'Backspace', windowsVirtualKeyCode: 8 },
    delete: { key: 'Delete', code: 'Delete', windowsVirtualKeyCode: 46 },
    arrowdown: { key: 'ArrowDown', code: 'ArrowDown', windowsVirtualKeyCode: 40 },
    arrowup: { key: 'ArrowUp', code: 'ArrowUp', windowsVirtualKeyCode: 38 },
    arrowleft: { key: 'ArrowLeft', code: 'ArrowLeft', windowsVirtualKeyCode: 37 },
    arrowright: { key: 'ArrowRight', code: 'ArrowRight', windowsVirtualKeyCode: 39 }
  }
  const match = special[normalized]
  if (match) return { ...match, nativeVirtualKeyCode: match.windowsVirtualKeyCode }
  const char = key[0] ?? ''
  return {
    key: char,
    code: `Key${char.toUpperCase()}`,
    text: char,
    unmodifiedText: char,
    windowsVirtualKeyCode: char.toUpperCase().charCodeAt(0),
    nativeVirtualKeyCode: char.toUpperCase().charCodeAt(0)
  }
}

/**
 * Finds text matches with bounded context for browser_find.
 */
export function findTextMatches(
  text: string,
  opts: { query: string; contextLines?: number; matchLimit?: number; caseSensitive?: boolean }
): BrowserFindMatch[] {
  const contextLines = Math.max(0, Math.min(opts.contextLines ?? 4, 12))
  const matchLimit = Math.max(1, Math.min(opts.matchLimit ?? 20, 50))
  const needle = opts.caseSensitive ? opts.query : opts.query.toLowerCase()
  const lines = text
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)

  const matches: BrowserFindMatch[] = []
  for (let index = 0; index < lines.length && matches.length < matchLimit; index += 1) {
    const haystack = opts.caseSensitive ? lines[index] : lines[index].toLowerCase()
    if (!haystack.includes(needle)) continue

    matches.push({
      line: index + 1,
      text: lines[index],
      before: lines.slice(Math.max(0, index - contextLines), index),
      after: lines.slice(index + 1, Math.min(lines.length, index + contextLines + 1))
    })
  }
  return matches
}

/**
 * Formats browser_find matches as readable text blocks.
 */
export function formatFindMatches(matches: BrowserFindMatch[]): string {
  if (matches.length === 0) return '(no matches)'

  return matches
    .map(match => {
      const lines = [`line ${match.line}: ${match.text}`]
      if (match.before.length > 0) lines.unshift(...match.before.map(line => `  ${line}`))
      if (match.after.length > 0) lines.push(...match.after.map(line => `  ${line}`))
      return lines.join('\n')
    })
    .join('\n---\n')
}
