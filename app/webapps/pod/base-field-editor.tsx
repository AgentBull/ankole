import { t } from 'i18next'
import { Button, Checkbox, Dialog, DialogContent, DialogFooter, DialogTitle, Input, Textarea } from '@ankole/uikit'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useRef } from 'react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { FieldEditorModel } from './state/field-editor'
import { requestErrorCode } from '../common/request-errors'
import { InternalAPIError } from '../common/internal-api-client'
import type { BaseField, BaseTable } from '@ankole/applet-sdk/types'
import { contentKeys } from './content-api'
import { Choice, ContentError, TextField } from './content-primitives'
import { baseHTTP } from './base-api'
import { fieldTypes } from './base-field-types'

export function FieldEditorButton({
  tableID,
  pageID,
  tables,
  field,
  canManage
}: {
  tableID: string
  pageID: string
  tables: BaseTable[]
  field?: BaseField
  canManage: boolean
}) {
  useSignals()
  const model = useModel(FieldEditorModel)
  const open = model.open.value
  const name = model.name.value
  const type = model.type.value
  const formula = model.formula.value
  const multiple = model.multiple.value
  const options = model.options.value
  const target = model.target.value
  const bidirectional = model.bidirectional.value
  const baseVersion = model.baseVersion.value
  const confirmation = model.confirmation.value
  const {
    setOpen,
    setName,
    setType,
    setFormula,
    setMultiple,
    setOptions,
    setTarget,
    setBidirectional,
    setConfirmation
  } = model
  const client = useQueryClient()
  const saving = useRef(false)
  const cancel = useRef<HTMLButtonElement>(null)
  const write = useMutation({
    mutationFn: () => {
      const config = model.config.value
      return field
        ? baseHTTP.updateField(
            field.id,
            { name: name.trim(), type, config, ...(confirmation === 'clear' ? { clear_invalid: true } : {}) },
            baseVersion
          )
        : baseHTTP.createField(tableID, { name: name.trim(), type, config })
    },
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      setOpen(false)
    },
    onError: () => client.invalidateQueries({ queryKey: contentKeys.all }),
    onSettled: () => {
      saving.current = false
    }
  })
  const remove = useMutation({
    mutationFn: () => baseHTTP.removeField(field!.id, baseVersion),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      setOpen(false)
    },
    onError: () => client.invalidateQueries({ queryKey: contentKeys.all }),
    onSettled: () => {
      saving.current = false
    }
  })
  const pending = write.isPending || remove.isPending
  const load = () => {
    model.load(field)
    write.reset()
    remove.reset()
  }
  const changesValues = model.changesValues.value
  const conversionFailed =
    write.error instanceof InternalAPIError && requestErrorCode(write.error.payload) === 'conversion_failed'
  const confirm = (next: 'delete' | 'change' | 'clear') => {
    setConfirmation(next)
    cancel.current?.focus()
  }
  const save = () => {
    if (saving.current || !name.trim() || confirmation === 'delete' || (type === 'link' && !target)) return
    if (changesValues && confirmation !== 'change' && confirmation !== 'clear') confirm('change')
    else {
      saving.current = true
      write.mutate()
    }
  }
  return (
    <Dialog
      open={open}
      onOpenChange={next => {
        if (saving.current) return
        if (next) load()
        setOpen(next)
      }}>
      <Button
        size="sm"
        variant="ghost"
        disabled={!canManage}
        onClick={() => {
          load()
          setOpen(true)
        }}>
        {field ? field.name : t('pod.content.field')}
      </Button>
      <DialogContent
        className="pod-dialog pod-dialog-wide"
        closeLabel={t('common.close')}
        showCloseButton={!pending}
        aria-busy={pending}
        render={
          <form
            onSubmit={event => {
              event.preventDefault()
              if (!confirmation) save()
            }}
          />
        }>
        <DialogTitle>{field ? t('pod.content.edit_field') : t('pod.content.add_field')}</DialogTitle>
        <div className="pod-dialog-body grid gap-4">
          <fieldset disabled={pending} className="grid gap-4">
            <TextField label={t('pod.content.field_name')} value={name} onChange={setName} />
            <Choice
              label={t('pod.content.field_type')}
              value={type}
              onChange={setType}
              options={fieldTypes}
              disabled={pending || field?.is_primary}
            />
            {type === 'formula' && (
              <label className="grid gap-2 text-sm">
                {t('pod.content.formula')}
                <Textarea
                  aria-label={t('pod.content.formula')}
                  value={formula}
                  onChange={event => setFormula(event.target.value)}
                  placeholder={t('pod.content.unit_price_quantity')}
                />
              </label>
            )}
            {type === 'select' && (
              <div className="grid gap-2 text-sm">
                <span>{t('pod.content.select')}</span>
                {options.map((option, index) => (
                  <div className="flex gap-2" key={option.id}>
                    <Input
                      disabled={pending}
                      aria-label={t('pod.content.option', { value1: index + 1 })}
                      value={option.name}
                      onChange={event =>
                        setOptions(
                          options.map((item, i) => (i === index ? { ...item, name: event.target.value } : item))
                        )
                      }
                    />
                    <Button
                      type="button"
                      disabled={pending}
                      variant="ghost"
                      size="sm"
                      onClick={() => setOptions(options.filter((_, i) => i !== index))}>
                      {t('pod.content.remove')}
                    </Button>
                  </div>
                ))}
                <Button
                  type="button"
                  variant="outline"
                  disabled={pending}
                  size="sm"
                  onClick={() => setOptions([...options, { id: crypto.randomUUID(), name: '' }])}>
                  {t('pod.content.add_option')}
                </Button>
              </div>
            )}
            {type === 'link' && (
              <>
                <Choice
                  label={t('pod.content.related_table')}
                  value={target}
                  onChange={setTarget}
                  disabled={pending}
                  options={{
                    '': t('pod.content.choose_a_table'),
                    ...Object.fromEntries(
                      tables.filter(table => table.page_id === pageID).map(table => [table.id, table.name])
                    )
                  }}
                />
                <label className="flex gap-2 text-sm">
                  <Checkbox disabled={pending} checked={bidirectional} onCheckedChange={setBidirectional} />
                  {t('pod.content.create_a_two_way_relation')}
                </label>
              </>
            )}
            {(type === 'select' || type === 'link') && (
              <label className="flex gap-2 text-sm">
                <Checkbox disabled={pending} checked={multiple} onCheckedChange={setMultiple} />
                {t('pod.content.allow_multiple_selections')}
              </label>
            )}
          </fieldset>
          <ContentError error={write.error || remove.error} />
          {!!(write.error || remove.error) && (
            <Button type="button" size="sm" variant="outline" onClick={load}>
              {t('pod.content.reload_field_definition')}
            </Button>
          )}
          {conversionFailed && confirmation !== 'clear' && (
            <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => confirm('clear')}>
              {t('pod.content.clear_values_that_cannot_be_converted_and_retry')}
            </Button>
          )}
          {confirmation && (
            <div role="alert" className="rounded border border-border p-3 text-sm">
              {confirmation === 'clear'
                ? t('pod.content.existing_values_that_cannot_be_converted_will_be_cleared_confirm')
                : confirmation === 'delete'
                  ? t('pod.content.deleting_permanently_removes_the_field_and_its_values_from_all', {
                      value1: field?.name
                    })
                  : t('pod.content.this_change_converts_existing_field_values_converting_to_a_formula')}
            </div>
          )}
        </div>
        <DialogFooter>
          <Button
            ref={cancel}
            type="button"
            variant="ghost"
            disabled={pending}
            onClick={() => {
              if (confirmation) setConfirmation(undefined)
              else setOpen(false)
            }}>
            {t('pod.content.cancel')}
          </Button>
          {field && !field.is_primary && (
            <Button
              type="button"
              variant="ghost"
              disabled={pending}
              onClick={() => {
                if (saving.current) return
                if (confirmation !== 'delete') confirm('delete')
                else {
                  saving.current = true
                  remove.mutate()
                }
              }}>
              {confirmation === 'delete' ? t('pod.content.confirm_field_deletion') : t('pod.content.delete_field')}
            </Button>
          )}
          <Button
            variant="outline"
            type={confirmation ? 'button' : 'submit'}
            disabled={!name.trim() || pending || confirmation === 'delete' || (type === 'link' && !target)}
            onClick={confirmation ? save : undefined}>
            {pending
              ? t('pod.content.saving')
              : confirmation === 'change' || confirmation === 'clear'
                ? t('pod.content.confirm_field_change')
                : t('pod.content.save_field')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
