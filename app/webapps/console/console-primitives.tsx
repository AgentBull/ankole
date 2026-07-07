import { recordValue, type JsonObject } from '@pleisto/active-support'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@ankole/uikit'
import { useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import i18n from '../common/i18n'
import { requestErrorMessage } from '../common/request-errors'

/**
 * Shared presentational primitives and helpers for the Console workspaces.
 *
 * Each workspace owns its domain logic (queries, mutations, drafts); these are
 * only the cross-workspace building blocks: the list/table shell, field label,
 * error surface, JSON helpers, and the one truly identical lifecycle hook
 * (auto-select the first row when none is selected).
 */

export function WorkspaceShell({
  action,
  children,
  title
}: {
  action?: ReactNode
  children: ReactNode
  title: string
}) {
  return (
    <div className="grid gap-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="text-xl font-semibold tracking-normal">{title}</h2>
        {action}
      </div>
      {children}
    </div>
  )
}

export function ResourceTable({
  children,
  columns,
  empty,
  loading
}: {
  children: ReactNode
  columns: string[]
  empty: boolean
  loading: boolean
}) {
  const { t } = useTranslation()
  return (
    <div className="overflow-hidden border border-border bg-card">
      <Table>
        <TableHeader>
          <TableRow>
            {columns.map(column => (
              <TableHead key={column}>{column}</TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {children}
          {loading ? (
            <TableRow>
              <TableCell colSpan={columns.length} className="text-muted-foreground">
                {t('common.loading')}...
              </TableCell>
            </TableRow>
          ) : null}
          {empty ? (
            <TableRow>
              <TableCell colSpan={columns.length} className="text-muted-foreground">
                {t('console.no_records')}
              </TableCell>
            </TableRow>
          ) : null}
        </TableBody>
      </Table>
    </div>
  )
}

export function Field({ children, label }: { children: ReactNode; label: string }) {
  return (
    <label className="grid min-w-0 gap-2 text-xs font-medium tracking-normal text-muted-foreground">
      <span>{label}</span>
      {children}
    </label>
  )
}

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

export function parseJson(text: string, field: string): { ok: true; value: unknown } | { ok: false; error: string } {
  try {
    return { ok: true, value: JSON.parse(text) }
  } catch (error) {
    return { ok: false, error: i18n.t('common.must_be_valid_json', { field, detail: requestErrorMessage(error) }) }
  }
}

export function parseObjectDraft(
  text: string,
  field: string
): { ok: true; value: JsonObject } | { ok: false; error: string } {
  const parsed = parseJson(text, field)
  if (!parsed.ok) return parsed
  const value = recordValue(parsed.value)
  if (value) return { ok: true, value }
  return { ok: false, error: i18n.t('common.must_be_json_object', { field }) }
}

export function formatJson(value: unknown): string {
  return JSON.stringify(value, null, 2)
}

// --- selection lifecycle ---

/**
 * Tracks the selected row id, auto-selecting the first item when nothing is
 * selected yet. `onFirstSelected` fires alongside that auto-select so callers
 * that mirror selection into their own UI state (e.g. new/edit mode) can stay
 * in sync without duplicating the "no selection yet" guard.
 *
 * Workspaces whose auto-select target is not simply `items[0]` (for example
 * AppConfigure, which lands on the first editable row) keep their own effect.
 */
export function useSelectFirst<T>(
  items: T[] | undefined,
  getId: (item: T) => string,
  onFirstSelected?: (item: T) => void
) {
  const [selectedId, setSelectedId] = useState<string | null>(null)
  useEffect(() => {
    if (!selectedId && items?.[0]) {
      setSelectedId(getId(items[0]))
      onFirstSelected?.(items[0])
    }
    // onFirstSelected is intentionally omitted: it closes over stable setters.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items, selectedId])
  return [selectedId, setSelectedId] as const
}
