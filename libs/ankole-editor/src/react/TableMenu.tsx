import { useState, type ReactElement } from 'react'
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuCheckboxItem,
  DropdownMenuSeparator,
  DropdownMenuLabel,
  DropdownMenuSub,
  DropdownMenuSubTrigger,
  DropdownMenuSubContent
} from '@ankole/uikit/components/dropdown-menu'
import { Align, CellBackground, HeaderCell, TableLayout } from '../editor/schema'
import { changeTable, colorTableCells, tableCSV, type TableAction } from '../editor/tables'
import { cellsIn, editableTable, scopeRect, type TableContext, type TableScope } from '../editor/table-context'
import { mergeCells, moveAxis, sortRows, splitCells } from '../editor/table-structure'
import { useEditor, useEditorLabel, useEditorState } from './context'

const colors = {
  gray: '#f1f1ef',
  brown: '#f8e7dc',
  yellow: '#fff3cc',
  green: '#dcf3e4',
  blue: '#deedfc',
  purple: '#eee3fb',
  pink: '#fbe2e8'
} as const

/** The same commands serve a row handle, a column handle and the selection toolbar. */
export function TableMenu({
  scope,
  trigger,
  select
}: {
  scope: TableScope
  trigger: ReactElement
  select?: (extend?: boolean) => void
}) {
  const editor = useEditor()
  const context = editableTable(useEditorState())
  const [open, setOpen] = useState(false)
  if (!context) return null
  return (
    <DropdownMenu
      modal={false}
      open={open}
      onOpenChange={(next, details) => {
        if (next) select?.()
        setOpen(next)
        if (!next && details.reason !== 'outside-press' && details.reason !== 'focus-out') editor.focus()
      }}>
      <DropdownMenuTrigger
        render={trigger}
        onMouseDown={event => {
          if (select) event.preventBaseUIHandler()
          else event.preventDefault()
        }}
        onClick={event => {
          if (!select) return
          event.preventBaseUIHandler()
          select(event.shiftKey)
          setOpen(!open)
        }}
      />
      <DropdownMenuContent className="ankole-editor-overlay" finalFocus={() => false}>
        {/* Base UI mounts the content only while the menu is open, so a closed menu checks no command. */}
        <TableMenuItems scope={scope} context={context} close={() => setOpen(false)} />
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

function TableMenuItems({ scope, context, close }: { scope: TableScope; context: TableContext; close: () => void }) {
  const editor = useEditor()
  const label = useEditorLabel()
  const state = useEditorState()
  const cells = cellsIn(context.map, scopeRect(context, scope))
  const nodes = cells.map(pos => context.map.getCell(pos))
  const run = (action: TableAction) => {
    const frame = editor.nodeDOM(context.table.before)
    const width = frame instanceof HTMLElement ? frame.querySelector('table')?.getBoundingClientRect().width : undefined
    changeTable(editor, action, scope, width)
    close()
  }
  const row = scope === 'row'
  const column = scope === 'column'
  const table = scope === 'table'
  const item = (action: TableAction, disabled = false, hint?: string) => (
    <DropdownMenuItem
      key={action}
      disabled={disabled}
      title={hint}
      variant={action.startsWith('delete') ? 'destructive' : 'default'}
      onClick={() => run(action)}>
      {label(`table_${action}`)}
    </DropdownMenuItem>
  )
  return (
    <>
      <DropdownMenuLabel>
        {label(table ? 'table_all' : row ? 'table_row' : column ? 'table_column' : 'table_cell')}
        {!table &&
          ` · ${row ? context.rect.endRow - context.rect.startRow : column ? context.rect.endCol - context.rect.startCol : cells.length}`}
      </DropdownMenuLabel>
      {table ? (
        <>
          {context.table.parent?.node === state.doc && (
            <DropdownMenuCheckboxItem
              checked={!!context.table.node.mark(TableLayout)}
              onClick={() => run('full_width')}>
              {label('table_full_width')}
            </DropdownMenuCheckboxItem>
          )}
          {item('distribute')}
          <DropdownMenuItem
            onClick={() => {
              const current = editableTable(editor.state)
              if (!current) return
              const url = URL.createObjectURL(
                new Blob(['\uFEFF', tableCSV(current)], { type: 'text/csv;charset=utf-8' })
              )
              const link = document.createElement('a')
              link.href = url
              link.download = `${document.title || 'table'}.csv`
              link.click()
              setTimeout(() => URL.revokeObjectURL(url), 1000)
            }}>
            {label('table_export')}
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          {item('delete_table')}
        </>
      ) : (
        <>
          {(['left', 'center', 'right'] as const).map(align => (
            <DropdownMenuCheckboxItem
              key={align}
              checked={nodes.every(node => (node.mark(Align) ?? 'left') === align)}
              onClick={() => run(`align_${align}`)}>
              {label(`table_align_${align}`)}
            </DropdownMenuCheckboxItem>
          ))}
          <DropdownMenuSub>
            <DropdownMenuSubTrigger>{label('table_background')}</DropdownMenuSubTrigger>
            <DropdownMenuSubContent className="ankole-editor-overlay" finalFocus={() => false}>
              <DropdownMenuCheckboxItem
                checked={nodes.every(node => !node.mark(CellBackground))}
                onClick={() => {
                  colorTableCells(editor, null, scope)
                  close()
                }}>
                {label('table_background_none')}
              </DropdownMenuCheckboxItem>
              {Object.entries(colors).map(([name, color]) => (
                <DropdownMenuCheckboxItem
                  key={color}
                  checked={nodes.every(node => node.mark(CellBackground) === color)}
                  onClick={() => {
                    colorTableCells(editor, color, scope)
                    close()
                  }}>
                  <span className="table-color-swatch" style={{ backgroundColor: color }} />
                  {label(`table_color_${name as keyof typeof colors}`)}
                </DropdownMenuCheckboxItem>
              ))}
              <label className="table-custom-color">
                {label('table_background_custom')}
                <input
                  type="color"
                  aria-label={label('table_background_custom')}
                  value={nodes[0]?.mark(CellBackground) ?? '#ffffff'}
                  onChange={event => {
                    colorTableCells(editor, event.target.value, scope)
                    close()
                  }}
                />
              </label>
            </DropdownMenuSubContent>
          </DropdownMenuSub>
          <DropdownMenuSeparator />
          {item('merge', !mergeCells(context), label('table_merge_hint'))}
          {item('split', !splitCells(context))}
          {(row || column) && (
            <>
              <DropdownMenuSeparator />
              <DropdownMenuCheckboxItem
                checked={nodes.every(node => node.type === HeaderCell.type)}
                onClick={() => run(row ? 'header' : 'header_column')}>
                {label(row ? 'table_header' : 'table_header_column')}
              </DropdownMenuCheckboxItem>
              {(row ? context.rect.endRow - context.rect.startRow : context.rect.endCol - context.rect.startCol) ===
                1 && (
                <>
                  {item(row ? 'row_before' : 'column_before')}
                  {item(row ? 'row_after' : 'column_after')}
                </>
              )}
              {item(
                row ? 'row_up' : 'column_left',
                !moveAxis(context, row ? 'row' : 'column', row ? context.rect.startRow - 1 : context.rect.startCol - 1),
                label('table_span_hint')
              )}
              {item(
                row ? 'row_down' : 'column_right',
                !moveAxis(context, row ? 'row' : 'column', row ? context.rect.endRow + 1 : context.rect.endCol + 1),
                label('table_span_hint')
              )}
              {column && (
                <>
                  {item('distribute')}
                  <DropdownMenuSub>
                    <DropdownMenuSubTrigger>{label('table_sort')}</DropdownMenuSubTrigger>
                    <DropdownMenuSubContent className="ankole-editor-overlay" finalFocus={() => false}>
                      {item('sort_ascending', !sortRows(context, false), label('table_sort_hint'))}
                      {item('sort_descending', !sortRows(context, true), label('table_sort_hint'))}
                    </DropdownMenuSubContent>
                  </DropdownMenuSub>
                </>
              )}
              <DropdownMenuSeparator />
              {item(row ? 'delete_row' : 'delete_column')}
            </>
          )}
        </>
      )}
    </>
  )
}
