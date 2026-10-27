import { t } from 'i18next'
import { useTranslation } from 'react-i18next'
import {
  Button,
  cn,
  ContextMenu,
  ContextMenuContent,
  ContextMenuTrigger,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuTrigger,
  Input,
  Popover,
  PopoverContent,
  PopoverTitle,
  PopoverTrigger,
  toast,
  TreeDropIndicator,
  useTreeAutoScroll,
  useTreeItemDrag
} from '@ankole/uikit'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { Link, useNavigate, useParams } from '@tanstack/react-router'
import {
  RiArrowRightSLine,
  RiDeleteBinLine,
  RiFolderLine,
  RiHistoryLine,
  RiLockLine,
  RiMoreFill,
  RiNodeTree,
  RiShareLine,
  RiStarLine
} from '@remixicon/react'
import { authenticationRef, podID, podLocation, podRouteID } from '../common/browser-context'
import { useSearchParams } from '../common/router'
import { requestErrorMessage } from '../common/request-errors'
import { NavigationModel, type NavigationScope } from './state/navigation'
import { pageAncestors } from './state/page-location'
import { canMovePage, dropAvailability, dropRequest, rootRequest } from './state/page-move'
import {
  contentKeys,
  pageAPI,
  pagesQuery,
  pageChildrenQuery,
  pageSearchQuery,
  cachedPages,
  type Page,
  type PageScope
} from './content-api'
import { contentError } from './content-errors'
import { ContentError, typeLabels } from './content-primitives'
import { CreatePageButton } from './page-create-menu'
import { PageMenuItems, usePageActions, type PageActions } from './page-actions'
import { MovePageDialog } from './page-move-dialog'
import { SpaceSettingsButton } from './space-settings'
import { PageIcon } from './page-icon'

export const scopeLabels: Record<PageScope, string> = {
  get all() {
    return t('pod.content.all_pages')
  },
  get space() {
    return t('pod.content.space')
  },
  get private() {
    return t('pod.content.private')
  },
  get shared() {
    return t('pod.content.shared_with_me')
  },
  get recent() {
    return t('pod.content.recently_visited')
  },
  get favorites() {
    return t('pod.content.favorites')
  },
  get trash() {
    return t('pod.content.trash')
  }
}

export const scopeIcons = {
  all: RiFolderLine,
  space: RiFolderLine,
  private: RiLockLine,
  shared: RiShareLine,
  recent: RiHistoryLine,
  favorites: RiStarLine,
  trash: RiDeleteBinLine
}

const pageTree = 'pod-pages'

type PageTreeContextValue = {
  favorites: Set<string>
  expanded: Set<string>
  actions: PageActions
  togglePage(id: string): void
  onNavigate?: () => void
}

const PageTreeContext = createContext<PageTreeContextValue | null>(null)

function usePageTree(): PageTreeContextValue {
  const value = useContext(PageTreeContext)
  if (!value) throw new Error('A page row must be inside ContentNavigation.')
  return value
}

export function ContentNavigation({ onNavigate }: { onNavigate?: () => void }) {
  useSignals()
  const model = useModel(() => new NavigationModel(podID(), authenticationRef()))
  const preferences = model.preferences.value
  useEffect(() => {
    const storageKey = model.storageKey()
    if (!storageKey) return
    const restore = (event: StorageEvent) => {
      if (event.key === storageKey || event.key === null) model.restore(event.newValue)
    }
    window.addEventListener('storage', restore)
    return () => window.removeEventListener('storage', restore)
  }, [model])
  const favorites = useQuery(pagesQuery('favorites'))
  const actions = usePageActions()
  const favoriteIDs = useMemo(() => new Set(favorites.data?.pages.map(page => page.id)), [favorites.data])
  const autoScroll = useTreeAutoScroll<HTMLElement>(pageTree)
  const scrollContainer = useCallback(
    (node: HTMLElement | null) => autoScroll(node?.closest<HTMLElement>('[data-sidebar="content"]') ?? null),
    [autoScroll]
  )
  const tree: PageTreeContextValue = {
    actions,
    favorites: favoriteIDs,
    expanded: preferences.expanded,
    togglePage: model.togglePage,
    onNavigate
  }
  return (
    <PageTreeContext value={tree}>
      <div ref={scrollContainer} className="pod-navigation">
        <nav aria-label={t('pod.content.page_navigation')} className="pod-nav-places">
          {(['shared', 'recent', 'favorites', 'trash'] as const).map(scope => {
            const Icon = scopeIcons[scope]
            return (
              <Link
                key={scope}
                className="pod-nav-link"
                to={podLocation(`/content/${scope}`).pathname}
                onClick={onNavigate}>
                <Icon aria-hidden />
                <span>{scopeLabels[scope]}</span>
              </Link>
            )
          })}
        </nav>
        {(['space', 'private'] as const).map(scope => (
          <NavigationTree
            key={scope}
            scope={scope}
            open={preferences.rootOpen[scope]}
            onToggleRoot={() => model.toggleRoot(scope)}
          />
        ))}
      </div>
    </PageTreeContext>
  )
}

