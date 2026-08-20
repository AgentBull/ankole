import {
  Badge,
  Button,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerFooter,
  DrawerHeader,
  DrawerTitle,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  Skeleton,
  TableCell,
  TableRow,
  toast
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import {
  RiArrowDownSLine,
  RiArrowRightSLine,
  RiCloseLine,
  RiLoaderLine,
  RiMore2Fill,
  RiResetLeftLine,
  RiSettings3Line
} from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useCallback, useDeferredValue, useEffect, useRef, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, Outlet, useBlocker, useNavigate, useParams } from 'react-router'
import { requestErrorMessage } from '../../common/request-errors'
import {
  ankoleWebAppConfigurationControllerDecryptMutation,
  ankoleWebAppConfigurationControllerDeleteMutation,
  ankoleWebAppConfigurationControllerIndexOptions,
  ankoleWebAppConfigurationControllerIndexQueryKey,
  ankoleWebAppConfigurationControllerShowOptions,
  ankoleWebAppConfigurationControllerShowQueryKey,
  ankoleWebAppConfigurationControllerUpdateMutation,
  ankoleWebControlPlanePluginControllerIndexQueryKey
} from '../api/generated/@tanstack/react-query.gen'
import type { AppConfigurationItem, JsonValue as JSONValue } from '../api/generated/types.gen'
import { DiscardConfirmDialog, SaveButton, useFormCompleteness } from '../console-form'
import { ErrorBlock } from '../../common/error-block'
import { formatJSON, parseJSON } from '../console-primitives'
import { ENCRYPTED_VALUE_MASK, isEncryptedValueMask } from '../encrypted-value-input'
import { ResourceListPage, ResourceSearch, RowActions } from '../console-list-page'
import {
  groupOverridden,
  settingGroupPrefix,
  settingOwnerRoute,
  settingRows,
  type SettingGroup
} from '../state/setting-groups'
import { encryptedSettingValue, SettingEditorModel, settingDecryptedDraft } from '../state/setting-editor-model'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import { settingDescription } from '../state/setting-description'
import {
  OBSERVABILITY_TRACE_KEYS,
  observabilityHeaderRows,
  observabilityHeadersValidationError,
  observabilityHeadersValue,
  observabilityTraceDraft,
  observabilityTraceValidationError,
  sameObservabilityHeaderRows,
  type ObservabilityHeaderRow
} from '../state/observability-setting-editor'
import { ObservabilitySettingsEditor } from './observability-settings-editor'
import { SettingValueEditor } from './setting-value-editors'

/** Keeps the list mounted while an optional nested key route renders its drawer. */
export function SettingsPage() {
  return (
    <>
      <SettingsList />
      <Outlet />
    </>
  )
}

