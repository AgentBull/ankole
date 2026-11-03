import { t } from 'i18next'
import {
  Button,
  Checkbox,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogTitle,
  Input,
  Label,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@ankole/uikit'
import { useEffect, useState } from 'react'
import { parseCell, replaceText, type FindMatch, type FindOptions } from '../state/spreadsheet-grid'
import type { SpreadsheetSession } from '../state/spreadsheet-collaboration'

export type FindMode = 'find' | 'replace'

/**
 * Find and replace over the active sheet or the whole workbook. A search lists its matches once;
 * stepping through them selects each cell, and a replace rewrites the matched cells' inputs as one
 * undo step and searches again.
 */
export function SpreadsheetFindDialog({
  open,
  mode,
  onOpenChange,
  model
}: {
  open: boolean
  mode: FindMode
  onOpenChange(open: boolean): void
  model: SpreadsheetSession
}) {
  const [query, setQuery] = useState('')
  const [replacement, setReplacement] = useState('')
  const [matchCase, setMatchCase] = useState(false)
  const [wholeCell, setWholeCell] = useState(false)
  const [inFormulas, setInFormulas] = useState(false)
  const [scope, setScope] = useState<'sheet' | 'workbook'>('sheet')
  const [matches, setMatches] = useState<FindMatch[]>()
  const [index, setIndex] = useState(0)
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    if (open) setMatches(undefined)
  }, [open])
  const replacing = mode === 'replace'
  // A replace rewrites inputs, so it always matches against them.
  const options: FindOptions = { match_case: matchCase, whole_cell: wholeCell, formulas: inFormulas || replacing }
  const editable = model.editable.value

  const search = async (): Promise<FindMatch[]> => {
    const found = (await model.find(query, options, scope)) ?? []
    setMatches(found)
    return found
  }
  const show = (list: FindMatch[], at: number) => {
    const match = list[at]
    const cell = match && parseCell(match.cell)
    if (match && cell) {
      setIndex(at)
      model.goTo(match.sheet_id, cell)
    }
  }
  const step = async (direction: 1 | -1) => {
    if (!query) return
    const list = matches ?? (await search())
    if (!list.length) return
    const at = matches ? (index + direction + list.length) % list.length : 0
    show(list, at)
  }
  const replaceOne = async () => {
    if (!query || !editable) return
    const list = matches ?? (await search())
    const match = list[index]
    if (!match) return
    const input = replaceText(match.text, query, replacement, options)
    setBusy(true)
    try {
      if (input !== undefined) await model.replaceCells(match.sheet_id, [{ cell: match.cell, input }])
      const next = await search()
      show(next, next.length ? Math.min(index, next.length - 1) : 0)
    } finally {
      setBusy(false)
    }
  }
  const replaceAll = async () => {
    if (!query || !editable) return
    setBusy(true)
    try {
      const list = await search()
      const bySheet = new Map<number, { cell: string; input: string }[]>()
      for (const match of list) {
        const input = replaceText(match.text, query, replacement, options)
        if (input === undefined) continue
        const edits = bySheet.get(match.sheet_id) ?? []
        edits.push({ cell: match.cell, input })
        bySheet.set(match.sheet_id, edits)
      }
      for (const [sheetID, edits] of bySheet) await model.replaceCells(sheetID, edits)
      setMatches(await model.find(query, options, scope))
      setIndex(0)
    } finally {
      setBusy(false)
    }
  }
  const reset =
    <T,>(set: (value: T) => void) =>
    (value: T) => {
      set(value)
      setMatches(undefined)
    }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogTitle>{replacing ? t('pod.spreadsheet.find_replace') : t('pod.spreadsheet.find')}</DialogTitle>
        <DialogDescription>
          {matches
            ? matches.length
              ? t('pod.spreadsheet.find_position', { index: index + 1, count: matches.length })
              : t('pod.spreadsheet.find_none')
            : t('pod.spreadsheet.find_description')}
        </DialogDescription>
        <form
          className="grid gap-3"
          onSubmit={event => {
            event.preventDefault()
            void step(1)
          }}>
          <Label className="grid gap-1 text-sm">
            {t('pod.spreadsheet.find_what')}
            <Input autoFocus value={query} onChange={event => reset(setQuery)(event.target.value)} />
          </Label>
          {replacing && (
            <Label className="grid gap-1 text-sm">
              {t('pod.spreadsheet.replace_with')}
              <Input value={replacement} onChange={event => setReplacement(event.target.value)} />
            </Label>
          )}
          <div className="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm">
            <Label className="flex items-center gap-2">
              <Checkbox checked={matchCase} onCheckedChange={on => reset(setMatchCase)(on === true)} />
              {t('pod.spreadsheet.find_match_case')}
            </Label>
            <Label className="flex items-center gap-2">
              <Checkbox checked={wholeCell} onCheckedChange={on => reset(setWholeCell)(on === true)} />
              {t('pod.spreadsheet.find_whole_cell')}
            </Label>
            {!replacing && (
              <Label className="flex items-center gap-2">
                <Checkbox checked={inFormulas} onCheckedChange={on => reset(setInFormulas)(on === true)} />
                {t('pod.spreadsheet.find_in_formulas')}
              </Label>
            )}
            <Select value={scope} onValueChange={value => value && reset(setScope)(value as 'sheet' | 'workbook')}>
              <SelectTrigger size="sm" className="w-36" aria-label={t('pod.spreadsheet.find_scope')}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="sheet">{t('pod.spreadsheet.find_scope_sheet')}</SelectItem>
                <SelectItem value="workbook">{t('pod.spreadsheet.find_scope_workbook')}</SelectItem>
              </SelectContent>
            </Select>
          </div>
          <div className="flex flex-wrap justify-end gap-2">
            {replacing && (
              <>
                <Button
                  type="button"
                  variant="outline"
                  disabled={!query || !editable || busy}
                  onClick={() => void replaceAll()}>
                  {t('pod.spreadsheet.replace_all')}
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  disabled={!query || !editable || busy}
                  onClick={() => void replaceOne()}>
                  {t('pod.spreadsheet.replace')}
                </Button>
              </>
            )}
            <Button type="button" variant="outline" disabled={!query || busy} onClick={() => void step(-1)}>
              {t('pod.spreadsheet.find_previous')}
            </Button>
            <Button type="submit" disabled={!query || busy}>
              {t('pod.spreadsheet.find_next')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
