import { expect, test } from 'bun:test'
import {
  activeOutlineIndex,
  collectOutlineHeadings,
  scrollToOffsetAsync,
  type OutlineHeading
} from './document-outline'

function fakeHeading(
  tagName: 'H1' | 'H2' | 'H3',
  textContent: string,
  options: { hidden?: boolean; excludedSelector?: string; top?: number } = {}
): HTMLElement {
  const top = options.top ?? 0
  return {
    tagName,
    textContent,
    classList: {
      contains: (cls: string) => Boolean(options.hidden && cls === 'heading-hidden')
    },
    closest: (selector: string) =>
      options.excludedSelector && selector.includes(options.excludedSelector) ? ({} as Element) : null,
    getBoundingClientRect: () => ({ top, bottom: top + 32, left: 0, right: 600, width: 600, height: 32 }) as DOMRect
  } as unknown as HTMLElement
}

function fakeRoot(nodes: HTMLElement[]): ParentNode {
  return {
    querySelectorAll: () => nodes as unknown as NodeListOf<Element>
  } as unknown as ParentNode
}

test('collectOutlineHeadings hides outlines with fewer than two visible headings and normalizes relative depth', () => {
  expect(collectOutlineHeadings(null)).toEqual([])
  expect(collectOutlineHeadings(fakeRoot([fakeHeading('H1', 'Only section')]))).toEqual([])

  const h2 = fakeHeading('H2', '  Overview \n  Notes ')
  const embedded = fakeHeading('H1', 'Embedded card heading', { excludedSelector: '.embed' })
  const folded = fakeHeading('H3', 'Folded subheading', { hidden: true })
  const empty = fakeHeading('H2', '   ')
  const h3 = fakeHeading('H3', 'Implementation details')

  const outline = collectOutlineHeadings(fakeRoot([h2, embedded, folded, empty, h3]))
  expect(outline.map(({ id, level, depth, title }) => ({ id, level, depth, title }))).toEqual([
    { id: 'outline-0', level: 2, depth: 0, title: 'Overview Notes' },
    { id: 'outline-1', level: 3, depth: 1, title: 'Implementation details' }
  ])
})

test('collectOutlineHeadings keeps headings inside read-only .editor-content[contenteditable="false"] while excluding non-editable blocks inside it', () => {
  type MiniElement = {
    tagName: string
    classes: Set<string>
    attrs: Record<string, string>
    textContent: string
    parent: MiniElement | null
    children: MiniElement[]
    classList: { contains(cls: string): boolean }
    matches(selector: string): boolean
    closest(selector: string): MiniElement | null
    querySelectorAll(selector: string): MiniElement[]
  }

  function matchesCompound(el: MiniElement, compound: string): boolean {
    if (compound.startsWith(':is(') && compound.endsWith(')')) {
      const choices = compound
        .slice(4, -1)
        .split(',')
        .map(s => s.trim())
      return choices.some(choice => matchesCompound(el, choice))
    }
    if (compound.startsWith('.')) return el.classes.has(compound.slice(1))
    const attrMatch = /^\[([a-z-]+)="([^"]*)"\]$/i.exec(compound)
    if (attrMatch) return el.attrs[attrMatch[1]!] === attrMatch[2]
    return el.tagName.toLowerCase() === compound.toLowerCase()
  }

  function splitTopLevelSpaces(rawSelector: string): string[] {
    const out: string[] = []
    let depth = 0
    let token = ''
    for (const ch of rawSelector.trim()) {
      if (ch === '(') {
        depth++
        token += ch
      } else if (ch === ')') {
        depth--
        token += ch
      } else if (/\s/.test(ch) && depth === 0) {
        if (token) {
          out.push(token)
          token = ''
        }
      } else {
        token += ch
      }
    }
    if (token) out.push(token)
    return out
  }

  function matchesSingleSelector(el: MiniElement, rawSelector: string): boolean {
    const parts = splitTopLevelSpaces(rawSelector)
    if (!matchesCompound(el, parts.at(-1)!)) return false
    let ancestor = el.parent
    for (let idx = parts.length - 2; idx >= 0; idx--) {
      while (ancestor && !matchesCompound(ancestor, parts[idx]!)) ancestor = ancestor.parent
      if (!ancestor) return false
      ancestor = ancestor.parent
    }
    return true
  }

  function splitTopLevelCommas(selectorList: string): string[] {
    const out: string[] = []
    let depth = 0
    let start = 0
    for (let i = 0; i < selectorList.length; i++) {
      const ch = selectorList[i]
      if (ch === '(') depth++
      else if (ch === ')') depth--
      else if (ch === ',' && depth === 0) {
        out.push(selectorList.slice(start, i).trim())
        start = i + 1
      }
    }
    out.push(selectorList.slice(start).trim())
    return out.filter(Boolean)
  }

  function makeEl(
    tagName: string,
    attrs: Record<string, string> = {},
    children: MiniElement[] = [],
    text = ''
  ): MiniElement {
    const classes = new Set((attrs.class ?? '').split(/\s+/).filter(Boolean))
    const node: MiniElement = {
      tagName: tagName.toUpperCase(),
      classes,
      attrs,
      textContent: text || children.map(c => c.textContent).join(''),
      parent: null,
      children,
      classList: { contains: cls => classes.has(cls) },
      matches: selectorList => splitTopLevelCommas(selectorList).some(sel => matchesSingleSelector(node, sel)),
      closest(selectorList) {
        let cur: MiniElement | null = node
        while (cur) {
          if (cur.matches(selectorList)) return cur
          cur = cur.parent
        }
        return null
      },
      querySelectorAll(selectorList) {
        const found: MiniElement[] = []
        const walk = (cur: MiniElement) => {
          for (const child of cur.children) {
            if (child.matches(selectorList)) found.push(child)
            walk(child)
          }
        }
        walk(node)
        return found
      }
    }
    for (const child of children) child.parent = node
    return node
  }

  // Mirrors `<div class="ankole-editor"><div class="editor-content" contenteditable="false">...</div></div>`
  const tree = makeEl('div', { class: 'ankole-editor' }, [
    makeEl('div', { class: 'editor-content', contenteditable: 'false' }, [
      makeEl('h1', {}, [], 'Reader Introduction'),
      makeEl('div', { contenteditable: 'false' }, [makeEl('h2', {}, [], 'Non-editable Card Heading')]),
      makeEl('h2', {}, [], 'Reader Architecture')
    ])
  ])

  const outline = collectOutlineHeadings(tree as unknown as ParentNode)
  expect(outline.map(item => ({ id: item.id, level: item.level, depth: item.depth, title: item.title }))).toEqual([
    { id: 'outline-0', level: 1, depth: 0, title: 'Reader Introduction' },
    { id: 'outline-1', level: 2, depth: 1, title: 'Reader Architecture' }
  ])
})

