import { t } from 'i18next'
import { Button } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { DatabaseCellModel } from './state/database-cell'
import type { DatabaseField, DatabaseRecord, RecordData, Value, Versions } from '@ankole/applet-sdk/types'
import { ContentError } from './content-primitives'
import { fieldValue } from './state/table-query'
import { writableField } from './database-field-types'
import { FieldValue } from './database-field-value'
import { FieldInput } from './database-field-input'
export { FieldValue } from './database-field-value'
export { FieldInput } from './database-field-input'
export { FieldEditorButton } from './database-field-editor'
export * from './database-field-types'

export function DatabaseCell({
  field,
  record,
  pageID,
  editable,
  readonlyFieldIDs = [],
  update
}: {
  field: DatabaseField
  record: DatabaseRecord
  pageID: string
  editable: boolean
  readonlyFieldIDs?: string[]
  update(data: RecordData, versions: Versions): Promise<unknown>
}) {
  const value = fieldValue(record, field)
  useSignals()
  const model = useModel(DatabaseCellModel)
  const error = model.error.value,
    attempt = model.attempt.value,
    pending = model.pending.value
  const save = (next: Value, retry = false) =>
    model.save(field.id, next, record.versions, (value, versions) => update({ [field.id]: value }, versions), retry)
  if (!editable || !writableField(field, readonlyFieldIDs)) {
    return (
      <span
        className="whitespace-pre-wrap"
        title={
          readonlyFieldIDs.includes(field.id) ? t('pod.content.externally_synced_fields_are_read_only') : undefined
        }>
        <FieldValue field={field} value={value} />
        {!!readonlyFieldIDs.includes(field.id) && (
          <span className="sr-only">{t('pod.content.externally_synced_fields_are_read_only')}</span>
        )}
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
