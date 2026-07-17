import type { CDPSession, Frame, Locator, Page } from 'playwright-core'
import type { BrowserCommandArgs } from '../protocol'
import { BrowserDataError } from '../errors'

export type RefTarget = {
  ref: string
  frameIndex: number
  frameURL: string
  selector: string
  backendDOMNodeId?: number
  role: string
  name: string
  box?: { x: number; y: number; width: number; height: number }
}

type SnapshotNode = {
  role: string
  name: string
  selector?: string
  backendDOMNodeId?: number
  interactive: boolean
  disabled: boolean
  checked?: boolean | string
  value?: string
  url?: string
  depth: number
  box?: { x: number; y: number; width: number; height: number }
}

export type SnapshotOptions = BrowserCommandArgs<'snapshot'>

export class SnapshotStore {
  private readonly refs = new Map<string, RefTarget>()
  private generation = 0

  clear(): void {
    this.refs.clear()
    this.generation += 1
  }

  entries(): RefTarget[] {
    return [...this.refs.values()]
  }

  async capture(page: Page, options: SnapshotOptions = {}): Promise<string> {
    this.refs.clear()
    this.generation += 1
    const lines: string[] = []
    let nextRef = 1
    const frames = page.frames()
    for (let frameIndex = 0; frameIndex < frames.length; frameIndex += 1) {
      const frame = frames[frameIndex]!
      let nodes: SnapshotNode[]
      try {
        nodes =
          frameIndex === 0 && !options.selector
            ? await collectAXNodes(page, options).catch(() => collectFrameNodes(frame, options))
            : await collectFrameNodes(frame, options)
      } catch (error) {
        lines.push(`[frame ${frameIndex} ${frame.url() || 'about:blank'} unavailable: ${errorMessage(error)}]`)
        continue
      }
      if (frame !== page.mainFrame()) lines.push(`[frame ${frameIndex} ${frame.url() || 'about:blank'}]`)
      for (const node of nodes) {
        let refText = ''
        if (node.interactive && node.selector) {
          const ref = `e${nextRef++}`
          this.refs.set(ref, {
            ref,
            frameIndex,
            frameURL: frame.url(),
            selector: node.selector,
            ...(node.backendDOMNodeId === undefined ? {} : { backendDOMNodeId: node.backendDOMNodeId }),
            role: node.role,
            name: node.name,
            box: node.box
          })
          refText = ` [ref=${ref}]`
        }
        const state = [node.disabled ? 'disabled' : '', node.checked === undefined ? '' : `checked=${node.checked}`]
          .filter(Boolean)
          .map(value => ` [${value}]`)
          .join('')
        const href = options.urls && node.url ? ` [url=${JSON.stringify(node.url)}]` : ''
        const value = node.value && node.value !== node.name ? ` [value=${JSON.stringify(node.value)}]` : ''
        const indent = options.compact ? '' : '  '.repeat(Math.min(node.depth, 8))
        const name = node.name ? ` ${JSON.stringify(node.name)}` : ''
        lines.push(`${indent}- ${node.role}${name}${refText}${state}${value}${href}`)
      }
    }
    if (lines.length === 0) return '(empty page)'
    const text = lines.join('\n')
    const budget = 16 * 1024
    return text.length <= budget ? text : `${text.slice(0, budget)}\n… [snapshot truncated]`
  }

