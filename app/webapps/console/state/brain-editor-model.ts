export type BrainEntrySnapshot = {
  id: string
  name: string
  type: string
  summary: string
  aliases: string[]
  properties: Record<string, unknown>
  lock_version: number
}

export type BrainMetadataDraft = {
  name: string
  type: string
  summary: string
  aliases: string[]
  properties: Record<string, unknown>
}

export type BrainMetadataOperation =
  | {
      operation: 'set_name'
      entry_id: string
      name: string
      expected_entry_lock_version: number
    }
  | {
      operation: 'set_type'
      entry_id: string
      type: string
      expected_entry_lock_version: number
    }
  | {
      operation: 'set_summary'
      entry_id: string
      summary: string
      expected_entry_lock_version: number
    }
  | {
      operation: 'set_aliases'
      entry_id: string
      aliases: string[]
      expected_entry_lock_version: number
    }
  | {
      operation: 'set_property'
      entry_id: string
      key: string
      value: unknown
      expected_entry_lock_version: number
    }

export type PropertyDraft = { key: string; value: string }

export type BrainOwnerOption = { uid: string; type: 'human' | 'agent' }

const ROOT_CURSOR = '~'
const CURSOR_HISTORY_SEPARATOR = '.'

/** Keeps Brain's agent-first default while allowing every active Principal to be selected. */
export function defaultBrainOwnerUID(principals: BrainOwnerOption[]): string {
  return principals.find(principal => principal.type === 'agent')?.uid ?? principals[0]?.uid ?? ''
}

/** Builds the smallest structured operation batch for the editable entry metadata. */
export function buildMetadataOperations(
  entry: BrainEntrySnapshot,
  draft: BrainMetadataDraft
): BrainMetadataOperation[] {
  const operations: BrainMetadataOperation[] = []

  if (draft.name.trim() !== entry.name) {
    operations.push({
      operation: 'set_name',
      entry_id: entry.id,
      name: draft.name.trim(),
      expected_entry_lock_version: entry.lock_version
    })
  }

  if (draft.type.trim() !== entry.type) {
    operations.push({
      operation: 'set_type',
      entry_id: entry.id,
      type: draft.type.trim(),
      expected_entry_lock_version: entry.lock_version
    })
  }

  if (draft.summary !== entry.summary) {
    operations.push({
      operation: 'set_summary',
      entry_id: entry.id,
      summary: draft.summary,
      expected_entry_lock_version: entry.lock_version
    })
  }

  const aliases = normalizeAliases(draft.aliases)
  if (!sameJSON(aliases, entry.aliases)) {
    operations.push({
      operation: 'set_aliases',
      entry_id: entry.id,
      aliases,
      expected_entry_lock_version: entry.lock_version
    })
  }

  for (const key of new Set([...Object.keys(entry.properties), ...Object.keys(draft.properties)])) {
    const before = entry.properties[key]
    const after = Object.hasOwn(draft.properties, key) ? draft.properties[key] : null
    if (sameJSON(before, after)) continue

    operations.push({
      operation: 'set_property',
      entry_id: entry.id,
      key,
      value: after,
      expected_entry_lock_version: entry.lock_version
    })
  }

  return operations
}

export function normalizeAliases(values: string[]): string[] {
  return [...new Set(values.map(value => value.trim()).filter(Boolean))]
}

export function propertiesToDrafts(properties: Record<string, unknown>): PropertyDraft[] {
  return Object.entries(properties).map(([key, value]) => ({ key, value: JSON.stringify(value, null, 2) }))
}

export function parsePropertyDrafts(
  drafts: PropertyDraft[]
): { ok: true; value: Record<string, unknown> } | { ok: false; key: string; detail: string } {
  const properties: Record<string, unknown> = {}

  for (const draft of drafts) {
    const key = draft.key.trim()
    if (!key) return { ok: false, key: '', detail: 'property key is required' }
    if (Object.hasOwn(properties, key)) return { ok: false, key, detail: 'property key is duplicated' }

    try {
      properties[key] = JSON.parse(draft.value)
    } catch (error) {
      return { ok: false, key, detail: error instanceof Error ? error.message : String(error) }
    }
  }

  return { ok: true, value: properties }
}

/** Updates one URL-backed Brain filter and invalidates any cursor page derived from the old filter set. */
export function setBrainFilter(
  searchParams: URLSearchParams,
  key: string,
  value: string,
  cursorPrefix = ''
): URLSearchParams {
  const next = new URLSearchParams(searchParams)
  if (value) next.set(key, value)
  else next.delete(key)
  next.delete(cursorParam(cursorPrefix))
  next.delete(cursorHistoryParam(cursorPrefix))
  return next
}

/** Advances to a server-issued cursor while retaining the exact cursor needed to return. */
export function nextBrainCursor(searchParams: URLSearchParams, nextCursor: string, cursorPrefix = ''): URLSearchParams {
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
export function previousBrainCursor(searchParams: URLSearchParams, cursorPrefix = ''): URLSearchParams {
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

export function brainCursorPage(searchParams: URLSearchParams, cursorPrefix = ''): number {
  return readCursorHistory(searchParams, cursorPrefix).length + 1
}

export function canReturnBrainCursor(searchParams: URLSearchParams, cursorPrefix = ''): boolean {
  return readCursorHistory(searchParams, cursorPrefix).length > 0
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

function sameJSON(left: unknown, right: unknown): boolean {
  return JSON.stringify(left) === JSON.stringify(right)
}
