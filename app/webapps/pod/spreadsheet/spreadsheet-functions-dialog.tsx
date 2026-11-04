import { t } from 'i18next'
import {
  Button,
  cn,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogTitle,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@ankole/uikit'
import { useMemo, useState } from 'react'
import { COMMON_FUNCTIONS } from '../state/spreadsheet-formula'
import type { FunctionInfo } from '../state/spreadsheet-grid'
import { functionDescription } from './spreadsheet-formula-assist'

const COMMON = 'common'
const ALL = 'all'
/** Categories in the order the list offers them; Cube and add-in functions have no use here. */
const CATEGORIES = [
  'math_trig',
  'statistical',
  'logical',
  'lookup',
  'text',
  'date_time',
  'financial',
  'information',
  'engineering',
  'database',
  'web',
  'compatibility'
]

/**
 * All functions by category, with a search over names and descriptions. Choosing one inserts its
 * name and opening parenthesis into the formula being typed, or starts a formula in the active cell.
 */
export function SpreadsheetFunctionsDialog({
  open,
  onOpenChange,
  functions,
  onInsert
}: {
  open: boolean
  onOpenChange(open: boolean): void
  functions: FunctionInfo[]
  onInsert(name: string): void
}) {
  const [category, setCategory] = useState(COMMON)
  const [query, setQuery] = useState('')
  const [chosen, setChosen] = useState<string>()
  const shown = useMemo(() => {
    const wanted = query.trim().toUpperCase()
    const found = functions.filter(fn =>
      wanted
        ? fn.name.includes(wanted) || functionDescription(fn).toUpperCase().includes(wanted)
        : category === ALL || (category === COMMON ? COMMON_FUNCTIONS.includes(fn.name) : fn.category === category)
    )
    return category === COMMON && !wanted
      ? found.sort((a, b) => COMMON_FUNCTIONS.indexOf(a.name) - COMMON_FUNCTIONS.indexOf(b.name))
      : found
  }, [functions, category, query])
  const selected = shown.find(fn => fn.name === chosen) ?? shown[0]
  const insert = (fn: FunctionInfo | undefined) => {
    if (!fn) return
    onOpenChange(false)
    onInsert(fn.name)
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-xl">
        <DialogTitle>{t('pod.spreadsheet.insert_function')}</DialogTitle>
        <DialogDescription>{t('pod.spreadsheet.insert_function_description')}</DialogDescription>
        <div className="flex gap-2">
          <Input
            autoFocus
            aria-label={t('pod.spreadsheet.search_functions')}
            placeholder={t('pod.spreadsheet.search_functions')}
            value={query}
            onChange={event => setQuery(event.target.value)}
            onKeyDown={event => {
              if (event.key === 'Enter') {
                event.preventDefault()
                insert(selected)
              }
            }}
          />
          <Select value={category} onValueChange={value => value && setCategory(value)}>
            <SelectTrigger className="w-40" aria-label={t('pod.spreadsheet.function_category')}>
              <SelectValue>{t(`pod.spreadsheet.function_categories.${category}`)}</SelectValue>
            </SelectTrigger>
            <SelectContent>
              {[COMMON, ALL, ...CATEGORIES].map(key => (
                <SelectItem key={key} value={key}>
                  {t(`pod.spreadsheet.function_categories.${key}`)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <ul
          role="listbox"
          aria-label={t('pod.spreadsheet.functions')}
          className="h-56 overflow-y-auto rounded-control border border-border py-1">
          {shown.map(fn => (
            <li
              key={fn.name}
              role="option"
              aria-selected={fn === selected}
              className={cn('cursor-pointer px-3 py-1 font-mono text-sm', fn === selected && 'bg-accent')}
              onClick={() => setChosen(fn.name)}
              onDoubleClick={() => insert(fn)}>
              {fn.name}
            </li>
          ))}
          {shown.length === 0 && (
            <li className="px-3 py-2 text-sm text-fg-secondary">{t('pod.spreadsheet.no_functions')}</li>
          )}
        </ul>
        {selected && (
          <div className="grid gap-1 text-sm">
            <code className="font-mono text-xs">{selected.signature}</code>
            <p className="text-fg-secondary">{functionDescription(selected)}</p>
          </div>
        )}
        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            {t('common.cancel')}
          </Button>
          <Button disabled={!selected} onClick={() => insert(selected)}>
            {t('pod.spreadsheet.insert')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