export function PageChildrenMenu({
  pageID,
  canCreate,
  scope,
  privateOwner
}: {
  pageID: string
  canCreate: boolean
  scope?: 'space' | 'private'
  privateOwner?: string
}) {
  const [open, setOpen] = useState(false)
  const navigate = useNavigate()
  const effectiveScope = scope ?? (privateOwner ? 'private' : 'space')
  const children = useInfiniteQuery({
    ...pageChildrenQuery(effectiveScope, pageID),
    enabled: open || !canCreate
  })
  const pages = children.data?.pages.flatMap(batch => batch.pages) ?? []
  if (!canCreate && children.isSuccess && !children.hasNextPage && pages.length === 0) return null
  return (
    <>
      <Popover open={open} onOpenChange={setOpen}>
        <PopoverTrigger render={<Button size="sm" variant="ghost" />}>
          <RiNodeTree aria-hidden className="size-4" />
          {t('pod.content.child_pages')}
        </PopoverTrigger>
        <PopoverContent
          align="end"
          className="max-h-[min(70vh,var(--available-height))] w-[min(24rem,calc(100vw-2rem))] overflow-y-auto">
          <PopoverTitle>{t('pod.content.child_pages')}</PopoverTitle>
          <ContentError error={children.error} retry={() => void children.refetch()} />
          {children.isPending ? (
            <p role="status">{t('pod.content.loading')}</p>
          ) : (
            pages.length > 0 && (
              <ul className="grid gap-1">
                {pages.map(page => (
                  <li key={page.id}>
                    <Link
                      className="flex items-center gap-2 rounded-control px-2 py-1.5 text-sm text-foreground no-underline hover:bg-accent"
                      to={podLocation(`/pages/${page.id}`).pathname}
                      onClick={() => setOpen(false)}>
                      <PageIcon page={page} />
                      <span className="truncate">{page.title || t('pod.content.untitled')}</span>
                    </Link>
                  </li>
                ))}
              </ul>
            )
          )}
          {!children.isPending && !children.error && !pages.length && (
            <p className="py-2 text-sm text-fg-tertiary">{t('pod.content.no_pages_yet')}</p>
          )}
          {children.hasNextPage && (
            <Button
              variant="ghost"
              size="sm"
              disabled={children.isFetching}
              onClick={() => void children.fetchNextPage()}>
              {t('pod.content.load_more_pages')}
            </Button>
          )}
          {canCreate && (
            <CreatePageButton
              parentID={pageID}
              scope={effectiveScope}
              privateOwner={privateOwner}
              label={t('pod.sidebar.new_subpage')}
              onCreated={page => {
                setOpen(false)
                void navigate({ to: podLocation(`/pages/${page.id}`).pathname })
              }}
            />
          )}
        </PopoverContent>
      </Popover>
    </>
  )
}

