import { canCreateChild } from './state/page-location'
import { usePageMetadata, usePagesMetadata } from './use-page-metadata'
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
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ComponentPropsWithRef
} from 'react'
import { useComputed, useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { Link, createLink, useLocation, useNavigate, useParams } from '@tanstack/react-router'
import { RiArrowRightSLine, RiChat3Line, RiMoreFill, RiNodeTree, RiShareLine, RiLoader4Line } from '@remixicon/react'
import { authenticationRef, podID, podLocation, podRouteID } from '../common/browser-context'
import { BdiLabel } from '../common/bidi-file-name'
import { sanitizeRenameValue, stripBidi } from '../common/bidi'
import { requestErrorMessage, requestErrorCode, requestErrorDetails } from '../common/request-errors'
import { InternalAPIError } from '../common/internal-api-client'
import { podKeys } from './api'
import { podConversations } from './api/generated/sdk.gen'
import { ChatAvatar } from './chat/chat-avatar'
import { ChatRowStatus } from './chat/chat-sidebar'
import {
  isSidebarSectionActive,
  mergeRecentEntries,
  NavigationModel,
  type CollapsibleSection,
  type NavigationScope,
  type PodSidebarNavigationState
} from './state/navigation'
import { canMovePage, dropAvailability, dropRequest, rootRequest } from './state/page-move'
import {
  pageAPI,
  pagesQuery,
  pageChildrenQuery,
  cachedPages,
  limitPageTitle,
  type Page,
  type NavigationPage
} from './content-api'
import { contentError } from './content-errors'
import { ContentError, scopeLabels } from './content-primitives'
import { CreatePageButton } from './page-create-menu'
import { PageMenuItems, usePageActions, type PageActions } from './page-actions'
import { MovePageDialog } from './page-move-dialog'
import { SpaceSettingsButton } from './space-settings'
import { PageIcon } from './page-icon'
import { navigationQuery, directoryPages, updatePageMetadata } from './state/navigation-cache'

const pageTree = 'pod-pages'

// The followed Sidebar section owns the current mark, even when several links share a URL.
// Keep the router's navigation handlers and href, then apply that mark to the rendered anchor.
const SidebarLink = createLink(function SidebarAnchor({
  current,
  ...props
}: ComponentPropsWithRef<'a'> & { current: boolean }) {
  return <a {...props} aria-current={current ? 'page' : undefined} data-status={undefined} />
})

type PageTreeContextValue = {
  ready: boolean
  path: NavigationPage[]
  favorites: Set<string>
  model: InstanceType<typeof NavigationModel>
  activeSection?: CollapsibleSection
  actions: PageActions
  togglePage(id: string): void
  closePage(id: string): void
  onNavigate?: () => void
}

const PageTreeContext = createContext<PageTreeContextValue | null>(null)

function usePageTree(): PageTreeContextValue {
  const value = useContext(PageTreeContext)
  if (!value) throw new Error('A page row must be inside ContentNavigation.')
  return value
}

function RootSectionToggle({ open, label, onToggle }: { open: boolean; label: string; onToggle(): void }) {
  const button = useRef<HTMLButtonElement>(null)
  const chevron = useRef<SVGSVGElement>(null)
  const pointerTarget = useRef<boolean | null>(null)
  const instant = () => {
    if (button.current) {
      button.current.dataset.motionInput = 'instant'
      delete button.current.dataset.pointerPressed
    }
    if (chevron.current) chevron.current.style.transition = 'none'
    pointerTarget.current = null
  }
  useLayoutEffect(() => {
    // Only the synchronous root toggle consumes pointer intent; restoration and drops are immediate.
    if (pointerTarget.current !== open) instant()
    pointerTarget.current = null
  }, [open])
  const release = () => {
    if (button.current) delete button.current.dataset.pointerPressed
  }
  return (
    <button
      ref={button}
      type="button"
      className="pod-tree-toggle"
      aria-label={label}
      aria-expanded={open}
      data-motion-input="instant"
      onPointerDown={event => {
        if (!event.isPrimary || event.button !== 0) return
        event.currentTarget.dataset.motionInput = 'pointer'
        event.currentTarget.dataset.pointerPressed = ''
      }}
      onPointerUp={release}
      onPointerCancel={release}
      onPointerLeave={release}
      onLostPointerCapture={release}
      onKeyDown={instant}
      onClick={event => {
        if (event.detail > 0) {
          pointerTarget.current = !open
          event.currentTarget.dataset.motionInput = 'pointer'
          if (chevron.current) {
            chevron.current.style.transition = 'transform var(--duration-feedback) var(--ease-in-out)'
          }
        } else instant()
        onToggle()
      }}>
      <RiArrowRightSLine
        ref={chevron}
        aria-hidden
        className="pod-nav-root-chevron"
        onTransitionEnd={event => {
          if (event.target !== chevron.current) return
          if (event.propertyName === 'transform') event.currentTarget.style.transition = 'none'
          if (event.propertyName === 'opacity' && !button.current?.hasAttribute('data-pointer-pressed')) instant()
        }}
      />
    </button>
  )
}

export function ContentNavigation({ onNavigate }: { onNavigate?: () => void }) {
  useSignals()
  const { t } = useTranslation()
  const pathname = useLocation({ select: location => location.pathname })
  const activeSection = useLocation({
    select: location => (location.state as PodSidebarNavigationState | null)?.sidebarSection
  })
  const routePageID = useParams({ strict: false, select: params => params.pageID })
  const [initialPageID] = useState(() => podRouteID(routePageID))
  const client = useQueryClient()
  const bootstrap = useQuery(navigationQuery(client, initialPageID))
  const restored = useRef(false)
  const model = useModel(() => new NavigationModel(podID(), authenticationRef()))
  const rootOpen = model.rootOpen.value
  useEffect(() => {
    const storageKey = model.storageKey()
    if (!storageKey) return
    model.refreshPreferences()
    const restore = (event: StorageEvent) => {
      if (event.key === storageKey || event.key === null) model.restore(event.newValue)
    }
    window.addEventListener('storage', restore)
    return () => window.removeEventListener('storage', restore)
  }, [model])
  useEffect(() => {
    if (!bootstrap.data || restored.current) return
    restored.current = true
    if (bootstrap.data.path.length) {
      model.revealPath(
        bootstrap.data.path.slice(0, -1).map(page => page.id),
        bootstrap.data.path[0].private_owner_uid ? 'private' : 'space'
      )
    }
  }, [bootstrap.data, model])
  const favorites = useQuery(pagesQuery('favorites'))
  const actions = usePageActions()
  const favoritePages = favorites.data?.pages ?? []
  const favoriteIDs = useMemo(() => new Set(favoritePages.map(page => page.id)), [favoritePages])
  const autoScroll = useTreeAutoScroll<HTMLElement>(pageTree)
  const scrollContainer = useCallback(
    (node: HTMLElement | null) => autoScroll(node?.closest<HTMLElement>('[data-sidebar="content"]') ?? null),
    [autoScroll]
  )
  const tree: PageTreeContextValue = {
    ready: bootstrap.isSuccess,
    path: bootstrap.data?.path ?? [],
    actions,
    favorites: favoriteIDs,
    model,
    activeSection,
    togglePage: model.togglePage,
    closePage: model.closePage,
    onNavigate
  }
  const sharedPath = podLocation('/content/shared').pathname
  const favoritesPath = podLocation('/content/favorites').pathname
  return (
    <PageTreeContext value={tree}>
      <nav ref={scrollContainer} aria-label={t('pod.content.page_navigation')} className="pod-navigation">
        <RecentNavigationSection
          open={rootOpen.recent}
          onToggle={() => model.toggleRoot('recent')}
          onNavigate={onNavigate}
        />
        {(favoritePages.length > 0 || pathname === favoritesPath) && (
          <FavoritesNavigationSection
            pages={favoritePages}
            open={rootOpen.favorites}
            onToggle={() => model.toggleRoot('favorites')}
            onNavigate={onNavigate}
          />
        )}
        {bootstrap.error && <ContentError error={bootstrap.error} retry={() => void bootstrap.refetch()} />}
        {(['space', 'private'] as const).map(scope => (
          <NavigationTree
            key={scope}
            scope={scope}
            open={rootOpen[scope]}
            onToggleRoot={() => model.toggleRoot(scope)}
          />
        ))}
        <div className="pod-nav-places">
          <Link
            className="nav-row pod-nav-link"
            to={sharedPath}
            aria-current={pathname === sharedPath ? 'page' : undefined}
            onClick={onNavigate}>
            <RiShareLine aria-hidden />
            <span className="truncate">{scopeLabels.shared}</span>
          </Link>
        </div>
      </nav>
    </PageTreeContext>
  )
}

function RecentNavigationSection({
  open,
  onToggle,
  onNavigate
}: {
  open: boolean
  onToggle(): void
  onNavigate?: () => void
}) {
  const { t } = useTranslation()
  const pathname = useLocation({ select: location => location.pathname })
  const { activeSection } = usePageTree()
  const routePageID = useParams({ strict: false, select: params => params.pageID })
  const activePageID = podRouteID(routePageID)
  const recentPages = useQuery(pagesQuery('recent'))
  const recentRooms = useQuery({
    queryKey: [...podKeys.conversations, 'recent', 'sidebar'],
    queryFn: ({ signal }) => podConversations({ query: { order: 'recent', limit: 10 }, signal })
  })
  const recentRows = usePagesMetadata(recentPages.data?.pages ?? [])
  const entries = mergeRecentEntries(recentRows, recentRooms.data?.conversations ?? []).slice(0, 5)
  const recentPath = podLocation('/content/recent').pathname
  const pending = recentPages.isPending && recentRooms.isPending
  return (
    <section aria-label={scopeLabels.recent} className="pod-nav-section">
      <div className="pod-nav-section-heading">
        <RootSectionToggle open={open} label={scopeLabels.recent} onToggle={onToggle} />
        <Link
          className="min-w-0 flex-1 truncate"
          to={recentPath}
          aria-current={pathname === recentPath ? 'page' : undefined}
          onClick={onNavigate}>
          {scopeLabels.recent}
        </Link>
      </div>
      {open &&
        (pending ? (
          <p role="status" className="pod-tree-empty">
            {t('pod.content.loading')}
          </p>
        ) : entries.length > 0 ? (
          <ul className="pod-nav-places">
            {entries.map(entry => {
              if (entry.kind === 'page') {
                const active = isSidebarSectionActive(activeSection, 'recent') && activePageID === entry.page.id
                return (
                  <li key={`page:${entry.id}`} className="min-w-0">
                    <SidebarLink
                      className="nav-row pod-nav-link"
                      to={podLocation(`/pages/${entry.page.id}`).pathname}
                      state={{ sidebarSection: 'recent' } as never}
                      current={active}
                      activeProps={{}}
                      onClick={onNavigate}>
                      <PageIcon page={entry.page} />
                      <span className="min-w-0 flex-1 truncate text-left" dir="auto">
                        {entry.page.title || t('pod.content.untitled')}
                      </span>
                    </SidebarLink>
                  </li>
                )
              }
              const target = podLocation(`/conversations/${entry.room.id}`).pathname
              const active = isSidebarSectionActive(activeSection, 'recent') && pathname === target
              return (
                <li key={`chat:${entry.id}`} className="min-w-0">
                  <SidebarLink
                    className="nav-row pod-nav-link"
                    to={target}
                    state={{ keepSidebarTab: 'home', sidebarSection: 'recent' } as never}
                    current={active}
                    activeProps={{}}
                    onClick={onNavigate}>
                    {entry.room.agents.length > 0 ? (
                      <span className="pod-recent-chat-avatar">
                        <ChatAvatar
                          name={entry.room.agents[0]!.displayName}
                          src={entry.room.agents[0]!.avatarURL}
                          agent
                        />
                      </span>
                    ) : (
                      <RiChat3Line aria-hidden />
                    )}
                    <span className="min-w-0 flex-1 truncate text-left" dir="auto">
                      {entry.room.title || t('pod.content.untitled')}
                    </span>
                    <ChatRowStatus status={entry.room.rowStatus} />
                  </SidebarLink>
                </li>
              )
            })}
          </ul>
        ) : (
          <p className="pod-tree-empty">{t('pod.sidebar.recent_empty')}</p>
        ))}
    </section>
  )
}

function FavoritesNavigationSection({
  pages: sourcePages,
  open,
  onToggle,
  onNavigate
}: {
  pages: Page[]
  open: boolean
  onToggle(): void
  onNavigate?: () => void
}) {
  const { t } = useTranslation()
  const pathname = useLocation({ select: location => location.pathname })
  const { activeSection } = usePageTree()
  const routePageID = useParams({ strict: false, select: params => params.pageID })
  const activePageID = podRouteID(routePageID)
  const pages = usePagesMetadata(sourcePages)
  const favoritesPath = podLocation('/content/favorites').pathname
  return (
    <section aria-label={scopeLabels.favorites} className="pod-nav-section">
      <div className="pod-nav-section-heading">
        <RootSectionToggle open={open} label={scopeLabels.favorites} onToggle={onToggle} />
        <Link
          className="min-w-0 flex-1 truncate"
          to={favoritesPath}
          aria-current={pathname === favoritesPath ? 'page' : undefined}
          onClick={onNavigate}>
          {scopeLabels.favorites}
        </Link>
      </div>
      {open &&
        (pages.length > 0 ? (
          <ul className="pod-nav-places">
            {pages.map(page => {
              const active = isSidebarSectionActive(activeSection, 'favorites') && activePageID === page.id
              return (
                <li key={page.id} className="min-w-0">
                  <SidebarLink
                    className="nav-row pod-nav-link"
                    to={podLocation(`/pages/${page.id}`).pathname}
                    state={{ sidebarSection: 'favorites' } as never}
                    current={active}
                    activeProps={{}}
                    onClick={onNavigate}>
                    <PageIcon page={page} />
                    <span className="min-w-0 flex-1 truncate text-left" dir="auto">
                      {page.title || t('pod.content.untitled')}
                    </span>
                  </SidebarLink>
                </li>
              )
            })}
          </ul>
        ) : (
          <p className="pod-tree-empty">{t('pod.content.no_pages_yet')}</p>
        ))}
    </section>
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
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const navigate = useNavigate()
  const effectiveScope = scope ?? (privateOwner ? 'private' : 'space')
  const children = useInfiniteQuery({
    ...pageChildrenQuery(effectiveScope, pageID),
    enabled: open || !canCreate
  })
  const pages = usePagesMetadata(children.data?.pages.flatMap(batch => batch.pages) ?? [])
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
  const { t } = useTranslation()
  const { actions, onNavigate, ready, path } = usePageTree()
  const client = useQueryClient()
  const pages = useInfiniteQuery({ ...pageChildrenQuery(scope), enabled: ready })
  const loaded = pages.data?.pages.flatMap(batch => batch.pages) ?? []
  const known = directoryPages(loaded, path, scope)
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
        <RootSectionToggle open={open} label={scopeLabels[scope]} onToggle={onToggleRoot} />
        <Link className="min-w-0 flex-1 truncate" to={podLocation(`/content/${scope}`).pathname} onClick={onNavigate}>
          {scopeLabels[scope]}
        </Link>
        <div className="pod-nav-actions flex items-center">
          {scope === 'space' && <SpaceSettingsButton canManage={pages.data?.pages[0]?.can_manage_space === true} />}
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
            <PageTree pages={known} siblings={loaded} scope={scope} />
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

function PageTree({ pages, siblings, scope }: { pages: NavigationPage[]; siblings: Page[]; scope: NavigationScope }) {
  const { t } = useTranslation()
  return pages.length ? (
    <ul className="pod-tree">
      {pages.map(page => (
        <PageTreeNode key={page.id} page={page} scope={scope} siblings={siblings} />
      ))}
    </ul>
  ) : (
    <p className="pod-tree-empty">{t('pod.content.no_pages_yet')}</p>
  )
}

function PageTreeNode({ page, scope, siblings }: { page: NavigationPage; scope: NavigationScope; siblings: Page[] }) {
  useSignals()
  const { t } = useTranslation()
  const { activeSection, model, closePage, ready, path } = usePageTree()
  const expanded = useComputed(() => model.preferences.value.expanded.has(page.id))
  const active = useParams({
    strict: false,
    select: params => isSidebarSectionActive(activeSection, scope) && podRouteID(params.pageID) === page.id
  })
  const open = page.has_children && expanded.value
  useEffect(() => {
    if (!page.has_children) closePage(page.id)
  }, [page.id, page.has_children, closePage])
  const children = useInfiniteQuery({ ...pageChildrenQuery(scope, page.id), enabled: ready && open })
  const loaded = children.data?.pages.flatMap(batch => batch.pages) ?? []
  const nested = directoryPages(loaded, path, scope, page.id)
  const [pending, setPending] = useState(false)
  useEffect(() => {
    if (!open || !children.isPending) {
      setPending(false)
      return
    }
    const timer = setTimeout(() => setPending(true), 250)
    return () => clearTimeout(timer)
  }, [open, children.isPending])
  return (
    <li className="min-w-0">
      <PageTreeRow page={page} siblings={siblings} scope={scope} open={open} pending={pending} active={active} />
      {open && (
        <ul className="pod-tree-children">
          {!!children.error && (
            <li>
              <ContentError error={children.error} retry={() => void children.refetch()} />
            </li>
          )}
          {nested.map(child => (
            <PageTreeNode key={child.id} page={child} scope={scope} siblings={loaded} />
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
      )}
    </li>
  )
}

function PageTreeRow({
  page: sourcePage,
  siblings,
  scope,
  open,
  pending,
  active
}: {
  page: NavigationPage
  siblings: Page[]
  scope: NavigationScope
  pending: boolean
  open: boolean
  active: boolean
}) {
  const { t } = useTranslation()
  const page = usePageMetadata(sourcePage)
  const { favorites, actions, togglePage, onNavigate } = usePageTree()
  const client = useQueryClient()
  const treeIntent = useRef<ReturnType<typeof setTimeout>>(undefined)
  const cancelTreeIntent = () => clearTimeout(treeIntent.current)
  useEffect(
    () => () => {
      cancelTreeIntent()
    },
    []
  )
  const prefetchTree = () => {
    cancelTreeIntent()
    treeIntent.current = setTimeout(() => void client.prefetchInfiniteQuery(pageChildrenQuery(scope, page.id)), 100)
  }
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
  const canEdit = canCreateChild(page)
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
      if (page.has_children && !open) togglePage(page.id)
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
          className="nav-row pod-tree-row"
          data-active={active ? '' : undefined}
          data-dragging={drag.dragging ? '' : undefined}>
          {page.has_children ? (
            <button
              type="button"
              className="pod-tree-toggle"
              aria-label={label}
              aria-expanded={open}
              aria-busy={pending || undefined}
              onPointerEnter={prefetchTree}
              onPointerLeave={cancelTreeIntent}
              onFocus={prefetchTree}
              onBlur={cancelTreeIntent}
              onClick={() => {
                cancelTreeIntent()
                togglePage(page.id)
              }}>
              {pending ? (
                <RiLoader4Line aria-hidden className="animate-spin" />
              ) : (
                <RiArrowRightSLine aria-hidden className={cn(open && 'rotate-90')} />
              )}
              {pending && (
                <span role="status" className="sr-only">
                  {t('pod.content.loading')}
                </span>
              )}
            </button>
          ) : (
            <span aria-hidden className="pod-tree-toggle-space" />
          )}
          {renaming ? (
            <PageRenameField page={page} onDone={() => setRenaming(false)} />
          ) : (
            <SidebarLink
              ref={drag.handleRef}
              className="pod-tree-link"
              to={podLocation(`/pages/${page.id}`).pathname}
              state={{ sidebarSection: scope } as never}
              onClick={onNavigate}
              current={active}
              activeProps={{}}
              title={stripBidi(label)}>
              <PageIcon page={page} />
              <span className="min-w-0 truncate text-left" dir="auto">
                <BdiLabel value={page.title} fallback={t('pod.content.untitled')} />
              </span>
            </SidebarLink>
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

export function PageRenameField({
  page: sourcePage,
  className,
  onDone
}: {
  page: Page
  className?: string
  onDone(): void
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const page = usePageMetadata(sourcePage)
  const [value, setValue] = useState(() => sanitizeRenameValue(page.title))
  const expectedTitle = useRef(page.title)
  const [conflictingTitle, setConflictingTitle] = useState<string | null>(null)
  const finished = useRef(false)
  const finish = () => {
    finished.current = true
    onDone()
  }
  const rename = useMutation({
    mutationFn: (title: string) => pageAPI.update(page.id, { title, expected_title: expectedTitle.current }),
    onSuccess: (result, title) => {
      updatePageMetadata(client, {
        id: page.id,
        title: result.page?.title ?? title,
        updated_at: result.page?.updated_at
      })
      finish()
    },
    onError: error => {
      finished.current = false
      if (error instanceof InternalAPIError && requestErrorCode(error.payload) === 'title_conflict') {
        const current = requestErrorDetails(error.payload).title
        if (typeof current === 'string') {
          setConflictingTitle(current)
          updatePageMetadata(client, { id: page.id, title: current })
          return
        }
      }
      toast.error(requestErrorMessage(contentError(error)))
    }
  })
  const submit = (confirmConflict = false) => {
    if (finished.current || rename.isPending) return
    if (conflictingTitle !== null) {
      if (!confirmConflict) return
      expectedTitle.current = conflictingTitle
      setConflictingTitle(null)
      const title = value.trim()
      if (title === conflictingTitle) return finish()
      finished.current = true
      rename.mutate(title)
      return
    }
    const title = value.trim()
    if (title === page.title) return finish()
    finished.current = true
    rename.mutate(title)
  }
  return (
    <span className="flex min-w-0 flex-1 flex-col">
      <Input
        autoFocus
        variant="inline"
        className={cn('pod-tree-rename', className)}
        aria-label={t('pod.sidebar.rename_label', { title: page.title || t('pod.content.untitled') })}
        value={value}
        disabled={rename.isPending}
        placeholder={t('pod.content.untitled')}
        onFocus={event => event.currentTarget.select()}
        onChange={event => setValue(limitPageTitle(event.target.value, value))}
        onBlur={() => submit(false)}
        onKeyDown={event => {
          if (event.nativeEvent.isComposing || event.keyCode === 229) return
          if (event.key === 'Enter') {
            event.preventDefault()
            submit(true)
          } else if (event.key === 'Escape') {
            event.preventDefault()
            finish()
          }
        }}
      />
      {conflictingTitle !== null && (
        <span role="alert" className="flex flex-wrap gap-1 text-xs">
          <span>{t('pod.document_title.current', { title: conflictingTitle })}</span>
          <Button size="xs" variant="ghost" onClick={finish}>
            {t('pod.document_title.use_current')}
          </Button>
          <Button size="xs" variant="ghost" disabled={rename.isPending} onClick={() => submit(true)}>
            {t('pod.document_title.save_draft')}
          </Button>
        </span>
      )}
    </span>
  )
}
