import { describe, expect, test } from 'bun:test'
import { readBaseLocation, writeBaseLocation } from './base-page'
import { buildSearchResultHref } from './search-targets'

describe('Base page URL state', () => {
  test('the table, view and open record round-trip through the URL beside other parameters', () => {
    const search = writeBaseLocation(new URLSearchParams('chat=latest'), {
      table: 'tbl-2',
      view: 'view-b',
      record: 'rec-9'
    })
    expect(Object.fromEntries(search)).toEqual({ chat: 'latest', at: 'table:tbl-2', view: 'view-b', record: 'rec-9' })
    expect(readBaseLocation(search)).toEqual({ table: 'tbl-2', view: 'view-b', record: 'rec-9' })
  })

  test('choosing another table drops the view and record of the previous one', () => {
    const search = writeBaseLocation(new URLSearchParams('at=table:tbl-2&view=view-b&record=rec-9'), { table: 'tbl-1' })
    expect(Object.fromEntries(search)).toEqual({ at: 'table:tbl-1' })
    expect(readBaseLocation(new URLSearchParams())).toEqual({})
  })

  test('a Base search result opens the table and view it names', () => {
    const href = buildSearchResultHref('/pages/base-1', 'revenue', {
      kind: 'base_table',
      table_id: 'tbl-3',
      view_id: 'v-1'
    })
    expect(readBaseLocation(new URLSearchParams(href.slice(href.indexOf('?'))))).toEqual({
      table: 'tbl-3',
      view: 'v-1'
    })
  })
})
