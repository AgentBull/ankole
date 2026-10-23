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
import { useIsMutating, useMutation, useQuery } from '@tanstack/react-query'
import { Fragment, useDeferredValue, useEffect, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, Outlet, useNavigate, useParams } from '@tanstack/react-router'
import { useSearchParams } from '../../common/router'
import { requestErrorCode, requestErrorMessage } from '../../common/request-errors'
import {
  decryptSiteAppConfigurationMutation,
  resetSiteAppConfigurationMutation,
  listSiteAppConfigurationsOptions,
  getSiteAppConfigurationOptions,
  updateSiteAppConfigurationMutation
} from '../api/v2-site/generated/@tanstack/react-query.gen'
import {
  decryptAppConfigurationMutation,
  resetAppConfigurationMutation,
  listAppConfigurationsOptions,
  getAppConfigurationOptions,
  updateAppConfigurationMutation
} from '../api/v2/generated/@tanstack/react-query.gen'
import type { AppConfigurationItem } from '../api/configuration-types'
import { EditorNavigationGuard, SaveButton, focusFirstInvalidControl, useFormCompleteness } from '../console-form'
import { ErrorBlock } from '../../common/error-block'
import { formatJSON } from '../console-primitives'
import { ENCRYPTED_VALUE_MASK } from '../encrypted-value-input'
import { ResourceListPage, ResourceSearch } from '../console-list-page'
import {
  settingDescription,
  settingGroup,
  settingOwnerRoute,
  settingRows,
  type SettingGroup
} from '../state/setting-groups'
import { SettingEditorModel } from '../state/setting-editor-model'
import { SettingGroupEditorModel } from '../state/setting-group-editor-model'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import { useEditorDraft } from '../use-editor-draft'
import { OBSERVABILITY_TRACE_KEYS } from '../state/observability-setting-editor'
import { BrainSettingsEditor } from './brain-settings-editor'
import { ObservabilitySettingsEditor } from './observability-settings-editor'
import { SettingValueEditor } from './setting-value-editors'

const SETTING_MUTATION_KEY = ['app-configurations']

const SETTING_API = {
  global: {
    index: listSiteAppConfigurationsOptions,
    show: getSiteAppConfigurationOptions,
    update: updateSiteAppConfigurationMutation,
    remove: resetSiteAppConfigurationMutation,
    decrypt: decryptSiteAppConfigurationMutation
  },
  tenant: {
    index: listAppConfigurationsOptions,
    show: getAppConfigurationOptions,
    update: updateAppConfigurationMutation,
    remove: resetAppConfigurationMutation,
    decrypt: decryptAppConfigurationMutation
  }
} as const

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
  const globalList = useQuery(listSiteAppConfigurationsOptions())
  const tenantList = useQuery(listAppConfigurationsOptions())
  const globalItems = new Map((globalList.data?.app_configurations ?? []).map(item => [item.key, item]))
  const tenantItems = new Map((tenantList.data?.app_configurations ?? []).map(item => [item.key, item]))
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const allItems = [...new Map([...tenantItems, ...globalItems]).values()]
  const items = searchQuery
    ? allItems.filter(item =>
        matchesResourceSearch(
          searchQuery,
          item.key,
          settingDescription(t, item),
          item.kind,
          t(`console.settings.kind_${item.kind}`),
          ...[globalItems.get(item.key), tenantItems.get(item.key)].flatMap(value =>
            value
              ? [
                  value.source,
                  t(`console.settings.source_${value.source}`),
                  value.encrypted ? t('console.status.encrypted') : ''
                ]
              : []
          )
        )
      )
    : allItems
  const rows = settingRows(items)
  const [managedOpen, setManagedOpen] = useState(false)
  const row = (item: AppConfigurationItem) => (
    <SettingRow
      key={`${item.kind}:${item.key}`}
      item={item}
      globalItem={globalItems.get(item.key)}
      tenantItem={tenantItems.get(item.key)}
    />
  )

  return (
    <ResourceListPage
      title={t('console.settings.title')}
      description={t('console.settings.description')}
      columns={[
        t('console.settings.key'),
        t('console.settings.kind'),
        t('console.settings.scope_global'),
        t('console.settings.scope_tenant')
      ]}
      isLoading={globalList.isLoading || tenantList.isLoading}
      isEmpty={items.length === 0}
      count={items.length}
      emptyTitle={t('console.settings.empty_title')}
      emptyIcon={<RiSettings3Line aria-hidden />}
      emptyDescription={t('console.no_settings')}
      error={globalList.error ?? tenantList.error}
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
        <Fragment key={group.id}>
          <SettingGroupRow group={group} tenantItems={tenantItems} />
          {group.items.map(row)}
        </Fragment>
      ))}
      {rows.singles.map(row)}
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
      {managedOpen ? rows.managed.map(row) : null}
    </ResourceListPage>
  )
}

