import {
  Badge,
  Button,
  buttonVariants,
  cn,
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
  DrawerHeader,
  DrawerTitle,
  Input,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  toast
} from '@ankole/uikit'
import { RiBrainLine, RiCloseLine, RiLoaderLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useDeferredValue, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, Outlet, useNavigate, useParams } from 'react-router'
import {
  ankoleWebBrainControllerForgetObjectMutation,
  ankoleWebBrainControllerForkObjectMutation,
  ankoleWebBrainControllerListObjectsOptions,
  ankoleWebBrainControllerListObjectsQueryKey,
  ankoleWebBrainControllerObjectVersionsOptions,
  ankoleWebBrainControllerObjectVersionsQueryKey,
  ankoleWebBrainControllerRestoreObjectMutation,
  ankoleWebBrainControllerRollbackObjectMutation,
  ankoleWebBrainControllerShowObjectOptions,
  ankoleWebBrainControllerShowObjectQueryKey
} from '../../api/generated/@tanstack/react-query.gen'
import { requestErrorMessage } from '../../../common/request-errors'
import { ErrorBlock } from '../../../common/error-block'
import { formatConsoleDate } from '../../console-primitives'
import { FilterSwitch, ResourceListPage, ResourceSearch, RowViewAction } from '../../console-list-page'
import { MarkdownBody } from '../../markdown-body'
import { effectiveResourceSearchQuery } from '../../state/resource-search'
import { BrainSubNav, brainObjectPath } from './brain-nav'

/** Keeps the list mounted while the nested slug route renders its drawer. */
export function BrainObjectsPage() {
  return (
    <>
      <BrainObjectsList />
      <Outlet />
    </>
  )
}

