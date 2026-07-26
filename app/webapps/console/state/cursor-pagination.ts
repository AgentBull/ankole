/**
 * URL-backed paging for the cursor-based Console list endpoints.
 *
 * The server issues an opaque `next_cursor` and no total, so a page number can
 * only be counted, and returning to a previous page can only be done by keeping
 * the cursor that produced it. Both live in the URL, so a page survives a reload
 * and can be shared. `cursorPrefix` lets one route page two independent lists.
 */

const ROOT_CURSOR = '~'
const CURSOR_HISTORY_SEPARATOR = '.'

/** Advances to a server-issued cursor while retaining the exact cursor needed to return. */
export function nextCursorParams(
  searchParams: URLSearchParams,
  nextCursor: string,
  cursorPrefix = ''
): URLSearchParams {
  const next = new URLSearchParams(searchParams)
  const cursorKey = cursorParam(cursorPrefix)
  const historyKey = cursorHistoryParam(cursorPrefix)
  const history = readCursorHistory(searchParams, cursorPrefix)
  history.push(searchParams.get(cursorKey) ?? '')
  next.set(cursorKey, nextCursor)
  next.set(historyKey, history.map(cursor => cursor || ROOT_CURSOR).join(CURSOR_HISTORY_SEPARATOR))
  return next
}

/** Returns to the cursor that produced the previous page without guessing from mutable row data. */
export function previousCursorParams(searchParams: URLSearchParams, cursorPrefix = ''): URLSearchParams {
  const next = new URLSearchParams(searchParams)
  const cursorKey = cursorParam(cursorPrefix)
  const historyKey = cursorHistoryParam(cursorPrefix)
  const history = readCursorHistory(searchParams, cursorPrefix)
  const previous = history.pop()

  if (previous) next.set(cursorKey, previous)
  else next.delete(cursorKey)

  if (history.length > 0) {
    next.set(historyKey, history.map(cursor => cursor || ROOT_CURSOR).join(CURSOR_HISTORY_SEPARATOR))
  } else {
    next.delete(historyKey)
  }

  return next
}

export function cursorPageNumber(searchParams: URLSearchParams, cursorPrefix = ''): number {
  return readCursorHistory(searchParams, cursorPrefix).length + 1
}

export function hasPreviousCursor(searchParams: URLSearchParams, cursorPrefix = ''): boolean {
  return readCursorHistory(searchParams, cursorPrefix).length > 0
}

/** Drops the cursor and its history, so a changed filter restarts at the first page. */
export function resetCursorParams(searchParams: URLSearchParams, cursorPrefix = ''): URLSearchParams {
  const next = new URLSearchParams(searchParams)
  next.delete(cursorParam(cursorPrefix))
  next.delete(cursorHistoryParam(cursorPrefix))
  return next
}

function readCursorHistory(searchParams: URLSearchParams, cursorPrefix: string): string[] {
  const encoded = searchParams.get(cursorHistoryParam(cursorPrefix))
  if (!encoded) return []

  return encoded
    .split(CURSOR_HISTORY_SEPARATOR)
    .filter(part => part === ROOT_CURSOR || /^[A-Za-z0-9_-]+$/.test(part))
    .map(part => (part === ROOT_CURSOR ? '' : part))
}

function cursorParam(prefix: string): string {
  return `${prefix}cursor`
}

function cursorHistoryParam(prefix: string): string {
  return `${prefix}cursor_history`
}