function SettingValueCell({ item, scope }: { item?: AppConfigurationItem; scope: 'global' | 'tenant' }) {
  const { t } = useTranslation()
  if (!item) return <TableCell className="text-muted-foreground">—</TableCell>
  const value =
    item.kind === 'pattern'
      ? '—'
      : item.encrypted && item.present
        ? ENCRYPTED_VALUE_MASK
        : item.present
          ? formatJSON(item.value ?? null)
          : t('console.settings.source_missing')
  return (
    <TableCell className="max-w-72 whitespace-normal">
      <div className="grid gap-1.5">
        <code className="line-clamp-3 break-all text-xs">{value}</code>
        <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
          <span>{t(`console.settings.source_${item.source}`)}</span>
          {item.encrypted ? <Badge variant="info">{t('console.status.encrypted')}</Badge> : null}
          {item.editable ? (
            <Link className="link" to={encodeURIComponent(item.key)} search={{ scope }}>
              {t('common.edit')}
            </Link>
          ) : null}
        </div>
      </div>
    </TableCell>
  )
}

function SettingRow({
  item,
  globalItem,
  tenantItem
}: {
  item: AppConfigurationItem
  globalItem?: AppConfigurationItem
  tenantItem?: AppConfigurationItem
}) {
  const { t } = useTranslation()
  const description = settingDescription(t, item)
  const ownerRoute = settingOwnerRoute(item.key)
  return (
    <TableRow>
      <TableCell className="max-w-[440px] whitespace-normal">
        <div className="grid gap-1.5">
          <span className="break-all font-mono text-xs">{item.key}</span>
          {description ? (
            <span className="line-clamp-2 text-xs leading-5 text-muted-foreground">{description}</span>
          ) : null}
        </div>
      </TableCell>
      <TableCell>
        <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>
          {t(`console.settings.kind_${item.kind}`)}
        </Badge>
      </TableCell>
      <SettingValueCell item={globalItem} scope="global" />
      <SettingValueCell item={tenantItem} scope="tenant" />
      <TableCell className="text-right">
        {ownerRoute ? (
          <Link className="link text-xs" to={ownerRoute}>
            {t('console.settings.managed_elsewhere')}
          </Link>
        ) : !globalItem?.editable && !tenantItem?.editable ? (
          <span className="text-xs text-muted-foreground">{t('console.settings.read_only')}</span>
        ) : null}
      </TableCell>
    </TableRow>
  )
}

function SettingGroupRow({
  group,
  tenantItems
}: {
  group: SettingGroup
  tenantItems: Map<string, AppConfigurationItem>
}) {
  const { t } = useTranslation()
  return (
    <TableRow className="bg-muted/30">
      <TableCell colSpan={2} className="whitespace-normal">
        <div className="grid gap-1">
          <span className="text-sm font-medium">{t(`console.settings.group_${group.id}`)}</span>
          <span className="text-xs text-muted-foreground">{t(`console.settings.group_${group.id}_description`)}</span>
        </div>
      </TableCell>
      <TableCell>
        <Link className="link text-xs" to={`group/${group.id}`} search={{ scope: 'global' }}>
          {t('common.edit')}
        </Link>
      </TableCell>
      <TableCell>
        {group.items.some(item => tenantItems.get(item.key)?.editable) ? (
          <Link className="link text-xs" to={`group/${group.id}`} search={{ scope: 'tenant' }}>
            {t('common.edit')}
          </Link>
        ) : null}
      </TableCell>
      <TableCell />
    </TableRow>
  )
}