function BrainObjectsList() {
  const { t } = useTranslation()
  const [query, setQuery] = useState('')
  const [prefix, setPrefix] = useState('')
  const [deleted, setDeleted] = useState(false)
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)

  const objects = useQuery(
    ankoleWebBrainControllerListObjectsOptions({
      query: {
        ...(prefix ? { prefix } : {}),
        ...(searchQuery ? { q: searchQuery } : {}),
        ...(deleted ? { deleted: true } : {})
      }
    })
  )
  const rows = objects.data?.objects ?? []
  // The slug's first segment is the natural prefix tree level; the chips list
  // what the current result actually contains instead of a hardcoded taxonomy.
  const prefixes = prefix ? [prefix] : [...new Set(rows.map(object => `${object.slug.split('/')[0] ?? ''}/`))].sort()
  const filtered = Boolean(query.trim() || prefix || deleted)

  return (
    <ResourceListPage
      title={t('console.brain.objects_title')}
      description={t('console.brain.objects_description')}
      subNav={<BrainSubNav />}
      columns={[
        t('console.brain.slug'),
        t('console.brain.type'),
        t('console.brain.object_title'),
        t('console.brain.updated'),
        t('console.brain.state')
      ]}
      isLoading={objects.isLoading}
      isEmpty={rows.length === 0}
      count={rows.length}
      emptyTitle={t('console.brain.objects_empty_title')}
      emptyDescription={t('console.brain.objects_empty_description')}
      emptyIcon={<RiBrainLine aria-hidden />}
      error={objects.error}
      isFiltered={filtered}
      onClearFilters={() => {
        setQuery('')
        setPrefix('')
        setDeleted(false)
      }}
      toolbarCanRevealRows
      toolbar={
        <ResourceSearch
          label={t('console.brain.objects_search')}
          placeholder={t('console.brain.objects_search_placeholder')}
          value={query}
          onChange={setQuery}
          filters={
            <>
              {prefixes.map(candidate => (
                <Button
                  key={candidate}
                  size="xs"
                  type="button"
                  variant={prefix === candidate ? 'secondary' : 'ghost'}
                  className="font-mono"
                  onClick={() => setPrefix(current => (current === candidate ? '' : candidate))}>
                  {candidate}
                </Button>
              ))}
              <FilterSwitch checked={deleted} label={t('console.brain.show_deleted')} onChange={setDeleted} />
            </>
          }
        />
      }>
      {rows.map(object => (
        <TableRow key={object.slug}>
          <TableCell className="font-mono text-xs">
            <Link className="text-foreground hover:text-link hover:underline" to={brainObjectPath(object.slug)}>
              {object.slug}
            </Link>
          </TableCell>
          <TableCell>
            <Badge variant="secondary">{object.subtype ? `${object.type}/${object.subtype}` : object.type}</Badge>
          </TableCell>
          <TableCell className="max-w-[360px] truncate">{object.title}</TableCell>
          <TableCell className="text-xs text-muted-foreground">{formatConsoleDate(object.updated_at)}</TableCell>
          <TableCell>
            <div className="flex flex-wrap gap-1">
              {object.library_managed ? <Badge variant="outline">{t('console.brain.library_managed')}</Badge> : null}
              {object.deleted_at ? <Badge variant="destructive">{t('console.brain.deleted')}</Badge> : null}
            </div>
          </TableCell>
          <RowViewAction label={t('common.open')} to={brainObjectPath(object.slug)} />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function BrainObjectDrawer() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const params = useParams()
  const slug = params['*'] ?? ''
  const [forgetOpen, setForgetOpen] = useState(false)
  const [forgetReason, setForgetReason] = useState('')
  const [forkOpen, setForkOpen] = useState(false)
  const [rollbackVersionID, setRollbackVersionID] = useState<string>()

  const detail = useQuery({
    ...ankoleWebBrainControllerShowObjectOptions({ query: { slug } }),
    enabled: Boolean(slug)
  })
  const page = detail.data?.object
  const versions = useQuery({
    ...ankoleWebBrainControllerObjectVersionsOptions({ query: { slug } }),
    enabled: Boolean(page)
  })

  const invalidate = () => {
    void queryClient.invalidateQueries({ queryKey: ankoleWebBrainControllerListObjectsQueryKey() })
    void queryClient.invalidateQueries({
      queryKey: ankoleWebBrainControllerShowObjectQueryKey({ query: { slug } })
    })
    void queryClient.invalidateQueries({
      queryKey: ankoleWebBrainControllerObjectVersionsQueryKey({ query: { slug } })
    })
  }
  const rollback = useMutation({
    ...ankoleWebBrainControllerRollbackObjectMutation(),
    onSuccess: () => {
      setRollbackVersionID(undefined)
      toast.success(t('console.brain.rollback_done', { slug }))
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const forget = useMutation({
    ...ankoleWebBrainControllerForgetObjectMutation(),
    onSuccess: () => {
      setForgetOpen(false)
      toast.success(t('console.brain.forget_object_done', { slug }))
      invalidate()
      navigate('/brain/objects')
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const restore = useMutation({
    ...ankoleWebBrainControllerRestoreObjectMutation(),
    onSuccess: () => {
      toast.success(t('console.brain.restore_object_done', { slug }))
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const fork = useMutation({
    ...ankoleWebBrainControllerForkObjectMutation(),
    onSuccess: () => {
      setForkOpen(false)
      toast.success(t('console.brain.fork_object_done', { slug }))
      invalidate()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const busy = rollback.isPending || forget.isPending || restore.isPending || fork.isPending
  const requestClose = () => {
    if (!busy) navigate('/brain/objects')
  }

  return (
    <>
      <Drawer open onOpenChange={open => !open && requestClose()} swipeDirection="right">
        <DrawerContent className="data-[swipe-axis=x]:[--drawer-content-width:100%] data-[swipe-axis=x]:sm:[--drawer-content-width:52rem]">
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
            <div className="flex flex-wrap items-center gap-2">
              {page ? (
                <Badge variant="secondary">{page.subtype ? `${page.type}/${page.subtype}` : page.type}</Badge>
              ) : null}
              {page?.library_managed ? <Badge variant="outline">{t('console.brain.library_managed')}</Badge> : null}
              {page?.deleted ? <Badge variant="destructive">{t('console.brain.deleted')}</Badge> : null}
              {page?.tags.map(tag => (
                <Badge key={tag} variant="outline">
                  {tag}
                </Badge>
              ))}
            </div>
            <DrawerTitle className="text-lg tracking-normal normal-case">{page?.title ?? slug}</DrawerTitle>
            <DrawerDescription className="text-left break-all font-mono text-xs">{slug}</DrawerDescription>
            {/* Ordinary library pages can be forked. Lazy Skill discovery
                records stay projection-owned and use Agent Library controls. */}
            {page?.library_managed && page.type !== 'agent-skills' ? (
              <div className="grid gap-2">
                <p className="text-xs text-muted-foreground">{t('console.brain.library_managed_hint')}</p>
                <div>
                  <Button size="xs" type="button" variant="outline" onClick={() => setForkOpen(true)}>
                    {t('console.brain.fork_object')}
                  </Button>
                </div>
              </div>
            ) : null}
            {page?.library_managed && page.type === 'agent-skills' ? (
              <div className="grid gap-2">
                <p className="text-xs text-muted-foreground">{t('console.brain.library_skill_managed_hint')}</p>
                <div>
                  <Link className={cn(buttonVariants({ size: 'xs', variant: 'outline' }))} to="/agent-library">
                    {t('console.brain.manage_skill_in_library')}
                  </Link>
                </div>
              </div>
            ) : null}
            {page && !page.deleted && !page.library_managed ? (
              <div>
                <Button size="xs" type="button" variant="outline" onClick={() => setForgetOpen(true)}>
                  {t('console.brain.forget_object')}
                </Button>
              </div>
            ) : null}
            {page?.deleted && !page.library_managed ? (
              <div>
                <Button
                  disabled={restore.isPending}
                  size="xs"
                  type="button"
                  variant="outline"
                  onClick={() => restore.mutate({ body: { slug } })}>
                  {restore.isPending ? <RiLoaderLine className="animate-spin" /> : null}
                  {t('console.brain.restore_object')}
                </Button>
              </div>
            ) : null}
          </DrawerHeader>

          <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-5">
            {detail.isLoading ? (
              <div className="grid gap-4">
                <Skeleton className="h-24 w-full" />
                <Skeleton className="h-64 w-full" />
              </div>
            ) : (
              <div className="grid gap-7">
                <ErrorBlock error={detail.error ?? versions.error} />

                {detail.data?.candidates ? (
                  <DrawerSection title={t('console.brain.ambiguous_title')}>
                    <ul className="grid gap-1">
                      {detail.data.candidates.map(candidate => (
                        <li key={candidate.slug}>
                          <Link
                            className="font-mono text-xs text-link hover:underline"
                            to={brainObjectPath(candidate.slug ?? '')}>
                            {candidate.slug}
                          </Link>
                          {candidate.title ? (
                            <span className="ml-2 text-xs text-muted-foreground">{candidate.title}</span>
                          ) : null}
                        </li>
                      ))}
                    </ul>
                  </DrawerSection>
                ) : null}

                {page ? (
                  <>
                    <DrawerSection title={t('console.brain.document')}>
                      <div className="border border-border bg-background p-4">
                        <MarkdownBody text={page.rendered} />
                      </div>
                    </DrawerSection>

                    <DrawerSection title={`${t('console.brain.facts')} (${page.facts.length})`}>
                      <CompactTable
                        columns={[
                          t('console.brain.claim'),
                          t('console.brain.kind'),
                          t('console.brain.holder'),
                          t('console.brain.valid_window'),
                          t('console.brain.scope')
                        ]}
                        empty={t('console.brain.no_rows')}
                        rowCount={page.facts.length}>
                        {page.facts.map(fact => (
                          <TableRow key={fact.id} className={fact.expired_at ? 'opacity-60' : undefined}>
                            <TableCell className="max-w-[320px] whitespace-normal text-xs">{fact.claim}</TableCell>
                            <TableCell className="text-xs">{fact.kind ?? '—'}</TableCell>
                            <TableCell className="font-mono text-xs">{fact.holder ?? '—'}</TableCell>
                            <TableCell className="text-xs text-muted-foreground">
                              {formatConsoleDate(fact.valid_from)}
                              {fact.valid_until ? ` → ${formatConsoleDate(fact.valid_until)}` : ''}
                              {fact.expired_at ? ` (${t('console.brain.expired')})` : ''}
                            </TableCell>
                            <TableCell className="font-mono text-xs">{fact.audience_scope}</TableCell>
                          </TableRow>
                        ))}
                      </CompactTable>
                    </DrawerSection>

                    <DrawerSection title={`${t('console.brain.takes')} (${page.takes.length})`}>
                      <CompactTable
                        columns={[
                          t('console.brain.claim'),
                          t('console.brain.kind'),
                          t('console.brain.weight'),
                          t('console.brain.grade'),
                          t('console.brain.resolution'),
                          t('console.brain.scope')
                        ]}
                        empty={t('console.brain.no_rows')}
                        rowCount={page.takes.length}>
                        {page.takes.map(take => (
                          <TableRow key={take.id} className={take.active ? undefined : 'opacity-60'}>
                            <TableCell className="max-w-[320px] whitespace-normal text-xs">{take.claim}</TableCell>
                            <TableCell className="text-xs">{take.kind ?? '—'}</TableCell>
                            <TableCell className="text-xs">{take.weight ?? '—'}</TableCell>
                            <TableCell className="text-xs">
                              {take.graded_quality
                                ? `${take.graded_quality}${take.graded_confidence != null ? ` · ${take.graded_confidence}` : ''}`
                                : '—'}
                            </TableCell>
                            <TableCell className="text-xs">
                              {take.resolved_at
                                ? `${take.resolved_quality ?? ''}${take.resolved_outcome != null ? ` · ${String(take.resolved_outcome)}` : ''}`
                                : '—'}
                            </TableCell>
                            <TableCell className="font-mono text-xs">{take.audience_scope}</TableCell>
                          </TableRow>
                        ))}
                      </CompactTable>
                    </DrawerSection>

                    <DrawerSection title={`${t('console.brain.timelines')} (${page.timelines.length})`}>
                      <CompactTable
                        columns={[
                          t('console.brain.date'),
                          t('console.brain.summary'),
                          t('console.brain.event_object'),
                          t('console.brain.scope')
                        ]}
                        empty={t('console.brain.no_rows')}
                        rowCount={page.timelines.length}>
                        {page.timelines.map(timeline => (
                          <TableRow key={timeline.id}>
                            <TableCell className="text-xs">{timeline.date}</TableCell>
                            <TableCell className="max-w-[360px] whitespace-normal text-xs">
                              {timeline.summary}
                            </TableCell>
                            <TableCell className="font-mono text-xs">
                              {timeline.event_object_slug ? (
                                <Link
                                  className="text-link hover:underline"
                                  to={brainObjectPath(timeline.event_object_slug)}>
                                  {timeline.event_object_slug}
                                </Link>
                              ) : (
                                '—'
                              )}
                            </TableCell>
                            <TableCell className="font-mono text-xs">{timeline.audience_scope}</TableCell>
                          </TableRow>
                        ))}
                      </CompactTable>
                    </DrawerSection>

                    <DrawerSection title={t('console.brain.links')}>
                      <div className="grid gap-3 text-xs sm:grid-cols-2">
                        <LinkList
                          title={t('console.brain.links_outgoing')}
                          links={page.links.outgoing.map(link => ({
                            slug: link.to,
                            linkType: link.link_type,
                            context: link.context
                          }))}
                          empty={t('console.brain.no_rows')}
                        />
                        <LinkList
                          title={t('console.brain.links_incoming')}
                          links={page.links.incoming.map(link => ({
                            slug: link.from,
                            linkType: link.link_type,
                            context: link.context
                          }))}
                          empty={t('console.brain.no_rows')}
                        />
                      </div>
                    </DrawerSection>

                    <DrawerSection title={t('console.brain.versions')}>
                      {versions.isLoading ? (
                        <Skeleton className="h-24 w-full" />
                      ) : (
                        <CompactTable
                          columns={[
                            t('console.brain.snapshot_at'),
                            t('console.brain.author'),
                            t('console.brain.body_preview'),
                            ''
                          ]}
                          empty={t('console.brain.no_versions')}
                          rowCount={versions.data?.versions.length ?? 0}>
                          {(versions.data?.versions ?? []).map(version => (
                            <TableRow key={version.id}>
                              <TableCell className="text-xs">{formatConsoleDate(version.snapshot_at)}</TableCell>
                              <TableCell className="font-mono text-xs">{version.author_uid ?? '—'}</TableCell>
                              <TableCell className="max-w-[280px] truncate text-xs text-muted-foreground">
                                {version.body}
                              </TableCell>
                              <TableCell className="text-right">
                                {page.library_managed ? null : (
                                  <Button
                                    disabled={rollback.isPending}
                                    size="xs"
                                    type="button"
                                    variant="outline"
                                    onClick={() => setRollbackVersionID(version.id)}>
                                    {t('console.brain.rollback')}
                                  </Button>
                                )}
                              </TableCell>
                            </TableRow>
                          ))}
                        </CompactTable>
                      )}
                    </DrawerSection>
                  </>
                ) : null}
              </div>
            )}
          </div>
        </DrawerContent>
      </Drawer>

      <Dialog open={forgetOpen} onOpenChange={open => !forget.isPending && setForgetOpen(open)}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!forget.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.forget_object_title')}</DialogTitle>
            <DialogDescription>{t('console.brain.forget_object_description', { slug })}</DialogDescription>
          </DialogHeader>
          <Input
            aria-label={t('console.brain.forget_reason')}
            placeholder={t('console.brain.forget_reason')}
            value={forgetReason}
            onChange={event => setForgetReason(event.target.value)}
          />
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={forget.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={forget.isPending || !forgetReason.trim()}
              variant="destructive"
              onClick={() => forget.mutate({ body: { slug, reason: forgetReason.trim() } })}>
              {forget.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.brain.forget_object')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={forkOpen} onOpenChange={open => !fork.isPending && setForkOpen(open)}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!fork.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.fork_object_title')}</DialogTitle>
            <DialogDescription>{t('console.brain.fork_object_description', { slug })}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={fork.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button disabled={fork.isPending} onClick={() => fork.mutate({ body: { slug } })}>
              {fork.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.brain.fork_object')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog
        open={Boolean(rollbackVersionID)}
        onOpenChange={open => !rollback.isPending && !open && setRollbackVersionID(undefined)}>
        <DialogContent closeLabel={t('common.close')} showCloseButton={!rollback.isPending}>
          <DialogHeader>
            <DialogTitle>{t('console.brain.rollback_title')}</DialogTitle>
            <DialogDescription>{t('console.brain.rollback_description', { slug })}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose render={<Button variant="outline" />} disabled={rollback.isPending}>
              {t('common.cancel')}
            </DialogClose>
            <Button
              disabled={rollback.isPending}
              onClick={() => rollbackVersionID && rollback.mutate({ body: { slug, version_id: rollbackVersionID } })}>
              {rollback.isPending ? <RiLoaderLine className="animate-spin" data-icon="inline-start" /> : null}
              {t('console.brain.rollback')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}

function DrawerSection({ children, title }: { children: ReactNode; title: string }) {
  return (
    <section className="grid gap-3">
      <h3 className="text-sm font-semibold text-foreground">{title}</h3>
      {children}
    </section>
  )
}

function CompactTable({
  children,
  columns,
  empty,
  rowCount
}: {
  children: ReactNode
  columns: string[]
  empty: string
  rowCount: number
}) {
  if (rowCount === 0) {
    return <p className="border border-dashed border-border px-4 py-4 text-xs text-muted-foreground">{empty}</p>
  }

  return (
    <Table containerClassName="border border-border bg-card">
      <TableHeader>
        <TableRow>
          {columns.map((column, index) => (
            <TableHead key={`${column}-${index}`}>{column}</TableHead>
          ))}
        </TableRow>
      </TableHeader>
      <TableBody>{children}</TableBody>
    </Table>
  )
}

function LinkList({
  empty,
  links,
  title
}: {
  empty: string
  links: Array<{ slug: string; linkType: string; context: string | null }>
  title: string
}) {
  return (
    <div className="grid content-start gap-2 border border-border bg-card p-3">
      <h4 className="text-xs font-semibold text-muted-foreground">{title}</h4>
      {links.length === 0 ? (
        <p className="text-xs text-muted-foreground">{empty}</p>
      ) : (
        <ul className="grid gap-1.5">
          {links.map((link, index) => (
            <li key={`${link.slug}-${index}`} className="flex min-w-0 flex-wrap items-center gap-2">
              <Badge variant="outline">{link.linkType}</Badge>
              <Link
                className="min-w-0 truncate font-mono text-xs text-link hover:underline"
                to={brainObjectPath(link.slug)}>
                {link.slug}
              </Link>
              {link.context ? <span className="text-xs text-muted-foreground">{link.context}</span> : null}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