  async resolve(page: Page, input: string, rawFrame: Frame = page.mainFrame()): Promise<Locator> {
    const explicitRef = /^(?:@|ref=)(e\d+)$/.exec(input)
    const normalized = explicitRef?.[1] ?? input
    const target = this.refs.get(normalized)
    if (!target) {
      if (explicitRef)
        throw new BrowserDataError('stale_ref', `ref ${normalized} is not present in the latest snapshot`)
      return rawFrame.locator(input)
    }
    const frames = page.frames()
    const frame = frames[target.frameIndex]
    if (!frame || frame.url() !== target.frameURL) {
      throw new BrowserDataError('stale_ref', `ref ${normalized} belongs to a stale frame`)
    }
    const locator =
      target.backendDOMNodeId === undefined
        ? frame.locator(target.selector)
        : await locatorForBackendNode(page, frame, target.backendDOMNodeId, normalized)
    if ((await locator.count()) !== 1)
      throw new BrowserDataError('stale_ref', `ref ${normalized} no longer resolves uniquely`)
    if (target.backendDOMNodeId !== undefined) return locator
    const fingerprint = await locator.evaluate(element => {
      const explicit = element.getAttribute('role')?.trim()
      let role = explicit?.split(/\s+/)[0]
      if (!role) {
        const tag = element.tagName.toLowerCase()
        if (/^h[1-6]$/.test(tag)) role = 'heading'
        else if (tag === 'a' && element.hasAttribute('href')) role = 'link'
        else if (tag === 'button') role = 'button'
        else if (tag === 'textarea') role = 'textbox'
        else if (tag === 'select') role = 'combobox'
        else if (tag === 'img') role = 'img'
        else if (tag === 'table') role = 'table'
        else if (tag === 'tr') role = 'row'
        else if (tag === 'td' || tag === 'th') role = 'cell'
        else if (tag === 'li') role = 'listitem'
        else if (tag === 'input') {
          const type = (element.getAttribute('type') ?? 'text').toLowerCase()
          if (type === 'checkbox') role = 'checkbox'
          else if (type === 'radio') role = 'radio'
          else if (['button', 'submit', 'reset'].includes(type)) role = 'button'
          else if (type === 'search') role = 'searchbox'
          else role = 'textbox'
        } else role = tag
      }

      let name = element.getAttribute('aria-label')?.trim() ?? ''
      const labelledBy = element.getAttribute('aria-labelledby')
      if (!name && labelledBy) {
        name = labelledBy
          .split(/\s+/)
          .map(id => document.getElementById(id)?.textContent?.trim() ?? '')
          .filter(Boolean)
          .join(' ')
      }
      if (!name && element instanceof HTMLInputElement) {
        name = element.labels?.[0]?.textContent?.trim() ?? element.placeholder
        if (!name && element.value && ['button', 'submit', 'reset'].includes(element.type)) name = element.value
      }
      if (!name && element instanceof HTMLImageElement) name = element.alt
      if (!name) name = element.getAttribute('title')?.trim() ?? ''
      if (!name) name = (element.textContent ?? '').replace(/\s+/g, ' ').trim().slice(0, 240)
      return { role, name }
    })
    if (fingerprint.role !== target.role || fingerprint.name !== target.name) {
      throw new BrowserDataError('stale_ref', `ref ${normalized} no longer matches its snapshot fingerprint`, {
        details: {
          expected: { role: target.role, name: target.name },
          actual: fingerprint
        }
      })
    }
    return locator
  }
}

type AXNodeLike = {
  nodeId: string
  ignored: boolean
  role?: { value?: unknown }
  chromeRole?: { value?: unknown }
  name?: { value?: unknown }
  value?: { value?: unknown }
  properties?: Array<{ name: string; value: { value?: unknown } }>
  parentId?: string
  backendDOMNodeId?: number
}

