import { recordValue, type JsonObject as JSONObject } from '@agentbull/active-support'
import { format, type Locale } from 'date-fns'
import { enUS, ja, ko, zhCN } from 'date-fns/locale'
import i18n from '../common/i18n'
import { requestErrorMessage } from '../common/request-errors'

/**
 * JSON/text parsing and date formatting shared by the console pages. The
 * inline error surface is `common/error-block`; page chrome lives in
 * `console-shell-chrome` (layout), `console-list-page` (list frame), and
 * `console-form` (editor frame).
 */

// --- JSON / text helpers ---

export function blankToNull(value: string): string | null {
  const text = value.trim()
  return text ? text : null
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

// --- Date formatting ---
//
// One console-wide date formatter so every page renders timestamps the same way.
// `dateStyle: 'medium', timeStyle: 'short'` was previously re-implemented inline
// in four pages via `Intl.DateTimeFormat`; date-fns lets the locale follow the
// active i18n language (zh-CN browsers no longer silently fall back to English).
//
// The pattern follows the language too. One English pattern rendered under the
// zh-CN locale produced "7月 26, 2026 1:09 上午" — Chinese month and meridiem
// glued to an English date order — and a 12-hour clock is not how an operator
// reads a timestamp in zh, ja, or ko. One entry per first-class locale catalog;
// a language without an entry falls back to the en pattern.
const CONSOLE_DATE_FORMATS: Record<string, { pattern: string; locale: Locale }> = {
  en: { pattern: 'MMM d, yyyy h:mm a', locale: enUS },
  ja: { pattern: 'yyyy年M月d日 H:mm', locale: ja },
  ko: { pattern: 'yyyy. M. d. HH:mm', locale: ko },
  zh: { pattern: 'yyyy年M月d日 HH:mm', locale: zhCN }
}

function consoleDateFormat(): { pattern: string; locale: Locale } {
  const language = i18n.language ?? ''
  return CONSOLE_DATE_FORMATS[language.slice(0, 2)] ?? CONSOLE_DATE_FORMATS.en
}

/**
 * Formats an ISO timestamp for display. Returns `'—'` for null/blank input and
 * the raw string for values that do not parse as dates, so callers can pass
 * nullable fields straight through.
 */
export function formatConsoleDate(value?: string | null): string {
  if (!value) return '—'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  const { pattern, locale } = consoleDateFormat()
  return format(date, pattern, { locale })
}
