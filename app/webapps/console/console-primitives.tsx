import { recordValue, type JsonObject as JSONObject } from '@agentbull/active-support'
import i18n from '../common/i18n'
import { requestErrorMessage } from '../common/request-errors'

/**
 * JSON/text parsing and date formatting shared by the console pages. The
 * inline error surface is `common/error-block`; page chrome lives in
 * `console-shell-chrome` (layout), `console-list-page` (list frame), and
 * `console-form` (editor frame).
 */

// JSON / text helpers

/** Bounds display text and marks the cut with an ellipsis. */
export function truncate(value: string, limit: number): string {
  return value.length <= limit ? value : `${value.slice(0, limit)}…`
}

export function blankToNull(value: string): string | null {
  const text = value.trim()
  return text ? text : null
}

/** Parses a decimal identifier and applies the owning API's lower bound. */
export function resourceID(value: string | null, minimum: number): number | undefined {
  if (!value || !/^[1-9][0-9]*$/.test(value)) return undefined

  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed >= minimum ? parsed : undefined
}

export function parseJSON(text: string, field: string): { ok: true; value: unknown } | { ok: false; error: string } {
  try {
    return { ok: true, value: JSON.parse(text) }
  } catch (error) {
    return { ok: false, error: i18n.t('common.must_be_valid_json', { field, detail: requestErrorMessage(error) }) }
  }
}

export function parseObjectDraft(
  text: string,
  field: string
): { ok: true; value: JSONObject } | { ok: false; error: string } {
  const parsed = parseJSON(text, field)
  if (!parsed.ok) return parsed
  const value = recordValue(parsed.value)
  if (value) return { ok: true, value }
  return { ok: false, error: i18n.t('common.must_be_json_object', { field }) }
}

export function formatJSON(value: unknown): string {
  return JSON.stringify(value, null, 2)
}

// Date formatting
//
// One formatter per first-class locale keeps all console timestamps consistent.
const CONSOLE_DATE_FORMATTERS: Record<string, Intl.DateTimeFormat> = {
  en: new Intl.DateTimeFormat('en-US', { dateStyle: 'medium', timeStyle: 'short' }),
  ja: new Intl.DateTimeFormat('ja-JP', { dateStyle: 'medium', timeStyle: 'short' }),
  ko: new Intl.DateTimeFormat('ko-KR', { dateStyle: 'medium', timeStyle: 'short' }),
  zh: new Intl.DateTimeFormat('zh-CN', { dateStyle: 'medium', timeStyle: 'short' })
}

function consoleDateFormatter(): Intl.DateTimeFormat {
  const language = i18n.language ?? ''
  return CONSOLE_DATE_FORMATTERS[language.slice(0, 2)] ?? CONSOLE_DATE_FORMATTERS.en
}

/** Compact duration for operator surfaces: 42s, 5m, 3h 20m, 22d 4h. */
export function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m`
  if (seconds < 86_400) return `${Math.floor(seconds / 3_600)}h ${Math.floor((seconds % 3_600) / 60)}m`
  return `${Math.floor(seconds / 86_400)}d ${Math.floor((seconds % 86_400) / 3_600)}h`
}

/**
 * Formats an ISO timestamp for display. Returns `'—'` for null/blank input and
 * the raw string for values that do not parse as dates, so callers can pass
 * nullable fields straight through.
 */
export function formatConsoleDate(value?: string | null): string {
  if (!value?.trim()) return '—'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return consoleDateFormatter().format(date)
}
