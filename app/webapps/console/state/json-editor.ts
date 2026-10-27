import { isRecord, Result, safeJsonParse } from '@agentbull/active-support'

export type JSONDraftState = { kind: 'empty' } | { kind: 'valid'; value: unknown } | { kind: 'invalid'; error: string }

export function inspectJSONDraft(text: string, parse?: (text: string) => unknown): JSONDraftState {
  if (!text.trim()) return { kind: 'empty' }

  const parsed = parse ? Result.try(() => parse(text)) : safeJsonParse(text)
  if (parsed.isOk()) return { kind: 'valid', value: parsed.value }

  const cause = parsed.error.cause
  const message = cause instanceof Error ? cause.message : String(cause)
  if (/line\s+\d+.*column\s+\d+/i.test(message)) return { kind: 'invalid', error: message }
  const offset = jsonErrorOffset(message)
  if (offset === undefined) return { kind: 'invalid', error: message }
  const { column, line } = lineAndColumn(text, offset)
  return { kind: 'invalid', error: `${message} (line ${line}, column ${column})` }
}

export function formatJSONDraft(text: string): string | undefined {
  const state = inspectJSONDraft(text)
  return state.kind === 'valid' ? JSON.stringify(state.value, null, 2) : undefined
}

export function parseJSONObjectDraft(text: string): Record<string, unknown> | undefined {
  const state = inspectJSONDraft(text)
  return state.kind === 'valid' && isRecord(state.value) ? state.value : undefined
}

export function serializeJSONObjectDraft(value: unknown): string | undefined {
  if (!isRecord(value)) return undefined

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
