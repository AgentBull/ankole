import { t } from 'i18next'
import { useTranslation } from 'react-i18next'
import { Button, Input, Popover, PopoverContent, PopoverTitle, PopoverTrigger } from '@ankole/uikit'
import { useState } from 'react'
import type { Condition, BaseField, Filter, Sort, Value } from '@ankole/applet-sdk/types'
import { Choice } from './content-primitives'
import { FieldInput, fieldOptions } from './base-fields'
import { principalUID } from './state/table-query'

const operators: Record<Condition['operator'], string> = {
  get is() {
    return t('pod.content.is')
  },
  get contains() {
    return t('pod.content.contains')
  },
  get is_empty() {
    return t('pod.content.is_empty')
  },
  get is_not_empty() {
    return t('pod.content.is_not_empty')
  },
  get gt() {
    return t('pod.content.greater_than')
  },
  get gte() {
    return t('pod.content.greater_than_or_equal_to')
  },
  get lt() {
    return t('pod.content.less_than')
  },
  get lte() {
    return t('pod.content.less_than_or_equal_to')
  },
  get text_contains() {
    return t('pod.content.contains_text')
  }
}

export function QueryControls({
  fields,
  pageID,
  filter,
  sort,
  update,
  disabled = false
}: {
  fields: BaseField[]
  pageID: string
  filter?: Filter
  sort?: Sort[]
  update(filter: Filter | undefined, sort: Sort[] | undefined): void
  disabled?: boolean
}) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const [conditions, setConditions] = useState<Condition[]>(filter?.conditions ?? [])
  const [conjunction, setConjunction] = useState<'and' | 'or'>(filter?.conjunction ?? 'and')
  const [ordering, setOrdering] = useState<Sort[]>(sort ?? [])
  const [attempted, setAttempted] = useState(false)
  const fieldNames = Object.fromEntries(fields.map(field => [field.id, field.name]))
  const openEditor = () => {
    if (disabled) return
    setConditions(filter?.conditions ?? [])
    setConjunction(filter?.conjunction ?? 'and')
    setOrdering(sort ?? [])
    setAttempted(false)
    setOpen(true)
  }
  const invalidConfiguration =
    conditions.some(condition => {
      const field = fields.find(field => field.id === condition.field_id)
      return !field || !Object.hasOwn(operatorsFor(field), condition.operator)
    }) || ordering.some(item => !fields.some(field => field.id === item.field_id))
  const missingValues = conditions.some(
    condition => !condition.operator.endsWith('empty') && (condition.value === null || condition.value === undefined)
  )
  return (
    <Popover
      open={open}
      onOpenChange={next => {
        if (disabled && next) return
        if (next) openEditor()
        else setOpen(false)
      }}>
      <PopoverTrigger disabled={disabled} render={<Button size="sm" variant="outline" />}>
        {t('pod.content.filter_and_sort')}
        {filter?.conditions.length || sort?.length
          ? ` · ${(filter?.conditions.length ?? 0) + (sort?.length ?? 0)}`
          : ''}
      </PopoverTrigger>
      <PopoverContent
        align="end"
        sideOffset={8}
        className="max-h-[min(70vh,var(--available-height))] w-[min(32rem,calc(100vw-2rem))] gap-3 overflow-y-auto">
        <PopoverTitle>{t('pod.content.filter_and_sort')}</PopoverTitle>
        <fieldset disabled={disabled} className="grid gap-4">
          {conditions.length >= 2 && (
            <Choice<'and' | 'or'>
              label={t('pod.content.combine_filters')}
              value={conjunction}
              onChange={setConjunction}
              options={{ and: t('pod.content.match_all_conditions'), or: t('pod.content.match_any_condition') }}
              disabled={disabled}
            />
          )}
          <div className="space-y-3">
            {conditions.map((condition, index) => (
              <div className="flex flex-wrap items-center gap-2" key={index}>
                <Choice
                  label={t('pod.content.filter_field')}
                  value={condition.field_id}
                  onChange={field_id =>
                    setConditions(
                      conditions.map((item, i) =>
                        i === index ? newCondition(fields.find(field => field.id === field_id)!) : item
                      )
                    )
                  }
                  options={{
                    ...(!fieldNames[condition.field_id]
                      ? { [condition.field_id]: t('pod.content.this_field_was_deleted_choose_another_field') }
                      : {}),
                    ...fieldNames
                  }}
                  disabled={disabled}
                />
                <Choice<string>
                  label={t('pod.content.filter_condition')}
                  value={condition.operator}
                  onChange={operator =>
                    setConditions(
                      conditions.map((item, i) =>
                        i === index
                          ? {
                              ...item,
                              operator: operator as Condition['operator'],
                              value: operator.endsWith('empty')
                                ? undefined
                                : item.operator.endsWith('empty')
                                  ? effectiveType(fields.find(field => field.id === item.field_id)!) === 'boolean'
                                    ? false
                                    : null
                                  : item.value
                            }
                          : item
                      )
                    )
                  }
                  options={operatorsFor(fields.find(field => field.id === condition.field_id))}
                  disabled={disabled || !fieldNames[condition.field_id]}
                />
                {!condition.operator.endsWith('empty') && (
                  <FilterValue
                    key={`${condition.field_id}:${condition.operator}`}
                    condition={condition}
                    field={fields.find(field => field.id === condition.field_id)}
                    pageID={pageID}
                    update={value =>
                      setConditions(conditions.map((item, i) => (i === index ? { ...item, value } : item)))
                    }
                  />
                )}
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() => setConditions(conditions.filter((_, i) => i !== index))}>
                  {t('pod.content.remove')}
                </Button>
              </div>
            ))}
            <Button
              size="sm"
              variant="outline"
              disabled={disabled || !fields.length}
              onClick={() => setConditions([...conditions, newCondition(fields[0]!)])}>
              {t('pod.content.add_filter_condition')}
            </Button>
          </div>
          <h3 className="text-sm font-semibold">{t('pod.content.sort')}</h3>
          <div className="space-y-3">
            {ordering.map((sort, index) => (
              <div className="flex gap-2" key={index}>
                <Choice
                  label={t('pod.content.sort_field')}
                  value={sort.field_id}
                  onChange={field_id =>
                    setOrdering(ordering.map((item, i) => (i === index ? { ...item, field_id } : item)))
                  }
                  options={{
                    ...(!fieldNames[sort.field_id]
                      ? { [sort.field_id]: t('pod.content.this_field_was_deleted_choose_another_field') }
                      : {}),
                    ...fieldNames
                  }}
                  disabled={disabled}
                />
                <Choice
                  label={t('pod.content.sort_direction')}
                  value={sort.direction}
                  onChange={direction =>
                    setOrdering(ordering.map((item, i) => (i === index ? { ...item, direction } : item)))
                  }
                  options={{ asc: t('pod.content.ascending'), desc: t('pod.content.descending') }}
                  disabled={disabled}
                />
                <Button
                  size="sm"
                  variant="ghost"
                  aria-label={t('pod.content.increase_priority_of_sort', { value1: index + 1 })}
                  disabled={disabled || index === 0}
                  onClick={() =>
                    setOrdering(
                      ordering.map((item, i) =>
                        i === index - 1 ? ordering[index]! : i === index ? ordering[index - 1]! : item
                      )
                    )
                  }>
                  ↑
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  aria-label={t('pod.content.decrease_priority_of_sort', { value1: index + 1 })}
                  disabled={disabled || index === ordering.length - 1}
                  onClick={() =>
                    setOrdering(
                      ordering.map((item, i) =>
                        i === index + 1 ? ordering[index]! : i === index ? ordering[index + 1]! : item
                      )
                    )
                  }>
                  ↓
                </Button>
                <Button size="sm" variant="ghost" onClick={() => setOrdering(ordering.filter((_, i) => i !== index))}>
                  {t('pod.content.remove')}
                </Button>
              </div>
            ))}
            <Button
              size="sm"
              variant="outline"
              disabled={disabled || fields.every(field => ordering.some(item => item.field_id === field.id))}
              onClick={() =>
                setOrdering([
                  ...ordering,
                  {
                    field_id: fields.find(field => !ordering.some(item => item.field_id === field.id))!.id,
                    direction: 'asc'
                  }
                ])
              }>
              {t('pod.content.add_sort_field')}
            </Button>
          </div>
        </fieldset>
        {invalidConfiguration && (
          <p role="alert" className="text-sm">
            {t('pod.content.enter_the_missing_filter_values_or_replace_deleted_fields_and')}
          </p>
        )}
        {missingValues && !invalidConfiguration && (
          <p role={attempted ? 'alert' : undefined} className="text-sm text-fg-tertiary">
            {t('pod.content.complete_filter_values')}
          </p>
        )}
        <p className="text-xs text-fg-tertiary">
          {t('pod.content.sorts_are_applied_in_order_from_top_to_bottom_filters')}
        </p>
        <div className="flex justify-end gap-2 border-t border-border pt-3">
          <Button variant="ghost" disabled={disabled} onClick={() => setOpen(false)}>
            {t('pod.content.cancel')}
          </Button>
          <Button
            variant="default"
            disabled={disabled || invalidConfiguration}
            onClick={() => {
              if (disabled || invalidConfiguration) return
              if (missingValues) {
                setAttempted(true)
                return
              }
              update(
                conditions.length
                  ? { conjunction: conditions.length >= 2 ? conjunction : 'and', conditions }
                  : undefined,
                ordering.length ? ordering : undefined
              )
              setOpen(false)
            }}>
            {t('pod.content.apply')}
          </Button>
        </div>
      </PopoverContent>
    </Popover>
  )
}