export function SettingEditorDrawer() {
  useSignals()
  const { t } = useTranslation()
  const formCompleteness = useFormCompleteness()
  const navigate = useNavigate()
  const model = useModel(SettingEditorModel)
  const params = useParams({ strict: false })
  const [searchParams] = useSearchParams()
  const scope = searchParams.get('scope') === 'global' ? 'global' : 'tenant'
  const api = SETTING_API[scope]
  const key = params.key ?? ''
  const [restoreDefaultOpen, setRestoreDefaultOpen] = useState(false)
  // Global writes can change the inherited tenant value for the same key.
  const writing =
    useIsMutating({
      mutationKey: SETTING_MUTATION_KEY,
      predicate: mutation => (mutation.state.variables as { path: { key: string } }).path.key === key
    }) > 0

  const list = useQuery(api.index())
  const summary = list.data?.app_configurations.find(item => item.key === key)
  const detail = useQuery({
    ...api.show({ path: { key } }),
    enabled: Boolean(summary?.editable && key) && !writing,
    staleTime: 0
  })
  const item = detail.data?.app_configuration ?? summary
  const description = item ? settingDescription(t, item) : undefined
  const sourceKey = `setting:${scope}:${key}`
  const sourceReady =
    model.sourceKey.value === sourceKey ||
    (!writing && detail.isFetchedAfterMount && detail.isSuccess && detail.fetchStatus === 'idle')
  const settingDraft =
    !item || !sourceReady
      ? undefined
      : item.encrypted
        ? item.present
          ? ENCRYPTED_VALUE_MASK
          : ''
        : formatJSON(item.value ?? null)
  const draftStatus = useEditorDraft(model, {
    sourceKey,
    source: settingDraft,
    absent: () => requestErrorCode(detail.error) === 'not_found' || (list.isSuccess && !list.isFetching && !item)
  })
  const initialized = draftStatus === 'ready'

  const decrypt = useMutation({
    meta: { invalidates: false },
    ...api.decrypt(),
    gcTime: 0
  })
  const reveal = () => {
    if (!item || !initialized) return
    return model
      .reveal(async () => (await decrypt.mutateAsync({ path: { key: item.key } })).decrypted_value.value)
      .catch(error => toast.error(requestErrorMessage(error)))
  }
  const finish = (message: string, clean: boolean) => {
    toast.success(message)
    if (!clean) return
    model.resetSource()
    decrypt.reset()
    void navigate({ to: '/settings' })
  }
  const update = useMutation({ ...api.update(), mutationKey: SETTING_MUTATION_KEY })
  const restoreDefault = useMutation({ ...api.remove(), mutationKey: SETTING_MUTATION_KEY })
  const restore = () => {
    if (!item?.overridden) return
    return model
      .restore(
        async () => (await restoreDefault.mutateAsync({ path: { key: item.key } })).app_configuration,
        clean => {
          setRestoreDefaultOpen(false)
          finish(t('console.settings.reset_done', { key: item.key }), clean)
        }
      )
      .catch(error => toast.error(requestErrorMessage(error)))
  }

  useEffect(() => {
    decrypt.reset()
    update.reset()
    restoreDefault.reset()
    setRestoreDefaultOpen(false)
  }, [decrypt.reset, update.reset, restoreDefault.reset, key, scope])

  const saving = update.isPending || restoreDefault.isPending
  const requestClose = () => {
    if (!saving) void navigate({ to: '/settings' })
  }
  const drawerError =
    model.validationError.value ??
    update.error ??
    restoreDefault.error ??
    decrypt.error ??
    (draftStatus === 'absent' ? t('console.settings.not_found') : undefined) ??
    detail.error ??
    (item && !item.editable ? t('console.settings.read_only') : undefined)

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (!event.currentTarget.reportValidity()) {
      focusFirstInvalidControl(event.currentTarget)
      return
    }
    if (!item?.editable || !initialized) return
    return model
      .save(
        item.encrypted,
        t,
        body => update.mutateAsync({ body: { data: body }, path: { key: item.key } }),
        clean => finish(t('console.settings.saved', { key: item.key }), clean)
      )
      .catch(error => toast.error(requestErrorMessage(error)))
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
            onInvalidCapture={event => event.preventDefault()}
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
                <Badge variant="secondary">{t(`console.settings.scope_${scope}`)}</Badge>
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
              {!initialized && (list.isLoading || detail.isFetching || writing) ? (
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
                        revealed: model.revealed.value,
                        revealing: decrypt.isPending,
                        onReveal: reveal
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
              {scope === 'tenant'
                ? t('console.settings.restore_tenant_description', { key })
                : item?.default_present
                  ? t('console.settings.restore_default_description', { key })
                  : t('console.settings.restore_unset_description', { key })}
              {model.dirty.value ? ` ${t('console.settings.restore_default_dirty_note')}` : null}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={restoreDefault.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button disabled={restoreDefault.isPending || !item?.overridden} variant="destructive" onClick={restore}>
              {restoreDefault.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.settings.restore_default_confirm')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <EditorNavigationGuard blocked={model.dirty.value && !saving} />
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
  useSignals()
  const { t } = useTranslation()
  const formCompleteness = useFormCompleteness()
  const navigate = useNavigate()
  const model = useModel(SettingGroupEditorModel)
  const params = useParams({ strict: false })
  const [searchParams] = useSearchParams()
  const scope = searchParams.get('scope') === 'global' ? 'global' : 'tenant'
  const api = SETTING_API[scope]
  const groupID = params.group ?? ''
  const group = settingGroup(groupID)
  const [restoreItem, setRestoreItem] = useState<AppConfigurationItem>()
  const writing =
    useIsMutating({
      mutationKey: SETTING_MUTATION_KEY,
      predicate: mutation =>
        Boolean(group && (mutation.state.variables as { path: { key: string } }).path.key.startsWith(group.prefix))
    }) > 0

  const list = useQuery({ ...api.index(), enabled: !writing, staleTime: 0 })
  const items = (list.data?.app_configurations ?? []).filter(
    item => item.editable && group !== undefined && item.key.startsWith(group.prefix)
  )
  const sourceKey = `setting-group:${scope}:${groupID}`
  const sourceReady =
    model.sourceKey.value === sourceKey ||
    (!writing && list.isFetchedAfterMount && list.isSuccess && list.fetchStatus === 'idle')
  const draftStatus = useEditorDraft(model, {
    sourceKey,
    source: sourceReady && group && items.length ? { kind: group.id, items } : undefined,
    absent: () => list.isSuccess && !list.isFetching && items.length === 0
  })
  const saving = model.saving.value
  const headersItem = items.find(item => item.key === OBSERVABILITY_TRACE_KEYS.headers)

  const update = useMutation({ ...api.update(), mutationKey: SETTING_MUTATION_KEY })
  const decrypt = useMutation({
    meta: { invalidates: false },
    ...api.decrypt(),
    gcTime: 0
  })
  const restoreDefault = useMutation({ ...api.remove(), mutationKey: SETTING_MUTATION_KEY })

  useEffect(() => {
    decrypt.reset()
    update.reset()
    restoreDefault.reset()
    setRestoreItem(undefined)
  }, [decrypt.reset, update.reset, restoreDefault.reset, groupID, scope])

  const revealHeaders = () => {
    if (!headersItem || draftStatus !== 'ready') return
    return model
      .revealHeaders(
        async () => (await decrypt.mutateAsync({ path: { key: headersItem.key } })).decrypted_value.value,
        t
      )
      .catch(error => toast.error(requestErrorMessage(error)))
  }

  const restore = () => {
    if (!restoreItem) return
    return model
      .restore(
        restoreItem.key,
        async () => (await restoreDefault.mutateAsync({ path: { key: restoreItem.key } })).app_configuration,
        item => {
          setRestoreItem(undefined)
          if (item.key === OBSERVABILITY_TRACE_KEYS.headers) decrypt.reset()
          toast.success(t('console.settings.reset_done', { key: item.key }))
        }
      )
      .catch(error => toast.error(requestErrorMessage(error)))
  }

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (!event.currentTarget.reportValidity()) {
      focusFirstInvalidControl(event.currentTarget)
      return
    }
    if (draftStatus !== 'ready') return
    return model
      .save(
        items,
        t,
        (key, value) => update.mutateAsync({ body: { data: { value } }, path: { key } }),
        (count, clean) => {
          toast.success(t('console.settings.group_saved', { count }))
          if (clean) void navigate({ to: '/settings' })
        }
      )
      .catch(error => toast.error(requestErrorMessage(error)))
  }

  const busy = saving || restoreDefault.isPending
  const requestClose = () => {
    if (!busy) void navigate({ to: '/settings' })
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
            onInvalidCapture={event => event.preventDefault()}
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
              {/* A stale or hand-typed group id has no catalog entry; the id
                  itself beats a raw i18n key as the title, and the body below
                  already explains the miss. */}
              <Badge variant="secondary" className="w-fit">
                {t(`console.settings.scope_${scope}`)}
              </Badge>
              <DrawerTitle className="text-lg">
                {t(`console.settings.group_${groupID}`, { defaultValue: groupID })}
              </DrawerTitle>
              <DrawerDescription className="text-left text-pretty">
                {t(`console.settings.group_${groupID}_description`, { defaultValue: '' })}
              </DrawerDescription>
            </DrawerHeader>

            <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-5">
              {list.isLoading || (draftStatus === 'loading' && !list.isError) ? (
                <div className="grid gap-4">
                  <Skeleton className="h-24 w-full" />
                  <Skeleton className="h-64 w-full" />
                </div>
              ) : (
                <div className="grid gap-8">
                  <ErrorBlock
                    error={
                      model.validationError.value ??
                      restoreDefault.error ??
                      decrypt.error ??
                      list.error ??
                      (draftStatus === 'absent' ? t('console.settings.not_found') : undefined)
                    }
                  />

                  {draftStatus === 'ready' && group?.id === 'brain' ? (
                    <BrainSettingsEditor
                      drafts={model.drafts.value}
                      items={items}
                      models={model.brainModels.value}
                      saving={saving || restoreDefault.isPending}
                      onDraftChange={model.setDraft}
                      onModelChange={model.setBrainModel}
                      onRestore={setRestoreItem}
                    />
                  ) : draftStatus === 'ready' && group?.id === 'observability' ? (
                    <ObservabilitySettingsEditor
                      drafts={model.drafts.value}
                      headerRows={model.headerRows.value}
                      headerRevealing={decrypt.isPending}
                      items={items}
                      saving={saving || restoreDefault.isPending}
                      onDraftChange={model.setDraft}
                      onHeaderRowsChange={model.setHeaderRows}
                      onReplaceHeaders={() => model.setHeaderRows([])}
                      onRestore={setRestoreItem}
                      onRevealHeaders={revealHeaders}
                    />
                  ) : null}
                </div>
              )}
            </div>

            <DrawerFooter className="flex-row items-center justify-end gap-2 border-t border-border p-4">
              {model.dirty.value ? (
                <span className="mr-auto text-xs text-muted-foreground">{t('console.settings.unsaved')}</span>
              ) : null}
              <Button disabled={busy} type="button" variant="ghost" onClick={requestClose}>
                {t('common.cancel')}
              </Button>
              <SaveButton
                disabled={busy || draftStatus !== 'ready' || (!model.dirty.value && !formCompleteness.incomplete)}
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
              {scope === 'tenant'
                ? t('console.settings.restore_tenant_description', { key: restoreItem?.key ?? '' })
                : restoreItem?.default_present
                  ? t('console.settings.restore_default_description', { key: restoreItem.key })
                  : t('console.settings.restore_unset_description', { key: restoreItem?.key })}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={restoreDefault.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button disabled={restoreDefault.isPending} variant="destructive" onClick={restore}>
              {restoreDefault.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.settings.restore_default_confirm')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <EditorNavigationGuard blocked={model.dirty.value && !saving} />
    </>
  )
}
