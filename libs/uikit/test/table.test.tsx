import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { DataGrid } from '../src/components/data-grid'
import { Table, TableBody, TableCell, TableRow } from '../src/components/table'

describe('Table', () => {
  test('labels a keyboard-scrollable table region when requested', () => {
    const html = renderToStaticMarkup(
      <Table containerLabel="Agents data table">
        <TableBody>
          <TableRow>
            <TableCell>research-analyst</TableCell>
          </TableRow>
        </TableBody>
      </Table>
    )

    expect(html).toContain('aria-label="Agents data table"')
    expect(html).toContain('role="region"')
    expect(html).toContain('tabindex="0"')
  })

  test('does not add an unnamed landmark to ordinary tables', () => {
    const html = renderToStaticMarkup(<Table />)

    expect(html).not.toContain('role="region"')
    expect(html).not.toContain('tabindex="0"')
  })
})

test('DataGrid gives a caller-supplied empty state the full table width', () => {
  const html = renderToStaticMarkup(
    <DataGrid<{ name: string; value: number }>
      label="Positions"
      rows={[]}
      getRowId={row => row.name}
      columns={[
        { id: 'name', header: 'Symbol', renderCell: row => row.name },
        { id: 'value', header: 'Value', renderCell: row => row.value, numeric: true }
      ]}
      emptyState={<p>No positions for this date.</p>}
    />
  )

  expect(html).toContain('colSpan="2"')
  expect(html).toContain('<p>No positions for this date.</p>')
})