function NavigationTree({
  scope,
  open,
  onToggleRoot
}: {
  scope: NavigationScope
  open: boolean
  onToggleRoot(): void
}) {
  const { actions, onNavigate } = usePageTree()
  const client = useQueryClient()
  const pages = useInfiniteQuery(pageChildrenQuery(scope))
  const known = pages.data?.pages.flatMap(batch => batch.pages) ?? []
  const owner = pages.data?.pages[0]?.principal_uid
  const canCreatePrivate = pages.data?.pages[0]?.can_create_private
  const canCreateSpace = pages.data?.pages[0]?.can_create_space
  const drop = useTreeItemDrag<HTMLElement, HTMLDivElement>({
    tree: pageTree,
    id: `root:${scope}`,
    availability: (sourceID, operation) => {
      const source = cachedPages(client).find(page => page.id === sourceID)
      return operation === 'inside' && source && canMovePage(source) && (scope === 'space' ? canCreateSpace : owner)
        ? 'available'
        : 'not-available'
    },
    onDrop: ({ source }) => {
      const page = cachedPages(client).find(candidate => candidate.id === source)
      if (!page) return
      actions.move(page, rootRequest(scope, owner))
      if (!open) onToggleRoot()
    }
  })
  if (scope === 'private' && canCreatePrivate === false) return null
  return (
    <section aria-label={scopeLabels[scope]} className="pod-nav-section">
      <div ref={drop.targetRef} className="pod-nav-section-heading">
        <button
          type="button"
          className="pod-tree-toggle"
          aria-label={scopeLabels[scope]}
          aria-expanded={open}
          onClick={onToggleRoot}>
          <RiArrowRightSLine aria-hidden className={open ? 'rotate-90' : ''} />
        </button>
        <Link className="min-w-0 flex-1 truncate" to={podLocation(`/content/${scope}`).pathname} onClick={onNavigate}>
          {scopeLabels[scope]}
        </Link>
        <div className="pod-nav-actions flex items-center">
          {scope === 'space' && <SpaceSettingsButton />}
          {(scope === 'private' || canCreateSpace) && <CreatePageButton scope={scope} privateOwner={owner} compact />}
        </div>
        <TreeDropIndicator indication={drop.indication} />
      </div>
      {open &&
        (pages.isPending ? (
          <p role="status" className="px-3 py-2">
            {t('pod.content.loading')}
          </p>
        ) : pages.error ? (
          <ContentError error={pages.error} retry={() => void pages.refetch()} />
        ) : (
          <>
            <PageTree pages={known} scope={scope} />
            {pages.hasNextPage && (
              <Button size="sm" variant="ghost" disabled={pages.isFetching} onClick={() => void pages.fetchNextPage()}>
                {t('pod.content.load_more_pages')}
              </Button>
            )}
          </>
        ))}
    </section>
  )
}

function PageTree({ pages, scope }: { pages: Page[]; scope: NavigationScope }) {
  return pages.length ? (
    <ul className="pod-tree">
      {pages.map(page => (
        <PageTreeNode key={page.id} page={page} scope={scope} siblings={pages} />
      ))}
    </ul>
  ) : (
    <p className="pod-tree-empty">{t('pod.content.no_pages_yet')}</p>
  )
}

function PageTreeNode({ page, scope, siblings }: { page: Page; scope: NavigationScope; siblings: Page[] }) {
  const { expanded } = usePageTree()
  const { pageID: routePageID } = useParams({ strict: false })
  const open = expanded.has(page.id)
  const children = useInfiniteQuery({ ...pageChildrenQuery(scope, page.id), enabled: open })
  const nested = children.data?.pages.flatMap(batch => batch.pages) ?? []
  const knownEmpty = children.isSuccess && nested.length === 0 && !children.hasNextPage
  return (
    <li className="min-w-0">
      <PageTreeRow
        page={page}
        siblings={siblings}
        open={open}
        knownEmpty={knownEmpty}
        active={podRouteID(routePageID) === page.id}
      />
      {open &&
        (knownEmpty ? (
          <p className="pod-tree-empty">{t('pod.content.no_pages_yet')}</p>
        ) : (
          <ul className="pod-tree-children">
            {children.isPending && <li role="status">{t('pod.content.loading')}</li>}
            {!!children.error && (
              <li>
                <ContentError error={children.error} retry={() => void children.refetch()} />
              </li>
            )}
            {nested.map(child => (
              <PageTreeNode key={child.id} page={child} scope={scope} siblings={nested} />
            ))}
            {children.hasNextPage && (
              <li>
                <Button
                  size="sm"
                  variant="ghost"
                  disabled={children.isFetching}
                  onClick={() => void children.fetchNextPage()}>
                  {t('pod.content.load_more_pages')}
                </Button>
              </li>
            )}
          </ul>
        ))}
    </li>
  )
}

