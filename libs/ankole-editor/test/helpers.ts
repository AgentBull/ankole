/*
 * Headless editors for unit tests.
 *
 * `open` builds the editor document with the same assembly as the visible editor and puts it in a
 * labeled fake of the view: it keeps the state and applies a dispatch as `Wordgard.dispatch` does,
 * with the transaction appenders (for example input rules) and then the transaction listeners (for
 * example page sessions). Commands, key bindings and page sessions run on it unchanged.
 *
 * The fake has no DOM. It does not draw, runs no update listeners and composes only when a test
 * says so. Behavior that needs a DOM, such as composition, clipboard events, selection drawing or
 * vertical caret motion, belongs in the e2e tests.
 */
import { expect } from 'bun:test'
import { Command } from '../src/core/command/command'
import { insertText } from '../src/core/command/commands'
import type { Node } from '../src/core/doc'
import { KeyBinding, Wordgard } from '../src/core/editor'
import { Transaction, type GardState } from '../src/core/state'
import { parseMarkdown, printMarkdown } from '../src/document/markdown'
import type { Element } from '../src/document/tree'
import { parseXml, printXml } from '../src/document/xml'
import { readTree as treeOf } from '../src/editor/convert'
import { editorExtension, headlessState, initialState } from '../src/editor/extension'
import { hostExtension } from '../src/editor/host'
import { type EditorHost } from '../src/editor/host-context'

class HeadlessEditor {
  composing = false
  constructor(public state: GardState) {}
  dispatch = (spec: Transaction | Transaction.Spec) => {
    if (spec instanceof Transaction && spec.startState !== this.state) {
      throw new Error('Dispatching a transaction starting from the wrong state')
    }
    const transactions = Transaction.append(spec instanceof Transaction ? spec : this.state.update(spec))
    for (const guard of this.state.facet(Wordgard.transactionGuard)) guard(transactions, this as unknown as Wordgard)
    this.state = transactions.at(-1)!.state
    for (const listener of this.state.facet(Wordgard.transactionListener)) {
      listener(transactions, this as unknown as Wordgard)
    }
  }
  focus() {}
}

/** A headless editor with a page from Markdown source or a page tree. */
export function open(source: string | Element = ''): Wordgard {
  return new HeadlessEditor(headlessState(source)) as unknown as Wordgard
}

/** A headless editor that also installs the extensions of `host`. */
export function openWithHost(source: string | Element, host: EditorHost): Wordgard {
  return new HeadlessEditor(initialState(source, [editorExtension(), hostExtension(host)])) as unknown as Wordgard
}

/** Mark a headless editor as composing with an input method, or not. */
export function setComposing(editor: Wordgard, composing: boolean) {
  ;(editor as unknown as HeadlessEditor).composing = composing
}

export const readTree = (editor: Wordgard) => treeOf(editor.state.doc)
export const exportMarkdown = (editor: Wordgard) => printMarkdown(readTree(editor))

/** An editor node as plain data: type name, parameter, marks by name, and content. */
export type Shape = { type: string; param?: unknown; marks?: Record<string, unknown>; content?: Shape[] }

export function shape(node: Node): Shape {
  const param = node.isPlot ? node.tag.param : node.param
  return {
    type: node.name,
    ...(param === null ? {} : { param }),
    ...(node.marks.length ? { marks: Object.fromEntries(node.marks.map(mark => [mark.name, mark.value])) } : {}),
    ...(node.isPlot ? { content: node.content.map(shape) } : {})
  }
}

/** Export the page as Markdown and as XML and open each in a new editor. Both must show the same page. */
export function expectReopens(editor: Wordgard) {
  const tree = readTree(editor)
  expect(readTree(open(parseMarkdown(printMarkdown(tree))))).toEqual(tree)
  expect(readTree(open(parseXml(printXml(tree))))).toEqual(tree)
}

/** Select from `anchor` to `head`. Without positions, put the caret at the end of the last text block. */
export function select(editor: Wordgard, anchor?: number, head = anchor) {
  if (anchor === undefined) {
    editor.state.doc.iterate((node, pos) => {
      if (node.isPlot && node.isTextblock) anchor = head = pos + node.length - 1
    })
  }
  if (anchor === undefined) throw new Error('The page has no text block')
  editor.dispatch({ selection: { anchor, head } })
}

/** Type text at the selection, one character at a time, as the editor handles `insertText` input events. */
export function typeText(editor: Wordgard, text: string) {
  for (const character of text) {
    const { from, to } = editor.state.selection
    Command.dispatch(editor, insertText, { from, to, insert: character, userEvent: 'input.type' })
  }
}

/**
 * Press a key through the editor's key bindings, as the editor handles a `keydown` event. Write keys
 * as key bindings do, for example `Tab`, `Shift-Tab` or `Enter`. Returns whether a binding handled it.
 */
export function press(editor: Wordgard, key: string): boolean {
  const parts = key.split(/-(?!$)/)
  const has = (modifier: string) => parts.slice(0, -1).includes(modifier)
  const event = {
    key: parts.at(-1)!,
    keyCode: 0,
    shiftKey: has('Shift'),
    ctrlKey: has('Ctrl'),
    metaKey: has('Meta'),
    altKey: has('Alt'),
    getModifierState: () => false,
    preventDefault() {}
  }
  return KeyBinding.handle(editor, event as unknown as KeyboardEvent)
}