async function collectAXNodes(page: Page, options: SnapshotOptions): Promise<SnapshotNode[]> {
  const session = await page.context().newCDPSession(page)
  try {
    await Promise.all([session.send('Accessibility.enable'), session.send('DOM.enable')])
    const tree = await session.send('Accessibility.getFullAXTree')
    const nodes = tree.nodes as AXNodeLike[]
    const byID = new Map(nodes.map(node => [node.nodeId, node]))
    const output: SnapshotNode[] = []

    for (const node of nodes) {
      if (node.ignored) continue
      const role = normalizeAXRole(stringValue(node.role?.value ?? node.chromeRole?.value))
      if (!role || role === 'inline-text') continue
      const name = stringValue(node.name?.value)
      const interactive = isAXInteractive(role, node)
      if (options.interactive && !interactive) continue
      if (!interactive && !name && (options.compact || !isAXStructure(role))) continue
      const depth = axDepth(node, byID)
      if (depth > (options.depth ?? 32)) continue

      let selector: string | undefined
      let box: SnapshotNode['box']
      if (interactive && node.backendDOMNodeId !== undefined) {
        selector = await selectorForBackendNode(session, node.backendDOMNodeId).catch(() => undefined)
        box = await boxForBackendNode(session, node.backendDOMNodeId).catch(() => undefined)
      }
      const checked = axProperty(node, 'checked')
      const value = stringValue(node.value?.value)
      const url = stringValue(axProperty(node, 'url'))
      output.push({
        role,
        name,
        ...(selector ? { selector } : {}),
        ...(selector && node.backendDOMNodeId !== undefined ? { backendDOMNodeId: node.backendDOMNodeId } : {}),
        interactive,
        disabled: axProperty(node, 'disabled') === true,
        ...(typeof checked === 'boolean' || typeof checked === 'string' ? { checked } : {}),
        ...(value ? { value } : {}),
        ...(url ? { url } : {}),
        depth,
        ...(box ? { box } : {})
      })
    }

    // AX trees can omit pointer/click handlers and other DOM-only interactive
    // affordances. Add those with the same selectors used by command refs.
    const extras = await collectFrameNodes(page.mainFrame(), { ...options, interactive: true })
    const selectors = new Set(output.map(node => node.selector).filter((value): value is string => Boolean(value)))
    for (const extra of extras) {
      if (extra.selector && !selectors.has(extra.selector)) output.push(extra)
    }
    return output
  } finally {
    await session.send('Accessibility.disable').catch(() => undefined)
    await session.detach().catch(() => undefined)
  }
}

function normalizeAXRole(value: string): string {
  if (!value) return ''
  if (value === 'RootWebArea' || value === 'WebArea') return 'document'
  if (value === 'StaticText' || value === 'LabelText') return 'text'
  if (value === 'InlineTextBox') return 'inline-text'
  return value
    .replace(/([a-z0-9])([A-Z])/g, '$1-$2')
    .replaceAll(' ', '-')
    .toLowerCase()
}

function isAXInteractive(role: string, node: AXNodeLike): boolean {
  if (
    [
      'button',
      'link',
      'textbox',
      'searchbox',
      'checkbox',
      'radio',
      'combobox',
      'listbox',
      'option',
      'menuitem',
      'menuitemcheckbox',
      'menuitemradio',
      'tab',
      'switch',
      'slider',
      'spinbutton',
      'treeitem'
    ].includes(role)
  ) {
    return true
  }
  return axProperty(node, 'focusable') === true || axProperty(node, 'editable') === true
}

function isAXStructure(role: string): boolean {
  return ['document', 'heading', 'paragraph', 'list', 'listitem', 'table', 'row', 'cell', 'img', 'text'].includes(role)
}

function axProperty(node: AXNodeLike, name: string): unknown {
  return node.properties?.find(property => property.name === name)?.value.value
}

function axDepth(node: AXNodeLike, byID: ReadonlyMap<string, AXNodeLike>): number {
  let depth = 0
  let parentID = node.parentId
  const seen = new Set<string>()
  while (parentID && !seen.has(parentID)) {
    seen.add(parentID)
    const parent = byID.get(parentID)
    if (!parent) break
    depth += 1
    parentID = parent.parentId
  }
  return depth
}

async function selectorForBackendNode(session: CDPSession, backendNodeId: number): Promise<string | undefined> {
  const resolved = await session.send('DOM.resolveNode', { backendNodeId })
  const objectId = resolved.object.objectId
  if (!objectId) return undefined
  try {
    const result = await session.send('Runtime.callFunctionOn', {
      objectId,
      returnByValue: true,
      functionDeclaration: `function () {
        if (!(this instanceof Element)) return null;
        if (this.id && document.querySelectorAll('#' + CSS.escape(this.id)).length === 1)
          return '#' + CSS.escape(this.id);
        for (const attribute of ['data-testid', 'data-test', 'name']) {
          const value = this.getAttribute(attribute);
          if (!value) continue;
          const selector = this.tagName.toLowerCase() + '[' + attribute + '=' + JSON.stringify(value) + ']';
          if (document.querySelectorAll(selector).length === 1) return selector;
        }
        const parts = [];
        let current = this;
        while (current && current !== document.documentElement) {
          const tag = current.tagName.toLowerCase();
          const parent = current.parentElement;
          if (!parent) break;
          const siblings = Array.from(parent.children).filter(child => child.tagName === current.tagName);
          parts.unshift(siblings.length === 1 ? tag : tag + ':nth-of-type(' + (siblings.indexOf(current) + 1) + ')');
          current = parent;
        }
        return 'html > ' + parts.join(' > ');
      }`
    })
    return typeof result.result.value === 'string' ? result.result.value : undefined
  } finally {
    await session.send('Runtime.releaseObject', { objectId }).catch(() => undefined)
  }
}

