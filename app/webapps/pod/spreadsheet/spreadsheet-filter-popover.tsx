import { t } from 'i18next'
import { Button, Checkbox, Input, Label, PopoverTitle } from '@ankole/uikit'
import { useEffect, useMemo, useState } from 'react'
import type { FilterValue } from '../state/spreadsheet-grid'

const BLANK = '\u0000'
const key = (value: FilterValue) => (value.blank ? BLANK : value.text)

/**
 * The value list of one filter column: a search, a checkbox per distinct value with the blank
 * entry last, and the buttons that apply the chosen values, clear the column, or close the list.
 */
export function SpreadsheetFilterPopover({
  column,
  values,
  onApply,
  onClose
}: {
  column: string
  values: FilterValue[] | undefined
  onApply(criterion: { values: string[]; blanks: boolean } | null): void
  onClose(): void
}) {
  const [query, setQuery] = useState('')
  const [checked, setChecked] = useState<Set<string>>(new Set())
  useEffect(() => {
    setChecked(new Set((values ?? []).filter(value => value.selected).map(key)))
  }, [values])
  const shown = useMemo(() => {
    const wanted = query.trim().toLowerCase()
    return (values ?? []).filter(value => !wanted || value.text.toLowerCase().includes(wanted))
  }, [values, query])
  const allShown = shown.length > 0 && shown.every(value => checked.has(key(value)))
  const toggleAll = (on: boolean) => {
    const next = new Set(checked)
    for (const value of shown) {
      if (on) next.add(key(value))
      else next.delete(key(value))
    }
    setChecked(next)
  }
  const toggle = (value: FilterValue, on: boolean) => {
    const next = new Set(checked)
    if (on) next.add(key(value))
    else next.delete(key(value))
    setChecked(next)
  }
  const apply = () => {
    const chosen = (values ?? []).filter(value => checked.has(key(value)))
    onApply({
      values: chosen.filter(value => !value.blank).map(value => value.text),
      blanks: chosen.some(value => value.blank)
    })
  }

  return (
    <div className="flex w-64 flex-col gap-2">
      <PopoverTitle>{t('pod.spreadsheet.filter_column', { column })}</PopoverTitle>
      <Input
        aria-label={t('pod.spreadsheet.filter_search')}
        placeholder={t('pod.spreadsheet.filter_search')}
        value={query}
        onChange={event => setQuery(event.target.value)}
      />
      {values === undefined ? (
        <p role="status" className="text-xs text-fg-tertiary">
          {t('pod.spreadsheet.loading')}
        </p>
      ) : (
        <div className="max-h-56 overflow-y-auto rounded-control border border-border p-1">
          <Label className="flex items-center gap-2 px-1 py-1 text-sm">
            <Checkbox checked={allShown} onCheckedChange={on => toggleAll(on === true)} />
            {t('pod.spreadsheet.filter_select_all')}
          </Label>
          {shown.map(value => (
            <Label key={key(value)} className="flex items-center gap-2 px-1 py-1 text-sm">
              <Checkbox checked={checked.has(key(value))} onCheckedChange={on => toggle(value, on === true)} />
              <span className={value.blank ? 'text-fg-tertiary' : 'truncate'}>
                {value.blank ? t('pod.spreadsheet.filter_blanks') : value.text}
              </span>
            </Label>
          ))}
          {!shown.length && (
            <p className="px-1 py-1 text-xs text-fg-tertiary">{t('pod.spreadsheet.filter_no_values')}</p>
          )}
        </div>
      )}
      <div className="flex items-center justify-between gap-2">
        <Button size="sm" variant="ghost" onClick={() => onApply(null)}>
          {t('pod.spreadsheet.filter_clear_column')}
        </Button>
        <div className="flex gap-2">
          <Button size="sm" variant="outline" onClick={onClose}>
            {t('common.cancel')}
          </Button>
          <Button size="sm" disabled={values === undefined} onClick={apply}>
            {t('pod.spreadsheet.filter_apply')}
          </Button>
        </div>
      </div>
    </div>
  )
}