function PageTreeRow({
  page,
  siblings,
  open,
  knownEmpty,
  active
}: {
  page: Page
  siblings: Page[]
  open: boolean
  knownEmpty: boolean
  active: boolean
}) {
  const { favorites, actions, togglePage, onNavigate } = usePageTree()
  const client = useQueryClient()
  const pages = siblings
  const [renaming, setRenaming] = useState(false)
  const [moving, setMoving] = useState(false)
  const keepFocusInRow = useRef(false)
  const menuFinalFocus = () => {
    const restore = !keepFocusInRow.current
    keepFocusInRow.current = false
    return restore
  }
  const label = page.title || t('pod.content.untitled')
  const canEdit = page.actions?.includes('page_edit') === true
  const canMove = canMovePage(page)
  const drag = useTreeItemDrag<HTMLAnchorElement, HTMLDivElement>({
    tree: pageTree,
    id: page.id,
    label,
    canDrag: canMove,
    availability: (sourceID, operation) =>
      dropAvailability(
        cachedPages(client),
        cachedPages(client).find(candidate => candidate.id === sourceID),
        page,
        operation
      ),
    onDrop: ({ source, operation }) => {
      const moving = cachedPages(client).find(candidate => candidate.id === source)
      if (!moving) return
      actions.move(moving, dropRequest(page, operation))
      if (operation === 'inside' && !open) togglePage(page.id)
    },
    onRestInside: () => {
      if (!open) togglePage(page.id)
    }
  })
  const menu = (
    <PageMenuItems
      page={page}
      pages={pages}
      favorited={favorites.has(page.id)}
      actions={actions}
      onRename={() => {
        keepFocusInRow.current = true
        setRenaming(true)
      }}
      onMoveTo={() => setMoving(true)}
    />
  )
  return (
    <>
      <ContextMenu>
        <ContextMenuTrigger
          ref={drag.targetRef}
          className="pod-tree-row"
          data-active={active ? '' : undefined}
          data-dragging={drag.dragging ? '' : undefined}>
          <button
            type="button"
            className="pod-tree-toggle"
            aria-label={label}
            aria-expanded={open}
            onClick={() => togglePage(page.id)}>
            <RiArrowRightSLine aria-hidden className={cn(open && 'rotate-90', knownEmpty && 'opacity-30')} />
          </button>
          {renaming ? (
            <PageRenameField page={page} onDone={() => setRenaming(false)} />
          ) : (
            <Link
              ref={drag.handleRef}
              className="pod-tree-link"
              to={podLocation(`/pages/${page.id}`).pathname}
              onClick={onNavigate}
              aria-current={active ? 'page' : undefined}
              title={label}>
              <PageIcon page={page} />
              <span className="truncate">{label}</span>
            </Link>
          )}
          {!renaming && (
            <span className="pod-row-action">
              <DropdownMenu>
                <DropdownMenuTrigger
                  render={
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      aria-label={t('pod.sidebar.page_actions', { title: label })}
                      title={t('common.more_actions')}
                    />
                  }>
                  <RiMoreFill aria-hidden className="size-4" />
                </DropdownMenuTrigger>
                <DropdownMenuContent align="start" className="w-56" finalFocus={menuFinalFocus}>
                  {menu}
                </DropdownMenuContent>
              </DropdownMenu>
              {canEdit && (
                <CreatePageButton
                  parentID={page.id}
                  scope={page.private_owner_uid ? 'private' : 'space'}
                  privateOwner={page.private_owner_uid ?? undefined}
                  compact
                />
              )}
            </span>
          )}
          <TreeDropIndicator indication={drag.indication} />
        </ContextMenuTrigger>
        <ContextMenuContent finalFocus={menuFinalFocus}>{menu}</ContextMenuContent>
      </ContextMenu>
      {moving && <MovePageDialog page={page} close={() => setMoving(false)} />}
    </>
  )
}

