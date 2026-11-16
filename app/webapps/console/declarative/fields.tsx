import { Button, Input, Select, SelectContent, SelectItem, SelectTrigger, SelectValue, Switch } from '@ankole/uikit'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { LabeledField } from '../console-form'
import { asRecord, formatIdentifierLabel } from './transport'
import type { DeclarativeFieldDescriptor, DeclarativeRuleSection } from './types'

export type DeclarativeDraft = Record<string, unknown>

export function DeclarativeSelect({
  label,
  value,
  options,
  disabled,
  onChange
}: {
  label: string
  value: string
  options: readonly (readonly [string, string])[]
  disabled?: boolean
  onChange: (value: string) => void
}) {
  return (
    <Select
      disabled={disabled}
      items={options.map(([val, text]) => ({ value: val, label: text }))}
      value={value}
      onValueChange={next => {
        if (next !== null) onChange(next)
      }}>
      <SelectTrigger aria-label={label}>
        <SelectValue placeholder={label} />
      </SelectTrigger>
      <SelectContent>
        {options.map(([optionValue, optionLabel]) => (
          <SelectItem key={optionValue} value={optionValue}>
            {optionLabel}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}

export function draftAt(root: unknown, path: readonly string[]): DeclarativeDraft {
  return asRecord(path.reduce<unknown>((cursor, segment) => asRecord(cursor)[segment], root))
}

export function setDraftAt(root: DeclarativeDraft, path: readonly string[], value: unknown): DeclarativeDraft {
  if (path.length === 0) return asRecord(value)
  const [head, ...tail] = path
  if (!head) return root
  if (tail.length === 0) return { ...root, [head]: value }
  return { ...root, [head]: setDraftAt(asRecord(root[head]), tail, value) }
}

function KeyValueEditor({
  descriptor,
  label,
  value,
  disabled,
  i18nPrefix,
  onChange
}: {
  descriptor: DeclarativeFieldDescriptor
  label: string
  value: unknown
  disabled?: boolean
  i18nPrefix: string
  onChange: (next: Record<string, unknown>) => void
}) {
  const { t } = useTranslation()
  const record = asRecord(value)
  const [extraRows, setExtraRows] = useState<readonly (readonly [string, string])[]>([])
  const savedPairs = Object.entries(record).map(([key, item]) => [key, item == null ? '' : String(item)] as const)
  const rows = [...savedPairs, ...extraRows]

  const keyLabel = t(descriptor.keyLabelKey ?? 'common.key', { defaultValue: 'Key' })
  const valueLabel = t(descriptor.valueLabelKey ?? 'common.value', { defaultValue: 'Value' })

  const commitPairs = (
    nextSaved: readonly (readonly [string, string])[],
    nextExtra: readonly (readonly [string, string])[]
  ) => {
    setExtraRows(nextExtra)
    const nextRecord: Record<string, unknown> = {}
    for (const [k, v] of nextSaved) {
      const trimmed = k.trim()
      if (!trimmed) continue
      nextRecord[trimmed] = descriptor.valueType === 'number' && v !== '' ? Number(v) : v
    }
    onChange(nextRecord)
  }

  return (
    <fieldset className="grid gap-3 border border-border p-3">
      <legend className="px-1 text-sm font-medium">{label}</legend>
      {rows.map(([rowKey, rowValue], index) => {
        const isExtra = index >= savedPairs.length
        return (
          <div key={`${index}-${rowKey}`} className="grid gap-2 sm:grid-cols-[1fr_1fr_auto]">
            <Input
              aria-label={`${keyLabel} ${index + 1}`}
              autoCapitalize="none"
              autoComplete="off"
              disabled={disabled}
              placeholder={keyLabel}
              spellCheck={false}
              value={rowKey}
              onChange={event => {
                const updated: readonly [string, string] = [event.target.value, rowValue]
                if (isExtra) {
                  const nextExtra = extraRows.map((entry, idx) => (idx === index - savedPairs.length ? updated : entry))
                  if (event.target.value.trim()) {
                    commitPairs(
                      [...savedPairs, updated],
                      extraRows.filter((_, idx) => idx !== index - savedPairs.length)
                    )
                  } else {
                    setExtraRows(nextExtra)
                  }
                } else {
                  commitPairs(
                    savedPairs.map((entry, idx) => (idx === index ? updated : entry)),
                    extraRows
                  )
                }
              }}
            />
            <Input
              aria-label={`${valueLabel} ${index + 1}`}
              autoCapitalize="none"
              autoComplete="off"
              disabled={disabled}
              placeholder={valueLabel}
              spellCheck={false}
              type={descriptor.valueType === 'number' ? 'number' : 'text'}
              value={rowValue}
              onChange={event => {
                const updated: readonly [string, string] = [rowKey, event.target.value]
                if (isExtra) {
                  setExtraRows(extraRows.map((entry, idx) => (idx === index - savedPairs.length ? updated : entry)))
                } else {
                  commitPairs(
                    savedPairs.map((entry, idx) => (idx === index ? updated : entry)),
                    extraRows
                  )
                }
              }}
            />
            <Button
              disabled={disabled}
              size="sm"
              type="button"
              variant="outline"
              onClick={() => {
                if (isExtra) {
                  setExtraRows(extraRows.filter((_, idx) => idx !== index - savedPairs.length))
                } else {
                  commitPairs(
                    savedPairs.filter((_, idx) => idx !== index),
                    extraRows
                  )
                }
              }}>
              {t(`${i18nPrefix}.ui.remove`, { defaultValue: t('common.delete', { defaultValue: 'Remove' }) })}
            </Button>
          </div>
        )
      })}
      <div>
        <Button
          disabled={disabled}
          size="sm"
          type="button"
          variant="outline"
          onClick={() => setExtraRows([...extraRows, ['', '']])}>
          {t(`${i18nPrefix}.ui.add`, { defaultValue: t('common.add', { defaultValue: 'Add entry' }) })}
        </Button>
      </div>
    </fieldset>
  )
}

function SignalTreeNodeEditor({
  node,
  opOptions,
  signalOptions,
  disabled,
  i18nPrefix,
  onChange,
  onRemove
}: {
  node: Record<string, unknown>
  opOptions: readonly string[]
  signalOptions: readonly string[]
  disabled?: boolean
  i18nPrefix: string
  onChange: (next: Record<string, unknown>) => void
  onRemove?: () => void
}) {
  const { t } = useTranslation()
  const rawOp = typeof node.op === 'string' && opOptions.includes(node.op) ? node.op : (opOptions[0] ?? 'signal')
  const children = Array.isArray(node.children) ? node.children.map(asRecord) : []

  const switchOp = (nextOp: string) => {
    if (nextOp === 'signal') {
      onChange({ op: 'signal', signal: typeof node.signal === 'string' ? node.signal : (signalOptions[0] ?? '') })
    } else if (nextOp === 'not') {
      onChange({
        op: 'not',
        child: node.child ? asRecord(node.child) : (children[0] ?? { op: 'signal', signal: signalOptions[0] ?? '' })
      })
    } else {
      onChange({
        op: nextOp,
        children: children.length > 0 ? children : [{ op: 'signal', signal: signalOptions[0] ?? '' }]
      })
    }
  }

  return (
    <div className="grid gap-2 border border-border p-2.5">
      <div className="flex flex-wrap items-center gap-2">
        <DeclarativeSelect
          disabled={disabled}
          label={t(`${i18nPrefix}.field.op`, { defaultValue: 'Operator' })}
          options={opOptions.map(val => [val, t(`${i18nPrefix}.value.${val}`, { defaultValue: val.toUpperCase() })])}
          value={rawOp}
          onChange={switchOp}
        />

        {rawOp === 'signal' ? (
          signalOptions.length > 0 ? (
            <DeclarativeSelect
              disabled={disabled}
              label={t(`${i18nPrefix}.field.signal`, { defaultValue: 'Signal' })}
              options={signalOptions.map(val => [val, t(`${i18nPrefix}.value.${val}`, { defaultValue: val })])}
              value={String(node.signal ?? '')}
              onChange={nextSignal => onChange({ op: 'signal', signal: nextSignal })}
            />
          ) : (
            <Input
              aria-label={t(`${i18nPrefix}.field.signal`, { defaultValue: 'Signal' })}
              autoCapitalize="none"
              autoComplete="off"
              className="min-w-44 flex-1"
              disabled={disabled}
              placeholder="signal"
              spellCheck={false}
              value={String(node.signal ?? '')}
              onChange={event => onChange({ op: 'signal', signal: event.target.value })}
            />
          )
        ) : null}

        {onRemove ? (
          <Button disabled={disabled} size="sm" type="button" variant="outline" onClick={onRemove}>
            {t(`${i18nPrefix}.ui.remove`, { defaultValue: t('common.delete', { defaultValue: 'Remove' }) })}
          </Button>
        ) : null}
      </div>

      {rawOp === 'not' ? (
        <div className="pl-4">
          <SignalTreeNodeEditor
            disabled={disabled}
            i18nPrefix={i18nPrefix}
            node={asRecord(node.child)}
            opOptions={opOptions}
            signalOptions={signalOptions}
            onChange={nextChild => onChange({ op: 'not', child: nextChild })}
          />
        </div>
      ) : null}

      {rawOp === 'and' || rawOp === 'or' ? (
        <div className="grid gap-2 pl-4">
          {children.map((childNode, idx) => (
            <SignalTreeNodeEditor
              key={idx}
              disabled={disabled}
              i18nPrefix={i18nPrefix}
              node={childNode}
              opOptions={opOptions}
              signalOptions={signalOptions}
              onChange={nextChild =>
                onChange({
                  op: rawOp,
                  children: children.map((entry, entryIdx) => (entryIdx === idx ? nextChild : entry))
                })
              }
              onRemove={() =>
                onChange({
                  op: rawOp,
                  children: children.filter((_, entryIdx) => entryIdx !== idx)
                })
              }
            />
          ))}
          <div>
            <Button
              disabled={disabled}
              size="sm"
              type="button"
              variant="outline"
              onClick={() =>
                onChange({
                  op: rawOp,
                  children: [...children, { op: 'signal', signal: signalOptions[0] ?? '' }]
                })
              }>
              {t(`${i18nPrefix}.ui.add`, { defaultValue: t('common.add', { defaultValue: 'Add child' }) })}
            </Button>
          </div>
        </div>
      ) : null}
    </div>
  )
}

function SignalRuleTreeEditor({
  section,
  draft,
  disabled,
  i18nPrefix,
  onChange
}: {
  section: DeclarativeRuleSection
  draft: DeclarativeDraft
  disabled?: boolean
  i18nPrefix: string
  onChange: (next: DeclarativeDraft) => void
}) {
  const { t } = useTranslation()
  const current = draftAt(draft, section.path)
  const hasNode = Object.keys(current).length > 0

  const sectionLabel = t(section.labelKey ?? `${i18nPrefix}.rule_section.${section.id}`, {
    defaultValue: formatIdentifierLabel(section.id)
  })
  const opField = section.fields.find(field => field.name === 'op')
  const signalField = section.fields.find(field => field.name === 'signal')
  const opOptions = opField?.enumValues ?? ['and', 'or', 'not', 'signal']
  const signalOptions = signalField?.enumValues ?? []

  const clearTree = () => {
    if (section.path.length === 2 && section.path[0] && section.path[1]) {
      const parent = asRecord(draft[section.path[0]])
      delete parent[section.path[1]]
      onChange({ ...draft, [section.path[0]]: parent })
    }
  }

  return (
    <fieldset className="grid gap-3 border border-border p-3">
      <legend className="px-1 text-sm font-medium">{sectionLabel}</legend>
      {hasNode ? (
        <div className="grid gap-2">
          <SignalTreeNodeEditor
            disabled={disabled}
            i18nPrefix={i18nPrefix}
            node={current}
            opOptions={opOptions}
            signalOptions={signalOptions}
            onChange={nextNode => onChange(setDraftAt(draft, section.path, nextNode))}
            onRemove={clearTree}
          />
        </div>
      ) : (
        <div>
          <Button
            disabled={disabled}
            size="sm"
            type="button"
            variant="outline"
            onClick={() =>
              onChange(
                setDraftAt(draft, section.path, {
                  op: opOptions.includes('and') ? 'and' : (opOptions[0] ?? 'signal'),
                  children: [{ op: 'signal', signal: signalOptions[0] ?? '' }]
                })
              )
            }>
            {t(`${i18nPrefix}.ui.add`, { defaultValue: t('common.add', { defaultValue: 'Add rule tree' }) })}
          </Button>
        </div>
      )}
    </fieldset>
  )
}

function DeclarativeField({
  descriptor,
  value,
  draft,
  disabled,
  i18nPrefix,
  ruleSchema,
  onChange,
  onChangeDraft
}: {
  descriptor: DeclarativeFieldDescriptor
  value: unknown
  draft: DeclarativeDraft
  disabled?: boolean
  i18nPrefix: string
  ruleSchema?: readonly DeclarativeRuleSection[] | null
  onChange: (value: unknown) => void
  onChangeDraft: (next: DeclarativeDraft) => void
}) {
  const { t } = useTranslation()
  const label = t(descriptor.labelKey, { defaultValue: formatIdentifierLabel(descriptor.name) })
  const description = descriptor.descriptionKey
    ? t(descriptor.descriptionKey, { defaultValue: '' }) || undefined
    : undefined
  const isDisabled = Boolean(disabled || descriptor.readOnly)

  if (descriptor.type === 'rule_tree' && ruleSchema && ruleSchema.length > 0) {
    return (
      <div className="grid gap-3">
        {ruleSchema.map(section => {
          if (section.kind === 'tree') {
            return (
              <SignalRuleTreeEditor
                key={section.id}
                section={section}
                draft={draft}
                disabled={isDisabled}
                i18nPrefix={i18nPrefix}
                onChange={onChangeDraft}
              />
            )
          }
          const sectionLabel = t(section.labelKey ?? `${i18nPrefix}.rule_section.${section.id}`, {
            defaultValue: formatIdentifierLabel(section.id)
          })
          const sectionDraft = section.path.length === 0 ? draft : draftAt(draft, section.path)
          return (
            <fieldset key={section.id} className="grid gap-3 border border-border p-3">
              <legend className="px-1 text-sm font-medium">{sectionLabel}</legend>
              <DeclarativeFields
                disabled={isDisabled}
                draft={sectionDraft}
                fields={section.fields}
                i18nPrefix={i18nPrefix}
                onChange={nextSection =>
                  onChangeDraft(
                    section.path.length === 0
                      ? { ...draft, ...nextSection }
                      : setDraftAt(draft, section.path, nextSection)
                  )
                }
              />
            </fieldset>
          )
        })}
      </div>
    )
  }

  if (descriptor.type === 'object') {
    const nestedFields = descriptor.fields ?? []
    if (nestedFields.length > 0) {
      const nestedRecord = asRecord(value)
      return (
        <fieldset className="grid gap-3 border border-border p-3">
          <legend className="px-1 text-sm font-medium">{label}</legend>
          <DeclarativeFields
            disabled={isDisabled}
            draft={nestedRecord}
            fields={nestedFields}
            i18nPrefix={i18nPrefix}
            onChange={onChange}
          />
        </fieldset>
      )
    }
    return (
      <KeyValueEditor
        descriptor={{ ...descriptor, type: 'key_value' }}
        disabled={isDisabled}
        i18nPrefix={i18nPrefix}
        label={label}
        value={value}
        onChange={onChange}
      />
    )
  }

  if (descriptor.type === 'key_value' || (descriptor.type === 'json' && !descriptor.readOnly)) {
    return (
      <KeyValueEditor
        descriptor={descriptor}
        disabled={isDisabled}
        i18nPrefix={i18nPrefix}
        label={label}
        value={value}
        onChange={onChange}
      />
    )
  }

  if (descriptor.type === 'enum' && descriptor.enumValues) {
    return (
      <LabeledField description={description} label={label} required={descriptor.required}>
        <DeclarativeSelect
          disabled={isDisabled}
          label={label}
          options={descriptor.enumValues.map(id => [
            id,
            t(`${i18nPrefix}.value.${id}`, { defaultValue: formatIdentifierLabel(id) })
          ])}
          value={String(value ?? descriptor.defaultValue ?? '')}
          onChange={onChange}
        />
      </LabeledField>
    )
  }

  if (descriptor.type === 'boolean') {
    return (
      <LabeledField description={description} label={label}>
        <Switch aria-label={label} checked={Boolean(value)} disabled={isDisabled} onCheckedChange={onChange} />
      </LabeledField>
    )
  }

  const isDate = descriptor.type === 'datetime'
  const isNumber = descriptor.type === 'integer' || descriptor.type === 'number'
  const isSecret = descriptor.type === 'secret'
  const isArray = descriptor.type === 'string_array'

  return (
    <LabeledField
      description={
        isArray
          ? t(`${i18nPrefix}.ui.separate_values`, { defaultValue: 'Separate multiple values with commas.' })
          : description
      }
      label={label}
      required={descriptor.required}>
      {isDate && descriptor.expiryPresets && descriptor.expiryPresets.length > 0 ? (
        <DeclarativeSelect
          disabled={isDisabled}
          label={t(`${i18nPrefix}.ui.expiry_preset`, { defaultValue: 'Expiry preset' })}
          options={[
            ['none', t(`${i18nPrefix}.ui.no_expiry`, { defaultValue: 'No expiry' })],
            ...descriptor.expiryPresets.map(
              days =>
                [
                  String(days),
                  t(`${i18nPrefix}.ui.expiry_days`, { count: days, defaultValue: `${days} days` })
                ] as const
            )
          ]}
          value=""
          onChange={days => {
            if (days === 'none') {
              onChange('')
              return
            }
            const next = new Date(Date.now() + Number(days) * 86_400_000)
            next.setMinutes(next.getMinutes() - next.getTimezoneOffset())
            onChange(next.toISOString().slice(0, descriptor.inputUnit === 'date' ? 10 : 16))
          }}
        />
      ) : null}

      <Input
        autoCapitalize="none"
        autoComplete={isSecret ? 'new-password' : 'off'}
        disabled={isDisabled}
        max={descriptor.max}
        min={descriptor.min}
        placeholder={descriptor.placeholderKey ? t(descriptor.placeholderKey) : undefined}
        required={descriptor.required}
        spellCheck={false}
        step={descriptor.type === 'integer' ? 1 : descriptor.type === 'number' ? 'any' : undefined}
        type={
          isNumber
            ? 'number'
            : isDate
              ? descriptor.inputUnit === 'date'
                ? 'date'
                : 'datetime-local'
              : isSecret
                ? 'password'
                : 'text'
        }
        value={
          Array.isArray(value)
            ? value.join(', ')
            : isDate && value
              ? String(value).slice(0, descriptor.inputUnit === 'date' ? 10 : 16)
              : typeof value === 'object' && value !== null
                ? JSON.stringify(value)
                : String(value ?? '')
        }
        onChange={event => onChange(event.target.value)}
      />
    </LabeledField>
  )
}

export function DeclarativeFields({
  fields,
  draft,
  disabled,
  i18nPrefix = 'console',
  ruleSchema,
  onChange
}: {
  fields: readonly DeclarativeFieldDescriptor[]
  draft: DeclarativeDraft
  disabled?: boolean
  i18nPrefix?: string
  ruleSchema?: readonly DeclarativeRuleSection[] | null
  onChange: (next: DeclarativeDraft) => void
}) {
  const safeDraft = asRecord(draft)
  const rootRuleFieldNames = new Set(
    ruleSchema && fields.some(field => field.type === 'rule_tree')
      ? ruleSchema
          .filter(section => section.path.length === 0)
          .flatMap(section => section.fields.map(item => item.name))
      : []
  )
  const visibleFields = fields.filter(field => !rootRuleFieldNames.has(field.name))

  return (
    <div className="grid gap-4">
      {visibleFields.map(descriptor => (
        <DeclarativeField
          key={descriptor.name}
          descriptor={descriptor}
          disabled={disabled}
          draft={safeDraft}
          i18nPrefix={i18nPrefix}
          ruleSchema={ruleSchema}
          value={descriptor.name in safeDraft ? safeDraft[descriptor.name] : descriptor.defaultValue}
          onChange={nextValue => onChange({ ...safeDraft, [descriptor.name]: nextValue })}
          onChangeDraft={onChange}
        />
      ))}
    </div>
  )
}
