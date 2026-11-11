import { TableRow, useInfiniteQuery, useQuery, Link, useNavigate } from '../../tenant-context'
import {
  Badge,
  Button,
  buttonVariants,
  cn,
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
  Skeleton,
  TableCell
} from '@ankole/uikit'
import { BrainRegular, DismissRegular } from '@ankole/uikit/icons'
import { keepPreviousData } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Outlet, useParams } from '@tanstack/react-router'
import {
  showBrainObjectOptions,
  listBrainObjectsInfiniteOptions
} from '../../api/v2/generated/@tanstack/react-query.gen'
import { nextPageParams, fromDocument } from '../../api/json-api'
import { ErrorBlock } from '../../../common/error-block'
import { formatConsoleDate } from '../../console-primitives'
import { FilterSwitch, ResourceListPage, ResourceSearch, useResourceSearchDraft } from '../../console-list-page'
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
  // The search goes to the server, so the box commits on the shared debounce
  // instead of querying per keystroke.
  const [query, setQuery] = useState('')
  const [queryDraft, setQueryDraft] = useResourceSearchDraft(query, setQuery)
  const [prefix, setPrefix] = useState('')
  const [deleted, setDeleted] = useState(false)
  const searchQuery = query.trim()

  const objects = useInfiniteQuery({
    ...listBrainObjectsInfiniteOptions({
      query: {
        ...(prefix ? { prefix } : {}),
        ...(searchQuery ? { search: searchQuery } : {}),
        ...(deleted ? { deleted: true } : {})
      }
    }),
    initialPageParam: {},
    getNextPageParam: nextPageParams,
    select: data => data.pages.flatMap(document => fromDocument(document)),
    // A committed search changes the query key; keep the previous rows on
    // screen instead of swapping the table for skeletons.
    placeholderData: keepPreviousData
  })
  const rows = objects.data ?? []
  // The slug's first segment is the natural prefix tree level; the chips list
  // what the current result actually contains instead of a hardcoded taxonomy.
  const prefixes = prefix
    ? [prefix]
    : [...new Set(rows.flatMap(object => (object.slug ? [`${object.slug.split('/')[0]}/`] : [])))].sort()
  const filtered = Boolean(query.trim() || prefix || deleted)

  return (
    <ResourceListPage
      title={t('console.brain.objects_title')}
      description={t('pod.knowledge.brain_description')}
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
      emptyIcon={<BrainRegular aria-hidden />}
      pagination={objects}
      isFiltered={filtered}
      onClearFilters={() => {
        setQuery('')
        setQueryDraft('')
        setPrefix('')
        setDeleted(false)
      }}
      emptyAction={
        <Link className={cn(buttonVariants({ size: 'sm', variant: 'outline' }))} to="/brain/health">
          {t('console.brain.empty_check_health')}
        </Link>
      }
      toolbarCanRevealRows
      toolbar={
        <ResourceSearch
          label={t('console.brain.objects_search')}
          placeholder={t('console.brain.objects_search_placeholder')}
          value={queryDraft}
          onChange={setQueryDraft}
          filters={
            <>
              {prefixes.map(candidate => (
                <Button
                  key={candidate}
                  size="xs"
                  type="button"
                  aria-pressed={prefix === candidate}
                  variant={prefix === candidate ? 'outline' : 'ghost'}
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
        <TableRow key={object.id}>
          <TableCell className="font-mono text-xs">
            <a data-row-link className="text-foreground" href={object.pod_url ?? undefined}>
              {object.slug ?? object.id}
            </a>
          </TableCell>
          <TableCell>
            <Badge variant="secondary">{object.subtype ? `${object.type}/${object.subtype}` : object.type}</Badge>
          </TableCell>
          <TableCell className="max-w-[360px] truncate">{object.title}</TableCell>
          <TableCell className="text-xs text-muted-foreground">{formatConsoleDate(object.updated_at)}</TableCell>
          <TableCell>
            <div className="flex flex-wrap gap-1">
              {object.deleted_at ? <Badge variant="destructive">{t('console.brain.deleted')}</Badge> : null}
            </div>
          </TableCell>
          <TableCell className="text-right">
            <a className={cn(buttonVariants({ size: 'xs', variant: 'ghost' }))} href={object.pod_url ?? undefined}>
              {t('pod.knowledge.open_in_pod')}
            </a>
          </TableCell>
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function BrainObjectDrawer() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const params = useParams({ strict: false })
  const slug = params._splat ?? params['*'] ?? ''
  const detail = useQuery({ ...showBrainObjectOptions({ query: { slug } }), enabled: Boolean(slug) })
  const page = detail.data?.object
  const requestClose = () => void navigate({ to: '/brain/objects' })
  return (
    <Drawer open onOpenChange={open => !open && requestClose()} swipeDirection="right">
      <DrawerContent className="data-[swipe-axis=x]:[--drawer-content-width:100%] data-[swipe-axis=x]:sm:[--drawer-content-width:32rem]">
        <DrawerHeader className="relative gap-3 border-b border-border p-5 pr-16">
          <Button
            aria-label={t('common.close')}
            size="icon-sm"
            type="button"
            variant="ghost"
            className="absolute top-3 right-3"
            onClick={requestClose}>
            <DismissRegular />
          </Button>
          <DrawerTitle className="text-lg tracking-normal normal-case">{page?.title ?? slug}</DrawerTitle>
          <DrawerDescription className="text-left break-all font-mono text-xs">{slug}</DrawerDescription>
        </DrawerHeader>
        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-5">
          <ErrorBlock error={detail.error} />
          {detail.isLoading && <Skeleton className="h-24 w-full" />}
          {page && (
            <>
              <Badge variant="secondary">{page.type}</Badge>
              {page.summary && <p className="whitespace-pre-wrap text-sm">{page.summary}</p>}
              <p className="text-sm text-muted-foreground">{t('pod.knowledge.brain_description')}</p>
              <a className={cn(buttonVariants({ size: 'sm' }))} href={page.pod_url}>
                {t('pod.knowledge.open_in_pod')}
              </a>
            </>
          )}
          {detail.data?.candidates && (
            <ul className="grid gap-2">
              {detail.data.candidates.map(candidate => (
                <li key={candidate.slug}>
                  <Link className="link font-mono text-xs" to={brainObjectPath(candidate.slug ?? '')}>
                    {candidate.slug}
                  </Link>
                  {candidate.title && <span className="ml-2 text-xs text-muted-foreground">{candidate.title}</span>}
                </li>
              ))}
            </ul>
          )}
        </div>
      </DrawerContent>
    </Drawer>
  )
}