function PageRenameField({ page, onDone }: { page: Page; onDone(): void }) {
  const client = useQueryClient()
  const [value, setValue] = useState(page.title)
  const finished = useRef(false)
  const finish = () => {
    finished.current = true
    onDone()
  }
  const rename = useMutation({
    mutationFn: (title: string) => pageAPI.update(page.id, { title }),
    onSuccess: async () => {
      await Promise.all([
        client.invalidateQueries({ queryKey: contentKeys.lists }),
        client.invalidateQueries({ queryKey: contentKeys.page(page.id) })
      ])
      finish()
    },
    onError: error => {
      finished.current = false
      toast.error(requestErrorMessage(contentError(error)))
    }
  })
  const submit = () => {
    if (finished.current || rename.isPending) return
    const title = value.trim()
    if (title === page.title) return finish()
    finished.current = true
    rename.mutate(title)
  }
  return (
    <input
      autoFocus
      className="pod-tree-rename"
      aria-label={t('pod.sidebar.rename_label', { title: page.title || t('pod.content.untitled') })}
      value={value}
      disabled={rename.isPending}
      placeholder={t('pod.content.untitled')}
      onFocus={event => event.currentTarget.select()}
      onChange={event => setValue(event.target.value)}
      onBlur={submit}
      onKeyDown={event => {
        if (event.nativeEvent.isComposing || event.keyCode === 229) return
        if (event.key === 'Enter') {
          event.preventDefault()
          submit()
        } else if (event.key === 'Escape') {
          event.preventDefault()
          finish()
        }
      }}
    />
  )
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

export function ContentListRoute() {
  const { scope = 'space' } = useParams({ strict: false })
  const effectiveScope: PageScope =
    scope === 'search' ? 'all' : Object.hasOwn(scopeLabels, scope) ? (scope as PageScope) : 'space'
  const search = scope === 'search' || effectiveScope === 'all'
  const trash = effectiveScope === 'trash'
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
    // Reset local input when navigating between list scopes.
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
  const { i18n } = useTranslation()
  const debouncing = (search || trash) && inputQuery !== query
  const rootScope = !search && (effectiveScope === 'space' || effectiveScope === 'private')
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
  return (
    <section
      className="pod-content-list h-full overflow-auto px-6 py-6 md:px-10"
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
        <h1 className="text-2xl font-semibold">
          {search ? t('pod.content.search_pages') : scopeLabels[effectiveScope]}
        </h1>
        {effectiveScope !== 'trash' &&
          (effectiveScope === 'private'
            ? pages.data?.can_create_private !== false
            : pages.data?.can_create_space === true) && (
            <CreatePageButton
              scope={effectiveScope === 'private' ? 'private' : 'space'}
              privateOwner={pages.data?.principal_uid}
            />
          )}
      </div>
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
      <ContentError error={pages.error || restore.error} retry={() => void pages.refetch()} />
      {pages.isPending || (debouncing && !rows?.length) ? (
        <p role="status">{t('pod.content.loading')}</p>
      ) : (
        <ul className="space-y-1">
          {rows?.map(page => {
            const parent = !rootScope
              ? pageAncestors(page, pagesByID)
                  .map(ancestor => ancestor.title || t('pod.content.untitled'))
                  .join(' / ')
              : ''
            const showPrivateBadge = !rootScope && Boolean(page.private_owner_uid)
            const timestamp = !rootScope
              ? formatPageTimestamp(trash ? (page.deleted_at ?? page.updated_at) : page.updated_at, i18n.language)
              : ''
            const description = [
              typeLabels[page.type],
              showPrivateBadge ? t('pod.content.private') : '',
              parent,
              timestamp
            ]
              .filter(Boolean)
              .join(' · ')
            return (
              <li
                key={page.id}
                className={trash ? 'flex min-h-8 items-center justify-between gap-3 py-0.5' : undefined}>
                {trash ? (
                  <span className="flex min-w-0 flex-1 items-center gap-3 px-3 py-1">
                    <PageIcon page={page} />
                    <span className="min-w-0 flex-1">
                      <span id={`pod-trash-title-${page.id}`} className="block truncate">
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
                  </span>
                ) : (
                  <Link
                    data-pod-list-item
                    className="pod-content-list-link flex min-h-8 min-w-0 items-center gap-3 rounded-control px-3 py-1 text-[13px] leading-5 text-foreground no-underline hover:bg-accent focus-visible:bg-accent focus-visible:outline-2 focus-visible:outline-ring"
                    aria-label={page.title || t('pod.content.untitled')}
                    aria-description={description}
                    to={podLocation(`/pages/${page.id}`).pathname}>
                    <PageIcon page={page} />
                    <span className="min-w-0 flex-1">
                      <span className="block truncate">{page.title || t('pod.content.untitled')}</span>
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
                  </Link>
                )}
                {effectiveScope === 'trash' ? (
                  <Button
                    data-pod-list-item
                    aria-describedby={`pod-trash-title-${page.id}`}
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
                ) : null}
              </li>
            )
          })}
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
      {!pages.isPending && !debouncing && !pages.error && !rows?.length && (
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
    </section>
  )
}
