import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
  Field,
  FieldDescription,
  FieldError,
  FieldGroup,
  FieldLabel,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Switch,
  Textarea
} from '@ankole/uikit'
import { RiArrowDownSLine } from '@remixicon/react'
import { useEffect, useId, useRef, useState } from 'react'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import i18n from './i18n'

export type LocalizedText = Record<string, string> | null | undefined

export type ConfigFieldRequirement = {
  path: string
  value: unknown
}

export type ConfigFieldValidation =
  | {
      kind: 'json_object'
      message: Record<string, string>
      requiredStringProperties?: string[]
      stringPrefixes?: Record<string, string>
    }
  | {
      kind: 'pattern'
      message: Record<string, string>
      pattern: string
    }

export type ConfigFieldDefinition = {
  advanced?: boolean
  default?: unknown
  description?: LocalizedText
  label?: LocalizedText
  max?: number
  min?: number
  options?: Array<{ description?: LocalizedText; label?: LocalizedText; value: string }>
  path: string
  required?: boolean
  requiredWhen?: ConfigFieldRequirement[]
  type: string
  validation?: ConfigFieldValidation
}

export function ConfigFields({
  advancedLabel = i18n.t('common.advanced_settings'),
  config,
  fieldGroupClassName = 'grid gap-5 md:grid-cols-2',
  fields,
  locale,
  onChange,
  showAdvancedCount = true
}: {
  advancedLabel?: string
  config: JSONObject
  fieldGroupClassName?: string
  fields: ConfigFieldDefinition[]
  locale: string
  onChange(path: string, value: unknown, field: ConfigFieldDefinition): void
  showAdvancedCount?: boolean
}) {
  const basicFields = fields.filter(field => !field.advanced)
  const advancedFields = fields.filter(field => field.advanced)

  return (
    <>
      {basicFields.length > 0 ? (
        <FieldGroup className={fieldGroupClassName}>{basicFields.map(field => renderConfigField(field))}</FieldGroup>
      ) : null}
      {advancedFields.length > 0 ? (
        <Collapsible className="grid gap-4" defaultOpen={false}>
          <CollapsibleTrigger className="flex w-full items-center justify-between gap-3 border border-border/70 bg-card/60 px-4 py-3 text-left text-sm font-medium text-foreground">
            <span>{advancedLabel}</span>
            <span className="flex items-center gap-2 text-xs text-muted-foreground">
              {showAdvancedCount ? advancedFields.length : null}
              <RiArrowDownSLine className="size-4" aria-hidden />
            </span>
          </CollapsibleTrigger>
          <CollapsibleContent>
            <FieldGroup className={fieldGroupClassName}>
              {advancedFields.map(field => renderConfigField(field))}
            </FieldGroup>
          </CollapsibleContent>
        </Collapsible>
      ) : null}
    </>
  )

  function renderConfigField(field: ConfigFieldDefinition) {
    return (
      <ConfigField
        field={field}
        key={field.path}
        locale={locale}
        required={configFieldRequired(field, config)}
        value={getPath(config, field.path)}
        onChange={value => onChange(field.path, value, field)}
      />
    )
  }
}

