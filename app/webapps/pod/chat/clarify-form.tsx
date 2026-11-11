import {
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
import { useBoundProp, type ComponentRenderProps } from '@json-render/react'
import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import type { ClarifyField } from './types'

type Draft = Record<string, unknown>

/** The spec props of one field of a structured clarify form; `value`, `error` and `edited` are bound to its draft. */
export type ClarifyFieldProps = {
  field: ClarifyField
  value: unknown
  /** The error code that the card's own check left for this field. */
  error: unknown
  /** The error code that the control plane returned for this field, and the submission that it rejected. */
  rejected?: string
  rejection?: number
  /** The rejected submission that was current when the field was last edited. */
  edited: unknown
  disabled: boolean
}

/**
 * Renders one field of a structured clarify form in the interaction surface. The control plane validates the
 * submission again and owns the result.
 */
export function ClarifyFieldControl({ element, bindings }: ComponentRenderProps<ClarifyFieldProps>) {
  const { field, disabled } = element.props
  const { t } = useTranslation()
  const controlID = `${useId()}-${field.id}`
  const [value, setValue] = useBoundProp<unknown>(element.props.value, bindings?.value)
  const { rejected, rejection } = element.props
  const [code, setCode] = useBoundProp<unknown>(element.props.error, bindings?.error)
  const [edited, setEdited] = useBoundProp<unknown>(element.props.edited, bindings?.edited)
  const checked = typeof code === 'string' ? code : undefined
  // An edited field drops the error it had; the next submission checks it again.
  const error = checked ?? (edited === rejection ? undefined : rejected)
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
  const change = (next: unknown) => {
    setValue(next)
    if (checked) setCode(undefined)
    if (edited !== rejection) setEdited(rejection)
  }
  return (
    <Field data-disabled={disabled || undefined}>
      <FieldLabel htmlFor={field.type === 'multi_select' ? undefined : controlID} id={`${controlID}-label`}>
        {field.label}
        {!field.required && (
          <span className="ml-1 font-normal text-muted-foreground">{t('pod.chat_form.optional')}</span>
        )}
      </FieldLabel>
      {control(field, value, change, common, t)}
      {field.help && <FieldDescription id={`${controlID}-help`}>{field.help}</FieldDescription>}
      {hint && <FieldDescription id={`${controlID}-hint`}>{hint}</FieldDescription>}
      {error && (
        <FieldError id={`${controlID}-error`}>
          {t(`pod.chat_form.errors.${error}`, { defaultValue: t('pod.chat_form.errors.invalid') })}
        </FieldError>
      )}
    </Field>
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

/** The draft that a form starts from: each field's default, or an empty answer. */
export function initialDraft(fields: ClarifyField[]): Draft {
  return Object.fromEntries(
    fields.map(field => {
      if (field.default !== undefined && field.default !== null) {
        return [field.id, field.type === 'number' || field.type === 'boolean' ? String(field.default) : field.default]
      }
      return [field.id, field.type === 'multi_select' ? [] : '']
    })
  )
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
