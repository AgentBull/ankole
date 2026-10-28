import { Button, Input, toast } from '@ankole/uikit'
import { RiChat3Line, RiLockLine } from '@remixicon/react'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useNavigate, useParams } from '@tanstack/react-router'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { podLocation } from '../common/browser-context'
import { useSearchParams } from '../common/router'
import { podKeys } from './api'
import { podConversations } from './api/generated/sdk.gen'
import { ChatAvatar } from './chat/chat-avatar'
import { ChatRowStatus } from './chat/chat-sidebar'
import {
  cachedPages,
  contentKeys,
  pageAPI,
  pageChildrenQuery,
  pagesQuery,
  pageSearchQuery,
  type Page,
  type PageScope
} from './content-api'
import { ContentError, scopeLabels, typeLabels } from './content-primitives'
import { CreatePageButton } from './page-create-menu'
import { PageIcon } from './page-icon'
import { mergeRecentEntries } from './state/navigation'
import { pageAncestors } from './state/page-location'

export function ContentListRoute() {
  const { scope = 'space' } = useParams({ strict: false })
  const effectiveScope = scope === 'search' || Object.hasOwn(scopeLabels, scope) ? scope : 'space'
  return effectiveScope === 'recent' ? (
    <RecentContentList />
  ) : (
    <PageContentList scope={effectiveScope as PageScope | 'search'} />
  )
}