export function ConfigField({
  field,
  locale,
  onChange,
  required = field.required === true,
  value
}: {
  field: ConfigFieldDefinition
  locale: string
  onChange(value: unknown): void
  required?: boolean
  value: unknown
}) {
  const label = localizedText(field.label, locale) ?? field.path
  const description = localizedText(field.description, locale)
  const controlID = useId()
  const descriptionID = `${controlID}-description`
  const errorID = `${controlID}-error`
  const inputRef = useRef<HTMLInputElement>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const [showValidationError, setShowValidationError] = useState(false)
  const validationError =
    required || !field.requiredWhen?.length ? configFieldValidationMessage(field, value, locale) : undefined
  const describedBy = [
    description ? descriptionID : undefined,
    showValidationError && validationError ? errorID : undefined
  ]
    .filter(Boolean)
    .join(' ')

  useEffect(() => {
    inputRef.current?.setCustomValidity(validationError ?? '')
    textareaRef.current?.setCustomValidity(validationError ?? '')
    if (!validationError) setShowValidationError(false)
  }, [validationError])

  const labelContent = (
    <>
      {label}
      {required ? <span className="ml-1 font-normal text-muted-foreground">{i18n.t('common.required')}</span> : null}
    </>
  )

  if (field.type === 'boolean') {
    return (
      <Field>
        <FieldLabel>{labelContent}</FieldLabel>
        <FieldLabel
          htmlFor={controlID}
          className="h-10 w-full cursor-pointer items-center justify-between border border-transparent border-b-input bg-field px-4 text-sm font-normal transition-[background-color,border-color] has-data-checked:border-transparent has-data-checked:border-b-input has-data-checked:bg-field has-focus-visible:border-b-ring dark:has-data-checked:border-transparent dark:has-data-checked:border-b-input dark:has-data-checked:bg-field">
          <span>{i18n.t('common.enable')}</span>
          <Switch
            id={controlID}
            aria-describedby={description ? descriptionID : undefined}
            aria-required={required || undefined}
            checked={Boolean(value)}
            onCheckedChange={onChange}
          />
        </FieldLabel>
        {description ? <FieldDescription id={descriptionID}>{description}</FieldDescription> : null}
      </Field>
    )
  }

  if (field.type === 'select') {
    const options = field.options ?? []

    return (
      <Field>
        <FieldLabel htmlFor={controlID}>{labelContent}</FieldLabel>
        <Select
          required={required}
          value={typeof value === 'string' ? value : ''}
          onValueChange={next => onChange(next ?? '')}>
          <SelectTrigger
            id={controlID}
            aria-describedby={description ? descriptionID : undefined}
            aria-required={required || undefined}
            className="w-full">
            <SelectValue />
          </SelectTrigger>
          <SelectContent emptyLabel={i18n.t('common.select_empty')}>
            {options.map(option => (
              <SelectItem key={option.value} value={option.value}>
                {localizedText(option.label, locale) ?? option.value}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        {description ? <FieldDescription id={descriptionID}>{description}</FieldDescription> : null}
      </Field>
    )
  }

  if (field.type === 'string_array') {
    return (
      <Field>
        <FieldLabel htmlFor={controlID}>{labelContent}</FieldLabel>
        <Textarea
          id={controlID}
          ref={textareaRef}
          aria-describedby={describedBy || undefined}
          aria-invalid={showValidationError && validationError ? true : undefined}
          required={required}
          value={Array.isArray(value) ? value.join('\n') : ''}
          onChange={event =>
            // Accept both newline and comma input because setup fields often copy
            // from provider consoles or docs with different list formats.
            onChange(
              event.target.value
                .split(/\n|,/)
                .map(item => item.trim())
                .filter(Boolean)
            )
          }
          onBlur={() => setShowValidationError(Boolean(validationError))}
          onInvalid={() => setShowValidationError(Boolean(validationError))}
        />
        {description ? <FieldDescription id={descriptionID}>{description}</FieldDescription> : null}
        {showValidationError && validationError ? <FieldError id={errorID}>{validationError}</FieldError> : null}
      </Field>
    )
  }

  return (
    <Field>
      <FieldLabel htmlFor={controlID}>{labelContent}</FieldLabel>
      <Input
        id={controlID}
        ref={inputRef}
        aria-describedby={describedBy || undefined}
        aria-invalid={showValidationError && validationError ? true : undefined}
        max={field.max}
        min={field.min}
        required={required}
        type={field.type === 'secret' ? 'password' : field.type === 'integer' ? 'number' : 'text'}
        value={value == null ? '' : String(value)}
        onChange={event => onChange(field.type === 'integer' ? Number(event.target.value) : event.target.value)}
        onBlur={() => setShowValidationError(Boolean(validationError))}
        onInvalid={() => setShowValidationError(Boolean(validationError))}
      />
      {description ? <FieldDescription id={descriptionID}>{description}</FieldDescription> : null}
      {showValidationError && validationError ? <FieldError id={errorID}>{validationError}</FieldError> : null}
    </Field>
  )
}

export function configFieldValidationMessage(
  field: ConfigFieldDefinition,
  value: unknown,
  locale: string
): string | undefined {
  const validation = field.validation
  if (!validation || configFieldValueEmpty(value)) return undefined

  const message = localizedText(validation.message, locale) ?? localizedText(validation.message, 'default')

  if (validation.kind === 'pattern') {
    const values = Array.isArray(value) ? value : [value]
    const pattern = new RegExp(validation.pattern)

    return values.every(item => typeof item === 'string' && pattern.test(item.trim())) ? undefined : message
  }

  if (typeof value !== 'string') return message

  try {
    const object = JSON.parse(value)
    if (!object || typeof object !== 'object' || Array.isArray(object)) return message

    const requiredPropertiesValid = (validation.requiredStringProperties ?? []).every(
      property => typeof object[property] === 'string' && object[property].trim() !== ''
    )
    const prefixesValid = Object.entries(validation.stringPrefixes ?? {}).every(
      ([property, prefix]) => typeof object[property] === 'string' && object[property].startsWith(prefix)
    )

    return requiredPropertiesValid && prefixesValid ? undefined : message
  } catch {
    return message
  }
}

export function configFieldRequired(field: ConfigFieldDefinition, config: JSONObject): boolean {
  if (field.required) return true
  if (!field.requiredWhen?.length) return false

  return field.requiredWhen.every(requirement => getPath(config, requirement.path) === requirement.value)
}

export function configFieldsValid(fields: ConfigFieldDefinition[], config: JSONObject, locale: string): boolean {
  return fields.every(field => {
    const value = getPath(config, field.path)
    if (configFieldRequired(field, config) && configFieldValueEmpty(value)) return false
    return !configFieldValidationMessage(field, value, locale)
  })
}

function configFieldValueEmpty(value: unknown): boolean {
  if (value == null) return true
  if (typeof value === 'string') return value.trim() === ''
  if (Array.isArray(value)) return value.length === 0
  return false
}

export function localizedText(value: LocalizedText, locale: string): string | undefined {
  if (!value) return undefined
  if (typeof value !== 'object' || Array.isArray(value)) return undefined

  return value[locale] ?? value.default
}

export function defaultConfig(fields: ConfigFieldDefinition[]): JSONObject {
  return fields.reduce<JSONObject>((config, field) => setPath(config, field.path, defaultValue(field)), {})
}

export function defaultValue(field: ConfigFieldDefinition): unknown {
  if (field.default !== undefined) return field.default
  if (field.type === 'boolean') return false
  if (field.type === 'integer') return 0
  if (field.type === 'string_array') return []
  if (field.type === 'select') return field.options?.[0]?.value ?? ''
  return ''
}

export function getPath(source: JSONObject, path: string): unknown {
  return path.split('.').reduce<unknown>((value, segment) => {
    if (value && typeof value === 'object' && !Array.isArray(value)) return (value as JSONObject)[segment]
    return undefined
  }, source)
}

export function setPath(source: JSONObject, path: string, value: unknown): JSONObject {
  const segments = path.split('.')
  const [head, ...rest] = segments

  if (!head) return source
  if (rest.length === 0) return { ...source, [head]: value }

  const current = source[head]
  const child = current && typeof current === 'object' && !Array.isArray(current) ? (current as JSONObject) : {}

  return {
    ...source,
    [head]: setPath(child, rest.join('.'), value)
  }
}
