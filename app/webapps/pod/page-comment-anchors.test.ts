import { beforeAll, expect, test } from 'bun:test'
import i18n, { loadLocale } from '../common/i18n'
import { captureAppletElement, pickAppletElement, type AppletElementSelection } from './applet-elements'
import { formatPageElementAnchor, parsePageElementAnchor } from './page-comment-anchors'

beforeAll(async () => {
  await loadLocale('zh-Hans-CN')
})

test('comment cards preserve Applet source coordinates and existing File anchor labels', () => {
  const anchor = {
    kind: 'applet_element' as const,
    revision: 4,
    source: 'src/OrderList.tsx:48',
    component: 'App > OrderList > StatusBadge',
    selector: '[data-ankole-src="src/OrderList.tsx:48"]',
    text_fingerprint: '待发货'
  }
  const parsed = parsePageElementAnchor(anchor)
  expect(parsed).toEqual(anchor)
  expect(formatPageElementAnchor(parsed!, i18n.t)).toBe('App > OrderList > StatusBadge · src/OrderList.tsx:48')
  expect(formatPageElementAnchor({ kind: 'lines', start_line: 7, end_line: 9 }, i18n.t)).toBe('L7–L9')
  expect(parsePageElementAnchor({ ...anchor, revision: '4' })).toBeNull()
  expect(parsePageElementAnchor({ ...anchor, source: 3 })).toBeNull()
  expect(parsePageElementAnchor({ kind: 'base_record', record_id: 'record' })).toBeNull()
  expect(parsePageElementAnchor(null)).toBeNull()
})

test('picking an unannotated UIKit button inside an annotated JSX container scopes quote and selector to the button', () => {
  const wrapper = {
    tagName: 'DIV',
    id: '',
    innerText: 'Full page dashboard heading with lots of unrelated text\nApprove order',
    parentElement: null,
    getAttribute: (name: string) => (name === 'data-ankole-src' ? 'src/App.tsx:10' : null),
    closest: (selector: string) => (selector.includes('[data-ankole-src]') ? wrapper : null)
  } as unknown as HTMLElement
  const button = {
    tagName: 'BUTTON',
    id: '',
    innerText: 'Approve order',
    parentElement: wrapper,
    getAttribute: () => null,
    closest: (selector: string) =>
      selector.includes('button') ? button : selector.includes('[data-ankole-src]') ? wrapper : null
  } as unknown as HTMLElement
  const label = {
    tagName: 'SPAN',
    id: '',
    innerText: 'Approve order',
    parentElement: button,
    getAttribute: () => null,
    closest: (selector: string) =>
      selector.includes('button') ? button : selector.includes('[data-ankole-src]') ? wrapper : null
  } as unknown as HTMLElement

  const captured = captureAppletElement(label, 7)
  expect(captured.quote).toBe('Approve order')
  expect(captured.anchor).toMatchObject({
    kind: 'applet_element',
    revision: 7,
    source: 'src/App.tsx:10',
    selector: 'div[data-ankole-src="src/App.tsx:10"] button',
    text_fingerprint: 'Approve order'
  })
})

