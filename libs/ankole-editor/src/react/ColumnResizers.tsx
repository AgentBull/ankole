import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { history } from '../core/history'
import { Decoration } from '../core/editor'
import { GardState, Transaction } from '../core/state'
import { Columns, ColumnWidth } from '../editor/schema'
import { markValue } from '../editor/attributes'
import { columnResize } from '../editor/columns'
import { redo, undo } from '../editor/commands'
import { useEditor, useEditorLabel, useEditorState } from './context'

type Divider = { left: number; right: number; x: number; y: number; height: number; value: number }

const preview = Transaction.Effect.define<{ left: number; right: number; a: number; b: number } | null>()
export const columnResizing = GardState.Field.define<null | { left: number; right: number; a: number; b: number }>({
  create: () => null,
  update(value, tr) {
    if (tr.docChanged) return null
    for (const effect of tr.effects) if (effect.is(preview)) value = effect.value
    return value
  },
  provide: field =>
    Decoration.Point.source.of(state => {
      const value = state.field(field)
      return value
        ? Decoration.Point.set([
            [Decoration.Point.attributes({ style: `--column-weight: ${value.a}` }), value.left],
            [Decoration.Point.attributes({ style: `--column-weight: ${value.b}` }), value.right]
          ])
        : Decoration.Point.none
    })
})

/** Column widths preview while dragging and commit through one undoable document transaction. */
export function ColumnResizers({ anchor }: { anchor: HTMLElement }) {
  const editor = useEditor()
  const label = useEditorLabel()
  const doc = useEditorState(state => state.doc)
  const resizing = useEditorState(state => state.field(columnResizing))
  const [dividers, setDividers] = useState<Divider[]>([])
  const cancel = useRef<(() => void) | null>(null)
  useLayoutEffect(() => {
    const measure = () => {
      const origin = anchor.getBoundingClientRect()
      const next: Divider[] = []
      doc.iterate((node, pos) => {
        if (node.type !== Columns.type || !node.isPlot) return
        let left = pos + 1
        for (let i = 0; i < node.content.length - 1; i++) {
          const a = node.content[i]!
          const b = node.content[i + 1]!
          const right = left + a.length
          const aDOM = editor.nodeDOM(left)
          const bDOM = editor.nodeDOM(right)
          if (aDOM instanceof HTMLElement && bDOM instanceof HTMLElement) {
            const ar = aDOM.getBoundingClientRect()
            const br = bDOM.getBoundingClientRect()
            const aw = resizing?.left === left ? resizing.a : (markValue(a, ColumnWidth) ?? 1000)
            const bw = resizing?.right === right ? resizing.b : (markValue(b, ColumnWidth) ?? 1000)
            next.push({
              left,
              right,
              x: (ar.right + br.left) / 2 - origin.left - 6,
              y: ar.top - origin.top,
              height: Math.max(ar.height, br.height),
              value: Math.round((100 * aw) / (aw + bw))
            })
          }
          left = right
        }
      })
      setDividers(next)
    }
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(anchor)
    return () => observer.disconnect()
  }, [anchor, editor, doc, resizing])
  useEffect(() => () => cancel.current?.(), [])

  const commit = (divider: Divider, weight: number) => {
    const spec = columnResize(editor.state, divider.left, divider.right, weight)
    if (spec) editor.dispatch({ ...spec, annotations: history.isolate.of(true) })
  }
  return dividers.map(divider => (
    <button
      key={divider.left}
      className="column-resizer"
      data-resizing={resizing?.left === divider.left || undefined}
      role="separator"
      aria-label={label('resize_columns')}
      aria-orientation="vertical"
      aria-valuenow={divider.value}
      aria-valuemin={1}
      aria-valuemax={99}
      style={{ left: divider.x, top: divider.y, height: divider.height }}
      onKeyDown={event => {
        if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === 'z') {
          event.preventDefault()
          ;(event.shiftKey ? redo : undo)(editor)
          return
        }
        if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return
        event.preventDefault()
        const a = editor.state.doc.resolveNode(divider.left)!.node
        const b = editor.state.doc.resolveNode(divider.right)!.node
        const aw = markValue(a, ColumnWidth) ?? 1000
        const bw = markValue(b, ColumnWidth) ?? 1000
        commit(divider, aw + ((event.key === 'ArrowLeft' ? -1 : 1) * (aw + bw)) / 100)
      }}
      onPointerDown={event => {
        if (event.button) return
        event.preventDefault()
        cancel.current?.()
        const before = editor.state.doc
        const a = editor.nodeDOM(divider.left) as HTMLElement
        const b = editor.nodeDOM(divider.right) as HTMLElement
        const ar = a.getBoundingClientRect()
        const br = b.getBoundingClientRect()
        const aw = markValue(before.resolveNode(divider.left)!.node, ColumnWidth) ?? 1000
        const bw = markValue(before.resolveNode(divider.right)!.node, ColumnWidth) ?? 1000
        const document = anchor.ownerDocument
        const total = aw + bw
        let weight = aw
        const restore = () => {
          editor.dispatch({ effects: preview.of(null) })
          document.removeEventListener('pointermove', move)
          document.removeEventListener('pointerup', up)
          document.removeEventListener('pointercancel', restore)
          document.removeEventListener('keydown', key, true)
          document.defaultView!.removeEventListener('blur', restore)
          cancel.current = null
        }
        const move = (next: PointerEvent) => {
          if (editor.state.doc !== before) return restore()
          const min = Math.min(48, (ar.width + br.width) / 3)
          const width = Math.min(ar.width + br.width - min, Math.max(min, ar.width + next.clientX - event.clientX))
          weight = Math.max(
            1,
            total - 9999,
            Math.min(9999, total - 1, Math.round((total * width) / (ar.width + br.width)))
          )
          editor.dispatch({
            effects: preview.of({ left: divider.left, right: divider.right, a: weight, b: total - weight })
          })
        }
        const up = () => {
          restore()
          if (weight !== aw && editor.state.doc === before) commit(divider, weight)
          editor.focus()
        }
        const key = (next: KeyboardEvent) => {
          if (next.key !== 'Escape') return
          next.preventDefault()
          next.stopPropagation()
          restore()
        }
        document.addEventListener('pointermove', move)
        document.addEventListener('pointerup', up)
        document.addEventListener('pointercancel', restore)
        document.addEventListener('keydown', key, true)
        document.defaultView!.addEventListener('blur', restore)
        cancel.current = restore
      }}
    />
  ))
}
