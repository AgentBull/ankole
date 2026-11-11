import { ArrowDownRegular, ArrowSortRegular, ArrowUpRegular } from '../icons'
import { defaultRangeExtractor, useVirtualizer } from '@tanstack/react-virtual'
import {
  Fragment,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type Key,
  type ReactNode
} from 'react'
import { cn } from '../lib/utils'
import { Button } from './button'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from './table'

export type DataGridColumn<Row> = {
  id: string
  header: ReactNode
  renderCell: (row: Row) => ReactNode
  /** Aligns quantities and uses tabular digits. */
  numeric?: boolean
  /** Use a non-interactive header label when the grid supplies the sort button. */
  sortable?: boolean
  width?: CSSProperties['width']
}

export type DataGridSort = { columnId: string; direction: 'asc' | 'desc' }

export type DataGridProps<Row> = {
  label: string
  rows: readonly Row[]
  columns: readonly DataGridColumn<Row>[]
  getRowId: (row: Row) => Key
  maxHeight?: CSSProperties['maxHeight']
  stickyFirstColumn?: boolean
  /** Virtual rows use fixed column widths. Each column defaults to 160px. */
  virtualize?: boolean
  sort?: DataGridSort | null
  onSortChange?: (sort: DataGridSort) => void
  emptyState?: ReactNode
  className?: string
}

/** Renders one page of rows. A cell can mark its opening button or link with `data-row-link`. */
export function DataGrid<Row>({
  label,
  rows,
  columns,
  getRowId,
  maxHeight,
  stickyFirstColumn = false,
  virtualize = false,
  sort,
  onSortChange,
  emptyState,
  className
}: DataGridProps<Row>) {
  const scroll = useRef<HTMLDivElement>(null)
  const header = useRef<HTMLTableSectionElement>(null)
  const [headerHeight, setHeaderHeight] = useState(0)
  const [focusedRow, setFocusedRow] = useState<Key>()
  const rowKey = useCallback((index: number) => getRowId(rows[index]!), [getRowId, rows])
  const focusedIndex = useMemo(
    () => (focusedRow === undefined ? -1 : rows.findIndex(row => getRowId(row) === focusedRow)),
    [focusedRow, getRowId, rows]
  )

  useEffect(() => {
    const element = header.current
    if (!virtualize || !element) return
    const observer = new ResizeObserver(() => setHeaderHeight(element.getBoundingClientRect().height))
    observer.observe(element)
    return () => observer.disconnect()
  }, [virtualize])

  const virtual = useVirtualizer({
    enabled: virtualize,
    count: rows.length,
    getScrollElement: () => scroll.current,
    getItemKey: rowKey,
    estimateSize: () => 32,
    overscan: 8,
    scrollMargin: headerHeight,
    rangeExtractor: useCallback(
      range => {
        const visible = defaultRangeExtractor(range)
        if (focusedIndex < 0) return visible
        // Keep the active control mounted and preserve the adjacent keyboard path after scrolling away.
        const adjacent = [focusedIndex - 1, focusedIndex, focusedIndex + 1].filter(
          index => index >= 0 && index < rows.length
        )
        return [...new Set([...visible, ...adjacent])].sort((left, right) => left - right)
      },
      [focusedIndex, rows.length]
    )
  })
  const virtualRows = virtualize ? virtual.getVirtualItems() : []
  const visibleRows = virtualize
    ? virtualRows.map((row, index) => ({
        index: row.index,
        gap: row.start - (virtualRows[index - 1]?.end ?? headerHeight)
      }))
    : rows.map((_, index) => ({ index, gap: 0 }))
  const lastVirtualRow = virtualRows.at(-1)
  const trailingGap = virtual.getTotalSize() - (lastVirtualRow ? lastVirtualRow.end - headerHeight : 0)

  return (
    <div
      ref={scroll}
      data-slot="data-grid"
      role="region"
      aria-label={label}
      tabIndex={0}
      onBlur={
        virtualize
          ? event => {
              if (!event.currentTarget.contains(event.relatedTarget)) setFocusedRow(undefined)
            }
          : undefined
      }
      className={cn('relative max-h-[60vh] overflow-auto scroll-pt-8 focus-visible:-outline-offset-2', className)}
      style={{ maxHeight }}>
      <Table
        containerClassName="overflow-visible"
        className={cn('border-separate border-spacing-0', virtualize && 'table-fixed')}
        aria-label={label}
        aria-rowcount={virtualize ? rows.length + 1 : undefined}>
        <colgroup>
          {columns.map(column => (
            <col key={column.id} style={{ width: column.width ?? (virtualize ? 160 : undefined) }} />
          ))}
        </colgroup>
        <TableHeader ref={header} className="sticky top-0 z-20 bg-background">
          <TableRow>
            {columns.map((column, index) => {
              const direction = sort?.columnId === column.id ? sort.direction : undefined
              const Icon =
                direction === 'asc' ? ArrowUpRegular : direction === 'desc' ? ArrowDownRegular : ArrowSortRegular
              return (
                <TableHead
                  key={column.id}
                  aria-sort={direction === 'asc' ? 'ascending' : direction === 'desc' ? 'descending' : undefined}
                  className={cn(
                    column.numeric ? 'text-end' : 'text-start',
                    virtualize && 'overflow-hidden text-ellipsis',
                    stickyFirstColumn && index === 0 && 'sticky inset-s-0 z-10 bg-background'
                  )}>
                  {column.sortable && onSortChange ? (
                    <Button
                      type="button"
                      size="xs"
                      variant="ghost"
                      className={cn('-mx-2 max-w-full', column.numeric && 'flex-row-reverse')}
                      onClick={() =>
                        onSortChange({ columnId: column.id, direction: direction === 'asc' ? 'desc' : 'asc' })
                      }>
                      <span className="truncate">{column.header}</span>
                      <Icon aria-hidden className="size-3.5" />
                    </Button>
                  ) : (
                    column.header
                  )}
                </TableHead>
              )
            })}
          </TableRow>
        </TableHeader>
        <TableBody>
          {visibleRows.map(({ index, gap }) => {
            const row = rows[index]!
            const id = getRowId(row)
            return (
              <Fragment key={id}>
                <RowSpacer height={gap} columns={columns.length} />
                <TableRow
                  className="group"
                  ref={virtualize ? virtual.measureElement : undefined}
                  data-index={virtualize ? index : undefined}
                  aria-rowindex={virtualize ? index + 2 : undefined}
                  onFocusCapture={virtualize ? () => setFocusedRow(id) : undefined}>
                  {columns.map((column, index) => (
                    <TableCell
                      key={column.id}
                      className={cn(
                        column.numeric ? 'text-end tabular-nums' : 'text-start',
                        virtualize && 'overflow-hidden text-ellipsis',
                        stickyFirstColumn &&
                          index === 0 &&
                          'sticky inset-s-0 z-10 bg-background fine-hover:group-hover:bg-accent group-has-aria-expanded:bg-accent'
                      )}>
                      {column.renderCell(row)}
                    </TableCell>
                  ))}
                </TableRow>
              </Fragment>
            )
          })}
          {virtualize && <RowSpacer height={trailingGap} columns={columns.length} />}
          {rows.length === 0 && emptyState != null && (
            <TableRow>
              <TableCell colSpan={columns.length} className="py-5 text-center whitespace-normal">
                {emptyState}
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>
    </div>
  )
}

function RowSpacer({ height, columns }: { height: number; columns: number }) {
  if (height <= 0) return null
  return (
    <tr aria-hidden="true">
      <td colSpan={columns} style={{ height, padding: 0, border: 0 }} />
    </tr>
  )
}