function effectiveType(field: BaseField) {
  if (field.type === 'formula') return String(field.config.result_type ?? 'text')
  if (field.type === 'auto_number') return 'number'
  if (['created_at', 'updated_at'].includes(field.type)) return 'datetime'
  if (['created_by', 'updated_by'].includes(field.type)) return 'person'
  if (field.type === 'checkbox') return 'boolean'
  if (['attachment', 'user', 'link'].includes(field.type) || (field.type === 'select' && field.config.multiple)) {
    return 'array'
  }
  return field.type
}

function operatorsFor(field?: BaseField) {
  const type = field ? effectiveType(field) : 'missing'
  const names: Condition['operator'][] =
    type === 'array'
      ? ['contains']
      : type === 'number' || type === 'datetime'
        ? ['is', 'gt', 'gte', 'lt', 'lte']
        : type === 'text'
          ? ['is', 'text_contains']
          : ['is']
  return Object.fromEntries(
    [...names, 'is_empty', 'is_not_empty'].map(key => [key, operators[key as Condition['operator']]])
  )
}

function newCondition(field: BaseField): Condition {
  const type = effectiveType(field)
  return {
    field_id: field.id,
    operator: type === 'array' ? 'contains' : 'is',
    value: type === 'boolean' ? false : null
  }
}

