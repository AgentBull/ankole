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
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  TableRow,
  toast
} from '@ankole/uikit'
import { RiInboxArchiveLine, RiLoaderLine } from '@remixicon/react'
import { useMutation, useInfiniteQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  archiveBrainSourceMutation,
  createBrainSourceMutation,
  learnBrainSourceMutation,
  listBrainSourcesInfiniteOptions,
  updateBrainSourceMutation
} from '../../api/v2/generated/@tanstack/react-query.gen'
import type { ListBrainSourcesResponse } from '../../api/v2/generated/types.gen'
import { nextPageParams, fromDocument, type Flat } from '../../api/json-api'
import { requestErrorMessage } from '../../../common/request-errors'
import { formatConsoleDate } from '../../console-primitives'
import { DiscardConfirmDialog, LabeledField, focusFirstInvalidControl, useDialogDiscardGuard } from '../../console-form'
import { ResourceListPage } from '../../console-list-page'
import { BrainSubNav } from './brain-nav'
import { BrainScopeLabel, BrainScopeSelector } from './brain-scope'

const SOURCE_KINDS = ['file', 'url'] as const

type BrainSource = Flat<NonNullable<ListBrainSourcesResponse['data']>[number]>

export function BrainSourcesPage() {
  const { t } = useTranslation()
  const [registerOpen, setRegisterOpen] = useState(false)
  const [kind, setKind] = useState<(typeof SOURCE_KINDS)[number]>('file')
  const [upstreamID, setUpstreamID] = useState('')
  const [name, setName] = useState('')
  const [scope, setScope] = useState('')
  const [archiveTarget, setArchiveTarget] = useState<BrainSource>()
  const [scopeTarget, setScopeTarget] = useState<BrainSource>()
  const [sourceScope, setSourceScope] = useState('')

  const sources = useInfiniteQuery({
    ...listBrainSourcesInfiniteOptions(),
    initialPageParam: {},
    getNextPageParam: nextPageParams,
    select: data => data.pages.flatMap(document => fromDocument(document))
  })
  const rows = sources.data ?? []

  const registerDirty = kind !== 'file' || Boolean(upstreamID.trim() || name.trim() || scope.trim())

  // Every open starts a fresh form; a cancelled draft never resurfaces later.
  const openRegister = () => {
    setKind('file')
    setUpstreamID('')
    setName('')
    setScope('')
    setRegisterOpen(true)
  }
  const register = useMutation({
    ...createBrainSourceMutation(),
    onSuccess: response => {
      toast.success(t('console.brain.source_registered', { name: response.name }))
      setRegisterOpen(false)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const registerGuard = useDialogDiscardGuard({
    dirty: registerDirty,
    onOpenChange: setRegisterOpen,
    pending: register.isPending
  })
  const learn = useMutation({
    ...learnBrainSourceMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.learn_done'))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const archive = useMutation({
    ...archiveBrainSourceMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.archive_done'))
      setArchiveTarget(undefined)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const updateScope = useMutation({
    ...updateBrainSourceMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.source_scope_saved'))
      setScopeTarget(undefined)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const scopeGuard = useDialogDiscardGuard({
    dirty: sourceScope !== (scopeTarget?.default_audience_scope ?? ''),
    onOpenChange: open => !open && setScopeTarget(undefined),
    pending: updateScope.isPending
  })

  return (
    <>
      <ResourceListPage
        title={t('console.brain.sources_title')}
        description={t('console.brain.sources_description')}
        subNav={<BrainSubNav />}
        columns={[
          t('console.brain.source_name'),
          t('console.brain.kind'),
          t('console.brain.upstream_id'),
          t('console.brain.scope'),
          t('console.brain.last_sync'),
          t('console.brain.state')
        ]}
        isLoading={sources.isLoading}
        isEmpty={rows.length === 0}
        count={rows.length}
        emptyTitle={t('console.brain.sources_empty_title')}
        emptyDescription={t('console.brain.sources_empty_description')}
        emptyIcon={<RiInboxArchiveLine aria-hidden />}
        pagination={sources}
        createAction={
          <Button size="sm" type="button" onClick={openRegister}>
            {t('console.brain.register_source')}
          </Button>
        }>
        {rows.map(source => (
          <TableRow key={source.id} className={source.archived_at ? 'opacity-60' : undefined}>
            <TableCell className="text-sm">{source.name}</TableCell>
            <TableCell>
              <Badge variant="secondary">
                {source.kind === 'library' || source.kind === 'oidc_client'
                  ? t(`console.brain.source_kind_${source.kind}`)
                  : source.kind}
              </Badge>
            </TableCell>
            <TableCell className="max-w-[280px] truncate font-mono text-xs">{source.upstream_id}</TableCell>
            <TableCell>
              {source.default_audience_scope ? (
                <BrainScopeLabel scope={source.default_audience_scope} />
              ) : (
                <span className="text-xs text-muted-foreground">
                  {source.kind === 'oidc_client' ? t('console.brain.source_scope_private') : '—'}
                </span>
              )}
            </TableCell>
            <TableCell className="text-xs text-muted-foreground">
              {source.last_sync_at ? formatConsoleDate(source.last_sync_at) : t('console.brain.never_synced')}
            </TableCell>
            <TableCell>
              {source.archived_at ? (
                <Badge variant="outline">{t('console.brain.archived')}</Badge>
              ) : (
                <Badge variant="success">{t('console.brain.active')}</Badge>
              )}
            </TableCell>
            <TableCell className="text-right">
              {source.archived_at ? (
                <span className="pr-2 text-xs text-muted-foreground">{t('console.brain.read_only')}</span>
              ) : (
                <div className="flex justify-end gap-1">
                  {source.kind === 'oidc_client' ? (
                    <Button
                      size="xs"
                      type="button"
                      variant="ghost"
                      onClick={() => {
                        setSourceScope(source.default_audience_scope ?? '')
                        setScopeTarget(source)
                      }}>
                      {t('console.brain.default_scope')}
                    </Button>
                  ) : null}
                  {source.kind === 'oidc_client' || (SOURCE_KINDS as readonly string[]).includes(source.kind) ? (
                    <Button
                      disabled={learn.isPending}
                      size="xs"
                      type="button"
                      variant="ghost"
                      onClick={() => learn.mutate({ path: { source_id: source.id } })}>
                      {learn.isPending && learn.variables?.path.source_id === source.id ? (
                        <RiLoaderLine className="animate-spin" data-icon="inline-start" />
                      ) : null}
                      {t('console.brain.learn_now')}
                    </Button>
                  ) : null}
                  <Button size="xs" type="button" variant="ghost" onClick={() => setArchiveTarget(source)}>
                    {t('console.brain.archive')}
                  </Button>
                </div>
              )}
            </TableCell>
          </TableRow>
        ))}
      </ResourceListPage>

      <Dialog open={registerOpen} onOpenChange={registerGuard.requestOpenChange}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!register.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.register_source_title')}</DialogTitle>
            <DialogDescription>{t('console.brain.register_source_description')}</DialogDescription>
          </DialogHeader>
          <form
            className="grid gap-4"
            noValidate
            onInvalidCapture={event => event.preventDefault()}
            onSubmit={event => {
              event.preventDefault()
              // Native `required` accepts blanks; a whitespace-only name or
              // upstream id must stop here instead of as a raw server error.
              if (!event.currentTarget.reportValidity() || !upstreamID.trim() || !name.trim()) {
                focusFirstInvalidControl(event.currentTarget)
                return
              }
              register.mutate({
                body: {
                  data: {
                    kind,
                    upstream_id: upstreamID.trim(),
                    name: name.trim(),
                    ...(scope.trim() ? { default_audience_scope: scope.trim() } : {})
                  }
                }
              })
            }}>
            <LabeledField label={t('console.brain.kind')}>
              <Select
                value={kind}
                onValueChange={value => {
                  if (value === 'file' || value === 'url') setKind(value)
                }}>
                <SelectTrigger aria-label={t('console.brain.kind')} className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {SOURCE_KINDS.map(option => (
                    <SelectItem key={option} value={option}>
                      {t(`console.brain.source_kind_${option}`)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </LabeledField>
            <LabeledField label={t('console.brain.upstream_id')} required>
              <Input
                className="font-mono"
                placeholder={kind === 'url' ? 'https://…' : '/path/to/file.txt'}
                required
                spellCheck={false}
                value={upstreamID}
                onChange={event => setUpstreamID(event.target.value)}
              />
            </LabeledField>
            <LabeledField label={t('console.brain.source_name')} required>
              <Input required value={name} onChange={event => setName(event.target.value)} />
            </LabeledField>
            <LabeledField label={t('console.brain.default_scope')}>
              <BrainScopeSelector
                ariaLabel={t('console.brain.default_scope')}
                unsetLabel={t('console.brain.scope_unset', { defaultValue: 'Source default' })}
                value={scope}
                onChange={setScope}
              />
            </LabeledField>
            <DialogFooter>
              <DialogClose render={<Button variant="outline" />} disabled={register.isPending}>
                {t('common.cancel')}
              </DialogClose>
              <Button disabled={register.isPending} type="submit">
                {register.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
                {t('console.brain.register_source')}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
      <DiscardConfirmDialog
        open={registerGuard.confirming}
        onDiscard={registerGuard.confirmDiscard}
        onKeep={registerGuard.keepEditing}
      />

      <Dialog open={Boolean(scopeTarget)} onOpenChange={scopeGuard.requestOpenChange}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!updateScope.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.default_scope')}</DialogTitle>
            <DialogDescription>{t('console.brain.source_scope_description')}</DialogDescription>
          </DialogHeader>
          <form
            className="grid gap-4"
            onSubmit={event => {
              event.preventDefault()
              if (scopeTarget) {
                updateScope.mutate({
                  path: { source_id: scopeTarget.id },
                  body: { data: { scope: sourceScope.trim() || null } }
                })
              }
            }}>
            <LabeledField label={t('console.brain.scope')}>
              <BrainScopeSelector
                ariaLabel={t('console.brain.scope')}
                unsetLabel={t('console.brain.source_scope_private')}
                value={sourceScope}
                onChange={setSourceScope}
              />
            </LabeledField>
            <DialogFooter>
              <DialogClose render={<Button variant="outline" />} disabled={updateScope.isPending}>
                {t('common.cancel')}
              </DialogClose>
              <Button type="submit" disabled={updateScope.isPending}>
                {t('common.save')}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
      <DiscardConfirmDialog
        open={scopeGuard.confirming}
        onDiscard={scopeGuard.confirmDiscard}
        onKeep={scopeGuard.keepEditing}
      />

      <Dialog
        open={Boolean(archiveTarget)}
        onOpenChange={open => !archive.isPending && !open && setArchiveTarget(undefined)}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!archive.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.source_archive_title', { name: archiveTarget?.name ?? '' })}</DialogTitle>
            {/* Archiving a library set withdraws its pages instead of only
                stopping sync, so the confirmation states that difference. */}
            <DialogDescription>
              {archiveTarget?.kind === 'library'
                ? t('console.brain.source_archive_library_description')
                : t('console.brain.source_archive_description')}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={archive.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={archive.isPending}
              variant="destructive"
              onClick={() => archiveTarget && archive.mutate({ path: { source_id: archiveTarget.id } })}>
              {archive.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.brain.archive')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