function PageContentList({ scope }: { scope: PageScope | 'search' }) {
  const { t, i18n } = useTranslation()
  const effectiveScope = scope === 'search' ? 'all' : scope
  const search = effectiveScope === 'all'
  const trash = effectiveScope === 'trash'
  const rootScope = effectiveScope === 'space' || effectiveScope === 'private'
  const [searchParams, setSearchParams] = useSearchParams()
  const query = searchParams.get('q') ?? ''
  const [inputQuery, setInputQuery] = useState(query)
  const lastPushedQuery = useRef(query)
  useEffect(() => {
    if (query !== lastPushedQuery.current) {
      lastPushedQuery.current = query
      setInputQuery(query)
    }
  }, [query])
  useEffect(() => {
    lastPushedQuery.current = query
    setInputQuery(query)
  }, [scope])
  useEffect(() => {
    if (!(search || trash) || inputQuery === query) return
    const timer = window.setTimeout(() => {
      lastPushedQuery.current = inputQuery
      setSearchParams(
        current => {
          if (inputQuery) current.set('q', inputQuery)
          else current.delete('q')
          return current
        },
        { replace: true, preventScrollReset: true }
      )
    }, 180)
    return () => window.clearTimeout(timer)
  }, [inputQuery, query, search, setSearchParams, trash])
  const debouncing = (search || trash) && inputQuery !== query
  const listing = useQuery({ ...pagesQuery(effectiveScope, trash ? query : ''), enabled: !rootScope && !search })
  const searched = useQuery({ ...pageSearchQuery(query), enabled: search })
  const roots = useInfiniteQuery({
    ...pageChildrenQuery(effectiveScope === 'private' ? 'private' : 'space'),
    enabled: rootScope
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
  const restore = useMutation({
    mutationFn: pageAPI.restore,
    onSuccess: async ({ page }) => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      toast.success(t('pod.content.page_restored'), {
        action: {
          label: t('pod.content.open_page'),
          onClick: () => void navigate({ to: podLocation(`/pages/${page.id}`).pathname })
        }
      })
    }
  })
  const rows: Page[] | undefined = pages.data?.pages
  const pagesByID = new Map(
    [...cachedPages(client), ...(rows ?? []), ...(searched.data?.ancestors ?? [])].map(page => [page.id, page])
  )
  const error = pages.error || restore.error
  return (
    <ContentListFrame
      title={search ? t('pod.content.search_pages') : scopeLabels[effectiveScope]}
      actions={
        !trash &&
        (effectiveScope === 'private'
          ? pages.data?.can_create_private !== false
          : pages.data?.can_create_space === true) && (
          <CreatePageButton
            scope={effectiveScope === 'private' ? 'private' : 'space'}
            privateOwner={pages.data?.principal_uid}
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
      <ContentError error={error} retry={() => void pages.refetch()} />
      {pages.isPending || (debouncing && !rows?.length) ? (
        <p role="status">{t('pod.content.loading')}</p>
      ) : (
        <ul className="space-y-1">
          {rows?.map(page => (
            <PageListItem
              key={page.id}
              page={page}
              parent={rootScope ? '' : pageParent(page, pagesByID, t('pod.content.untitled'))}
              showPrivateBadge={!rootScope && Boolean(page.private_owner_uid)}
              timestamp={
                rootScope
                  ? ''
                  : formatPageTimestamp(trash ? (page.deleted_at ?? page.updated_at) : page.updated_at, i18n.language)
              }
              restoreAction={
                trash && (
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
    </ContentListFrame>
  )
}

function RecentContentList() {
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const pages = useQuery(pagesQuery('recent'))
  const conversations = useQuery({
    queryKey: [...podKeys.conversations, 'recent', 'list'],
    queryFn: ({ signal }) => podConversations({ query: { order: 'recent', limit: 100 }, signal })
  })
  const entries = mergeRecentEntries(pages.data?.pages ?? [], conversations.data?.conversations ?? [])
  const pending = pages.isPending || conversations.isPending
  const error = pages.error || conversations.error
  const pagesByID = new Map([...cachedPages(client), ...(pages.data?.pages ?? [])].map(page => [page.id, page]))
  return (
    <ContentListFrame
      title={scopeLabels.recent}
      actions={
        pages.data?.can_create_space && <CreatePageButton scope="space" privateOwner={pages.data.principal_uid} />
      }>
      <ContentError
        error={error}
        retry={() => {
          void pages.refetch()
          void conversations.refetch()
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
                parent={pageParent(entry.page, pagesByID, t('pod.content.untitled'))}
                showPrivateBadge={Boolean(entry.page.private_owner_uid)}
                timestamp={formatPageTimestamp(entry.timestamp, i18n.language)}
              />
            )
          }
          const room = entry.room
          const subtitle = room.agents.map(agent => agent.displayName).join(', ')
          const timestamp = formatPageTimestamp(entry.timestamp, i18n.language)
          const chatLabel = t('pod.sidebar.tabs.chat')
          return (
            <li key={`chat:${room.id}`}>
              <Link
                data-pod-list-item
                className={listLinkClass}
                aria-label={room.title}
                aria-description={[chatLabel, subtitle, timestamp].filter(Boolean).join(' · ')}
                state={{ keepSidebarTab: 'home' } as never}
                to={podLocation(`/conversations/${room.id}`).pathname}>
                {room.agents.length > 0 ? (
                  <span className="pod-recent-chat-avatar">
                    <ChatAvatar name={room.agents[0]!.displayName} src={room.agents[0]!.avatarURL} agent />
                  </span>
                ) : (
                  <RiChat3Line aria-hidden className="size-4 shrink-0 text-fg-tertiary" />
                )}
                <span className="min-w-0 flex-1">
                  <span className="block truncate">{room.title}</span>
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

function ContentListFrame({ title, actions, children }: { title: string; actions?: ReactNode; children: ReactNode }) {
  return (
    <section
      className="pod-content-list h-full overflow-auto px-6 pt-2 pb-6 md:px-10"
      onKeyDown={event => {
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
      }}>
      <div className="mb-6 flex items-center justify-between gap-3">
        <h1 className="text-2xl font-semibold">{title}</h1>
        {actions}
      </div>
      {children}
    </section>
  )
}

const listLinkClass =
  'pod-content-list-link flex min-h-8 min-w-0 items-center gap-3 rounded-control px-3 py-1 text-[13px] leading-5 text-foreground no-underline hover:bg-accent focus-visible:bg-accent focus-visible:outline-2 focus-visible:outline-ring'

function PageListItem({
  page,
  parent,
  showPrivateBadge,
  timestamp,
  restoreAction
}: {
  page: Page
  parent: string
  showPrivateBadge: boolean
  timestamp: string
  restoreAction?: ReactNode
}) {
  const { t } = useTranslation()
  const content = (
    <>
      <PageIcon page={page} />
      <span className="min-w-0 flex-1">
        <span id={`pod-list-title-${page.id}`} className="block truncate">
          {page.title || t('pod.content.untitled')}
        </span>
        {parent && <span className="block truncate text-xs text-fg-tertiary">{parent}</span>}
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
    <li className={restoreAction ? 'flex min-h-8 items-center justify-between gap-3 py-0.5' : undefined}>
      {restoreAction ? (
        <span className="flex min-w-0 flex-1 items-center gap-3 px-3 py-1">{content}</span>
      ) : (
        <Link
          data-pod-list-item
          className={listLinkClass}
          aria-label={page.title || t('pod.content.untitled')}
          aria-description={[typeLabels[page.type], showPrivateBadge ? t('pod.content.private') : '', parent, timestamp]
            .filter(Boolean)
            .join(' · ')}
          to={podLocation(`/pages/${page.id}`).pathname}>
          {content}
        </Link>
      )}
      {restoreAction}
    </li>
  )
}

function pageParent(page: Page, pagesByID: Map<string, Page>, untitled: string): string {
  return pageAncestors(page, pagesByID)
    .map(ancestor => ancestor.title || untitled)
    .join(' / ')
}

function formatPageTimestamp(iso: string | null | undefined, locale?: string): string {
  if (!iso) return ''
  const time = Date.parse(iso)
  if (Number.isNaN(time)) return ''
  const now = Date.now()
  const diffSeconds = Math.round((time - now) / 1000)
  const absSeconds = Math.abs(diffSeconds)
  try {
    const rtf = new Intl.RelativeTimeFormat(locale || undefined, { numeric: 'auto' })
    if (absSeconds < 60) return rtf.format(0, 'minute')
    if (absSeconds < 3600) return rtf.format(Math.round(diffSeconds / 60), 'minute')
    if (absSeconds < 86400) return rtf.format(Math.round(diffSeconds / 3600), 'hour')
    if (absSeconds < 7 * 86400) return rtf.format(Math.round(diffSeconds / 86400), 'day')
    const date = new Date(time)
    const sameYear = date.getFullYear() === new Date(now).getFullYear()
    return new Intl.DateTimeFormat(locale || undefined, {
      ...(sameYear ? {} : { year: 'numeric' }),
      month: 'short',
      day: 'numeric'
    }).format(date)
  } catch {
    return new Date(time).toLocaleDateString()
  }
}
