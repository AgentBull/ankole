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
import { RiCloseLine, RiLoaderLine, RiMore2Fill, RiResetLeftLine } from '@remixicon/react'
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
import { ErrorBlock, formatJSON, parseJSON } from '../console-primitives'
import { ENCRYPTED_VALUE_MASK, isEncryptedValueMask } from '../encrypted-value-input'
import { ResourceListPage, ResourceSearch, RowActions } from '../console-shell'
import { SettingEditorModel } from '../state/setting-editor-model'
import { matchesResourceSearch } from '../state/resource-search'
import { settingDescription } from '../state/setting-description'
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
  const items = (list.data?.app_configurations ?? []).filter(item =>
    matchesResourceSearch(
      deferredQuery,
      item.key,
      settingDescription(t, item),
      item.kind,
      item.source,
      item.encrypted ? 'encrypted' : '',
      item.overridden ? 'overridden' : ''
    )
  )

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
      emptyTitle={t('console.settings.empty_title')}
      emptyDescription={t('console.no_settings')}
      error={list.error}
      isFiltered={Boolean(query.trim())}
      toolbar={
        <ResourceSearch
          label={t('console.settings.search')}
          placeholder={t('console.settings.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }>
      {items.map(item => {
        const description = settingDescription(t, item)

        return (
          <TableRow key={`${item.kind}:${item.key}`}>
            <TableCell className="max-w-[440px] whitespace-normal">
              <div className="grid gap-1.5">
                {item.editable ? (
                  <Link
                    className="break-all font-mono text-xs text-foreground hover:text-primary hover:underline"
                    to={encodeURIComponent(item.key)}>
                    {item.key}
                  </Link>
                ) : (
                  <span className="break-all font-mono text-xs">{item.key}</span>
                )}
                {description ? (
                  <span className="line-clamp-2 text-xs leading-5 text-muted-foreground">{description}</span>
                ) : null}
              </div>
            </TableCell>
            <TableCell>
              <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>{item.kind}</Badge>
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
                <span className="pr-2 text-xs text-muted-foreground">{t('console.settings.read_only')}</span>
              </TableCell>
            )}
          </TableRow>
        )
      })}
    </ResourceListPage>
  )
}

export function SettingEditorDrawer() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const model = useModel(SettingEditorModel)
  const params = useParams()
  const key = params.key ? decodeURIComponent(params.key) : ''
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
    onSuccess: response => model.reveal(JSON.stringify(response.decrypted_value.value) ?? ''),
    onError: mutationError => toast.error(requestErrorMessage(mutationError))
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
    onError: mutationError => toast.error(requestErrorMessage(mutationError))
  })
  const restoreDefault = useMutation({
    ...ankoleWebAppConfigurationControllerDeleteMutation(),
    onSuccess: () => {
      setRestoreDefaultOpen(false)
      finish(t('console.settings.reset_done', { key }))
    },
    onError: mutationError => toast.error(requestErrorMessage(mutationError))
  })

  useEffect(() => {
    decrypt.reset()
    if (!item || detail.isLoading) return
    model.initialize(
      sourceKey,
      item.encrypted ? (item.present ? ENCRYPTED_VALUE_MASK : '') : formatJSON(item.value ?? null)
    )
  }, [detail.isLoading, item, model, sourceKey])

  const requestClose = () => navigate('/settings')
  const saving = update.isPending || restoreDefault.isPending
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
    const parsed = parseJSON(model.text.value, t('console.settings.value'))
    if (!parsed.ok) {
      model.validationError.value = parsed.error
      return
    }
    update.mutate({ body: { value: parsed.value }, path: { key: item.key } })
  }

  return (
    <>
      <Drawer open onOpenChange={open => !open && requestClose()} swipeDirection="right">
        <DrawerContent className="data-[swipe-axis=x]:[--drawer-content-width:100%] data-[swipe-axis=x]:sm:[--drawer-content-width:42rem]">
          <form className="flex min-h-0 flex-1 flex-col" onSubmit={submit}>
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
                  size="icon-sm"
                  type="button"
                  variant="ghost"
                  onClick={requestClose}>
                  <RiCloseLine />
                </Button>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                {item ? <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>{item.kind}</Badge> : null}
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
              <Button disabled={!item?.editable || !initialized || !model.dirty.value || saving} type="submit">
                {saving ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
                {t('common.save')}
              </Button>
            </DrawerFooter>
          </form>
        </DrawerContent>
      </Drawer>

      <Dialog open={restoreDefaultOpen} onOpenChange={setRestoreDefaultOpen}>
        <DialogContent>
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

      <Dialog open={blocker.state === 'blocked'}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('console.settings.discard_title')}</DialogTitle>
            <DialogDescription>{t('console.settings.discard_description')}</DialogDescription>
          </DialogHeader>
          <DialogFooter showCloseButton={false}>
            <DialogClose render={<Button variant="outline" />} onClick={() => blocker.reset?.()}>
              {t('console.settings.keep_editing')}
            </DialogClose>
            <Button variant="destructive" onClick={() => blocker.proceed?.()}>
              {t('console.settings.discard')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
