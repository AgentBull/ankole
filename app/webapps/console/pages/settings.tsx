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
  toast
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { RiCloseLine, RiLoaderLine, RiMore2Fill, RiResetLeftLine } from '@remixicon/react'
import { useIsMutating, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, Navigate, Outlet, useNavigate, useParams } from '@tanstack/react-router'
import { linkTarget, useSearchParams } from '../../common/router'
import { dataTenantID } from '../../common/browser-session'
import i18n from '../../common/i18n'
import { requestErrorCode, requestErrorDetailList, requestErrorMessage } from '../../common/request-errors'
import {
  decryptSiteAppConfigurationMutation,
  getPrivilegedTenantOptions,
  resetSiteAppConfigurationMutation,
  listSiteAppConfigurationsOptions,
  getSiteAppConfigurationOptions,
  updateSiteAppConfigurationMutation,
  updateSiteAppConfigurationGroupMutation,
  testSiteAuthenticationMailMutation
} from '../api/v2-site/generated/@tanstack/react-query.gen'
import { fromDocument } from '../api/json-api'
import {
  decryptAppConfigurationMutation,
  resetAppConfigurationMutation,
  listAppConfigurationsOptions,
  getAppConfigurationOptions,
  updateAppConfigurationMutation,
  updateAppConfigurationGroupMutation
} from '../api/v2/generated/@tanstack/react-query.gen'
import type { AppConfigurationItem } from '../api/configuration-types'
import { EditorNavigationGuard, SaveButton, focusFirstInvalidControl, useFormCompleteness } from '../console-form'
import { ErrorBlock } from '../../common/error-block'
import { formatJSON } from '../console-primitives'
import { ENCRYPTED_VALUE_MASK } from '../encrypted-value-input'
import { settingDescription, settingGroup, settingGroupID, settingOwnerRoute } from '../state/setting-groups'
import { SettingsList, SettingsTenantContext } from './settings-list'
import { settingsScope, settingsSearch } from '../state/settings-search'
import { SettingEditorModel, syncConsoleLocaleIfPrivileged } from '../state/setting-editor-model'
import { SettingGroupEditorModel } from '../state/setting-group-editor-model'
import { useEditorDraft } from '../use-editor-draft'
import { OBSERVABILITY_TRACE_KEYS } from '../state/observability-setting-editor'
import { BrainSettingsEditor } from './brain-settings-editor'
import { ObservabilitySettingsEditor } from './observability-settings-editor'
import { SettingValueEditor } from './setting-value-editors'
import { SettingsTaskEditor } from './settings-task-editor'
import { settingDurationParts } from '../state/setting-value-editor'

const SETTING_MUTATION_KEY = ['app-configurations']

