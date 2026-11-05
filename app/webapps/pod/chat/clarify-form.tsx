import {
  Button,
  Checkbox,
  Field,
  FieldDescription,
  FieldError,
  FieldLabel,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Textarea
} from '@ankole/uikit'
import { useContext, useEffect, useId, useRef, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { RevealInTimeline } from './timeline-scroll'
import type { ClarifyField } from './types'

type Draft = Record<string, unknown>

/** Renders a structured clarify form; the control plane validates the submission again and owns the result. */
export function ClarifyForm({
  fields,
  disabled,
  errors,
  onSubmit
}: {
  fields: ClarifyField[]
  disabled: boolean
  /** Field error codes from the last rejected submission. */
  errors?: Record<string, string>
  onSubmit(values: Record<string, unknown>): void
}) {
  const { t } = useTranslation()
  const formID = useId()
  const form = useRef<HTMLFormElement>(null)
  const [draft, setDraft] = useState<Draft>(() => Object.fromEntries(fields.map(field => [field.id, initial(field)])))
  const [localErrors, setLocalErrors] = useState<Record<string, string>>({})
  const [touched, setTouched] = useState<Set<string>>(new Set())
  const shown = (id: string) => (touched.has(id) ? localErrors[id] : (localErrors[id] ?? errors?.[id]))
  const reveal = useContext(RevealInTimeline)
  // The field moves to the middle of the view once the error messages have rendered.
  const focusField = (id: string) =>
    requestAnimationFrame(() => {
      const field = form.current?.querySelector<HTMLElement>(`[data-field="${id}"]`)
      if (!field) return
      reveal(field)
      field.focus({ preventScroll: true })
    })

  // Each rejected submission brings a new `errors` object; focus moves to the
  // first field the server flagged, and FieldError announces it as an alert.
  useEffect(() => {
    const first = fields.find(field => errors?.[field.id])
    if (first) {
      setTouched(new Set())
      focusField(first.id)
    }
  }, [errors])

  const submit = (event: FormEvent) => {
    event.preventDefault()
    if (disabled) return
    const { values, errors: found } = collect(fields, draft)
    setLocalErrors(found)
    setTouched(new Set())
    const first = fields.find(field => found[field.id])
    if (first) {
      focusField(first.id)
      return
    }
    onSubmit(values)
  }

  const change = (id: string, value: unknown) => {
    setDraft(current => ({ ...current, [id]: value }))
    setTouched(current => new Set(current).add(id))
    setLocalErrors(({ [id]: _cleared, ...rest }) => rest)
  }

  return (
    <form ref={form} className="pod-chat-choice-form" noValidate onSubmit={submit}>
      {fields.map(field => {
        const controlID = `${formID}-${field.id}`
        const error = shown(field.id)
        const hint = field.type === 'multi_select' ? itemsHint(field, t) : undefined
        const describedBy =
          [field.help && `${controlID}-help`, hint && `${controlID}-hint`, error && `${controlID}-error`]
            .filter(Boolean)
            .join(' ') || undefined
        const common = {
          id: controlID,
          'data-field': field.id,
          disabled,
          'aria-describedby': describedBy,
          'aria-invalid': error ? true : undefined,
          'aria-required': field.required || undefined
        }
        return (
          <Field key={field.id} data-disabled={disabled || undefined}>
            <FieldLabel htmlFor={field.type === 'multi_select' ? undefined : controlID} id={`${controlID}-label`}>
              {field.label}
              {!field.required && (
                <span className="ml-1 font-normal text-muted-foreground">{t('pod.chat_form.optional')}</span>
              )}
            </FieldLabel>
            {control(field, draft[field.id], value => change(field.id, value), common, t)}
            {field.help && <FieldDescription id={`${controlID}-help`}>{field.help}</FieldDescription>}
            {hint && <FieldDescription id={`${controlID}-hint`}>{hint}</FieldDescription>}
            {error && (
              <FieldError id={`${controlID}-error`}>
                {t(`pod.chat_form.errors.${error}`, { defaultValue: t('pod.chat_form.errors.invalid') })}
              </FieldError>
            )}
          </Field>
        )
      })}
      <Button type="submit" size="sm" disabled={disabled}>
        {t('pod.chat_form.submit')}
      </Button>
    </form>
  )
}

function control(
  field: ClarifyField,
  value: unknown,
  onChange: (value: unknown) => void,
  common: Record<string, unknown> & { id: string },
  t: (key: string) => string
) {
  switch (field.type) {
    case 'text':
      return field.multiline ? (
        <Textarea
          {...common}
          maxLength={field.max_length}
          value={String(value ?? '')}
          onChange={event => onChange(event.target.value)}
        />
      ) : (
        <Input
          {...common}
          maxLength={field.max_length}
          value={String(value ?? '')}
          onChange={event => onChange(event.target.value)}
        />
      )
    case 'number':
      return (
        <span className="pod-chat-choice-form-number">
          <Input
            {...common}
            type="number"
            inputMode={field.integer ? 'numeric' : 'decimal'}
            step={field.integer ? 1 : 'any'}
            min={field.min}
            max={field.max}
            value={String(value ?? '')}
            onChange={event => onChange(event.target.value)}
          />
          {field.unit}
        </span>
      )
    case 'date':
      return (
        <Input
          {...common}
          type="date"
          min={field.min}
          max={field.max}
          value={String(value ?? '')}
          onChange={event => onChange(event.target.value)}
        />
      )
    case 'select':
      return choice(field.options, value, onChange, common, t)
    case 'multi_select': {
      const selected = Array.isArray(value) ? (value as string[]) : []
      return (
        <div
          className="pod-chat-choice-form-options"
          role="group"
          aria-labelledby={`${common.id}-label`}
          aria-describedby={common['aria-describedby'] as string | undefined}>
          {field.options.map((option, index) => (
            <label key={option.value}>
              <Checkbox
                data-field={index === 0 ? field.id : undefined}
                disabled={common.disabled as boolean}
                aria-labelledby={`${common.id}-option-${index}`}
                aria-invalid={common['aria-invalid'] as boolean | undefined}
                checked={selected.includes(option.value)}
                onCheckedChange={checked =>
                  onChange(
                    field.options
                      .map(item => item.value)
                      .filter(item => (item === option.value ? checked : selected.includes(item)))
                  )
                }
              />
              <span id={`${common.id}-option-${index}`}>{option.label}</span>
            </label>
          ))}
        </div>
      )
    }
    // A boolean starts unanswered, so a required one means the user chose Yes or No.
    case 'boolean':
      return choice(
        [
          { value: 'true', label: t('pod.chat_form.yes') },
          { value: 'false', label: t('pod.chat_form.no') }
        ],
        value,
        onChange,
        common,
        t
      )
  }
}

function choice(
  options: { value: string; label: string }[],
  value: unknown,
  onChange: (value: unknown) => void,
  common: Record<string, unknown>,
  t: (key: string) => string
) {
  return (
    <Select value={typeof value === 'string' ? value : ''} onValueChange={next => onChange(next ?? '')}>
      <SelectTrigger {...common} className="w-full">
        <SelectValue placeholder={t('pod.chat_form.choose')} />
      </SelectTrigger>
      <SelectContent>
        {options.map(option => (
          <SelectItem key={option.value} value={option.value}>
            {option.label}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}

function itemsHint(
  field: Extract<ClarifyField, { type: 'multi_select' }>,
  t: (key: string, values?: Record<string, unknown>) => string
) {
  const { min_items: min, max_items: max } = field
  if (min && max) return t('pod.chat_form.items_range', { min, max })
  if (min) return t('pod.chat_form.items_min', { min })
  if (max) return t('pod.chat_form.items_max', { max })
  return undefined
}

function initial(field: ClarifyField): unknown {
  if (field.default !== undefined && field.default !== null) {
    return field.type === 'number' || field.type === 'boolean' ? String(field.default) : field.default
  }
  if (field.type === 'multi_select') return []
  return ''
}

/** Converts the draft into typed values and flags only what the browser can decide; the server checks the rest. */
export function collect(fields: ClarifyField[], draft: Draft) {
  const values: Record<string, unknown> = {}
  const errors: Record<string, string> = {}
  for (const field of fields) {
    const raw = draft[field.id]
    const empty =
      raw === undefined || (typeof raw === 'string' && !raw.trim()) || (Array.isArray(raw) && raw.length === 0)
    if (empty) {
      if (field.required) errors[field.id] = 'required'
      continue
    }
    if (field.type === 'number') {
      const number = Number(raw)
      if (!Number.isFinite(number)) errors[field.id] = 'invalid'
      else values[field.id] = number
    } else if (field.type === 'boolean') {
      values[field.id] = raw === 'true'
    } else {
      values[field.id] = typeof raw === 'string' ? raw.trim() : raw
    }
  }
  return { values, errors }
}
