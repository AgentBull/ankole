import { t } from 'i18next'
import {
  Button,
  Checkbox,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogTitle,
  Input,
  Label,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Textarea
} from '@ankole/uikit'
import { useEffect, useState } from 'react'
import type { RenderValidation, ValidationKind, ValidationOperator, ValidationRule } from '../state/spreadsheet-grid'

const KINDS: ValidationKind[] = ['any', 'whole', 'decimal', 'list', 'date', 'time', 'text_length', 'custom']
const OPERATORS: ValidationOperator[] = [
  'between',
  'not_between',
  'equal',
  'not_equal',
  'greater',
  'less',
  'greater_or_equal',
  'less_or_equal'
]
/** Kinds that compare the value with one or two bounds. */
const BOUNDED: ValidationKind[] = ['whole', 'decimal', 'date', 'time', 'text_length']

type Form = {
  kind: ValidationKind
  operator: ValidationOperator
  formula1: string
  formula2: string
  allowBlank: boolean
  showDropdown: boolean
  inputMessage: string
  errorMessage: string
}

const EMPTY: Form = {
  kind: 'list',
  operator: 'between',
  formula1: '',
  formula2: '',
  allowBlank: true,
  showDropdown: true,
  inputMessage: '',
  errorMessage: ''
}

/**
 * The rule of a range's data validation: what the cells accept, the bounds or the list entries,
 * and the messages the editor shows. Saving writes the rule over the range; removing clears it.
 */
export function SpreadsheetValidationDialog({
  open,
  onOpenChange,
  range,
  current,
  onSave
}: {
  open: boolean
  onOpenChange(open: boolean): void
  range: string
  /** The rule the range's first cell has now, which seeds the form's list entries and messages. */
  current?: RenderValidation
  onSave(rule: ValidationRule | null): void
}) {
  const [form, setForm] = useState<Form>(EMPTY)
  useEffect(() => {
    if (!open) return
    setForm({
      ...EMPTY,
      kind: current?.kind ?? 'list',
      formula1: current?.kind === 'list' ? current.items.join(',') : '',
      showDropdown: current?.dropdown ?? true,
      inputMessage: current?.input_message ?? ''
    })
  }, [open, current])
  const set = <K extends keyof Form>(field: K, value: Form[K]) => setForm(previous => ({ ...previous, [field]: value }))
  const bounded = BOUNDED.includes(form.kind)
  const pair = bounded && (form.operator === 'between' || form.operator === 'not_between')
  const valid = form.kind === 'any' || (form.formula1.trim() !== '' && (!pair || form.formula2.trim() !== ''))
  const save = () => {
    const rule: ValidationRule = { kind: form.kind }
    if (bounded) rule.operator = form.operator
    if (form.kind !== 'any') rule.formula1 = form.formula1.trim()
    if (pair) rule.formula2 = form.formula2.trim()
    if (!form.allowBlank) rule.allow_blank = false
    if (form.kind === 'list' && !form.showDropdown) rule.show_dropdown = false
    if (form.inputMessage.trim()) rule.input_message = form.inputMessage.trim()
    if (form.errorMessage.trim()) rule.error_message = form.errorMessage.trim()
    onOpenChange(false)
    onSave(rule)
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogTitle>{t('pod.spreadsheet.validation_for', { range })}</DialogTitle>
        <DialogDescription>{t('pod.spreadsheet.validation_description')}</DialogDescription>
        <div className="grid gap-3">
          <Label className="grid gap-1 text-sm">
            {t('pod.spreadsheet.validation_kind')}
            <Select value={form.kind} onValueChange={value => value && set('kind', value as ValidationKind)}>
              <SelectTrigger aria-label={t('pod.spreadsheet.validation_kind')}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {KINDS.map(kind => (
                  <SelectItem key={kind} value={kind}>
                    {t(`pod.spreadsheet.validation_kinds.${kind}`)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Label>
          {bounded && (
            <Label className="grid gap-1 text-sm">
              {t('pod.spreadsheet.validation_operator')}
              <Select
                value={form.operator}
                onValueChange={value => value && set('operator', value as ValidationOperator)}>
                <SelectTrigger aria-label={t('pod.spreadsheet.validation_operator')}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {OPERATORS.map(operator => (
                    <SelectItem key={operator} value={operator}>
                      {t(`pod.spreadsheet.validation_operators.${operator}`)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Label>
          )}
          {form.kind !== 'any' && (
            <Label className="grid gap-1 text-sm">
              {form.kind === 'list'
                ? t('pod.spreadsheet.validation_list_items')
                : form.kind === 'custom'
                  ? t('pod.spreadsheet.validation_formula')
                  : pair
                    ? t('pod.spreadsheet.validation_minimum')
                    : t('pod.spreadsheet.validation_value')}
              <Input
                value={form.formula1}
                placeholder={form.kind === 'list' ? t('pod.spreadsheet.validation_list_hint') : undefined}
                onChange={event => set('formula1', event.target.value)}
              />
            </Label>
          )}
          {pair && (
            <Label className="grid gap-1 text-sm">
              {t('pod.spreadsheet.validation_maximum')}
              <Input value={form.formula2} onChange={event => set('formula2', event.target.value)} />
            </Label>
          )}
          <Label className="flex items-center gap-2 text-sm">
            <Checkbox checked={form.allowBlank} onCheckedChange={on => set('allowBlank', on === true)} />
            {t('pod.spreadsheet.validation_allow_blank')}
          </Label>
          {form.kind === 'list' && (
            <Label className="flex items-center gap-2 text-sm">
              <Checkbox checked={form.showDropdown} onCheckedChange={on => set('showDropdown', on === true)} />
              {t('pod.spreadsheet.validation_show_dropdown')}
            </Label>
          )}
          <Label className="grid gap-1 text-sm">
            {t('pod.spreadsheet.validation_input_message')}
            <Textarea rows={2} value={form.inputMessage} onChange={event => set('inputMessage', event.target.value)} />
          </Label>
          <Label className="grid gap-1 text-sm">
            {t('pod.spreadsheet.validation_error_message')}
            <Input value={form.errorMessage} onChange={event => set('errorMessage', event.target.value)} />
          </Label>
        </div>
        <DialogFooter>
          {current && (
            <Button
              variant="ghost"
              className="mr-auto"
              onClick={() => {
                onOpenChange(false)
                onSave(null)
              }}>
              {t('pod.spreadsheet.validation_remove')}
            </Button>
          )}
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            {t('common.cancel')}
          </Button>
          <Button disabled={!valid} onClick={save}>
            {t('common.save')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