const SETTING_API = {
  global: {
    index: listSiteAppConfigurationsOptions,
    show: getSiteAppConfigurationOptions,
    update: updateSiteAppConfigurationMutation,
    groupUpdate: updateSiteAppConfigurationGroupMutation,
    remove: resetSiteAppConfigurationMutation,
    decrypt: decryptSiteAppConfigurationMutation
  },
  tenant: {
    index: listAppConfigurationsOptions,
    show: getAppConfigurationOptions,
    update: updateAppConfigurationMutation,
    groupUpdate: updateAppConfigurationGroupMutation,
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

export function SettingEditorDrawer() {
  const params = useParams({ strict: false })
  const [search] = useSearchParams()
  const key = params.key ?? ''
  const group = settingGroupID(key)
  const owner = settingOwnerRoute(key)
  if (group) return <Navigate to={`/settings/group/${group}`} search={settingsSearch(search, { focus: key })} replace />
  if (owner) {
    return (
      <Navigate
        {...linkTarget(owner + (key.startsWith('ai_agent.library.') ? `&defaults_scope=${settingsScope(search)}` : ''))}
        replace
      />
    )
  }
  return <SingleSettingEditorDrawer />
}

function SingleSettingEditorDrawer() {
  useSignals()
  const { t } = useTranslation()
  const formCompleteness = useFormCompleteness()
  const navigate = useNavigate()
  const model = useModel(SettingEditorModel)
  const params = useParams({ strict: false })
  const [searchParams] = useSearchParams()
  const scope = settingsScope(searchParams)
  const api = SETTING_API[scope]
  const key = params.key ?? ''
  const [restoreDefaultOpen, setRestoreDefaultOpen] = useState(false)
  // Global writes can change the inherited tenant value for the same key.
  const writing =
    useIsMutating({
      mutationKey: SETTING_MUTATION_KEY,
      predicate: mutation => (mutation.state.variables as { path?: { key?: string } })?.path?.key === key
    }) > 0

  const list = useQuery(api.index())
  const privilegedTenant = useQuery({
    ...getPrivilegedTenantOptions(),
    select: document => fromDocument(document),
    enabled: scope === 'tenant' && key === 'i18n.default_locale'
  })
  const summary = list.data?.app_configurations.find(item => item.key === key)
  const detail = useQuery({
    ...api.show({ path: { key } }),
    enabled: Boolean(summary?.editable && key) && !writing,
    staleTime: 0
  })
  const item = detail.data?.app_configuration ?? summary
  const description = item ? settingDescription(t, item) : undefined
  const sourceKey = `setting:${scope}:${dataTenantID() ?? 'privileged'}:${key}`
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
  useSettingFocus(searchParams.get('focus'), initialized)

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
    void navigate({ to: '/settings', search: settingsSearch(searchParams, { focus: undefined }) })
  }
  const update = useMutation({ ...api.update(), mutationKey: SETTING_MUTATION_KEY })
  const restoreDefault = useMutation({ ...api.remove(), mutationKey: SETTING_MUTATION_KEY })
  const restore = () => {
    if (!item?.overridden) return
    return model
      .restore(
        async () => {
          const restored = (await restoreDefault.mutateAsync({ path: { key: item.key } })).app_configuration
          await syncConsoleLocaleIfPrivileged({
            scope,
            key: item.key,
            value: restored.value,
            selectedTenantID: dataTenantID(),
            privilegedTenantID: privilegedTenant.data?.id
          })
          return restored
        },
        clean => {
          setRestoreDefaultOpen(false)
          finish(i18n.t('console.settings.reset_done', { key: item.key }), clean)
        }
      )
      .catch(error => toast.error(requestErrorMessage(error)))
  }

  useEffect(() => {
    decrypt.reset()
    update.reset()
    restoreDefault.reset()
    setRestoreDefaultOpen(false)
  }, [decrypt.reset, update.reset, restoreDefault.reset, sourceKey])

  const saving = update.isPending || restoreDefault.isPending
  const requestClose = () => {
    if (!saving) void navigate({ to: '/settings', search: settingsSearch(searchParams, { focus: undefined }) })
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
        async body => {
          const saved = (await update.mutateAsync({ body: { data: body }, path: { key: item.key } })).app_configuration
          await syncConsoleLocaleIfPrivileged({
            scope,
            key: item.key,
            value: saved.value,
            selectedTenantID: dataTenantID(),
            privilegedTenantID: privilegedTenant.data?.id
          })
          return saved
        },
        clean => finish(i18n.t('console.settings.saved', { key: item.key }), clean)
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
                <SettingsTenantContext />
                {item ? (
                  <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>
                    {t(`console.settings.kind_${item.kind}`)}
                  </Badge>
                ) : null}
                {item ? <Badge variant="outline">{t(`console.settings.source_${item.source}`)}</Badge> : null}
                {item?.encrypted ? <Badge variant="info">{t('console.status.encrypted')}</Badge> : null}
              </div>
              <DrawerTitle className="text-lg tracking-normal normal-case">
                {t(`console.settings.task_${key.replaceAll('.', '_')}`, { defaultValue: key })}
              </DrawerTitle>
              <code className="break-all text-xs text-muted-foreground">{key}</code>
              <DrawerDescription className="text-left text-pretty">
                {description ?? t('console.settings.editor_description')}
              </DrawerDescription>
              {scope === 'global' && item ? (
                <p className="text-xs text-muted-foreground">
                  {t(
                    item.scope === 'global'
                      ? 'console.settings.site_shared_effect'
                      : 'console.settings.site_default_effect'
                  )}
                </p>
              ) : null}
            </DrawerHeader>

            <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-5">
              {!initialized && (list.isLoading || detail.isFetching || writing) ? (
                <div className="grid gap-4">
                  <Skeleton className="h-24 w-full" />
                  <Skeleton className="h-64 w-full" />
                </div>
              ) : (
                <div
                  data-setting-key={key}
                  className="grid gap-6 data-[search-match=true]:ring-2 data-[search-match=true]:ring-ring">
                  <ErrorBlock error={drawerError} />
                  {item?.editable && initialized ? (
                    <SettingValueEditor
                      key={item.key}
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
              {scope === 'tenant' && item?.scope !== 'pod'
                ? t('console.settings.restore_tenant_description', { key })
                : item?.default_present
                  ? t('console.settings.restore_default_description', { key })
                  : t('console.settings.restore_unset_description', { key })}
              {model.dirty.value ? ` ${t('console.settings.restore_default_dirty_note')}` : null}
              {item ? <SettingFallback item={item} /> : null}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={restoreDefault.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={restoreDefault.isPending || !item?.overridden || item.fallback_source === 'error'}
              variant="destructive"
              onClick={restore}>
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
 * Edits one declared task in one scope. The server validates and commits the entire batch.
 */
export function SettingGroupDrawer() {
  useSignals()
  const queryClient = useQueryClient()
  const { t } = useTranslation()
  const formCompleteness = useFormCompleteness()
  const navigate = useNavigate()
  const model = useModel(SettingGroupEditorModel)
  const params = useParams({ strict: false })
  const [searchParams] = useSearchParams()
  const scope = settingsScope(searchParams)
  const api = SETTING_API[scope]
  const groupID = params.group ?? ''
  const group = settingGroup(groupID)
  const [restoreItem, setRestoreItem] = useState<AppConfigurationItem>()
  const writing =
    useIsMutating({
      mutationKey: SETTING_MUTATION_KEY
    }) > 0

  const list = useQuery({ ...api.index(), enabled: !writing, staleTime: 0 })
  const members = (list.data?.app_configurations ?? []).filter(item => group && settingGroupID(item.key) === group.id)
  const items = members.filter(item => item.editable)
  const sourceKey = `setting-group:${scope}:${dataTenantID() ?? 'privileged'}:${groupID}`
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

  const update = useMutation({
    ...api.groupUpdate(),
    mutationKey: SETTING_MUTATION_KEY,
    onError: () => queryClient.invalidateQueries()
  })
  const errorPath = requestErrorDetailList(update.error).find(detail => typeof detail.path === 'string')?.path
  useSettingFocus(typeof errorPath === 'string' ? errorPath : searchParams.get('focus'), draftStatus === 'ready')
  const testMail = useMutation({ ...testSiteAuthenticationMailMutation(), meta: { invalidates: false } })
  const decrypt = useMutation({
    meta: { invalidates: false },
    ...api.decrypt(),
    gcTime: 0
  })

  useEffect(() => {
    decrypt.reset()
    update.reset()
    setRestoreItem(undefined)
  }, [decrypt.reset, update.reset, sourceKey])

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
        async () => {
          const result = await update.mutateAsync({
            path: { group: groupID },
            body: { data: { values: {}, reset_keys: [restoreItem.key] } }
          })
          return result.app_configurations.find(item => item.key === restoreItem.key)!
        },
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
        values => update.mutateAsync({ body: { data: { values, reset_keys: [] } }, path: { group: groupID } }),
        (count, clean) => {
          toast.success(t('console.settings.group_saved', { count }))
          if (clean) void navigate({ to: '/settings', search: settingsSearch(searchParams, { focus: undefined }) })
        }
      )
      .catch(error => toast.error(requestErrorMessage(error)))
  }

  const busy = saving || update.isPending
  const requestClose = () => {
    if (!busy) void navigate({ to: '/settings', search: settingsSearch(searchParams, { focus: undefined }) })
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
              <div className="flex flex-wrap items-center gap-2">
                <Badge variant="secondary" className="w-fit">
                  {t(`console.settings.scope_${scope}`)}
                </Badge>
                <SettingsTenantContext />
              </div>
              {scope === 'global' ? (
                <p className="text-xs text-muted-foreground">
                  {t(
                    members.every(item => item.scope === 'global')
                      ? 'console.settings.site_shared_effect'
                      : members.some(item => item.scope === 'global')
                        ? 'console.settings.site_mixed_effect'
                        : 'console.settings.site_default_effect'
                  )}
                </p>
              ) : null}
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
                      update.error ??
                      decrypt.error ??
                      list.error ??
                      (draftStatus === 'absent' ? t('console.settings.not_found') : undefined)
                    }
                  />

                  {group?.id === 'brain' && scope === 'tenant' ? (
                    <div className="grid gap-2 border border-border p-4">
                      <p className="text-sm font-medium">{t('console.settings.site_foundation')}</p>
                      {members
                        .filter(item => item.scope === 'global')
                        .map(item => (
                          <div
                            key={item.key}
                            data-setting-key={item.key}
                            tabIndex={-1}
                            className="grid gap-1 text-xs data-[search-match=true]:ring-2 data-[search-match=true]:ring-ring">
                            <code>{item.key}</code>
                            <span>{formatJSON(item.value)}</span>
                          </div>
                        ))}
                      <Link
                        className="link text-xs"
                        to="/settings/group/brain"
                        search={settingsSearch(searchParams, { scope: 'global' })}>
                        {t('console.settings.open_site_task')}
                      </Link>
                    </div>
                  ) : null}
                  {group?.id === 'brain' ? (
                    <p className="text-sm">
                      {t('console.settings.schedule_timezone', {
                        timezone:
                          list.data?.app_configurations.find(item => item.key === 'system.timezone')?.value ?? '—'
                      })}{' '}
                      ·{' '}
                      <Link
                        className="link"
                        to="/settings/system.timezone"
                        search={settingsSearch(searchParams, { focus: undefined })}>
                        {t('common.edit')}
                      </Link>
                    </p>
                  ) : null}
                  {members.find(item => item.runtime_status) ? (
                    <p role="status" className="text-sm">
                      {t(`console.settings.runtime_${members.find(item => item.runtime_status)!.runtime_status}`)}
                    </p>
                  ) : null}
                  {draftStatus === 'ready' && group?.id === 'brain' ? (
                    <BrainSettingsEditor
                      drafts={model.drafts.value}
                      items={items}
                      models={model.brainModels.value}
                      saving={busy}
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
                      saving={busy}
                      onDraftChange={model.setDraft}
                      onHeaderRowsChange={model.setHeaderRows}
                      onReplaceHeaders={() => model.setHeaderRows([])}
                      onRestore={setRestoreItem}
                      onRevealHeaders={revealHeaders}
                    />
                  ) : draftStatus === 'ready' && group ? (
                    <SettingsTaskEditor
                      key={sourceKey}
                      group={group.id}
                      items={items}
                      drafts={model.drafts.value}
                      onDraftChange={model.setDraft}
                      onRestore={setRestoreItem}
                      saving={busy}
                      testMail={(settings, recipient) =>
                        testMail.mutateAsync({
                          path: { key: 'authn.email.mail' },
                          body: { data: { settings, recipient } }
                        })
                      }
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
        onOpenChange={open => !open && !update.isPending && setRestoreItem(undefined)}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!update.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.settings.restore_default_title')}</DialogTitle>
            <DialogDescription>
              {scope === 'tenant' && restoreItem?.scope !== 'pod'
                ? t('console.settings.restore_tenant_description', { key: restoreItem?.key ?? '' })
                : restoreItem?.default_present
                  ? t('console.settings.restore_default_description', { key: restoreItem.key })
                  : t('console.settings.restore_unset_description', { key: restoreItem?.key })}
              {restoreItem ? <SettingFallback item={restoreItem} /> : null}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={update.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={update.isPending || restoreItem?.fallback_source === 'error'}
              variant="destructive"
              onClick={restore}>
              {update.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.settings.restore_default_confirm')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <EditorNavigationGuard blocked={model.dirty.value && !saving} />
    </>
  )
}

function SettingFallback({ item }: { item: AppConfigurationItem }) {
  const { t } = useTranslation()
  const display = (present: boolean, value: unknown) => {
    const duration = settingDurationParts(item.key, value)
    if (present && item.key === 'ai_agent.max_output_tokens' && value == null) {
      return t('console.settings.no_explicit_limit')
    }
    if (present && item.key === 'ai_agent.inactivity_timeout_ms' && value === 0) {
      return t('console.settings.inactivity_timeout_disabled')
    }
    return !present
      ? t('console.settings.source_missing')
      : item.encrypted
        ? '••••••••'
        : duration
          ? `${duration.amount} ${t(`console.settings.unit_${duration.unit}`)}`
          : formatJSON(value ?? null)
  }
  return (
    <span className="mt-3 block break-all text-sm">
      {t('console.settings.reset_preview', {
        current: display(item.present, item.value),
        fallback: display(Boolean(item.fallback_present), item.fallback_value),
        source: t(`console.settings.source_${item.fallback_source ?? 'missing'}`)
      })}
      {['pod.trash_retention_days', 'brain.soft_delete_retention_hours'].includes(item.key) &&
      Number(item.fallback_value) < Number(item.value) ? (
        <span className="mt-2 block text-warning-foreground">{t('console.settings.retention_warning')}</span>
      ) : null}
    </span>
  )
}

function useSettingFocus(focus: string | null, ready: boolean) {
  useEffect(() => {
    if (!focus || !ready) return
    const section = [...document.querySelectorAll<HTMLElement>('[data-setting-key]')].find(
      node => focus === node.dataset.settingKey || focus.startsWith(`${node.dataset.settingKey}.`)
    )
    if (!section) return
    section.dataset.searchMatch = 'true'
    const field = [...section.querySelectorAll<HTMLElement>('[data-setting-field]')].find(node =>
      focus.endsWith(`.${node.dataset.settingField}`)
    )
    const target = field?.matches('input, select, textarea, [role="combobox"], [role="switch"]')
      ? field
      : (field ?? section).querySelector<HTMLElement>('input, select, textarea, [role="combobox"], [role="switch"]')
    section.scrollIntoView({ block: 'center' })
    target?.focus({ preventScroll: true })
    const timer = setTimeout(() => {
      delete section.dataset.searchMatch
    }, 2000)
    return () => {
      clearTimeout(timer)
      delete section.dataset.searchMatch
    }
  }, [focus, ready])
}