test('pickAppletElement resolves cross-realm iframe <svg>/<path> targets to the enclosing button and suppresses press events', () => {
  class RealmNode {
    parentElement: RealmElement | null = null
  }
  class RealmElement extends RealmNode {
    tagName: string
    id = ''
    ownerDocument: unknown
    attrs = new Map<string, string>()
    style: Record<string, string> = {}
    dataset: Record<string, string> = {}
    textContent = ''
    innerText?: string
    constructor(tagName: string, ownerDocument: unknown) {
      super()
      this.tagName = tagName
      this.ownerDocument = ownerDocument
    }
    getAttribute(name: string) {
      return this.attrs.get(name) ?? null
    }
    matchesSelector(selector: string): boolean {
      return (
        (selector.includes('button') && this.tagName.toLowerCase() === 'button') ||
        (selector.includes('[data-ankole-src]') && this.attrs.has('data-ankole-src'))
      )
    }
    closest(selector: string): RealmElement | null {
      if (this.matchesSelector(selector)) return this
      return this.parentElement ? this.parentElement.closest(selector) : null
    }
    getBoundingClientRect() {
      return { left: 12, top: 40, bottom: 72, width: 120, height: 32 } as DOMRect
    }
    remove() {}
  }
  class RealmHTMLElement extends RealmElement {}
  class RealmSVGElement extends RealmElement {}

  const listeners = new Map<string, Set<(event: any) => void>>()
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, 'window')
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: {
      addEventListener() {},
      removeEventListener() {}
    }
  })

  try {
    const iframeDoc: any = {
      defaultView: {
        Node: RealmNode,
        Element: RealmElement,
        HTMLElement: RealmHTMLElement,
        innerHeight: 600,
        innerWidth: 800
      },
      head: { append() {} },
      body: { append() {} },
      createElement: (tag: string) => new RealmHTMLElement(tag.toUpperCase(), iframeDoc),
      addEventListener: (type: string, fn: (event: any) => void) => {
        if (!listeners.has(type)) listeners.set(type, new Set())
        listeners.get(type)!.add(fn)
      },
      removeEventListener: (type: string, fn: (event: any) => void) => {
        listeners.get(type)?.delete(fn)
      }
    }

    const container = new RealmHTMLElement('DIV', iframeDoc)
    container.attrs.set('data-ankole-src', 'src/Toolbar.tsx:22')
    const button = new RealmHTMLElement('BUTTON', iframeDoc)
    button.parentElement = container
    button.innerText = 'Filter region'
    const svg = new RealmSVGElement('svg', iframeDoc)
    svg.parentElement = button
    const pathNode = new RealmSVGElement('path', iframeDoc)
    pathNode.parentElement = svg

    let selection: AppletElementSelection | undefined
    const dispose = pickAppletElement(
      { contentDocument: iframeDoc } as unknown as HTMLIFrameElement,
      9,
      picked => {
        selection = picked
      },
      () => {}
    )

    for (const pressType of ['pointerdown', 'mousedown']) {
      let prevented = false
      let stopped = false
      for (const handler of listeners.get(pressType) ?? []) {
        handler({
          target: pathNode,
          preventDefault: () => {
            prevented = true
          },
          stopImmediatePropagation: () => {
            stopped = true
          }
        })
      }
      expect(prevented).toBe(true)
      expect(stopped).toBe(true)
    }

    for (const handler of listeners.get('click') ?? []) {
      handler({
        target: pathNode,
        preventDefault() {},
        stopImmediatePropagation() {}
      })
    }
    dispose()

    expect(selection).toBeDefined()
    expect(selection!.quote).toBe('Filter region')
    expect(selection!.anchor).toMatchObject({
      kind: 'applet_element',
      revision: 9,
      source: 'src/Toolbar.tsx:22',
      selector: 'div[data-ankole-src="src/Toolbar.tsx:22"] button',
      text_fingerprint: 'Filter region'
    })
  } finally {
    if (previousWindow) Object.defineProperty(globalThis, 'window', previousWindow)
    else Reflect.deleteProperty(globalThis, 'window')
  }
})

test('captureAppletElement trims emoji text_fingerprint, component, and source cleanly within MAX_ANCHOR_BYTES without lone surrogates', () => {
  const encoder = new TextEncoder()
  const emojiFlood = '🚀🧪📊🔥'.repeat(40)
  const emojiButton = {
    tagName: 'BUTTON',
    id: '',
    innerText: emojiFlood,
    parentElement: null,
    __reactFiber$test: {
      type: { displayName: 'EmojiActionCardWithVeryDescriptiveComponentDisplayName' },
      return: { type: { displayName: 'WorkspaceDashboardRootShellContainer' } }
    },
    getAttribute: (name: string) =>
      name === 'data-ankole-src' ? `src/features/${'deeply-nested-segment/'.repeat(16)}Card.tsx:88` : null,
    closest: (selector: string) =>
      selector.includes('button') || selector.includes('[data-ankole-src]') ? emojiButton : null
  } as unknown as HTMLElement

  const capturedEmoji = captureAppletElement(emojiButton, 12)
  const serializedEmoji = JSON.stringify(capturedEmoji.anchor)
  expect(encoder.encode(serializedEmoji).length).toBeLessThanOrEqual(1024)
  expect(capturedEmoji.anchor.text_fingerprint.isWellFormed()).toBe(true)
  expect(capturedEmoji.anchor.text_fingerprint.length).toBeGreaterThan(0)

  const hugeSource = `src/${'very-long-module-folder-'.repeat(45)}Main.tsx:104`
  const hugeMetaNode = {
    tagName: 'DIV',
    id: '',
    innerText: '🚀 Summary',
    parentElement: null,
    __reactFiber$test: {
      type: { displayName: 'A'.repeat(120) }
    },
    getAttribute: (name: string) => (name === 'data-ankole-src' ? hugeSource : null),
    closest: (selector: string) => (selector.includes('[data-ankole-src]') ? hugeMetaNode : null)
  } as unknown as HTMLElement

  const capturedHuge = captureAppletElement(hugeMetaNode, 12)
  expect(encoder.encode(JSON.stringify(capturedHuge.anchor)).length).toBeLessThanOrEqual(1024)
  expect(capturedHuge.anchor.text_fingerprint.isWellFormed()).toBe(true)
  expect(capturedHuge.anchor.component.isWellFormed()).toBe(true)
  expect(capturedHuge.anchor.source.isWellFormed()).toBe(true)
})
