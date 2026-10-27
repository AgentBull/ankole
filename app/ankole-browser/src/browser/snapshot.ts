import type { Frame, Locator, Page } from 'playwright-core'
import type { BrowserCommandArgs } from '../protocol'
import { BrowserDataError } from '../errors'

// This module uses the Playwright AI snapshot.
// `page.getByRef` resolves a ref from the latest snapshot.
const SnapshotBudget = 16 * 1024
const ExplicitRef = /^(?:@|ref=)((?:f\d+)?e\d+)$/
const RefInText = /\[ref=((?:f\d+)?e\d+)\]/g

type SnapshotOptions = BrowserCommandArgs<'snapshot'>

type SnapshotNode = {
  role: string
  name?: string
  text?: string
  ref?: string
  cursor?: string
  url?: string
  disabled?: boolean
  checked?: boolean | 'mixed'
  expanded?: boolean
  pressed?: boolean | 'mixed'
  selected?: boolean
  children?: (SnapshotNode | string)[]
}

const InteractiveRoles = new Set([
  'button',
  'checkbox',
  'combobox',
  'link',
  'listbox',
  'menuitem',
  'menuitemcheckbox',
  'menuitemradio',
  'option',
  'radio',
  'scrollbar',
  'searchbox',
  'slider',
  'spinbutton',
  'switch',
  'tab',
  'textbox',
  'treeitem'
])

export class SnapshotStore {
  private readonly refs = new Set<string>()

  clear(): void {
    this.refs.clear()
  }

  entries(): string[] {
    return [...this.refs]
  }

  async capture(
    page: Page,
    options: SnapshotOptions = {},
    frame: Frame = page.mainFrame(),
    deadline = Date.now() + 30_000
  ): Promise<string> {
    const locator = options.selector ? frame.locator(options.selector).first() : undefined
    const root = locator ?? page
    let snapshot: string
    try {
      // Snapshot calls can reject a missing selector before their timeout.
      if (locator) {
        await locator.waitFor({ state: 'attached', timeout: Math.max(1, deadline - Date.now()) })
      }
      const captureOptions = {
        mode: 'ai' as const,
        timeout: Math.max(1, deadline - Date.now()),
        ...(options.depth === undefined ? {} : { depth: options.depth })
      }
      if (options.interactive) {
        const nodes: SnapshotNode[] = await root.ariaSnapshotJSON(captureOptions)
        snapshot = interactiveSnapshot(nodes)
      } else {
        snapshot = await root.ariaSnapshot(captureOptions)
      }
    } catch (error) {
      throw asSnapshotError(error)
    }
    const text = presentSnapshot(snapshot, options)
    this.refs.clear()
    for (const match of text.matchAll(RefInText)) this.refs.add(match[1]!)
    return text
  }

  async resolve(page: Page, input: string, rawFrame: Frame = page.mainFrame()): Promise<Locator> {
    const explicit = ExplicitRef.exec(input)
    const ref = explicit?.[1] ?? (this.refs.has(input) ? input : undefined)
    if (!ref) return rawFrame.locator(input)
    if (!this.refs.has(ref)) {
      throw new BrowserDataError('stale_ref', `ref ${ref} is not present in the latest snapshot`)
    }
    return await locatorForRef(page, ref)
  }
}

function interactiveSnapshot(nodes: (SnapshotNode | string)[], depth = 0): string {
  const lines: string[] = []
  for (const node of nodes) {
    if (typeof node === 'string') continue
    if (node.ref && (InteractiveRoles.has(node.role) || node.cursor === 'pointer')) {
      const name = node.name ?? node.text
      let line = `${'  '.repeat(depth)}- ${node.role}${name ? ` ${JSON.stringify(name)}` : ''} [ref=${node.ref}]`
      for (const state of ['disabled', 'checked', 'expanded', 'pressed', 'selected'] as const) {
        if (node[state] !== undefined) line += ` [${state}=${node[state]}]`
      }
      if (node.name && node.text && node.text !== node.name) line += `: ${JSON.stringify(node.text)}`
      lines.push(line)
      if (node.url) lines.push(`${'  '.repeat(depth + 1)}- /url: ${node.url}`)
    }
    if (node.children) lines.push(interactiveSnapshot(node.children, depth + 1))
  }
  return lines.filter(Boolean).join('\n')
}

function presentSnapshot(snapshot: string, options: SnapshotOptions): string {
  const lines = snapshot.split('\n').flatMap(line => {
    if (!options.urls && line.trimStart().startsWith('- /url:')) return []
    return [options.compact ? line.trimStart() : line]
  })
  const text = lines.join('\n').trim()
  if (text.length === 0) return '(empty page)'
  if (text.length <= SnapshotBudget) return text
  return `${text.slice(0, SnapshotBudget)}\n… [snapshot truncated]`
}

async function locatorForRef(page: Page, ref: string): Promise<Locator> {
  const locator = page.getByRef(ref)
  let count = 0
  try {
    count = await locator.count()
  } catch (error) {
    throw new BrowserDataError('stale_ref', `ref ${ref} no longer points to its snapshot element`, { cause: error })
  }
  if (count !== 1) {
    throw new BrowserDataError('stale_ref', `ref ${ref} no longer points to its snapshot element`)
  }
  return locator
}

function asSnapshotError(error: unknown): BrowserDataError {
  if (error instanceof BrowserDataError) return error
  if (error instanceof Error && error.name === 'TimeoutError') {
    return new BrowserDataError('timeout', error.message, { retryable: true, cause: error })
  }
  const message = error instanceof Error ? error.message : String(error)
  return new BrowserDataError('invalid_result', message, { cause: error })
}
