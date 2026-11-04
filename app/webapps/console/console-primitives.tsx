export { truncate } from '../common/text'
import { safeJsonParse } from '@agentbull/active-support'
import i18n from '../common/i18n'
import { requestErrorMessage } from '../common/request-errors'

/**
 * The inline error surface is `common/error-block`. Page chrome lives in
 * `console-shell-chrome` (layout), `console-list-page` (list frame), and
 * `console-form` (editor frame).
 */

export function blankToNull(value: string): string | null {
  const text = value.trim()
  return text ? text : null
}

export function resourceID(value: string | null, minimum: number): number | undefined {
  if (!value || !/^[1-9][0-9]*$/.test(value)) return undefined

  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed >= minimum ? parsed : undefined
}

export function parseJSON(text: string, field: string): { ok: true; value: unknown } | { ok: false; error: string } {
  const parsed = safeJsonParse(text)
  if (parsed.isOk()) return { ok: true, value: parsed.value }
  return {
    ok: false,
    error: i18n.t('common.must_be_valid_json', { field, detail: requestErrorMessage(parsed.error.cause) })
  }
}

export function formatJSON(value: unknown): string {
  return JSON.stringify(value, null, 2)
}

export function formatDuration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m`
  if (seconds < 86_400) return `${Math.floor(seconds / 3_600)}h ${Math.floor((seconds % 3_600) / 60)}m`
  return `${Math.floor(seconds / 86_400)}d ${Math.floor((seconds % 86_400) / 3_600)}h`
}

export { formatDateTime as formatConsoleDate } from '../common/date-time'
