import { t } from 'i18next'
import { Button } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { BaseCellModel } from './state/base-cell'
import type { BaseField, BaseRecord, RecordData, Value, Versions } from '@ankole/applet-sdk/types'
import { ContentError } from './content-primitives'
import { fieldValue } from './state/table-query'
import { writableField } from './base-field-types'
import { FieldValue } from './base-field-value'
import { FieldInput } from './base-field-input'
export { FieldValue } from './base-field-value'
export { FieldInput } from './base-field-input'
export { FieldEditorButton } from './base-field-editor'
export * from './base-field-types'

export function BaseCell({
  field,
  record,
  pageID,
  editable,
  update
}: {
  field: BaseField
  record: BaseRecord
  pageID: string
  editable: boolean
  update(data: RecordData, versions: Versions): Promise<unknown>
}) {
  const value = fieldValue(record, field)
  useSignals()
  const model = useModel(BaseCellModel)
  const error = model.error.value,
    attempt = model.attempt.value,
    pending = model.pending.value
  const save = (next: Value, retry = false) =>
    model.save(field.id, next, record.versions, (value, versions) => update({ [field.id]: value }, versions), retry)
  if (!editable || !writableField(field)) {
    return (
      <span className="whitespace-pre-wrap">
        <FieldValue field={field} value={value} pageID={pageID} />
      </span>
    )
  }
  return (
    <div
      data-cell-retained={!!attempt || pending ? 'true' : undefined}
      className="min-w-28"
      onFocusCapture={() => {
        model.begin(record.versions)
      }}>
      <FieldInput
        key={`${record.id}:${field.id}:${model.generation.value}`}
        pageID={pageID}
        field={field}
        value={attempt ? attempt.value : value}
        disabled={pending}
        onEditStart={() => {
          model.begin(record.versions)
        }}
        onEditEnd={model.end}
        onChange={save}
      />
      {pending && (
        <span role="status" className="text-xs text-fg-tertiary">
          {t('pod.content.saving')}
        </span>
      )}
      <ContentError error={error} />
      {!!error && attempt && (
        <div className="flex flex-wrap gap-1">
          <Button size="sm" variant="outline" onClick={() => void save(attempt.value, true).catch(() => {})}>
            {t('pod.content.retry_save')}
          </Button>
          <Button
            size="sm"
            variant="ghost"
            onClick={() => {
              model.discard()
            }}>
            {t('pod.content.use_latest_value')}
          </Button>
        </div>
      )}
    </div>
  )
}