async function boxForBackendNode(session: CDPSession, backendNodeId: number): Promise<SnapshotNode['box']> {
  const result = await session.send('DOM.getBoxModel', { backendNodeId })
  const quad = result.model.border
  const xs = [quad[0], quad[2], quad[4], quad[6]]
  const ys = [quad[1], quad[3], quad[5], quad[7]]
  const x = Math.min(...xs)
  const y = Math.min(...ys)
  return { x, y, width: Math.max(...xs) - x, height: Math.max(...ys) - y }
}

function stringValue(value: unknown): string {
  if (typeof value === 'string') return value
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  return ''
}

async function collectFrameNodes(frame: Frame, options: SnapshotOptions): Promise<SnapshotNode[]> {
  const root = frame.locator(options.selector ?? 'body').first()
  return await root.evaluate((scope, captureOptions) => {
    const output: SnapshotNode[] = []
    const maxDepth = captureOptions.depth ?? 32
    const elements = [scope, ...Array.from(scope.querySelectorAll('*'))]
    for (const candidate of elements) {
      if (!(candidate instanceof Element)) continue
      const style = getComputedStyle(candidate)
      const rect = candidate.getBoundingClientRect()
      if (style.display === 'none' || style.visibility === 'hidden' || rect.width === 0 || rect.height === 0) continue
      const role = semanticRole(candidate)
      const interactive = isInteractive(candidate, role, style)
      if (captureOptions.interactive && !interactive) continue
      if (!interactive && !isStructural(role)) continue
      const depth = relativeDepth(candidate, scope)
      if (depth > maxDepth) continue
      const input = candidate instanceof HTMLInputElement ? candidate : undefined
      output.push({
        role,
        name: accessibleName(candidate),
        selector: uniqueSelector(candidate),
        interactive,
        disabled: candidate.matches(':disabled') || candidate.getAttribute('aria-disabled')?.toLowerCase() === 'true',
        ...(input?.type === 'checkbox' || input?.type === 'radio'
          ? { checked: input.checked }
          : candidate.getAttribute('aria-checked')
            ? { checked: candidate.getAttribute('aria-checked') === 'true' }
            : {}),
        ...(candidate instanceof HTMLAnchorElement && candidate.href ? { url: candidate.href } : {}),
        depth,
        box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
      })
    }
    return output

    function semanticRole(element: Element): string {
      const explicit = element.getAttribute('role')?.trim()
      if (explicit) return explicit.split(/\s+/)[0]!
      const tag = element.tagName.toLowerCase()
      if (/^h[1-6]$/.test(tag)) return 'heading'
      if (tag === 'a' && element.hasAttribute('href')) return 'link'
      if (tag === 'button') return 'button'
      if (tag === 'textarea') return 'textbox'
      if (tag === 'select') return 'combobox'
      if (tag === 'img') return 'img'
      if (tag === 'table') return 'table'
      if (tag === 'tr') return 'row'
      if (tag === 'td' || tag === 'th') return 'cell'
      if (tag === 'li') return 'listitem'
      if (tag === 'input') {
        const type = (element.getAttribute('type') ?? 'text').toLowerCase()
        if (type === 'checkbox') return 'checkbox'
        if (type === 'radio') return 'radio'
        if (['button', 'submit', 'reset'].includes(type)) return 'button'
        if (type === 'search') return 'searchbox'
        return 'textbox'
      }
      return tag
    }

    function accessibleName(element: Element): string {
      const aria = element.getAttribute('aria-label')?.trim()
      if (aria) return aria
      const labelledBy = element.getAttribute('aria-labelledby')
      if (labelledBy) {
        const label = labelledBy
          .split(/\s+/)
          .map(id => document.getElementById(id)?.textContent?.trim() ?? '')
          .filter(Boolean)
          .join(' ')
        if (label) return label
      }
      if (element instanceof HTMLInputElement) {
        const label = element.labels?.[0]?.textContent?.trim()
        if (label) return label
        if (element.placeholder) return element.placeholder
        if (element.value && ['button', 'submit', 'reset'].includes(element.type)) return element.value
      }
      if (element instanceof HTMLImageElement && element.alt) return element.alt
      const title = element.getAttribute('title')?.trim()
      if (title) return title
      return (element.textContent ?? '').replace(/\s+/g, ' ').trim().slice(0, 240)
    }

    function isInteractive(element: Element, role: string, style: CSSStyleDeclaration): boolean {
      return (
        ['button', 'link', 'textbox', 'checkbox', 'radio', 'combobox', 'option', 'menuitem', 'tab', 'switch'].includes(
          role
        ) ||
        element.hasAttribute('onclick') ||
        element.hasAttribute('contenteditable') ||
        (element.hasAttribute('tabindex') && Number(element.getAttribute('tabindex')) >= 0) ||
        style.cursor === 'pointer'
      )
    }

    function isStructural(role: string): boolean {
      return ['heading', 'table', 'row', 'cell', 'listitem', 'img'].includes(role)
    }

    function relativeDepth(element: Element, rootElement: Element): number {
      let depth = 0
      let current: Element | null = element
      while (current && current !== rootElement) {
        current = current.parentElement
        depth += 1
      }
      return depth
    }

    function uniqueSelector(element: Element): string {
      if (element.id && document.querySelectorAll(`#${CSS.escape(element.id)}`).length === 1) {
        return `#${CSS.escape(element.id)}`
      }
      for (const attribute of ['data-testid', 'data-test', 'name']) {
        const value = element.getAttribute(attribute)
        if (!value) continue
        const selector = `${element.tagName.toLowerCase()}[${attribute}=${JSON.stringify(value)}]`
        if (document.querySelectorAll(selector).length === 1) return selector
      }
      const parts: string[] = []
      let current: Element | null = element
      while (current && current !== document.documentElement) {
        const tag = current.tagName.toLowerCase()
        const parent: Element | null = current.parentElement
        if (!parent) break
        const siblings = Array.from(parent.children).filter(child => child.tagName === current!.tagName)
        parts.unshift(siblings.length === 1 ? tag : `${tag}:nth-of-type(${siblings.indexOf(current) + 1})`)
        current = parent
      }
      return `html > ${parts.join(' > ')}`
    }
  }, options)
}

