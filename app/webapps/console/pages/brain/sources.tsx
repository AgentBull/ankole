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
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebBrainControllerArchiveSourceMutation,
  ankoleWebBrainControllerCreateSourceMutation,
  ankoleWebBrainControllerLearnSourceMutation,
  ankoleWebBrainControllerListSourcesOptions,
  ankoleWebBrainControllerListSourcesQueryKey
} from '../../api/generated/@tanstack/react-query.gen'
import type { BrainSource } from '../../api/generated/types.gen'
import { requestErrorMessage } from '../../../common/request-errors'
import { formatConsoleDate } from '../../console-primitives'
import { DiscardConfirmDialog, LabeledField, focusFirstInvalidControl, useDialogDiscardGuard } from '../../console-form'
import { ResourceListPage } from '../../console-list-page'
import { BrainSubNav } from './brain-nav'

const SOURCE_KINDS = ['file', 'url'] as const

export function BrainSourcesPage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [registerOpen, setRegisterOpen] = useState(false)
  const [kind, setKind] = useState<(typeof SOURCE_KINDS)[number]>('file')
  const [upstreamID, setUpstreamID] = useState('')
  const [name, setName] = useState('')
  const [scope, setScope] = useState('')
  const [archiveTarget, setArchiveTarget] = useState<BrainSource>()

  const sources = useQuery(ankoleWebBrainControllerListSourcesOptions())
  const rows = sources.data?.sources ?? []
  const invalidate = () =>
    void queryClient.invalidateQueries({ queryKey: ankoleWebBrainControllerListSourcesQueryKey() })
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
    ...ankoleWebBrainControllerCreateSourceMutation(),
    onSuccess: response => {
      toast.success(t('console.brain.source_registered', { name: response.source.name }))
      setRegisterOpen(false)
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const registerGuard = useDialogDiscardGuard({
    dirty: registerDirty,
    onOpenChange: setRegisterOpen,
    pending: register.isPending
  })
  const learn = useMutation({
    ...ankoleWebBrainControllerLearnSourceMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.learn_done'))
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const archive = useMutation({
    ...ankoleWebBrainControllerArchiveSourceMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.archive_done'))
      setArchiveTarget(undefined)
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
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
        error={sources.error}
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
                {source.kind === 'library' ? t('console.brain.source_kind_library') : source.kind}
              </Badge>
            </TableCell>
            <TableCell className="max-w-[280px] truncate font-mono text-xs">{source.upstream_id}</TableCell>
            <TableCell className="font-mono text-xs">{source.default_audience_scope ?? '—'}</TableCell>
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
                  {/* Only file and url Sources have a learning run; auto-registered
                      signal_channel Sources learn through slice processing. */}
                  {(SOURCE_KINDS as readonly string[]).includes(source.kind) ? (
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
                  kind,
                  upstream_id: upstreamID.trim(),
                  name: name.trim(),
                  ...(scope.trim() ? { default_audience_scope: scope.trim() } : {})
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
                placeholder={kind === 'url' ? 'https://…' : '/path/or/drive-id'}
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
              <Input
                className="font-mono"
                placeholder="world"
                spellCheck={false}
                value={scope}
                onChange={event => setScope(event.target.value)}
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
