import {
  Checkbox,
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
  Field,
  FieldDescription,
  FieldGroup,
  FieldLabel,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Textarea
} from '@ankole/uikit'
import { RiArrowDownSLine } from '@remixicon/react'
import type { JsonObject } from '@pleisto/active-support'
import i18n from './i18n'

export type LocalizedText = Record<string, string> | null | undefined

export type ConfigFieldDefinition = {
  default?: unknown
  description?: LocalizedText
  label?: LocalizedText
  max?: number
  min?: number
  options?: Array<{ description?: LocalizedText; label?: LocalizedText; value: string }>
  path: string
  advanced?: boolean
  required?: boolean
  type: string
}

export function ConfigFields({
  advancedLabel = i18n.t('common.advanced_settings'),
  config,
  fieldGroupClassName = 'grid gap-5 md:grid-cols-2',
  fields,
  locale,
  onChange
}: {
  advancedLabel?: string
  config: JsonObject
  fieldGroupClassName?: string
  fields: ConfigFieldDefinition[]
  locale: string
  onChange(path: string, value: unknown, field: ConfigFieldDefinition): void
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
              {advancedFields.length}
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
  value
}: {
  field: ConfigFieldDefinition
  locale: string
  onChange(value: unknown): void
  value: unknown
}) {
  const label = localizedText(field.label, locale) ?? field.path
  const description = localizedText(field.description, locale)

  if (field.type === 'boolean') {
    return (
      <Field orientation="horizontal" className="items-center justify-between border border-border/70 bg-card/60 p-4">
        <div className="grid gap-1">
          <FieldLabel>{label}</FieldLabel>
          {description ? <FieldDescription>{description}</FieldDescription> : null}
        </div>
        <Checkbox checked={Boolean(value)} onCheckedChange={checked => onChange(checked === true)} />
      </Field>
    )
  }

  if (field.type === 'select') {
    const options = field.options ?? []

    return (
      <Field>
        <FieldLabel>{label}</FieldLabel>
        <Select value={typeof value === 'string' ? value : ''} onValueChange={next => onChange(next ?? '')}>
          <SelectTrigger className="w-full">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {options.map(option => (
              <SelectItem key={option.value} value={option.value}>
                {localizedText(option.label, locale) ?? option.value}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        {description ? <FieldDescription>{description}</FieldDescription> : null}
      </Field>
    )
  }

  if (field.type === 'string_array') {
    return (
      <Field>
        <FieldLabel>{label}</FieldLabel>
        <Textarea
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
        />
        {description ? <FieldDescription>{description}</FieldDescription> : null}
      </Field>
    )
  }

  return (
    <Field>
      <FieldLabel>{label}</FieldLabel>
      <Input
        max={field.max}
        min={field.min}
        type={field.type === 'secret' ? 'password' : field.type === 'integer' ? 'number' : 'text'}
        value={value == null ? '' : String(value)}
        onChange={event => onChange(field.type === 'integer' ? Number(event.target.value) : event.target.value)}
      />
      {description ? <FieldDescription>{description}</FieldDescription> : null}
    </Field>
  )
}

export function localizedText(value: LocalizedText, locale: string): string | undefined {
  if (!value) return undefined
  if (typeof value !== 'object' || Array.isArray(value)) return undefined

  return value[locale] ?? value.default
}

export function defaultConfig(fields: ConfigFieldDefinition[]): JsonObject {
  return fields.reduce<JsonObject>((config, field) => setPath(config, field.path, defaultValue(field)), {})
}

export function defaultValue(field: ConfigFieldDefinition): unknown {
  if (field.default !== undefined) return field.default
  if (field.type === 'boolean') return false
  if (field.type === 'integer') return 0
  if (field.type === 'string_array') return []
  if (field.type === 'select') return field.options?.[0]?.value ?? ''
  return ''
}

export function getPath(source: JsonObject, path: string): unknown {
  return path.split('.').reduce<unknown>((value, segment) => {
    if (value && typeof value === 'object' && !Array.isArray(value)) return (value as JsonObject)[segment]
    return undefined
  }, source)
}

export function setPath(source: JsonObject, path: string, value: unknown): JsonObject {
  const segments = path.split('.')
  const [head, ...rest] = segments

  if (!head) return source
  if (rest.length === 0) return { ...source, [head]: value }

  const current = source[head]
  const child = current && typeof current === 'object' && !Array.isArray(current) ? (current as JsonObject) : {}

  return {
    ...source,
    [head]: setPath(child, rest.join('.'), value)
  }
}
