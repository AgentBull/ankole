import type { Node } from '../core/doc'
import type { Wordgard } from '../core/editor'
import { Widget } from '../core/editor/decoration'

export type ConnectedWidgetSpec<Param, DOM extends HTMLElement = HTMLElement> = Omit<
  Widget.Spec<Param>,
  'render' | 'connect' | 'disconnect'
> & {
  render: (value: Param, editor: Wordgard) => DOM
  connect: (value: Param, dom: DOM, editor: Wordgard) => (() => void) | void
}

const editors = new WeakMap<Element, Wordgard>()
const cleanups = new WeakMap<Element, () => void>()

/**
 * Define an interactive widget whose `connect` hook receives the owning `Wordgard` and returns a
 * cleanup function invoked on `disconnect`, including when a reused DOM element reconnects with a
 * new widget value.
 */
export function connectedWidget<Param, DOM extends HTMLElement = HTMLElement>(
  spec: ConnectedWidgetSpec<Param, DOM>
): Widget.Type<Param> {
  const { render, connect, ...rest } = spec
  return Widget.define<Param>({
    ...rest,
    render: (value, editor) => {
      const dom = render(value, editor)
      editors.set(dom, editor)
      return dom
    },
    connect: (value, dom) => {
      const element = dom as DOM
      const editor = editors.get(element)
      if (!editor) return
      const cleanup = connect(value, element, editor)
      if (cleanup) cleanups.set(element, cleanup)
    },
    disconnect: (_value, dom) => {
      const element = dom as Element
      cleanups.get(element)?.()
      cleanups.delete(element)
    }
  })
}

/**
 * Resolve the document node and position that currently own a mounted widget DOM element. Using the
 * live tile tree avoids colliding when multiple blocks share the same default `Plot.Tag`.
 */
export function widgetBlock(editor: Wordgard, dom: Element): { pos: number; node: Node } | null {
  if (!editor.connected) return null
  editor.flush()
  return editor.nodeFromDOM(dom)
}