function SettingsList() {
  const { t } = useTranslation()
  const list = useQuery(ankoleWebAppConfigurationControllerIndexOptions())
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  // Search every word the row renders and keep the internal tokens for
  // operators who know the registry vocabulary.
  const items = (list.data?.app_configurations ?? []).filter(item =>
    matchesResourceSearch(
      searchQuery,
      item.key,
      settingDescription(t, item),
      item.kind,
      t(`console.settings.kind_${item.kind}`),
      item.source,
      t(`console.settings.source_${item.source}`),
      item.encrypted ? 'encrypted' : '',
      item.encrypted ? t('console.status.encrypted') : '',
      item.overridden ? 'overridden' : '',
      item.overridden ? t('console.status.global') : ''
    )
  )
  const rows = settingRows(items)
  const [managedOpen, setManagedOpen] = useState(false)

  return (
    <ResourceListPage
      title={t('console.settings.title')}
      description={t('console.settings.description')}
      columns={[
        t('console.settings.key'),
        t('console.settings.kind'),
        t('console.settings.source'),
        t('console.settings.state')
      ]}
      isLoading={list.isLoading}
      isEmpty={items.length === 0}
      count={items.length}
      emptyTitle={t('console.settings.empty_title')}
      emptyIcon={<RiSettings3Line aria-hidden />}
      emptyDescription={t('console.no_settings')}
      error={list.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      toolbar={
        <ResourceSearch
          label={t('console.settings.search')}
          placeholder={t('console.settings.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }>
      {rows.groups.map(group => (
        <SettingGroupRow key={group.id} group={group} />
      ))}
      {rows.singles.map(item => (
        <SettingRow key={`${item.kind}:${item.key}`} item={item} />
      ))}
      {rows.managed.length > 0 ? (
        <TableRow>
          <TableCell colSpan={5} className="whitespace-normal">
            <button
              type="button"
              className="flex w-full items-center gap-2 text-left text-xs text-muted-foreground hover:text-foreground"
              onClick={() => setManagedOpen(open => !open)}>
              {managedOpen ? <RiArrowDownSLine /> : <RiArrowRightSLine />}
              {t('console.settings.managed_group', { count: rows.managed.length })}
            </button>
          </TableCell>
        </TableRow>
      ) : null}
      {managedOpen ? rows.managed.map(item => <SettingRow key={`${item.kind}:${item.key}`} item={item} />) : null}
    </ResourceListPage>
  )
}




function SettingRow({ item }: { item: AppConfigurationItem }) {
  const { t } = useTranslation()
  const description = settingDescription(t, item)
  const ownerRoute = settingOwnerRoute(item.key)

  return (
    <TableRow>
      <TableCell className="max-w-[440px] whitespace-normal">
        <div className="grid gap-1.5">
          {item.editable ? (
            <Link
              className="break-all font-mono text-xs text-foreground hover:text-link hover:underline"
              to={encodeURIComponent(item.key)}>
              {item.key}
            </Link>
          ) : (
            <span className="break-all font-mono text-xs">{item.key}</span>
          )}
          {description ? (
            <span className="line-clamp-2 text-xs leading-5 text-muted-foreground">{description}</span>
          ) : null}
          {!item.editable && !item.encrypted ? (
            <code className="line-clamp-2 break-all text-xs text-muted-foreground">
              {formatJSON(item.value ?? null)}
            </code>
          ) : null}
        </div>
      </TableCell>
      <TableCell>
        <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>
          {t(`console.settings.kind_${item.kind}`)}
        </Badge>
      </TableCell>
      <TableCell>{t(`console.settings.source_${item.source}`)}</TableCell>
      <TableCell>
        <div className="flex flex-wrap gap-1.5">
          {item.encrypted ? <Badge variant="info">{t('console.status.encrypted')}</Badge> : null}
          {item.overridden ? <Badge variant="success">{t('console.status.global')}</Badge> : null}
        </div>
      </TableCell>
      {item.editable ? (
        <RowActions editTo={encodeURIComponent(item.key)} editLabel={t('common.edit')} />
      ) : (
        <TableCell className="text-right">
          {ownerRoute ? (
            <Link className="pr-2 text-xs text-foreground underline underline-offset-4" to={ownerRoute}>
              {t('console.settings.managed_elsewhere')}
            </Link>
          ) : (
            <span className="pr-2 text-xs text-muted-foreground">{t('console.settings.read_only')}</span>
          )}
        </TableCell>
      )}
    </TableRow>
  )
}

function SettingGroupRow({ group }: { group: SettingGroup }) {
  const { t } = useTranslation()

  return (
    <TableRow>
      <TableCell className="max-w-[440px] whitespace-normal">
        <div className="grid gap-1.5">
          <Link
            className="text-sm font-medium text-foreground hover:text-link hover:underline"
            to={`group/${group.id}`}>
            {t(`console.settings.group_${group.id}`)}
          </Link>
          <span className="text-xs leading-5 text-muted-foreground">
            {t(`console.settings.group_${group.id}_description`)}
          </span>
          <span className="font-mono text-xs text-muted-foreground">
            {group.items.map(item => item.key).join(' · ')}
          </span>
        </div>
      </TableCell>
      <TableCell>
        <Badge variant="secondary">{t('console.settings.group_kind', { count: group.items.length })}</Badge>
      </TableCell>
      <TableCell className="text-muted-foreground">—</TableCell>
      <TableCell>
        {groupOverridden(group) ? <Badge variant="success">{t('console.status.global')}</Badge> : null}
      </TableCell>
      <RowActions editTo={`group/${group.id}`} editLabel={t('common.edit')} />
    </TableRow>
  )
}

export function SettingEditorDrawer() {
  useSignals()
  const { t } = useTranslation()
  const formCompleteness = useFormCompleteness()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(SettingEditorModel)
  const params = useParams()
  const key = params.key ?? ''
  const sourceKey = `setting:${key}`
  const allowNavigation = useRef(false)
  const [restoreDefaultOpen, setRestoreDefaultOpen] = useState(false)
  const blocker = useBlocker(useCallback(() => !allowNavigation.current && model.dirty.value, [model]))

  const list = useQuery(ankoleWebAppConfigurationControllerIndexOptions())
  const summary = list.data?.app_configurations.find(item => item.key === key)
  const detail = useQuery({
    ...ankoleWebAppConfigurationControllerShowOptions({ path: { key } }),
    enabled: Boolean(summary?.editable && key)
  })
  const item = detail.data?.app_configuration ?? summary
  const description = item ? settingDescription(t, item) : undefined
  const initialized = model.sourceKey.value === sourceKey

  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: ankoleWebAppConfigurationControllerIndexQueryKey() })
    void queryClient.invalidateQueries({
      queryKey: ankoleWebAppConfigurationControllerShowQueryKey({ path: { key } })
    })
    if (key === 'plugins.enabled_ids') {
      void queryClient.invalidateQueries({ queryKey: ankoleWebControlPlanePluginControllerIndexQueryKey() })
    }
  }
  const decrypt = useMutation({
    ...ankoleWebAppConfigurationControllerDecryptMutation(),
    gcTime: 0,
    onSuccess: response => model.reveal(settingDecryptedDraft(response.decrypted_value.value)),
    onError: error => toast.error(requestErrorMessage(error))
  })
  const finish = (message: string) => {
    toast.success(message)
    allowNavigation.current = true
    model.resetSource()
    decrypt.reset()
    refresh()
    navigate('/settings')
  }
  const update = useMutation({
    ...ankoleWebAppConfigurationControllerUpdateMutation(),
    onSuccess: response => finish(t('console.settings.saved', { key: response.app_configuration.key })),
    onError: error => toast.error(requestErrorMessage(error))
  })
  const restoreDefault = useMutation({
    ...ankoleWebAppConfigurationControllerDeleteMutation(),
    onSuccess: () => {
      setRestoreDefaultOpen(false)
      finish(t('console.settings.reset_done', { key }))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  useEffect(() => {
    decrypt.reset()
    if (!item || detail.isLoading) return
    model.initialize(
      sourceKey,
      item.encrypted ? (item.present ? ENCRYPTED_VALUE_MASK : '') : formatJSON(item.value ?? null)
    )
  }, [detail.isLoading, item, model, sourceKey])

  const saving = update.isPending || restoreDefault.isPending
  const requestClose = () => {
    if (!saving) navigate('/settings')
  }
  const drawerError =
    model.validationError.value ??
    update.error ??
    restoreDefault.error ??
    decrypt.error ??
    detail.error ??
    (list.isSuccess && !item ? t('console.settings.not_found') : undefined) ??
    (item && !item.editable ? t('console.settings.read_only') : undefined)

  const submit = (event: FormEvent) => {
    event.preventDefault()
    model.clearValidation()
    if (!item?.editable || !initialized) return
    if (item.encrypted && isEncryptedValueMask(model.text.value)) {
      update.mutate({ body: {}, path: { key: item.key } })
      return
    }
    if (item.encrypted && !model.text.value.trim()) {
      model.validationError.value = t('common.field_required', { field: t('console.settings.value') })
      return
    }
    if (item.encrypted) {
      const value = encryptedSettingValue(model.text.value)
      update.mutate({ body: { value }, path: { key: item.key } })
      return
    }

    const parsed = parseJSON(model.text.value, t('console.settings.value'))
    if (!parsed.ok) {
      model.validationError.value = parsed.error
      return
    }
    const value = parsed.value

    update.mutate({ body: { value }, path: { key: item.key } })
  }

  return (
    <>
      <Drawer open onOpenChange={open => !open && requestClose()} swipeDirection="right">
        <DrawerContent className="data-[swipe-axis=x]:[--drawer-content-width:100%] data-[swipe-axis=x]:sm:[--drawer-content-width:42rem]">
          <form
            ref={formCompleteness.formRef}
            className="flex min-h-0 flex-1 flex-col"
            noValidate
            onChange={formCompleteness.refresh}
            onInput={formCompleteness.refresh}
            onSubmit={submit}>
            <DrawerHeader className="relative gap-3 border-b border-border p-5 pr-24">
              <div className="absolute top-3 right-3 flex items-center gap-1">
                {item?.editable && item.overridden ? (
                  <DropdownMenu>
                    <DropdownMenuTrigger
                      render={
                        <Button
                          aria-label={t('common.more_actions')}
                          disabled={saving}
                          size="icon-sm"
                          title={t('common.more_actions')}
                          type="button"
                          variant="ghost"
                        />
                      }>
                      <RiMore2Fill />
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="end" className="w-52">
                      <DropdownMenuItem variant="destructive" onClick={() => setRestoreDefaultOpen(true)}>
                        <RiResetLeftLine />
                        {t('console.settings.restore_default')}
                      </DropdownMenuItem>
                    </DropdownMenuContent>
                  </DropdownMenu>
                ) : null}
                <Button
                  aria-label={t('common.close')}
                  disabled={saving}
                  size="icon-sm"
                  type="button"
                  variant="ghost"
                  onClick={requestClose}>
                  <RiCloseLine />
                </Button>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                {item ? (
                  <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>
                    {t(`console.settings.kind_${item.kind}`)}
                  </Badge>
                ) : null}
                {item ? <Badge variant="outline">{t(`console.settings.source_${item.source}`)}</Badge> : null}
                {item?.encrypted ? <Badge variant="info">{t('console.status.encrypted')}</Badge> : null}
              </div>
              <DrawerTitle className="break-all font-mono text-lg tracking-normal normal-case">{key}</DrawerTitle>
              <DrawerDescription className="text-left text-pretty">
                {description ?? t('console.settings.editor_description')}
              </DrawerDescription>
            </DrawerHeader>

            <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-5">
              {!initialized && (list.isLoading || detail.isLoading) ? (
                <div className="grid gap-4">
                  <Skeleton className="h-24 w-full" />
                  <Skeleton className="h-64 w-full" />
                </div>
              ) : (
                <div className="grid gap-6">
                  <ErrorBlock error={drawerError} />
                  {item?.editable && initialized ? (
                    <SettingValueEditor
                      item={item}
                      value={model.text.value}
                      error={model.validationError.value}
                      onChange={value => {
                        model.text.value = value
                        model.clearValidation()
                      }}
                      decrypt={{
                        revealed: decrypt.data?.decrypted_value.key === item.key,
                        revealing: decrypt.isPending,
                        onReveal: () => decrypt.mutate({ path: { key: item.key } })
                      }}
                    />
                  ) : null}
                </div>
              )}
            </div>

            <DrawerFooter className="flex-row items-center justify-end gap-2 border-t border-border p-4">
              {model.dirty.value ? (
                <span className="mr-auto text-xs text-muted-foreground">{t('console.settings.unsaved')}</span>
              ) : null}
              <Button disabled={saving} type="button" variant="ghost" onClick={requestClose}>
                {t('common.cancel')}
              </Button>
              <SaveButton
                disabled={
                  !item?.editable || !initialized || saving || (!model.dirty.value && !formCompleteness.incomplete)
                }
                incomplete={formCompleteness.incomplete && Boolean(item?.editable && initialized) && !saving}
                loading={saving}
                type="submit">
                {t('common.save')}
              </SaveButton>
            </DrawerFooter>
          </form>
        </DrawerContent>
      </Drawer>

      <Dialog open={restoreDefaultOpen} onOpenChange={open => !restoreDefault.isPending && setRestoreDefaultOpen(open)}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!restoreDefault.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.settings.restore_default_title')}</DialogTitle>
            <DialogDescription>
              {item?.default_present
                ? t('console.settings.restore_default_description', { key })
                : t('console.settings.restore_unset_description', { key })}
              {model.dirty.value ? ` ${t('console.settings.restore_default_dirty_note')}` : null}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={restoreDefault.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={restoreDefault.isPending || !item?.overridden}
              variant="destructive"
              onClick={() => item?.overridden && restoreDefault.mutate({ path: { key: item.key } })}>
              {restoreDefault.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.settings.restore_default_confirm')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <DiscardConfirmDialog
        open={blocker.state === 'blocked' && !saving}
        onDiscard={() => blocker.proceed?.()}
        onKeep={() => blocker.reset?.()}
      />
    </>
  )
}

/**
 * Edits every key of one declared prefix group on one page.
 *
 * The key stays the save unit. Every dirty section is parsed and checked before the first write, so
 * a value the console can reject never leaves part of the group written, and one failing key
 * reports itself by name instead of hiding behind a whole-group error.
 */
export function SettingGroupDrawer() {
  const { t } = useTranslation()
  const formCompleteness = useFormCompleteness()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const params = useParams()
  const groupID = params.group ?? ''
  const prefix = settingGroupPrefix(groupID)
  const allowNavigation = useRef(false)
  const initializedFor = useRef<string | undefined>(undefined)
  const [drafts, setDrafts] = useState<Record<string, string>>({})
  const [initial, setInitial] = useState<Record<string, string>>({})
  const [editorError, setEditorError] = useState<string>()
  const [restoreItem, setRestoreItem] = useState<AppConfigurationItem>()
  const [saving, setSaving] = useState(false)
  // `undefined` keeps the stored encrypted map opaque. An empty array is an explicit replacement,
  // so editing another field can never turn an unread secret into an empty header map.
  const [headerRows, setHeaderRows] = useState<ObservabilityHeaderRow[]>()
  const [initialHeaderRows, setInitialHeaderRows] = useState<ObservabilityHeaderRow[]>()
  const [headersEditing, setHeadersEditing] = useState(false)

  const list = useQuery(ankoleWebAppConfigurationControllerIndexOptions())
  const items = (list.data?.app_configurations ?? []).filter(
    item => item.editable && prefix !== undefined && item.key.startsWith(prefix)
  )
  const signature = items.map(item => item.key).join(',')
  const visualObservabilityEditor = groupID === 'observability'
  const headersItem = items.find(item => item.key === OBSERVABILITY_TRACE_KEYS.headers)
  const headersDirty =
    visualObservabilityEditor && headersEditing && !sameObservabilityHeaderRows(headerRows, initialHeaderRows)
  const dirty = items.some(item => drafts[item.key] !== initial[item.key]) || headersDirty
  const blocker = useBlocker(useCallback(() => !allowNavigation.current && dirty, [dirty]))

  useEffect(() => {
    if (!signature || initializedFor.current === signature) return
    initializedFor.current = signature
    const next = Object.fromEntries(
      items.map(item => [
        item.key,
        item.key === OBSERVABILITY_TRACE_KEYS.headers && item.present
          ? ENCRYPTED_VALUE_MASK
          : formatJSON(item.value ?? null)
      ])
    )
    setDrafts(next)
    setInitial(next)
    setHeaderRows(undefined)
    setInitialHeaderRows(undefined)
    setHeadersEditing(false)
  }, [items, signature])

  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: ankoleWebAppConfigurationControllerIndexQueryKey() })
  }
  const update = useMutation(ankoleWebAppConfigurationControllerUpdateMutation())
  const decrypt = useMutation({
    ...ankoleWebAppConfigurationControllerDecryptMutation(),
    gcTime: 0,
    onSuccess: response => {
      const rows = observabilityHeaderRows(response.decrypted_value.value)
      if (!rows) {
        setEditorError(t('console.settings.observability_headers_invalid'))
        return
      }
      setHeaderRows(rows)
      setInitialHeaderRows(rows)
      setHeadersEditing(false)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const restoreDefault = useMutation({
    ...ankoleWebAppConfigurationControllerDeleteMutation(),
    onSuccess: response => {
      setRestoreItem(undefined)
      // Rebaseline only the restored key from the response. Re-initializing
      // every draft would read the still-stale list cache and discard sibling
      // edits, and the key-only signature would then skip the refetch.
      const restoredKey = response.app_configuration.key
      const restoredDraft = formatJSON(response.app_configuration.value ?? null)
      setDrafts(current => ({ ...current, [restoredKey]: restoredDraft }))
      setInitial(current => ({ ...current, [restoredKey]: restoredDraft }))
      if (restoredKey === OBSERVABILITY_TRACE_KEYS.headers) {
        setHeaderRows(undefined)
        setInitialHeaderRows(undefined)
        setHeadersEditing(false)
        decrypt.reset()
      }
      toast.success(t('console.settings.reset_done', { key: restoredKey }))
      refresh()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    setEditorError(undefined)

    const pending: Array<{ key: string; value: JSONValue }> = []

    if (visualObservabilityEditor) {
      const traceError = observabilityTraceValidationError(observabilityTraceDraft(drafts))
      if (traceError) {
        setEditorError(t(`console.settings.observability_error_${traceError}`))
        return
      }

      if (headersDirty && headerRows) {
        const headersError = observabilityHeadersValidationError(headerRows)
        if (headersError) {
          setEditorError(t(`console.settings.observability_error_${headersError}`))
          return
        }
      }
    }

    for (const item of items) {
      if (item.key === OBSERVABILITY_TRACE_KEYS.headers && visualObservabilityEditor) {
        if (headersDirty && headerRows) {
          pending.push({ key: item.key, value: observabilityHeadersValue(headerRows) })
        }
        continue
      }
      if (drafts[item.key] === initial[item.key]) continue

      const parsed = parseJSON(drafts[item.key] ?? '', item.key)
      if (!parsed.ok) {
        setEditorError(parsed.error)
        return
      }


      pending.push({ key: item.key, value: parsed.value })
    }

    if (pending.length === 0) return

    setSaving(true)

    for (const entry of pending) {
      try {
        await update.mutateAsync({ body: { value: entry.value }, path: { key: entry.key } })
        setInitial(current => ({ ...current, [entry.key]: drafts[entry.key] ?? '' }))
        if (entry.key === OBSERVABILITY_TRACE_KEYS.headers && headerRows) {
          setInitialHeaderRows(headerRows)
        }
      } catch (error) {
        setSaving(false)
        setEditorError(t('console.settings.group_save_failed', { key: entry.key, reason: requestErrorMessage(error) }))
        refresh()
        return
      }
    }

    setSaving(false)
    toast.success(t('console.settings.group_saved', { count: pending.length }))
    allowNavigation.current = true
    refresh()
    navigate('/settings')
  }

  const busy = saving || restoreDefault.isPending
  const requestClose = () => {
    if (!busy) navigate('/settings')
  }

  return (
    <>
      <Drawer open onOpenChange={open => !open && requestClose()} swipeDirection="right">
        <DrawerContent className="data-[swipe-axis=x]:[--drawer-content-width:100%] data-[swipe-axis=x]:sm:[--drawer-content-width:48rem]">
          <form
            ref={formCompleteness.formRef}
            className="flex min-h-0 flex-1 flex-col"
            noValidate
            onChange={formCompleteness.refresh}
            onInput={formCompleteness.refresh}
            onSubmit={submit}>
            <DrawerHeader className="relative gap-3 border-b border-border p-5 pr-16">
              <div className="absolute top-3 right-3">
                <Button
                  aria-label={t('common.close')}
                  disabled={busy}
                  size="icon-sm"
                  type="button"
                  variant="ghost"
                  onClick={requestClose}>
                  <RiCloseLine />
                </Button>
              </div>
              <DrawerTitle className="text-lg">{t(`console.settings.group_${groupID}`)}</DrawerTitle>
              <DrawerDescription className="text-left text-pretty">
                {t(`console.settings.group_${groupID}_description`)}
              </DrawerDescription>
            </DrawerHeader>

            <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-5">
              {list.isLoading ? (
                <div className="grid gap-4">
                  <Skeleton className="h-24 w-full" />
                  <Skeleton className="h-64 w-full" />
                </div>
              ) : (
                <div className="grid gap-8">
                  <ErrorBlock
                    error={editorError ?? list.error ?? (prefix ? undefined : t('console.settings.not_found'))}
                  />

                  {visualObservabilityEditor ? (
                    <ObservabilitySettingsEditor
                      drafts={drafts}
                      headerRows={headerRows}
                      headerRevealing={decrypt.isPending}
                      items={items}
                      saving={saving || restoreDefault.isPending}
                      onDraftChange={(key, value) => {
                        setDrafts(current => ({ ...current, [key]: value }))
                        setEditorError(undefined)
                      }}
                      onHeaderRowsChange={rows => {
                        setHeaderRows(rows)
                        setHeadersEditing(true)
                        setEditorError(undefined)
                      }}
                      onReplaceHeaders={() => {
                        setHeaderRows([])
                        setHeadersEditing(true)
                        setEditorError(undefined)
                      }}
                      onRestore={setRestoreItem}
                      onRevealHeaders={() => headersItem && decrypt.mutate({ path: { key: headersItem.key } })}
                    />
                  ) : (
                    items.map(item => (
                      <section key={item.key} className="grid gap-4">
                        <div className="flex items-start justify-between gap-3 border-b border-border pb-2">
                          <div className="grid gap-1">
                            <h2 className="font-mono text-sm text-foreground">{item.key}</h2>
                            <p className="text-xs leading-5 text-muted-foreground">{settingDescription(t, item)}</p>
                          </div>
                          {item.overridden ? (
                            <Button
                              disabled={saving || restoreDefault.isPending}
                              size="sm"
                              type="button"
                              variant="ghost"
                              onClick={() => setRestoreItem(item)}>
                              <RiResetLeftLine />
                              {t('console.settings.restore_default')}
                            </Button>
                          ) : null}
                        </div>

                        <SettingValueEditor
                          item={item}
                          value={drafts[item.key] ?? ''}
                          onChange={value => {
                            setDrafts(current => ({ ...current, [item.key]: value }))
                            setEditorError(undefined)
                          }}
                        />
                      </section>
                    ))
                  )}
                </div>
              )}
            </div>

            <DrawerFooter className="flex-row items-center justify-end gap-2 border-t border-border p-4">
              {dirty ? (
                <span className="mr-auto text-xs text-muted-foreground">{t('console.settings.unsaved')}</span>
              ) : null}
              <Button disabled={busy} type="button" variant="ghost" onClick={requestClose}>
                {t('common.cancel')}
              </Button>
              <SaveButton
                disabled={saving || (!dirty && !formCompleteness.incomplete)}
                incomplete={formCompleteness.incomplete && !saving}
                loading={saving}
                type="submit">
                {t('common.save')}
              </SaveButton>
            </DrawerFooter>
          </form>
        </DrawerContent>
      </Drawer>

      <Dialog
        open={Boolean(restoreItem)}
        onOpenChange={open => !open && !restoreDefault.isPending && setRestoreItem(undefined)}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!restoreDefault.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.settings.restore_default_title')}</DialogTitle>
            <DialogDescription>
              {restoreItem?.default_present
                ? t('console.settings.restore_default_description', { key: restoreItem.key })
                : t('console.settings.restore_unset_description', { key: restoreItem?.key })}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={restoreDefault.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={restoreDefault.isPending}
              variant="destructive"
              onClick={() => restoreItem && restoreDefault.mutate({ path: { key: restoreItem.key } })}>
              {restoreDefault.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.settings.restore_default_confirm')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <DiscardConfirmDialog
        open={blocker.state === 'blocked' && !busy}
        onDiscard={() => blocker.proceed?.()}
        onKeep={() => blocker.reset?.()}
      />
    </>
  )
}
