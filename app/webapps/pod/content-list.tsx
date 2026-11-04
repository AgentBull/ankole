import { useSearchDraft } from '../common/use-search-draft'
import { formatRelativeTime } from '../common/date-time'
import { usePageHref, usePageMetadata, usePagesMetadata } from './use-page-metadata'
import { Button, Input, toast } from '@ankole/uikit'
import { pageCreated } from './state/navigation-cache'
import { RiDeleteBinLine, RiLockLine } from '@remixicon/react'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useNavigate, useParams } from '@tanstack/react-router'
import type { TFunction } from 'i18next'
import { useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { podPagePath } from '../common/pod-url'
import { BdiLabel } from '../common/bidi-file-name'
import { stripBidi } from '../common/bidi'
import { useSearchParams } from '../common/router'
import { podKeys } from './api'
import { podConversations } from './api/generated/sdk.gen'
import {
  ChatRowStatus,
  ConversationGlyph,
  ConversationTitle,
  conversationLabel,
  conversationPath
} from './chat/conversation-row'
import {
  cachedPages,
  directoryCapabilitiesQuery,
  pageAPI,
  pageChildrenQuery,
  pagesQuery,
  pageSearchQuery,
  type Page,
  type PageDomain,
  type PageScope
} from './content-api'
import { ContentError, scopeLabels, typeLabels } from './content-primitives'
import { PermanentDeletePageDialog, usePagePurge } from './page-actions'
import { CreatePageButton } from './page-create-menu'
import { PageIcon } from './page-icon'
import { mergeRecentEntries } from './state/navigation'
import { pageAncestors } from './state/page-location'

/** Retention 0 keeps Trash rows, and a started purge already shows its own state. */
function purgeDays(page: Page, retentionDays: number | null | undefined, t: TFunction): string {
  if (!retentionDays || !page.deleted_at || page.purge_started_at) return ''
  const left = Date.parse(page.deleted_at) + retentionDays * 86_400_000 - Date.now()
  return t('pod.content.days_until_permanent_deletion', { count: Math.max(1, Math.ceil(left / 86_400_000)) })
}

export function ContentListRoute() {
  const { scope = 'space' } = useParams({ strict: false })
  const effectiveScope = scope === 'search' || Object.hasOwn(scopeLabels, scope) ? scope : 'space'
  return effectiveScope === 'recent' ? (
    <RecentContentList />
  ) : (
    <PageContentList scope={effectiveScope as PageScope | 'search'} />
  )
}

export function PageContentList({ scope, domain = 'pages' }: { scope: PageScope | 'search'; domain?: PageDomain }) {
  const { t, i18n } = useTranslation()
  const effectiveScope = scope === 'search' ? 'all' : scope
  const search = effectiveScope === 'all'
  const trash = effectiveScope === 'trash'
  const rootScope = effectiveScope === 'space' || effectiveScope === 'private'
  const [searchParams, setSearchParams] = useSearchParams()
  const query = searchParams.get('q') ?? ''
  const [inputQuery, setInputQuery] = useSearchDraft(
    query,
    value =>
      setSearchParams(
        current => {
          if (value) current.set('q', value)
          else current.delete('q')
          return current
        },
        { replace: true, preventScrollReset: true }
      ),
    { delay: 180, enabled: search || trash, scope }
  )
  const debouncing = (search || trash) && inputQuery !== query
  const listing = useQuery({
    ...pagesQuery(effectiveScope, trash ? query : '', domain),
    enabled: !rootScope && !search
  })
  const searched = useQuery({ ...pageSearchQuery(query, { domain }), enabled: search })
  const roots = useInfiniteQuery({
    ...pageChildrenQuery(effectiveScope === 'private' ? 'private' : 'space'),
    enabled: !trash && domain === 'pages'
  })
  const pages = rootScope
    ? {
        ...roots,
        data: roots.data
          ? { ...roots.data.pages[0]!, pages: roots.data.pages.flatMap(batch => batch.pages) }
          : undefined
      }
    : search
      ? searched
      : listing
  const client = useQueryClient()
  const navigate = useNavigate()
  const [purging, setPurging] = useState<Page>()
  const purge = usePagePurge(() => setPurging(undefined))
  const restore = useMutation({
    mutationFn: pageAPI.restore,
    onSuccess: ({ page }) => {
      pageCreated(client, page)
      toast.success(t('pod.content.page_restored'), {
        action: {
          label: t('pod.content.open_page'),
          onClick: () =>
            void navigate({ to: domain === 'brain' ? `/meta/brain/${page.id}` : podPagePath(page.id, page.title) })
        }
      })
    }
  })
  const capabilities = roots.data?.pages[0]
  const rows: Page[] | undefined = pages.data?.pages
  const retentionDays = pages.data && 'trash_retention_days' in pages.data ? pages.data.trash_retention_days : null
  const pagesByID = new Map(
    [...cachedPages(client), ...(rows ?? []), ...(searched.data?.ancestors ?? [])].map(page => [page.id, page])
  )
  const error = pages.error || (!trash && roots.error) || restore.error
  return (
    <ContentListFrame
      title={search ? t('pod.content.search_pages') : scopeLabels[effectiveScope]}
      actions={
        domain === 'pages' &&
        !trash &&
        (effectiveScope === 'private'
          ? capabilities?.can_create_private !== false
          : capabilities?.can_create_space === true) && (
          <CreatePageButton
            scope={effectiveScope === 'private' ? 'private' : 'space'}
            privateOwner={capabilities?.principal_uid}
            disabled={roots.isError}
          />
        )
      }>
      {(search || trash) && (
        <Input
          key={scope}
          autoFocus={search}
          aria-label={trash ? t('pod.content.search_trash') : t('pod.content.search_pages')}
          className="mb-5 max-w-xl"
          placeholder={
            trash ? t('pod.content.search_titles_in_trash') : t('pod.content.search_titles_and_document_content')
          }
          value={inputQuery}
          onChange={event => setInputQuery(event.target.value)}
        />
      )}
      <ContentError
        error={error}
        retry={() => {
          void pages.refetch()
          if (!rootScope && !trash) void roots.refetch()
        }}
      />
      {pages.isPending || (debouncing && !rows?.length) ? (
        <p role="status">{t('pod.content.loading')}</p>
      ) : (
        <ul className="space-y-1">
          {rows?.map(page => (
            <PageListItem
              key={page.id}
              page={page}
              ancestors={rootScope ? [] : pageAncestors(page, pagesByID)}
              showPrivateBadge={!rootScope && Boolean(page.private_owner_uid)}
              timestamp={
                rootScope
                  ? ''
                  : [
                      formatRelativeTime(trash ? (page.deleted_at ?? page.updated_at) : page.updated_at, i18n.language),
                      trash && purgeDays(page, retentionDays, t)
                    ]
                      .filter(Boolean)
                      .join(' · ')
              }
              restoreAction={
                trash &&
                page.actions?.includes('node_manage') && (
                  <>
                    <Button
                      data-pod-list-item
                      aria-describedby={`pod-list-title-${page.id}`}
                      size="sm"
                      variant="outline"
                      disabled={!!page.purge_started_at || restore.isPending}
                      onClick={() => restore.mutate(page.id)}>
                      {page.purge_started_at
                        ? t('pod.content.purging')
                        : restore.isPending && restore.variables === page.id
                          ? t('pod.content.restoring')
                          : t('pod.content.restore')}
                    </Button>
                    <Button
                      data-pod-list-item
                      aria-describedby={`pod-list-title-${page.id}`}
                      aria-label={t('pod.content.permanently_delete')}
                      title={t('pod.content.permanently_delete')}
                      size="icon-sm"
                      variant="ghost"
                      disabled={!!page.purge_started_at || purge.isPending}
                      onClick={() => setPurging(page)}>
                      <RiDeleteBinLine aria-hidden className="size-4" />
                    </Button>
                  </>
                )
              }
            />
          ))}
        </ul>
      )}
      {rootScope && roots.hasNextPage && (
        <Button
          className="mt-4"
          variant="outline"
          disabled={roots.isFetching}
          onClick={() => void roots.fetchNextPage()}>
          {t('pod.content.load_more_pages')}
        </Button>
      )}
      {!pages.isPending && !debouncing && !error && !rows?.length && (
        <p className="py-10 text-sm text-fg-tertiary">
          {query
            ? trash
              ? t('pod.content.no_matching_pages_in_trash')
              : t('pod.content.no_pages_you_can_view_were_found')
            : trash
              ? t('pod.content.trash_is_empty')
              : t('pod.content.no_pages_yet')}
        </p>
      )}
      {purging && (
        <PermanentDeletePageDialog
          page={purging}
          pending={purge.isPending}
          onCancel={() => setPurging(undefined)}
          onConfirm={() => purge.mutate(purging)}
        />
      )}
    </ContentListFrame>
  )
}

function RecentContentList() {
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const pages = useQuery(pagesQuery('recent'))
  const destinations = useInfiniteQuery(directoryCapabilitiesQuery())
  const capabilities = destinations.data
  const conversations = useQuery({
    queryKey: [...podKeys.conversations, 'recent', 'list'],
    queryFn: ({ signal }) => podConversations({ query: { order: 'recent', limit: 100 }, signal })
  })
  const entries = mergeRecentEntries(pages.data?.pages ?? [], conversations.data?.conversations ?? [])
  const pending = pages.isPending || conversations.isPending
  const error = pages.error || conversations.error || destinations.error
  const pagesByID = new Map([...cachedPages(client), ...(pages.data?.pages ?? [])].map(page => [page.id, page]))
  return (
    <ContentListFrame
      title={scopeLabels.recent}
      actions={!destinations.isError && capabilities?.can_create_space && <CreatePageButton scope="space" />}>
      <ContentError
        error={error}
        retry={() => {
          void pages.refetch()
          void conversations.refetch()
          void destinations.refetch()
        }}
      />
      {pending && !entries.length && <p role="status">{t('pod.content.loading')}</p>}
      <ul className="space-y-1">
        {entries.map(entry => {
          if (entry.kind === 'page') {
            return (
              <PageListItem
                key={`page:${entry.id}`}
                page={entry.page}
                ancestors={pageAncestors(entry.page, pagesByID)}
                showPrivateBadge={Boolean(entry.page.private_owner_uid)}
                timestamp={formatRelativeTime(entry.timestamp, i18n.language)}
              />
            )
          }
          const room = entry.room
          const subtitle =
            room.conversationKind === 'colleague_dm'
              ? room.agents[0]?.role
              : room.agents.map(agent => agent.displayName).join(', ')
          const timestamp = formatRelativeTime(entry.timestamp, i18n.language)
          const chatLabel = t('pod.sidebar.tabs.chat')
          return (
            <li key={`chat:${room.id}`}>
              <Link
                data-pod-list-item
                className={listLinkClass}
                aria-label={conversationLabel(room, t('pod.content.untitled'))}
                aria-description={[chatLabel, subtitle, timestamp].filter(Boolean).join(' · ')}
                state={{ keepSidebarTab: 'home' } as never}
                to={conversationPath(room)}>
                <ConversationGlyph room={room} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate">
                    <ConversationTitle room={room} />
                  </span>
                  {subtitle && <span className="block truncate text-xs text-fg-tertiary">{subtitle}</span>}
                </span>
                <ChatRowStatus status={room.rowStatus} />
                {timestamp && <span className="shrink-0 text-xs text-fg-tertiary">{timestamp}</span>}
                <span className="shrink-0 text-xs text-fg-tertiary">{chatLabel}</span>
              </Link>
            </li>
          )
        })}
      </ul>
      {!pending && !error && !entries.length && (
        <p className="py-10 text-sm text-fg-tertiary">{t('pod.sidebar.recent_empty')}</p>
      )}
    </ContentListFrame>
  )
}

export function handlePodListKeyDown(event: React.KeyboardEvent<HTMLElement>) {
  if (
    event.nativeEvent.isComposing ||
    event.nativeEvent.keyCode === 229 ||
    event.altKey ||
    event.ctrlKey ||
    event.metaKey ||
    event.shiftKey ||
    (event.key !== 'j' && event.key !== 'k') ||
    !(event.target instanceof HTMLElement) ||
    event.target.closest('input, textarea, select, [contenteditable="true"], [role="textbox"], [role="combobox"]')
  ) {
    return
  }
  const rows = [...event.currentTarget.querySelectorAll<HTMLElement>('[data-pod-list-item]:not([disabled])')]
  const current = rows.indexOf(document.activeElement as HTMLElement)
  if (current < 0 || rows.length < 2) return
  event.preventDefault()
  const next = rows[(current + (event.key === 'j' ? 1 : -1) + rows.length) % rows.length]!
  next.focus()
  next.scrollIntoView({ block: 'nearest' })
}

function ContentListFrame({ title, actions, children }: { title: string; actions?: ReactNode; children: ReactNode }) {
  return (
    <section className="pod-content-list h-full overflow-auto px-6 pt-2 pb-6 md:px-10" onKeyDown={handlePodListKeyDown}>
      <div className="mb-6 flex items-center justify-between gap-3">
        <h1 className="title-page">{title}</h1>
        {actions}
      </div>
      {children}
    </section>
  )
}

const listLinkClass =
  'pod-content-list-link flex min-h-8 min-w-0 items-center gap-3 rounded-control px-3 py-1 text-[13px] leading-5 text-foreground no-underline hover:bg-accent focus-visible:bg-accent focus-visible:outline-2 focus-visible:outline-ring'

function PageListItem({
  page: sourcePage,
  ancestors,
  showPrivateBadge,
  timestamp,
  restoreAction
}: {
  page: Page
  ancestors: Page[]
  showPrivateBadge: boolean
  timestamp: string
  restoreAction?: ReactNode
}) {
  const { t } = useTranslation()
  const pageHref = usePageHref()
  const page = usePageMetadata(sourcePage)
  const parent = usePagesMetadata(ancestors)
    .map(page => stripBidi(page.title) || t('pod.content.untitled'))
    .join(' / ')
  const content = (
    <>
      <PageIcon page={page} />
      <span className="min-w-0 flex-1">
        <span id={`pod-list-title-${page.id}`} className="block truncate">
          <BdiLabel value={page.title} fallback={t('pod.content.untitled')} />
        </span>
        {parent && (
          <span className="block truncate text-xs text-fg-tertiary">
            <bdi>{parent}</bdi>
          </span>
        )}
      </span>
      {showPrivateBadge && (
        <span className="inline-flex shrink-0 items-center gap-1 rounded-mini bg-muted px-1.5 py-0.5 text-[11px] leading-4 text-fg-secondary">
          <RiLockLine aria-hidden className="size-3" />
          {t('pod.content.private')}
        </span>
      )}
      {timestamp && <span className="shrink-0 text-xs text-fg-tertiary">{timestamp}</span>}
      <span className="shrink-0 text-xs text-fg-tertiary">{typeLabels[page.type]}</span>
    </>
  )
  return (
    <li className={restoreAction ? 'flex min-h-8 items-center justify-between gap-1 py-0.5' : undefined}>
      <Link
        data-pod-list-item
        className={`${listLinkClass} flex-1`}
        aria-label={page.title || t('pod.content.untitled')}
        aria-description={[typeLabels[page.type], showPrivateBadge ? t('pod.content.private') : '', parent, timestamp]
          .filter(Boolean)
          .join(' · ')}
        to={pageHref(page.id, page.title)}>
        {content}
      </Link>
      {restoreAction}
    </li>
  )
}