async function locatorForBackendNode(
  page: Page,
  frame: Frame,
  backendDOMNodeId: number,
  ref: string
): Promise<Locator> {
  const session = await page.context().newCDPSession(page)
  try {
    await session.send('DOM.enable')
    const resolved = await session.send('DOM.resolveNode', { backendNodeId: backendDOMNodeId })
    const objectId = resolved.object.objectId
    if (!objectId) throw new Error('backend node is no longer an element')
    const marker = `ankole-${ref}-${crypto.randomUUID()}`
    try {
      const marked = await session.send('Runtime.callFunctionOn', {
        objectId,
        arguments: [{ value: marker }],
        returnByValue: true,
        functionDeclaration: `function (value) {
          if (!(this instanceof Element)) return false;
          this.setAttribute('data-ankole-browser-ref', value);
          return true;
        }`
      })
      if (marked.result.value !== true) throw new Error('backend node is no longer an element')
    } finally {
      await session.send('Runtime.releaseObject', { objectId }).catch(() => undefined)
    }
    return frame.locator(`[data-ankole-browser-ref="${marker}"]`)
  } catch (error) {
    throw new BrowserDataError('stale_ref', `ref ${ref} no longer points to its snapshot element`, {
      cause: error
    })
  } finally {
    await session.send('DOM.disable').catch(() => undefined)
    await session.detach().catch(() => undefined)
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
