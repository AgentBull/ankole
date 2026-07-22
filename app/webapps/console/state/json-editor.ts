export type JSONDraftState = { kind: 'empty' } | { kind: 'valid'; value: unknown } | { kind: 'invalid'; error: string }

/** Parses a JSON draft and annotates native parse errors with a line and column. */
export function inspectJSONDraft(text: string, parse: (text: string) => unknown = JSON.parse): JSONDraftState {
  if (!text.trim()) return { kind: 'empty' }

  try {
    return { kind: 'valid', value: parse(text) }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    if (/line\s+\d+.*column\s+\d+/i.test(message)) return { kind: 'invalid', error: message }
    const offset = jsonErrorOffset(message)
    if (offset === undefined) return { kind: 'invalid', error: message }
    const { column, line } = lineAndColumn(text, offset)
    return { kind: 'invalid', error: `${message} (line ${line}, column ${column})` }
  }
}

export function formatJSONDraft(text: string): string | undefined {
  const state = inspectJSONDraft(text)
  return state.kind === 'valid' ? JSON.stringify(state.value, null, 2) : undefined
}

export function parseJSONObjectDraft(text: string): Record<string, unknown> | undefined {
  const state = inspectJSONDraft(text)
  return state.kind === 'valid' && isJSONObject(state.value) ? state.value : undefined
}

export function serializeJSONObjectDraft(value: unknown): string | undefined {
  if (!isJSONObject(value)) return undefined

  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return undefined
  }
}

function jsonErrorOffset(message: string): number | undefined {
  const match = message.match(/(?:position|at position)\s+(\d+)/i)
  if (!match?.[1]) return undefined
  const offset = Number(match[1])
  return Number.isFinite(offset) ? offset : undefined
}

function lineAndColumn(text: string, offset: number): { column: number; line: number } {
  const prefix = text.slice(0, Math.max(0, Math.min(offset, text.length)))
  const lines = prefix.split('\n')
  return { line: lines.length, column: (lines.at(-1)?.length ?? 0) + 1 }
}

function isJSONObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