function FilterValue({
  condition,
  field,
  pageID,
  update
}: {
  condition: Condition
  field?: BaseField
  pageID: string
  update(value: Condition['value']): void
}) {
  const { t } = useTranslation()
  if (!field) return null
  if (field.type === 'attachment') {
    return (
      <Input
        variant="overlay"
        aria-label={t('pod.content.attachment_name')}
        value={
          condition.value && typeof condition.value === 'object' && 'name' in condition.value
            ? String(condition.value.name)
            : ''
        }
        onChange={event => update(event.target.value ? { name: event.target.value } : null)}
      />
    )
  }
  if (field.type === 'select' && condition.operator === 'contains') {
    return (
      <Choice
        label={t('pod.content.contains_option')}
        value={String(condition.value ?? '')}
        onChange={update}
        options={{
          '': t('pod.content.choose_an_option'),
          ...Object.fromEntries(fieldOptions(field).map(option => [option.id, option.name]))
        }}
      />
    )
  }
  const person = effectiveType(field) === 'person'
  const effective =
    field.type === 'formula' ||
    field.type === 'auto_number' ||
    ['created_at', 'updated_at', 'created_by', 'updated_by'].includes(field.type)
      ? {
          ...field,
          type:
            effectiveType(field) === 'number'
              ? ('number' as const)
              : effectiveType(field) === 'boolean'
                ? ('checkbox' as const)
                : effectiveType(field) === 'datetime'
                  ? ('datetime' as const)
                  : person
                    ? ('user' as const)
                    : ('text' as const)
        }
      : field
  const referenceContains = (['user', 'link'].includes(field.type) && condition.operator === 'contains') || person
  const selectedReference = person ? principalUID(condition.value) : condition.value ? String(condition.value) : null
  return (
    <FieldInput
      variant="overlay"
      commitOnChange
      pageID={pageID}
      field={referenceContains ? { ...effective, config: { ...effective.config, multiple: false } } : effective}
      value={referenceContains ? (selectedReference ? [selectedReference] : []) : (condition.value ?? null)}
      onChange={value =>
        update(
          referenceContains && Array.isArray(value)
            ? person
              ? principalUID((value.at(-1) as Value) ?? null)
              : ((value.at(-1) as string) ?? null)
            : value
        )
      }
    />
  )
}
