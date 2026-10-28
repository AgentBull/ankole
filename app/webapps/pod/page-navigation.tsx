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
import { Link, useLocation, useNavigate, useParams } from '@tanstack/react-router'
import { RiArrowRightSLine, RiChat3Line, RiMoreFill, RiNodeTree, RiShareLine } from '@remixicon/react'
import { authenticationRef, podID, podLocation, podRouteID } from '../common/browser-context'
import { requestErrorMessage } from '../common/request-errors'
import { podKeys } from './api'
import { podConversations } from './api/generated/sdk.gen'
import { ChatAvatar } from './chat/chat-avatar'
import { ChatRowStatus } from './chat/chat-sidebar'
import { mergeRecentEntries, NavigationModel, type NavigationScope } from './state/navigation'
import { canMovePage, dropAvailability, dropRequest, rootRequest } from './state/page-move'
import { contentKeys, pageAPI, pagesQuery, pageChildrenQuery, cachedPages, type Page } from './content-api'
import { contentError } from './content-errors'
import { ContentError, scopeLabels } from './content-primitives'
import { CreatePageButton } from './page-create-menu'
import { PageMenuItems, usePageActions, type PageActions } from './page-actions'
import { MovePageDialog } from './page-move-dialog'
import { SpaceSettingsButton } from './space-settings'
import { PageIcon } from './page-icon'

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
  const location = useLocation()
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
  const favoritePages = favorites.data?.pages ?? []
  const favoriteIDs = useMemo(() => new Set(favoritePages.map(page => page.id)), [favoritePages])
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
  const sharedPath = podLocation('/content/shared').pathname
  const favoritesPath = podLocation('/content/favorites').pathname
  return (
    <PageTreeContext value={tree}>
      <nav ref={scrollContainer} aria-label={t('pod.content.page_navigation')} className="pod-navigation">
        <RecentNavigationSection
          open={preferences.rootOpen.recent}
          onToggle={() => model.toggleRoot('recent')}
          onNavigate={onNavigate}
        />
        {(favoritePages.length > 0 || location.pathname === favoritesPath) && (
          <FavoritesNavigationSection
            pages={favoritePages}
            open={preferences.rootOpen.favorites}
            onToggle={() => model.toggleRoot('favorites')}
            onNavigate={onNavigate}
          />
        )}
        {(['space', 'private'] as const).map(scope => (
          <NavigationTree
            key={scope}
            scope={scope}
            open={preferences.rootOpen[scope]}
            onToggleRoot={() => model.toggleRoot(scope)}
          />
        ))}
        <div className="pod-nav-places">
          <Link
            className="pod-nav-link"
            to={sharedPath}
            aria-current={location.pathname === sharedPath ? 'page' : undefined}
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
  const location = useLocation()
  const { pageID: routePageID } = useParams({ strict: false })
  const activePageID = podRouteID(routePageID)
  const recentPages = useQuery(pagesQuery('recent'))
  const recentRooms = useQuery({
    queryKey: [...podKeys.conversations, 'recent', 'sidebar'],
    queryFn: ({ signal }) => podConversations({ query: { order: 'recent', limit: 10 }, signal })
  })
  const entries = useMemo(
    () => mergeRecentEntries(recentPages.data?.pages ?? [], recentRooms.data?.conversations ?? []).slice(0, 5),
    [recentPages.data?.pages, recentRooms.data?.conversations]
  )
  const recentPath = podLocation('/content/recent').pathname
  const pending = recentPages.isPending && recentRooms.isPending
  return (
    <section aria-label={scopeLabels.recent} className="pod-nav-section">
      <div className="pod-nav-section-heading">
        <button
          type="button"
          className="pod-tree-toggle"
          aria-label={scopeLabels.recent}
          aria-expanded={open}
          onClick={onToggle}>
          <RiArrowRightSLine aria-hidden className={open ? 'rotate-90' : ''} />
        </button>
        <Link
          className="min-w-0 flex-1 truncate"
          to={recentPath}
          aria-current={location.pathname === recentPath ? 'page' : undefined}
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
                const active = activePageID === entry.page.id
                return (
                  <li key={`page:${entry.id}`} className="min-w-0">
                    <Link
                      className="pod-nav-link"
                      data-shortcut="true"
                      to={podLocation(`/pages/${entry.page.id}`).pathname}
                      aria-current={active ? 'page' : undefined}
                      onClick={onNavigate}>
                      <PageIcon page={entry.page} />
                      <span className="min-w-0 flex-1 truncate">{entry.page.title || t('pod.content.untitled')}</span>
                    </Link>
                  </li>
                )
              }
              const target = podLocation(`/conversations/${entry.room.id}`).pathname
              const active = location.pathname === target
              return (
                <li key={`chat:${entry.id}`} className="min-w-0">
                  <Link
                    className="pod-nav-link"
                    to={target}
                    state={{ keepSidebarTab: 'home' } as never}
                    aria-current={active ? 'page' : undefined}
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
                    <span className="min-w-0 flex-1 truncate">{entry.room.title}</span>
                    <ChatRowStatus status={entry.room.rowStatus} />
                  </Link>
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
  pages,
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
  const location = useLocation()
  const { pageID: routePageID } = useParams({ strict: false })
  const activePageID = podRouteID(routePageID)
  const favoritesPath = podLocation('/content/favorites').pathname
  return (
    <section aria-label={scopeLabels.favorites} className="pod-nav-section">
      <div className="pod-nav-section-heading">
        <button
          type="button"
          className="pod-tree-toggle"
          aria-label={scopeLabels.favorites}
          aria-expanded={open}
          onClick={onToggle}>
          <RiArrowRightSLine aria-hidden className={open ? 'rotate-90' : ''} />
        </button>
        <Link
          className="min-w-0 flex-1 truncate"
          to={favoritesPath}
          aria-current={location.pathname === favoritesPath ? 'page' : undefined}
          onClick={onNavigate}>
          {scopeLabels.favorites}
        </Link>
      </div>
      {open &&
        (pages.length > 0 ? (
          <ul className="pod-nav-places">
            {pages.map(page => {
              const active = activePageID === page.id
              return (
                <li key={page.id} className="min-w-0">
                  <Link
                    className="pod-nav-link"
                    data-shortcut="true"
                    to={podLocation(`/pages/${page.id}`).pathname}
                    aria-current={active ? 'page' : undefined}
                    onClick={onNavigate}>
                    <PageIcon page={page} />
                    <span className="min-w-0 flex-1 truncate">{page.title || t('pod.content.untitled')}</span>
                  </Link>
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