test('activeOutlineIndex tracks the reading line and activates the final heading at the bottom of the scrollport', () => {
  let tops = [80, 260, 520]
  const headings: OutlineHeading[] = ['First', 'Second', 'Third'].map((title, index) => ({
    id: `outline-${index}`,
    index,
    level: 2,
    depth: 0,
    title,
    element: {
      getBoundingClientRect: () =>
        ({ top: tops[index]!, bottom: tops[index]! + 28, left: 0, right: 500, width: 500, height: 28 }) as DOMRect
    } as unknown as HTMLElement
  }))

  const scroller = {
    scrollTop: 0,
    clientHeight: 600,
    scrollHeight: 1400,
    getBoundingClientRect: () => ({ top: 0, bottom: 600, left: 0, right: 800, width: 800, height: 600 }) as DOMRect
  } as unknown as HTMLElement

  // Reading line is min(140, 600 * 0.25) = 140. Heading 0 (80) is above 140; Heading 1 (260) is below.
  expect(activeOutlineIndex(scroller, headings)).toBe(0)

  // Scroll down so Heading 1 crosses the reading line (110 <= 142).
  tops = [-120, 110, 410]
  expect(activeOutlineIndex(scroller, headings)).toBe(1)

  // Reach the bottom of the scrollport while Heading 2 is visible below the reading line (top = 340 < bottom 600).
  tops = [-420, -90, 340]
  Object.assign(scroller, { scrollTop: 800 })
  expect(activeOutlineIndex(scroller, headings)).toBe(2)
})

test('activeOutlineIndex highlights the first heading on short documents where scrollHeight <= clientHeight at scrollTop === 0', () => {
  const tops = [60, 220, 380]
  const headings: OutlineHeading[] = ['Intro', 'Details', 'Summary'].map((title, index) => ({
    id: `outline-${index}`,
    index,
    level: 2,
    depth: 0,
    title,
    element: {
      getBoundingClientRect: () =>
        ({ top: tops[index]!, bottom: tops[index]! + 28, left: 0, right: 500, width: 500, height: 28 }) as DOMRect
    } as unknown as HTMLElement
  }))

  for (const scrollHeight of [480, 600]) {
    const shortScroller = {
      scrollTop: 0,
      clientHeight: 600,
      scrollHeight,
      getBoundingClientRect: () => ({ top: 0, bottom: 600, left: 0, right: 800, width: 800, height: 600 }) as DOMRect
    } as unknown as HTMLElement

    expect(activeOutlineIndex(shortScroller, headings)).toBe(0)
  }
})

test('scrollToOffsetAsync awaits native scroll Promises and falls back cleanly to scrollend or idle timers', async () => {
  let resolvedNative = false
  const promiseScroller = {
    scrollTo: () =>
      new Promise<void>(resolve => {
        setTimeout(() => {
          resolvedNative = true
          resolve()
        }, 10)
      })
  } as unknown as HTMLElement

  await scrollToOffsetAsync(promiseScroller, 240, 'smooth')
  expect(resolvedNative).toBe(true)

  const listeners = new Map<string, Set<() => void>>()
  const eventScroller = {
    scrollTo: () => undefined,
    addEventListener: (type: string, fn: () => void) => {
      if (!listeners.has(type)) listeners.set(type, new Set())
      listeners.get(type)!.add(fn)
    },
    removeEventListener: (type: string, fn: () => void) => {
      listeners.get(type)?.delete(fn)
    }
  } as unknown as HTMLElement

  const pending = scrollToOffsetAsync(eventScroller, 320, 'smooth')
  for (const fn of listeners.get('scrollend') ?? []) fn()
  await pending
  expect(listeners.get('scroll')?.size ?? 0).toBe(0)
})
