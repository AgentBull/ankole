import { t } from 'i18next'
import {
  Button,
  Checkbox,
  Input,
  Popover,
  PopoverContent,
  PopoverTitle,
  PopoverTrigger,
  RadioGroup,
  RadioGroupItem
} from '@ankole/uikit'
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useEffect, useRef, useState } from 'react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { FieldInputModel } from './state/field-input'
import type { BaseField, Value } from '@ankole/applet-sdk/types'
import { contentKeys, fileURL } from './content-api'
import { Choice, ContentError } from './content-primitives'
import { baseHTTP, baseSchemaQuery } from './base-api'
import { uploadPageFile } from './page-files'
import { podSubjects } from './api/generated/sdk.gen'
import { fieldValue } from './state/table-query'
import { displayValue, fieldOptions } from './base-field-types'
import { FieldValue } from './base-field-value'

export function FieldInput({
  field,
  value,
  onChange,
  pageID,
  required = false,
  disabled = false,
  commitOnChange = false,
  onEditStart,
  onEditEnd,
  onPendingChange
}: {
  field: BaseField
  value: Value
  onChange(value: Value): void | Promise<unknown>
  pageID: string
  required?: boolean
  disabled?: boolean
  /** Local forms need the current value before their submit button receives focus. */
  commitOnChange?: boolean
  onEditStart?(): void
  onEditEnd?(): void
  onPendingChange?(pending: boolean): void
}) {
  useSignals()
  const model = useModel(FieldInputModel)
  model.load(value, field.type)
  const draft = model.draft.value,
    error = model.error.value,
    picker = model.picker.value
  const setError = (value: unknown) => {
    model.error.value = value
  }
  const setPicker = (value: boolean) => {
    model.picker.value = value
  }
  const [uploading, setUploading] = useState(false)
  const unavailable = useRef(disabled)
  const mounted = useRef(true)
  const uploadingRef = useRef(false)
  const pendingCallback = useRef(onPendingChange)
  const editStartValue = useRef<Value>(value)
  pendingCallback.current = onPendingChange
  unavailable.current = disabled
  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
      if (uploadingRef.current) {
        uploadingRef.current = false
        pendingCallback.current?.(false)
      }
    }
  }, [])
  const change = (next: Value) => {
    if (unavailable.current || !mounted.current) return
    setError(undefined)
    return onChange(next)
  }
  const labels = fieldOptions(field)
  if (field.type === 'checkbox') {
    return (
      <Checkbox
        aria-label={field.name}
        disabled={disabled}
        checked={value === true}
        onCheckedChange={next => void Promise.resolve(change(next)).catch(() => {})}
      />
    )
  }
  if (field.type === 'select' && !field.config.multiple) {
    return (
      <Choice
        label={field.name}
        value={value === null ? '' : String(value)}
        disabled={disabled}
        onChange={next => void Promise.resolve(change(next || null)).catch(() => {})}
        options={{ '': '—', ...Object.fromEntries(labels.map(option => [option.id, option.name])) }}
      />
    )
  }
  if (field.type === 'select') {
    return (
      <Popover
        open={picker}
        onOpenChange={next => {
          setPicker(next)
          if (next) onEditStart?.()
          else onEditEnd?.()
        }}>
        <PopoverTrigger
          disabled={disabled}
          render={<Button size="sm" variant="ghost" className="w-full justify-start truncate" />}
          aria-label={field.name}>
          <span className="truncate">{displayValue(field, value) || '—'}</span>
        </PopoverTrigger>
        <PopoverContent align="start" className="max-h-72 w-56 gap-1 overflow-auto p-2">
          {labels.map(option => (
            <label
              key={option.id}
              className="flex cursor-pointer items-center gap-2 rounded-control px-2 py-1.5 text-sm hover:bg-accent">
              <Checkbox
                disabled={disabled}
                checked={Array.isArray(value) && value.includes(option.id)}
                onCheckedChange={checked =>
                  void Promise.resolve(
                    change(
                      checked
                        ? [...(Array.isArray(value) ? value : []), option.id]
                        : (Array.isArray(value) ? value : []).filter(item => item !== option.id)
                    )
                  ).catch(() => {})
                }
              />
              <span className="truncate">{option.name}</span>
            </label>
          ))}
        </PopoverContent>
      </Popover>
    )
  }
  if (field.type === 'user' || field.type === 'link') {
    return (
      <div data-cell-retained={picker ? 'true' : undefined}>
        <Popover
          open={picker}
          onOpenChange={next => {
            setPicker(next)
            if (next) onEditStart?.()
            else onEditEnd?.()
          }}>
          <PopoverTrigger
            disabled={disabled}
            render={<Button size="sm" variant="ghost" className="w-full justify-start truncate" />}>
            <span className="sr-only">{field.name}: </span>
            <span className="truncate">
              {Array.isArray(value) && value.length ? (
                <FieldValue field={field} value={value} pageID={pageID} />
              ) : (
                t('pod.content.choose')
              )}
            </span>
          </PopoverTrigger>
          <ReferencePicker
            open={picker}
            close={() => {
              setPicker(false)
              onEditEnd?.()
            }}
            field={field}
            disabled={disabled}
            pageID={pageID}
            value={Array.isArray(value) ? (value as string[]) : []}
            onChange={next => void Promise.resolve(change(next)).catch(() => {})}
          />
        </Popover>
      </div>
    )
  }
  if (field.type === 'attachment') {
    const attachments = Array.isArray(value)
      ? (value as { path: string; name: string; mime: string; size: number }[])
      : []
    return (
      <div className="space-y-1" data-cell-retained={uploading ? 'true' : undefined}>
        {attachments.map((file, index) => (
          <div key={file.path} className="flex gap-2 text-xs">
            <a
              className="link truncate"
              href={fileURL(pageID, file.path.replace(`pages/${pageID}/`, ''))}
              download={file.name}>
              {file.name}
            </a>
            <button
              aria-label={t('pod.content.remove_2', { value1: file.name })}
              type="button"
              disabled={disabled || uploading}
              onClick={() => void Promise.resolve(change(attachments.filter((_, i) => i !== index))).catch(() => {})}>
              ×
            </button>
          </div>
        ))}
        <label className="cursor-pointer text-xs underline">
          {t('pod.content.add_attachment')}
          <input
            type="file"
            disabled={disabled || uploading}
            className="sr-only"
            onChange={event => {
              const file = event.target.files?.[0]
              if (!file || unavailable.current || uploadingRef.current) return
              onEditStart?.()
              setError(undefined)
              setUploading(true)
              uploadingRef.current = true
              pendingCallback.current?.(true)
              void uploadPageFile(pageID, file, 'attachment')
                .then(uploaded =>
                  change([
                    ...attachments,
                    {
                      path: `pages/${pageID}/${uploaded.file.path}`,
                      name: file.name,
                      mime: file.type || 'application/octet-stream',
                      size: file.size
                    }
                  ])
                )
                .catch(setError)
                .finally(() => {
                  if (mounted.current) setUploading(false)
                  if (mounted.current) onEditEnd?.()
                  if (uploadingRef.current) {
                    uploadingRef.current = false
                    pendingCallback.current?.(false)
                  }
                })
              event.target.value = ''
            }}
          />
        </label>
        {uploading && (
          <span role="status" className="text-xs text-fg-tertiary">
            {t('pod.content.uploading')}
          </span>
        )}
        <ContentError error={error} />
      </div>
    )
  }
  const datetime = field.type === 'datetime'
  const commitText = (input: HTMLInputElement, finishEditing: boolean) => {
    if (unavailable.current) return
    const raw = input.value
    const next = raw === '' ? null : field.type === 'number' ? Number(raw) : datetime ? new Date(raw).getTime() : raw
    if (input.validity.badInput || ((field.type === 'number' || datetime) && next !== null && !Number.isFinite(next))) {
      if (commitOnChange) void Promise.resolve(change(null)).catch(() => {})
      if (finishEditing) {
        setError(
          new Error(datetime ? t('pod.content.enter_a_valid_date_and_time') : t('pod.content.enter_a_valid_number'))
        )
      }
      return
    }
    const parsed =
      datetime && typeof next === 'number' ? new Date(next).toISOString().replace('.000Z', '.000000Z') : next
    if (parsed === value) {
      if (finishEditing) {
        model.dirty.value = false
        onEditEnd?.()
      }
      return
    }
    void Promise.resolve(change(parsed))
      .then(() => {
        if (finishEditing && model.draft.peek() === raw) model.dirty.value = false
      })
      .catch(() => {})
  }
  return (
    <div data-cell-retained={model.dirty.value ? 'true' : undefined}>
      <Input
        disabled={disabled}
        required={required}
        aria-label={field.name}
        type={field.type === 'number' ? 'number' : datetime ? 'datetime-local' : 'text'}
        step={field.type === 'number' ? 'any' : undefined}
        value={draft}
        onFocus={() => {
          editStartValue.current = value
          onEditStart?.()
        }}
        onChange={event => {
          model.edit(event.target.value)
          if (commitOnChange) commitText(event.currentTarget, false)
        }}
        onKeyDown={event => {
          if (event.nativeEvent.isComposing) return
          if (event.key === 'Enter') {
            event.preventDefault()
            event.currentTarget.blur()
          } else if (event.key === 'Escape') {
            event.preventDefault()
            event.stopPropagation()
            const baseline = commitOnChange ? editStartValue.current : value
            if (commitOnChange) void Promise.resolve(change(baseline)).catch(() => {})
            model.cancel(baseline, field.type)
            onEditEnd?.()
            event.currentTarget.blur()
          }
        }}
        onBlur={event => {
          if (model.cancelled.value) {
            model.cancelled.value = false
            return
          }
          if (!model.dirty.value) {
            onEditEnd?.()
            return
          }
          commitText(event.currentTarget, true)
        }}
      />
      <ContentError error={error} />
    </div>
  )
}

