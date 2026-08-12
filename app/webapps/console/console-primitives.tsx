import { Alert, AlertDescription, AlertTitle } from '@ankole/uikit'
import { RiErrorWarningLine } from '@remixicon/react'
import { recordValue, type JsonObject as JSONObject } from '@agentbull/active-support'
import { format, type Locale } from 'date-fns'
import { enUS, zhCN } from 'date-fns/locale'
import type { ReactNode } from 'react'
import i18n from '../common/i18n'
import { requestErrorMessage } from '../common/request-errors'

/**
 * Cross-workspace helpers shared by the console pages: the inline error surface
 * and the JSON/text parsing used by the freeform payload fields. Page chrome
 * (layout, list, editor frames) lives in `console-shell`.
 */

export function ErrorBlock({ action, error, title }: { action?: ReactNode; error: unknown; title?: string }) {
  if (!error) return null
  return (
    <Alert className="min-w-0 overflow-hidden" variant="destructive">
      <RiErrorWarningLine aria-hidden />
      <AlertTitle>{title ?? i18n.t('common.error')}</AlertTitle>
      <AlertDescription className="min-w-0 break-all whitespace-pre-wrap">
        {requestErrorMessage(error)}
      </AlertDescription>
      {action ? <div className="mt-3">{action}</div> : null}
    </Alert>
  )
}

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
// reads a timestamp in Chinese.
const CONSOLE_DATE_FORMATS = { en: 'MMM d, yyyy h:mm a', zh: 'yyyy年M月d日 HH:mm' }

function usesChinese(): boolean {
  return Boolean(i18n.language?.startsWith('zh'))
}

function consoleDateLocale(): Locale {
  return usesChinese() ? zhCN : enUS
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
  return format(date, usesChinese() ? CONSOLE_DATE_FORMATS.zh : CONSOLE_DATE_FORMATS.en, {
    locale: consoleDateLocale()
  })
}
