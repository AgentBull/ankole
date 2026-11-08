import { useSearchDraft } from '../common/use-search-draft'
import { formatRelativeTime } from '../common/date-time'
import { usePageHref, usePageMetadata, usePagesMetadata } from './use-page-metadata'
import { Button, Input, Select, SelectContent, SelectItem, SelectTrigger, SelectValue, toast } from '@ankole/uikit'
import { pageCreated } from './state/navigation-cache'
import { RiCloseLine, RiDeleteBinLine, RiLockLine } from '@remixicon/react'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useNavigate, useParams } from '@tanstack/react-router'
import type { TFunction } from 'i18next'
import { useMemo, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { principalUID } from '../common/browser-context'
import { podPagePath } from '../common/pod-url'
import { stripBidi } from '../common/bidi'
import { linkTarget, useSearchParams } from '../common/router'
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
  contentKeys,
  pagesByID,
  directoryCapabilitiesQuery,
  pageAPI,
  pageChildrenQuery,
  pageQuery,
  pagesQuery,
  pageSearchQuery,
  type Page,
  type PageDomain,
  type PageScope,
  type PageSearchFilterScope,
  type PageSearchMatch,
  type PageSearchOptions,
  type PageSearchSort,
  type PageType
} from './content-api'
import { ContentError, scopeLabels, typeLabels, ContentSkeleton } from './content-primitives'
import { PermanentDeletePageDialog, usePagePurge } from './page-actions'
import { CreatePageButton } from './page-create-menu'
import { PageIcon } from './page-icon'
import { HighlightedBdiLabel, SearchSnippet } from './search-highlight'
import { buildSearchResultHref, formatSearchTargetBadge } from './search-targets'
import { mergeRecentEntries } from './state/navigation'
import { pagePathAncestors } from './state/page-location'

type SearchDomainFilter = NonNullable<PageSearchOptions['domain']>
type UpdatedPreset = 'any' | '24h' | '7d' | '30d'