function ReferencePicker({
  open,
  close,
  field,
  pageID,
  value,
  onChange,
  disabled
}: {
  open: boolean
  close(): void
  field: BaseField
  pageID: string
  value: string[]
  onChange(value: Value): void
  disabled: boolean
}) {
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const [pageToken, setPageToken] = useState<string>()
  const [previousTokens, setPreviousTokens] = useState<(string | undefined)[]>([])
  const multiple = field.config.multiple !== false
  const search = useRef<HTMLInputElement>(null)
  const client = useQueryClient()
  const candidates = useQuery({
    queryKey: [...contentKeys.page(pageID), 'reference', field.id, deferredQuery, pageToken],
    enabled: open,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      if (field.type === 'user') {
        const result = await client.fetchQuery({
          queryKey: [...contentKeys.all, 'subjects'],
          queryFn: () => podSubjects(),
          staleTime: 30_000
        })
        const items = result.subjects
          .filter(subject => subject.kind === 'human' && !!subject.principal_uid)
          .map(subject => ({ id: subject.principal_uid!, name: subject.name }))
          .filter(subject => subject.name.toLocaleLowerCase().includes(deferredQuery.toLocaleLowerCase()))
        return { items, next: undefined as string | undefined }
      }
      const schema = await client.fetchQuery({ ...baseSchemaQuery(String(field.config.table_id)), staleTime: 30_000 })
      const primary = schema.fields.find(field => field.is_primary) ?? schema.fields[0]
      const result = await baseHTTP.query(schema.table.id, {
        page_size: 100,
        page_token: pageToken,
        ...(deferredQuery && primary
          ? {
              filter: {
                conjunction: 'and',
                conditions: [{ field_id: primary.id, operator: 'text_contains', value: deferredQuery }]
              }
            }
          : {})
      })
      return {
        items: result.records.map(record => ({
          id: record.id,
          name: primary ? displayValue(primary, fieldValue(record, primary)) : record.id
        })),
        next: result.page_token ?? undefined
      }
    }
  })
  return (
    <PopoverContent
      align="start"
      className="max-h-[var(--available-height)] w-80 max-w-[calc(100vw-2rem)] overflow-y-auto"
      initialFocus={search}>
      <PopoverTitle>{field.type === 'user' ? t('pod.content.people') : t('pod.content.related_records')}</PopoverTitle>
      <Input
        ref={search}
        aria-label={t('pod.content.search_options')}
        placeholder={t('pod.content.search')}
        disabled={disabled}
        value={query}
        onChange={event => {
          setQuery(event.target.value)
          setPageToken(undefined)
          setPreviousTokens([])
        }}
      />
      <ContentError error={candidates.error} />
      {candidates.isPending && <p role="status">{t('pod.content.loading_options')}</p>}
      {candidates.data?.items.length === 0 && <p className="text-sm text-fg-tertiary">{t('pod.content.no_matches')}</p>}
      {multiple ? (
        <ul className="min-h-0 max-h-[min(18rem,40dvh)] space-y-2 overflow-y-auto">
          {candidates.data?.items.map(candidate => (
            <li key={candidate.id}>
              <label className="flex min-h-10 items-center gap-2 rounded-control px-2 py-1 text-sm hover:bg-accent">
                <Checkbox
                  disabled={disabled}
                  checked={value.includes(candidate.id)}
                  onCheckedChange={checked =>
                    onChange(checked ? [...value, candidate.id] : value.filter(id => id !== candidate.id))
                  }
                />
                {candidate.name}
              </label>
            </li>
          ))}
        </ul>
      ) : (
        <RadioGroup
          aria-label={field.name}
          className="min-h-0 max-h-[min(18rem,40dvh)] overflow-y-auto"
          value={value[0] ?? ''}
          disabled={disabled}
          onValueChange={selected => {
            onChange([String(selected)])
            close()
          }}>
          {candidates.data?.items.map(candidate => (
            <label
              key={candidate.id}
              className="flex min-h-10 items-center gap-2 rounded-control px-2 py-1 text-sm hover:bg-accent">
              <RadioGroupItem value={candidate.id} />
              {candidate.name}
            </label>
          ))}
        </RadioGroup>
      )}
      {(previousTokens.length > 0 || candidates.data?.next) && (
        <div className="mt-2 flex justify-between gap-2">
          <Button
            size="sm"
            variant="ghost"
            disabled={!previousTokens.length || candidates.isFetching}
            onClick={() => {
              setPageToken(previousTokens.at(-1))
              setPreviousTokens(tokens => tokens.slice(0, -1))
            }}>
            {t('pod.content.previous_page')}
          </Button>
          <Button
            size="sm"
            variant="ghost"
            disabled={!candidates.data?.next || candidates.isFetching}
            onClick={() => {
              setPreviousTokens(tokens => [...tokens, pageToken])
              setPageToken(candidates.data?.next)
            }}>
            {t('pod.content.next_page')}
          </Button>
        </div>
      )}
      {multiple ? (
        <div className="flex justify-end">
          <Button variant="outline" type="button" onClick={close}>
            {t('pod.content.done')}
          </Button>
        </div>
      ) : (
        value.length > 0 && (
          <Button
            type="button"
            variant="ghost"
            disabled={disabled}
            onClick={() => {
              onChange([])
              close()
            }}>
            {t('common.clear')}
          </Button>
        )
      )}
    </PopoverContent>
  )
}
