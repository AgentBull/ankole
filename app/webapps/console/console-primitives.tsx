import { recordValue, type JsonObject as JSONObject } from '@pleisto/active-support'
import i18n from '../common/i18n'
import { requestErrorMessage } from '../common/request-errors'

/**
 * Cross-workspace helpers shared by the console pages: the inline error surface
 * and the JSON/text parsing used by the freeform payload fields. Page chrome
 * (layout, list, editor frames) lives in `console-shell`.
 */

export function ErrorBlock({ error }: { error: unknown }) {
  if (!error) return null
  return (
    <div className="border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive" role="alert">
      {typeof error === 'string' ? error : requestErrorMessage(error)}
    </div>
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
