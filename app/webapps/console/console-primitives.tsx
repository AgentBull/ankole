import { Alert, AlertDescription, AlertTitle } from '@ankole/uikit'
import { RiErrorWarningLine } from '@remixicon/react'
import { recordValue, type JsonObject as JSONObject } from '@pleisto/active-support'
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
