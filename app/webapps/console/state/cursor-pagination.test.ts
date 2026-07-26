import { describe, expect, test } from 'bun:test'
import {
  cursorPageNumber,
  hasPreviousCursor,
  nextCursorParams,
  previousCursorParams,
  resetCursorParams
} from './cursor-pagination'

describe('cursor pagination', () => {
  test('keeps a stable cursor history for next and previous page navigation', () => {
    const first = new URLSearchParams('owner=agent-one')
    const second = nextCursorParams(first, 'cursor-two')
    const third = nextCursorParams(second, 'cursor-three')

    expect(second.get('cursor')).toBe('cursor-two')
    expect(cursorPageNumber(second)).toBe(2)
    expect(cursorPageNumber(third)).toBe(3)
    expect(hasPreviousCursor(third)).toBe(true)

    const returnedToSecond = previousCursorParams(third)
    const returnedToFirst = previousCursorParams(returnedToSecond)
    expect(returnedToSecond.get('cursor')).toBe('cursor-two')
    expect(returnedToFirst.get('cursor')).toBeNull()
    expect(returnedToFirst.get('cursor_history')).toBeNull()
    expect(hasPreviousCursor(returnedToFirst)).toBe(false)
  })

  test('pages two independent lists on one route through the prefix', () => {
    const params = new URLSearchParams('owner=agent-one')
    const listPage = nextCursorParams(params, 'list-two')
    const bothPaged = nextCursorParams(listPage, 'audit-two', 'audit_')

    expect(bothPaged.get('cursor')).toBe('list-two')
    expect(bothPaged.get('audit_cursor')).toBe('audit-two')
    expect(cursorPageNumber(bothPaged)).toBe(2)
    expect(cursorPageNumber(bothPaged, 'audit_')).toBe(2)
    expect(previousCursorParams(bothPaged, 'audit_').get('cursor')).toBe('list-two')
  })

  test('resetting clears only the matching cursor surface', () => {
    const params = new URLSearchParams(
      'owner=agent-one&cursor=list-page&cursor_history=~&audit_cursor=audit-page&audit_cursor_history=~'
    )
    const reset = resetCursorParams(params)

    expect(reset.get('cursor')).toBeNull()
    expect(reset.get('cursor_history')).toBeNull()
    expect(reset.get('audit_cursor')).toBe('audit-page')
    expect(reset.get('owner')).toBe('agent-one')
  })

  test('discards a history entry that is not a server-issued cursor', () => {
    // The root marker and `page-two` are well formed; the third entry is not,
    // so a tampered URL shortens the history rather than paging to a bad cursor.
    const params = new URLSearchParams('cursor=page-four&cursor_history=~.page-two.not%20a%20cursor')

    expect(cursorPageNumber(params)).toBe(3)
    expect(previousCursorParams(params).get('cursor')).toBe('page-two')
  })
})