const VALID_SEARCH_DOMAINS: ReadonlySet<string> = new Set(['all', 'pages', 'brain'])
const VALID_PAGE_TYPES: ReadonlySet<string> = new Set(['doc', 'knowledge', 'base', 'applet', 'file'])
const VALID_FILTER_SCOPES: ReadonlySet<string> = new Set(['all', 'private', 'space', 'shared', 'conversation'])
const VALID_SORTS: ReadonlySet<string> = new Set(['best', 'updated_desc', 'updated_asc', 'created_desc', 'created_asc'])
const VALID_UPDATED_PRESETS: ReadonlySet<string> = new Set(['any', '24h', '7d', '30d'])

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

  const rawDomainParam = searchParams.get('domain')
  const searchDomain: SearchDomainFilter =
    rawDomainParam && VALID_SEARCH_DOMAINS.has(rawDomainParam) ? (rawDomainParam as SearchDomainFilter) : 'all'

  const rawTypeParam = searchParams.get('type')
  const typeFilter: PageType | 'all' =
    rawTypeParam && VALID_PAGE_TYPES.has(rawTypeParam) ? (rawTypeParam as PageType) : 'all'

  const rawScopeParam = searchParams.get('scope')
  const locationFilter: PageSearchFilterScope =
    rawScopeParam && VALID_FILTER_SCOPES.has(rawScopeParam) ? (rawScopeParam as PageSearchFilterScope) : 'all'

  const rawUpdatedParam = searchParams.get('updated')
  const updatedPreset: UpdatedPreset =
    rawUpdatedParam && VALID_UPDATED_PRESETS.has(rawUpdatedParam) ? (rawUpdatedParam as UpdatedPreset) : 'any'

  const createdBy = searchParams.get('created_by')?.trim() || 'all'
  const titleOnly = searchParams.get('title_only') === 'true'
  const rawSortParam = searchParams.get('sort')
  const sort: PageSearchSort = rawSortParam && VALID_SORTS.has(rawSortParam) ? (rawSortParam as PageSearchSort) : 'best'
  const ancestorID = searchParams.get('ancestor_id')?.trim() || undefined

  const updatedAfter = useMemo(() => {
    if (updatedPreset === 'any') return undefined
    const ms = updatedPreset === '24h' ? 86_400_000 : updatedPreset === '7d' ? 7 * 86_400_000 : 30 * 86_400_000
    const roundedNow = Math.floor(Date.now() / 60_000) * 60_000
    return new Date(roundedNow - ms).toISOString()
  }, [updatedPreset])

  const searchOptions = useMemo<PageSearchOptions>(
    () => ({
      domain: searchDomain,
      title_only: titleOnly,
      sort,
      ...(typeFilter !== 'all' ? { types: typeFilter } : {}),
      ...(locationFilter !== 'all' ? { scope: locationFilter } : {}),
      ...(createdBy !== 'all' ? { created_by: createdBy } : {}),
      ...(ancestorID ? { ancestor_id: ancestorID } : {}),
      ...(updatedAfter ? { updated_after: updatedAfter } : {}),
      limit: 50
    }),
    [ancestorID, createdBy, locationFilter, searchDomain, sort, titleOnly, typeFilter, updatedAfter]
  )

  const updateFilterParam = (key: string, value: string | undefined, defaultValue?: string) => {
    setSearchParams(
      current => {
        if (!value || value === defaultValue) current.delete(key)
        else current.set(key, value)
        return current
      },
      { replace: true, preventScrollReset: true }
    )
  }

  const hasNonDefaultFilters =
    searchDomain !== 'all' ||
    typeFilter !== 'all' ||
    locationFilter !== 'all' ||
    createdBy !== 'all' ||
    updatedPreset !== 'any' ||
    titleOnly ||
    sort !== 'best' ||
    Boolean(ancestorID)

  const clearAllFilters = () => {
    setSearchParams(
      current => {
        for (const key of ['domain', 'type', 'scope', 'created_by', 'updated', 'title_only', 'sort', 'ancestor_id']) {
          current.delete(key)
        }
        return current
      },
      { replace: true, preventScrollReset: true }
    )
  }

  const debouncing = (search || trash) && inputQuery !== query
  const listing = useQuery({
    ...pagesQuery(effectiveScope, trash ? query : '', domain),
    enabled: !rootScope && !search
  })
  const searched = useQuery({ ...pageSearchQuery(query, searchOptions), enabled: search })
  const roots = useInfiniteQuery({
    ...pageChildrenQuery(effectiveScope === 'private' ? 'private' : 'space'),
    enabled: !trash && domain === 'pages'
  })
  const creatorCandidates = useQuery({
    queryKey: contentKeys.mentionCandidates('principal', ''),
    queryFn: ({ signal }) => pageAPI.mentionCandidates('', 'principal', undefined, signal),
    staleTime: 60_000,
    enabled: search
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
  const viewerUID = principalUID() ?? capabilities?.principal_uid
  const creatorOptions = useMemo(() => {
    const others = (creatorCandidates.data?.principals ?? []).filter(
      item => item.principal_uid && item.principal_uid !== viewerUID
    )
    const hasCustomCreator =
      createdBy !== 'all' && createdBy !== viewerUID && !others.some(item => item.principal_uid === createdBy)
    return { others, hasCustomCreator }
  }, [createdBy, creatorCandidates.data?.principals, viewerUID])

  const rows: Page[] | undefined = pages.data?.pages
  const retentionDays = pages.data && 'trash_retention_days' in pages.data ? pages.data.trash_retention_days : null
  const knownPages = pagesByID(client, [...(rows ?? []), ...(searched.data?.ancestors ?? [])])
  const ancestorDetail = useQuery({
    ...pageQuery(ancestorID ?? ''),
    enabled: search && Boolean(ancestorID) && !knownPages.has(ancestorID ?? '')
  })
  const ancestorTitle = ancestorID ? (knownPages.get(ancestorID)?.title ?? ancestorDetail.data?.page.title) : undefined
  const matchesByPageID = useMemo(
    () => new Map((searched.data?.matches ?? []).map(match => [match.page_id, match])),
    [searched.data?.matches]
  )
  const recordSearchOnClick = () => {
    const clean = query.trim()
    if (!search || clean.length < 2) return
    void pageAPI
      .recordRecentSearch(clean, rows?.length ?? 0)
      .then(() => client.invalidateQueries({ queryKey: contentKeys.recentSearches(8) }))
      .catch(() => {})
  }
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
      {search && (
        <div className="mb-3 flex flex-wrap items-center gap-1.5" data-testid="search-filters">
          <Select value={searchDomain} onValueChange={next => next && updateFilterParam('domain', next, 'all')}>
            <SelectTrigger size="sm" variant="ghost" aria-label={t('pod.content.filter_domain')}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">{t('pod.content.domain_all')}</SelectItem>
              <SelectItem value="pages">{t('pod.content.domain_pages')}</SelectItem>
              <SelectItem value="brain">{t('pod.content.domain_brain')}</SelectItem>
            </SelectContent>
          </Select>

          <Select value={typeFilter} onValueChange={next => next && updateFilterParam('type', next, 'all')}>
            <SelectTrigger size="sm" variant="ghost" aria-label={t('pod.content.filter_type')}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">{t('pod.content.type_all')}</SelectItem>
              <SelectItem value="doc">{typeLabels.doc}</SelectItem>
              <SelectItem value="knowledge">{t('pod.content.type_knowledge')}</SelectItem>
              <SelectItem value="base">{typeLabels.base}</SelectItem>
              <SelectItem value="applet">{typeLabels.applet}</SelectItem>
              <SelectItem value="file">{typeLabels.file}</SelectItem>
            </SelectContent>
          </Select>

          <Select value={locationFilter} onValueChange={next => next && updateFilterParam('scope', next, 'all')}>
            <SelectTrigger size="sm" variant="ghost" aria-label={t('pod.content.filter_scope')}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">{t('pod.content.scope_all')}</SelectItem>
              <SelectItem value="space">{t('pod.content.scope_space')}</SelectItem>
              <SelectItem value="private">{t('pod.content.scope_private')}</SelectItem>
              <SelectItem value="shared">{t('pod.content.scope_shared')}</SelectItem>
              <SelectItem value="conversation">{t('pod.content.scope_conversation')}</SelectItem>
            </SelectContent>
          </Select>

          <Select value={createdBy} onValueChange={next => next && updateFilterParam('created_by', next, 'all')}>
            <SelectTrigger size="sm" variant="ghost" aria-label={t('pod.content.filter_creator')}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">{t('pod.content.creator_anyone')}</SelectItem>
              {viewerUID && <SelectItem value={viewerUID}>{t('pod.content.creator_me')}</SelectItem>}
              {creatorOptions.others.map(person => (
                <SelectItem key={person.principal_uid} value={person.principal_uid}>
                  {person.name ? `${person.name} (@${person.principal_uid})` : `@${person.principal_uid}`}
                </SelectItem>
              ))}
              {creatorOptions.hasCustomCreator && <SelectItem value={createdBy}>@{createdBy}</SelectItem>}
            </SelectContent>
          </Select>

          <Select value={updatedPreset} onValueChange={next => next && updateFilterParam('updated', next, 'any')}>
            <SelectTrigger size="sm" variant="ghost" aria-label={t('pod.content.filter_updated')}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="any">{t('pod.content.updated_any')}</SelectItem>
              <SelectItem value="24h">{t('pod.content.updated_today')}</SelectItem>
              <SelectItem value="7d">{t('pod.content.updated_7d')}</SelectItem>
              <SelectItem value="30d">{t('pod.content.updated_30d')}</SelectItem>
            </SelectContent>
          </Select>

          <Button
            type="button"
            size="sm"
            variant={titleOnly ? 'outline' : 'ghost'}
            aria-pressed={titleOnly}
            onClick={() => updateFilterParam('title_only', titleOnly ? undefined : 'true')}>
            {t('pod.command.title_only')}
          </Button>

          <Select value={sort} onValueChange={next => next && updateFilterParam('sort', next, 'best')}>
            <SelectTrigger size="sm" variant="ghost" aria-label={t('pod.command.sort_label')}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="best">{t('pod.command.sort_best')}</SelectItem>
              <SelectItem value="updated_desc">{t('pod.command.sort_updated_desc')}</SelectItem>
              <SelectItem value="updated_asc">{t('pod.command.sort_updated_asc')}</SelectItem>
              <SelectItem value="created_desc">{t('pod.command.sort_created_desc')}</SelectItem>
              <SelectItem value="created_asc">{t('pod.command.sort_created_asc')}</SelectItem>
            </SelectContent>
          </Select>

          {ancestorID && (
            <span className="inline-flex h-7 items-center gap-1 rounded-control bg-muted pr-1 pl-2 text-xs text-fg-secondary">
              <span className="max-w-44 truncate">
                {t('pod.command.in_page_chip', { title: ancestorTitle || t('pod.content.untitled') })}
              </span>
              <button
                type="button"
                aria-label={t('pod.command.clear_in_page')}
                className="inline-flex size-6 min-h-6 min-w-6 cursor-pointer items-center justify-center rounded-mini text-fg-tertiary hover:text-foreground"
                onClick={() => updateFilterParam('ancestor_id', undefined)}>
                <RiCloseLine aria-hidden className="size-3.5" />
              </button>
            </span>
          )}

          {hasNonDefaultFilters && (
            <Button type="button" size="sm" variant="ghost" onClick={clearAllFilters}>
              {t('pod.content.clear_filters')}
            </Button>
          )}
        </div>
      )}
      {(search || trash) && (
        <Input
          key={scope}
          autoFocus={search}
          aria-label={trash ? t('pod.content.search_trash') : t('pod.content.search_pages')}
          autoCorrect="off"
          autoCapitalize="off"
          spellCheck={false}
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
        <ContentSkeleton variant="list" rows={6} />
      ) : (
        <ul className="space-y-1">
          {rows?.map(page => (
            <PageListItem
              key={page.id}
              page={page}
              ancestors={rootScope ? [] : pagePathAncestors(page, knownPages)}
              showPrivateBadge={!rootScope && Boolean(page.private_owner_uid)}
              match={search ? matchesByPageID.get(page.id) : undefined}
              searchQuery={search ? query : undefined}
              onOpenSearchResult={search ? recordSearchOnClick : undefined}
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
          {query || (search && hasNonDefaultFilters)
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
  const knownPages = pagesByID(client, pages.data?.pages ?? [])
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
      {pending && !entries.length && <ContentSkeleton variant="list" rows={6} />}
      <ul className="space-y-1">
        {entries.map(entry => {
          if (entry.kind === 'page') {
            return (
              <PageListItem
                key={`page:${entry.id}`}
                page={entry.page}
                ancestors={pagePathAncestors(entry.page, knownPages)}
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
  match,
  searchQuery,
  onOpenSearchResult,
  restoreAction
}: {
  page: Page
  ancestors: Page[]
  showPrivateBadge: boolean
  timestamp: string
  match?: PageSearchMatch
  searchQuery?: string
  onOpenSearchResult?: () => void
  restoreAction?: ReactNode
}) {
  const { t } = useTranslation()
  const pageHref = usePageHref()
  const page = usePageMetadata(sourcePage)
  const parent = usePagesMetadata(ancestors)
    .map(page => stripBidi(page.title) || t('pod.content.untitled'))
    .join(' / ')
  const baseHref = pageHref(page.id, page.title)
  const href =
    searchQuery?.trim() || match?.primary_target
      ? buildSearchResultHref(baseHref, searchQuery ?? '', match?.primary_target, match?.match_fields ?? ['title'])
      : baseHref
  const targetBadge = searchQuery?.trim() ? formatSearchTargetBadge(match?.primary_target, t) : undefined
  const showSnippet = Boolean(searchQuery?.trim() && match?.snippet && match.snippet.segments.length > 0)
  const content = (
    <>
      <PageIcon page={page} />
      <span className="min-w-0 flex-1">
        <span id={`pod-list-title-${page.id}`} className="block truncate">
          <HighlightedBdiLabel value={page.title} fallback={t('pod.content.untitled')} query={searchQuery} />
        </span>
        {parent && (
          <span className="block truncate text-xs text-fg-tertiary">
            <bdi>{parent}</bdi>
          </span>
        )}
        {showSnippet && match?.snippet && <SearchSnippet snippet={match.snippet} className="mt-0.5" />}
      </span>
      {targetBadge && (
        <span className="max-w-44 shrink-0 truncate rounded-mini bg-muted px-1.5 py-0.5 text-[11px] leading-4 text-fg-secondary">
          {targetBadge}
        </span>
      )}
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
        onClick={onOpenSearchResult}
        {...linkTarget(href)}>
        {content}
      </Link>
      {restoreAction}
    </li>
  )
}
