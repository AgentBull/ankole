import { uuidV4 } from '@agentbull/active-support'
import { t } from 'i18next'
import { Button, Checkbox, Input, Popover, PopoverContent, PopoverTitle, PopoverTrigger, Textarea } from '@ankole/uikit'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useRef } from 'react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { RiEqualizerLine } from '@remixicon/react'
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
  canManage,
  iconOnly = false,
  onCreated
}: {
  tableID: string
  pageID: string
  tables: BaseTable[]
  field?: BaseField
  canManage: boolean
  iconOnly?: boolean
  onCreated?(fieldID: string): void
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
  const invalidate = () =>
    Promise.all([
      client.invalidateQueries({ queryKey: [...contentKeys.all, 'table'] }),
      client.invalidateQueries({ queryKey: [...contentKeys.all, 'reference-labels'] }),
      client.invalidateQueries({ queryKey: contentKeys.page(pageID) })
    ])
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
    onSuccess: async result => {
      await invalidate()
      if (!field && result.field?.id) onCreated?.(result.field.id)
      setOpen(false)
    },
    onError: () => invalidate(),
    onSettled: () => {
      saving.current = false
    }
  })
  const remove = useMutation({
    mutationFn: () => baseHTTP.removeField(field!.id, baseVersion),
    onSuccess: async () => {
      await invalidate()
      setOpen(false)
    },
    onError: () => invalidate(),
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
  if (!canManage) return <span className="px-2 text-sm font-medium">{field?.name}</span>
  const iconLabel = iconOnly && field ? `${t('pod.content.edit_field')} ${field.name}` : undefined
  return (
    <Popover
      open={open}
      onOpenChange={next => {
        if (saving.current) return
        if (next) load()
        setOpen(next)
      }}>
      <PopoverTrigger
        render={<Button size={iconOnly ? 'icon-xs' : 'sm'} variant="ghost" aria-label={iconLabel} title={iconLabel} />}>
        {iconOnly ? (
          <RiEqualizerLine aria-hidden="true" />
        ) : (
          <span className="truncate">{field ? field.name : t('pod.content.field')}</span>
        )}
      </PopoverTrigger>
      <PopoverContent
        align="start"
        sideOffset={6}
        collisionPadding={16}
        className="max-h-[min(32rem,calc(100dvh-2rem),calc(var(--available-height)-0.25rem))] w-[min(22rem,calc(100vw-2rem))] gap-3 overflow-hidden p-4"
        aria-busy={pending}
        render={
          <form
            onSubmit={event => {
              event.preventDefault()
              if (!confirmation) save()
            }}
          />
        }>
        <PopoverTitle render={<h2 />} className="shrink-0">
          {field ? t('pod.content.edit_field') : t('pod.content.add_field')}
        </PopoverTitle>
        <div className="pod-dialog-body min-h-0 flex-1 grid gap-4 overflow-y-auto pr-1">
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
                  onClick={() => setOptions([...options, { id: uuidV4(), name: '' }])}>
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
        <div className="flex shrink-0 flex-wrap justify-end gap-2 border-t border-border pt-3">
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
              variant={confirmation === 'delete' ? 'destructive' : 'ghost'}
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
            variant="default"
            type={confirmation ? 'button' : 'submit'}
            disabled={!name.trim() || pending || confirmation === 'delete' || (type === 'link' && !target)}
            onClick={confirmation ? save : undefined}>
            {pending
              ? t('pod.content.saving')
              : confirmation === 'change' || confirmation === 'clear'
                ? t('pod.content.confirm_field_change')
                : t('pod.content.save_field')}
          </Button>
        </div>
      </PopoverContent>
    </Popover>
  )
}
