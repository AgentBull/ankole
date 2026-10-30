import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Button } from '@ankole/uikit/components/button'
import { Rect } from '../core/table/tablemap'
import { changeTable, moveTableAxis, resizeTable } from '../editor/tables'
import { editableTable, tableSelection, type TableScope } from '../editor/table-context'
import { moveAxis } from '../editor/table-structure'
import { previewTableWidth } from '../editor/table-presentation'
import { useEditor, useEditorLabel, useEditorState } from './context'
import { useAnchoredOverlay } from './anchored-overlay'
import { TableMenu } from './TableMenu'

type Geometry = {
  left: number
  right: number
  top: number
  bottom: number
  rows: { top: number; bottom: number }[]
  columns: number[]
}

export function TableTools() {
  const editor = useEditor()
  const label = useEditorLabel()
  const state = useEditorState()
  const context = editableTable(state)
  const table = context?.table.before ?? null
  const panel = useRef<HTMLDivElement>(null)
  const cancel = useRef<(() => void) | null>(null)
  const [geometry, setGeometry] = useState<Geometry | null>(null)
  const [drop, setDrop] = useState<{ axis: 'row' | 'column'; index: number } | null>(null)
  const dragging = useRef<'row' | 'column' | null>(null)
  const position = useAnchoredOverlay({
    open: table !== null,
    panelRef: panel,
    anchor: () => {
      const rect = table === null ? null : editor.nodeDOM(table)?.getBoundingClientRect()
      return rect && rect.bottom > 0 && rect.top < innerHeight ? rect : null
    },
    observe: () => (table === null ? null : (editor.nodeDOM(table) as Element | null)),
    align: 'end',
    sideOffset: 24,
    dependencies: [table, state]
  })

  useLayoutEffect(() => {
    if (table === null) {
      setGeometry(null)
      return
    }
    const frame = editor.nodeDOM(table) as HTMLElement | null
    const scroll = frame?.querySelector<HTMLElement>('.table-scroll')
    const dom = scroll?.querySelector('table')
    if (!frame || !scroll || !dom || !context) return
    const measure = () => {
      const bounds = scroll.getBoundingClientRect()
      if (bounds.bottom <= 0 || bounds.top >= innerHeight) {
        setGeometry(null)
        return
      }
      const tableBounds = dom.getBoundingClientRect()
      const columns = [tableBounds.left]
      const cols = dom.querySelectorAll(':scope > colgroup > col')
      const declared = Array.from(cols, col => parseFloat((col as HTMLTableColElement).style.width) || 0)
      const total = declared.reduce((sum, width) => sum + width, 0)
      const scale = total ? tableBounds.width / total : 0
      for (let c = 1; c <= context.width; c++) {
        // WebKit does not expose column boxes; declared widths still describe merged first rows.
        const width = cols?.[c - 1]?.getBoundingClientRect().width || declared[c - 1]! * scale
        if (width) {
          columns.push(columns[c - 1]! + width)
          continue
        }
        const pos = context.map.cellAt(c - 1, 0)
        const cell = pos === null ? null : (editor.nodeDOM(pos) as HTMLElement | null)
        if (!cell || pos === null) {
          columns.push(tableBounds.left + (tableBounds.width * c) / context.width)
          continue
        }
        const box = context.map.cellRect(pos)
        const rect = cell.getBoundingClientRect()
        columns.push(columns[c - 1]! + rect.width / (box.endCol - box.startCol))
      }
      setGeometry({
        left: Math.max(bounds.left, 24),
        right: Math.min(bounds.right, innerWidth - 24),
        top: Math.max(bounds.top, 24),
        bottom: Math.min(bounds.bottom, innerHeight - 24),
        rows: Array.from(dom.rows, row => {
          const rect = row.getBoundingClientRect()
          return { top: rect.top, bottom: rect.bottom }
        }),
        columns
      })
    }
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(frame)
    observer.observe(dom)
    window.addEventListener('scroll', measure, true)
    window.addEventListener('resize', measure)
    return () => {
      observer.disconnect()
      window.removeEventListener('scroll', measure, true)
      window.removeEventListener('resize', measure)
    }
  }, [editor, table, state])
  useEffect(() => () => cancel.current?.(), [])
  if (!context || table === null) return null

  const select = (scope: TableScope, index?: number, extend = false) => {
    const current = editableTable(editor.state)
    if (!current) return
    const { map, rect } = current
    const startRow = extend && index !== undefined ? Math.min(rect.startRow, index) : (index ?? rect.startRow)
    const endRow = index === undefined ? rect.endRow : extend ? Math.max(rect.endRow, index + 1) : index + 1
    const startCol = extend && index !== undefined ? Math.min(rect.startCol, index) : (index ?? rect.startCol)
    const endCol = index === undefined ? rect.endCol : extend ? Math.max(rect.endCol, index + 1) : index + 1
    const area =
      scope === 'row'
        ? new Rect(0, startRow, map.width, endRow)
        : scope === 'column'
          ? new Rect(startCol, 0, endCol, map.height)
          : scope === 'table'
            ? new Rect(0, 0, map.width, map.height)
            : rect
    editor.dispatch({ selection: tableSelection(editor.state.doc, map, area), userEvent: 'select' })
  }
  const resize = (index: number, event: React.PointerEvent) => {
    if (event.button || !geometry) return
    event.preventDefault()
    cancel.current?.()
    const before = editor.state.doc
    const widths = geometry.columns.slice(1).map((right, i) => Math.round(right - geometry.columns[i]!))
    const original = widths[index]!
    const startX = event.clientX
    const owner = editor.contentDOM.ownerDocument
    const restore = () => {
      editor.dispatch({ effects: previewTableWidth.of(null) })
      owner.removeEventListener('pointermove', move)
      owner.removeEventListener('pointerup', up)
      owner.removeEventListener('pointercancel', restore)
      owner.removeEventListener('keydown', key, true)
      owner.defaultView!.removeEventListener('blur', restore)
      cancel.current = null
    }
    const move = (next: PointerEvent) => {
      if (editor.state.doc !== before) return restore()
      widths[index] = Math.min(9999, Math.max(25, Math.round(original + next.clientX - startX)))
      editor.dispatch({ effects: previewTableWidth.of({ pos: table, widths: [...widths] }) })
    }
    const up = () => {
      restore()
      if (editor.state.doc === before) resizeTable(editor, table, widths)
      editor.focus()
    }
    const key = (next: KeyboardEvent) => {
      if (next.key === 'Escape') {
        next.preventDefault()
        next.stopPropagation()
        restore()
      }
    }
    owner.addEventListener('pointermove', move)
    owner.addEventListener('pointerup', up)
    owner.addEventListener('pointercancel', restore)
    owner.addEventListener('keydown', key, true)
    owner.defaultView!.addEventListener('blur', restore)
    cancel.current = restore
  }
  const drag = (axis: 'row' | 'column', index: number) => ({
    draggable: true,
    onDragStart: (event: React.DragEvent) => {
      event.stopPropagation()
      select(axis, index)
      dragging.current = axis
      event.dataTransfer.effectAllowed = 'move'
      event.dataTransfer.setData('text/plain', axis)
    },
    onDragOver: (event: React.DragEvent) => {
      const current = editableTable(editor.state)
      if (dragging.current === axis && current && moveAxis(current, axis, index)) {
        event.preventDefault()
        event.dataTransfer.dropEffect = 'move'
        setDrop({ axis, index })
      } else {
        event.dataTransfer.dropEffect = 'none'
        setDrop(null)
      }
    },
    onDrop: (event: React.DragEvent) => {
      event.preventDefault()
      event.stopPropagation()
      if (dragging.current === axis) moveTableAxis(editor, axis, index)
      dragging.current = null
      setDrop(null)
    },
    onDragEnd: () => {
      dragging.current = null
      setDrop(null)
    }
  })
  return createPortal(
    <div className="ankole-editor-overlay table-tools">
      <div ref={panel} className="table-selection-tools" style={position ?? { visibility: 'hidden' }}>
        {(['cell', 'row', 'column', 'table'] as const).map(scope => (
          <TableMenu
            key={scope}
            scope={scope}
            trigger={
              <Button size="xs" variant="outline">
                {label(scope === 'table' ? 'table_menu' : `table_${scope}`)}
              </Button>
            }
          />
        ))}
      </div>
      {geometry && (
        <>
          {geometry.rows.map(
            (row, index) =>
              row.bottom > geometry.top &&
              row.top < geometry.bottom && (
                <TableMenu
                  key={`r${index}`}
                  scope="row"
                  select={extend => select('row', index, extend)}
                  trigger={
                    <button
                      className="table-handle table-row-handle"
                      aria-label={`${label('table_row')} ${index + 1}`}
                      style={{
                        left: geometry.left - 23,
                        top: Math.max(row.top, geometry.top),
                        height: Math.min(row.bottom, geometry.bottom) - Math.max(row.top, geometry.top)
                      }}
                      {...drag('row', index)}>
                      ⋮
                    </button>
                  }
                />
              )
          )}
          {geometry.columns.slice(0, -1).map((left, index) => {
            const right = geometry.columns[index + 1]!
            if (right <= geometry.left || left >= geometry.right) return null
            return (
              <TableMenu
                key={`c${index}`}
                scope="column"
                select={extend => select('column', index, extend)}
                trigger={
                  <button
                    className="table-handle table-column-handle"
                    aria-label={`${label('table_column')} ${index + 1}`}
                    style={{
                      left: Math.max(left, geometry.left),
                      top: geometry.top - 23,
                      width: Math.min(right, geometry.right) - Math.max(left, geometry.left)
                    }}
                    {...drag('column', index)}>
                    ⋯
                  </button>
                }
              />
            )
          })}
          {geometry.columns.slice(1).map(
            (right, index) =>
              right > geometry.left &&
              right <= geometry.right + 1 && (
                <button
                  key={index}
                  className="table-resizer"
                  role="separator"
                  aria-label={`${label('table_resize')} ${index + 1}`}
                  aria-orientation="vertical"
                  aria-valuemin={25}
                  aria-valuemax={9999}
                  aria-valuenow={Math.round(right - geometry.columns[index]!)}
                  style={{ left: right - 4, top: geometry.top, height: geometry.bottom - geometry.top }}
                  onPointerDown={event => resize(index, event)}
                  onKeyDown={event => {
                    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return
                    event.preventDefault()
                    const widths = geometry.columns.slice(1).map((right, i) => right - geometry.columns[i]!)
                    widths[index] = widths[index]! + (event.key === 'ArrowLeft' ? -10 : 10)
                    resizeTable(editor, table, widths)
                  }}
                />
              )
          )}
          <button
            className="table-add table-add-row"
            aria-label={label('table_add_row')}
            style={{ left: geometry.left, top: geometry.bottom, width: geometry.right - geometry.left }}
            onMouseDown={event => event.preventDefault()}
            onClick={() => {
              select('row', context.map.height - 1)
              changeTable(editor, 'row_after')
            }}
            {...drag('row', context.map.height)}>
            +
          </button>
          <button
            className="table-add table-add-column"
            aria-label={label('table_add_column')}
            style={{ left: geometry.right, top: geometry.top, height: geometry.bottom - geometry.top }}
            onMouseDown={event => event.preventDefault()}
            onClick={() => {
              select('column', context.width - 1)
              changeTable(editor, 'column_after')
            }}
            {...drag('column', context.width)}>
            +
          </button>
          {drop && (
            <div
              className={`table-drop-line table-drop-${drop.axis}`}
              style={
                drop.axis === 'row'
                  ? {
                      left: geometry.left,
                      top: geometry.rows[drop.index]?.top ?? geometry.bottom,
                      width: geometry.right - geometry.left
                    }
                  : { left: geometry.columns[drop.index], top: geometry.top, height: geometry.bottom - geometry.top }
              }
            />
          )}
        </>
      )}
    </div>,
    document.body
  )
}
