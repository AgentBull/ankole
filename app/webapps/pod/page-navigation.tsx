import { useMenuFinalFocus } from '@ankole/uikit/hooks/use-menu-final-focus'
import { agentsQuery, conversationAttentionQuery, podKeys } from './api'
import { commentAttentionQuery } from './content-api'
import { canCreateChild, canRenamePage } from './state/page-location'
import { usePageHref, usePageMetadata, usePagesMetadata } from './use-page-metadata'
import { useTranslation } from 'react-i18next'
import {
  Badge,
  Button,
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
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuAction,
  SidebarMenuActions,
  SidebarMenuButton,
  SidebarMenuIcon,
  SidebarMenuItem,
  SidebarMenuRow,
  SidebarMenuSub,
  SidebarMenuToggle,
  TreeDropIndicator,
  useTreeAutoScroll,
  useTreeItemDrag,
  Spinner
} from '@ankole/uikit'
import {
  CaretRightFilled,
  MoreHorizontalRegular,
  ShareRegular,
  TaskListSquareLtrRegular,
  TextBulletListTreeRegular
} from '@ankole/uikit/icons'
import { useInfiniteQuery, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ComponentPropsWithRef,
  type CSSProperties,
  type ReactNode,
  type Ref
} from 'react'
import { useComputed, useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { Link, createLink, useLocation, useNavigate, useParams } from '@tanstack/react-router'
import { authenticationRef, podID } from '../common/browser-context'
import { podLocation, podPageRouteID } from '../common/pod-url'
import { BdiLabel } from '../common/bidi-file-name'
import { stripBidi } from '../common/bidi'
import { podConversations } from './api/generated/sdk.gen'
import { ChatRowStatus, ConversationGlyph, ConversationTitle, conversationPath } from './chat/conversation-row'
import { MetaNavigation } from './meta-navigation'
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
  pagesQuery,
  pageChildrenQuery,
  cachedPageMap,
  cachedPages,
  type Page,
  type NavigationPage
} from './content-api'
import { ContentError, scopeLabels, ContentSkeleton } from './content-primitives'
import { CreatePageButton } from './page-create-menu'
import { PageMenuItems, usePageActions, type PageActions } from './page-actions'
import { MovePageDialog } from './page-move-dialog'
import { PageRenameField } from './page-rename-field'
import { SpaceSettingsButton } from './space-settings'
import { PageIcon } from './page-icon'
import { navigationQuery, directoryPages } from './state/navigation-cache'
import { workItemsQuery } from './work-api'

const pageTree = 'pod-pages'

// The followed Sidebar section owns the current mark, even when several links share a URL.
// Keep the router's navigation handlers and href, then apply that mark to the rendered anchor.
export const SidebarLink = createLink(function SidebarAnchor({
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

/** Lets a wider heading target toggle the section with the same chevron motion as the chevron itself. */
export interface RootSectionToggleHandle {
  toggle(detail: number): void
}

export function RootSectionToggle({
  open,
  label,
  onToggle,
  ref
}: {
  open: boolean
  label: string
  onToggle(): void
  ref?: Ref<RootSectionToggleHandle>
}) {
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
  // A pointer click (detail > 0) rotates the chevron with the section body's height; keyboard and programmatic clicks
  // flip it at once.
  const toggle = (detail: number) => {
    if (detail > 0) {
      pointerTarget.current = !open
      if (button.current) button.current.dataset.motionInput = 'pointer'
      if (chevron.current) {
        chevron.current.style.transition = `rotate ${open ? 'var(--duration-overlay)' : 'var(--duration-dialog)'} var(--ease-out)`
      }
    } else instant()
    onToggle()
  }
  useImperativeHandle(ref, () => ({ toggle }))
  // The UIKit caret follows its title and turns while the section is open; this toggle decides how fast it turns.
  return (
    <SidebarMenuToggle
      ref={button}
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
      onClick={event => toggle(event.detail)}>
      <CaretRightFilled
        ref={chevron}
        aria-hidden
        className="pod-nav-root-chevron"
        onTransitionEnd={event => {
          if (event.target !== chevron.current) return
          if (event.propertyName === 'rotate') event.currentTarget.style.transition = 'none'
          if (event.propertyName === 'opacity' && !button.current?.hasAttribute('data-pointer-pressed')) instant()
        }}
      />
    </SidebarMenuToggle>
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
  const [initialPageID] = useState(() => (pathname.startsWith('/meta/') ? undefined : podPageRouteID(routePageID)))
  const client = useQueryClient()
  const bootstrap = useQuery(navigationQuery(client, initialPageID))
  const agents = useQuery(agentsQuery)
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
        // shortcut: a top Page beyond the first loaded root rows has no known scope and opens Space, as before.
        bootstrap.data.scope ?? 'space'
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
  const workPath = podLocation('/work').pathname
  // The board's row appears while any work item waits to start or runs, and stays while the board is open.
  const activeWork = useQuery({
    ...workItemsQuery,
    select: items => items.filter(item => item.status === 'todo' || item.status === 'working').length
  })
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
        {agents.data?.personalAssistantAvailable && (
          <MetaNavigationSection
            open={rootOpen.meta}
            onToggle={() => model.toggleRoot('meta')}
            activeSection={activeSection}
            onNavigate={onNavigate}
          />
        )}
        <SidebarGroup>
          <SidebarMenu>
            {((activeWork.data ?? 0) > 0 || pathname === workPath) && (
              <SidebarMenuItem>
                <SidebarMenuButton
                  render={
                    <Link
                      to={workPath}
                      aria-current={pathname === workPath ? 'page' : undefined}
                      onClick={onNavigate}
                    />
                  }
                  className="pod-nav-link">
                  <SidebarMenuIcon>
                    <TaskListSquareLtrRegular />
                  </SidebarMenuIcon>
                  <span>{t('pod.work.title')}</span>
                </SidebarMenuButton>
              </SidebarMenuItem>
            )}
            <SidebarMenuItem>
              <SidebarMenuButton
                render={
                  <Link
                    to={sharedPath}
                    aria-current={pathname === sharedPath ? 'page' : undefined}
                    onClick={onNavigate}
                  />
                }
                className="pod-nav-link">
                <SidebarMenuIcon>
                  <ShareRegular />
                </SidebarMenuIcon>
                <span>{scopeLabels.shared}</span>
              </SidebarMenuButton>
            </SidebarMenuItem>
          </SidebarMenu>
        </SidebarGroup>
      </nav>
    </PageTreeContext>
  )
}

/**
 * A section of the Home navigation: a region that its title names. The 32px heading holds the title, which opens the
 * section's own list, the caret that opens and closes the section, and the section's actions at its end, which show
 * while the heading is hovered or focused. The section's body opens and closes with the sidebar's disclosure motion
 * and renders only while the section is open or closing.
 */
function NavigationSection({
  label,
  to,
  open,
  onToggle,
  onNavigate,
  headingRef,
  actions,
  indicator,
  children
}: {
  label: string
  to: string
  open: boolean
  onToggle(): void
  onNavigate?: () => void
  headingRef?: Ref<HTMLDivElement>
  actions?: ReactNode
  indicator?: ReactNode
  children?: ReactNode
}) {
  return (
    <SidebarGroup render={<section aria-label={label} />} className="pod-nav-section">
      <SidebarGroupLabel ref={headingRef} className="pod-nav-section-heading relative">
        <Link
          className="min-w-0 truncate text-inherit no-underline hover:text-foreground"
          to={to}
          activeOptions={{ exact: true }}
          onClick={onNavigate}>
          {label}
        </Link>
        <RootSectionToggle open={open} label={label} onToggle={onToggle} />
        {actions && <div className="pod-nav-actions ms-auto flex items-center">{actions}</div>}
        {indicator}
      </SidebarGroupLabel>
      <SidebarGroupContent open={open}>{children}</SidebarGroupContent>
    </SidebarGroup>
  )
}

function MetaNavigationSection({
  open,
  onToggle,
  activeSection,
  onNavigate
}: {
  open: boolean
  onToggle(): void
  activeSection?: CollapsibleSection
  onNavigate?: () => void
}) {
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set())
  const toggleBranch = useCallback((key: string) => {
    setExpanded(current => {
      const next = new Set(current)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }, [])
  return (
    <NavigationSection
      label="Meta Ankole"
      to={podLocation('/meta').pathname}
      open={open}
      onToggle={onToggle}
      onNavigate={onNavigate}>
      <MetaNavigation
        activeSection={activeSection}
        expanded={expanded}
        onToggleBranch={toggleBranch}
        onNavigate={onNavigate}
      />
    </NavigationSection>
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
  const pageHref = usePageHref()
  const pathname = useLocation({ select: location => location.pathname })
  const { activeSection } = usePageTree()
  const routePageID = useParams({ strict: false, select: params => params.pageID })
  const activePageID = podPageRouteID(routePageID)
  const recentPages = useQuery(pagesQuery('recent'))
  const recentRooms = useQuery({
    queryKey: [...podKeys.conversations, 'recent', 'sidebar'],
    queryFn: ({ signal }) => podConversations({ query: { order: 'recent', limit: 10 }, signal })
  })
  const attention = useQuery(conversationAttentionQuery)
  const commentAttention = useQuery(commentAttentionQuery)
  const unread = new Map(commentAttention.data?.map(row => [row.page.id, row.unread_count]))
  const recentRows = usePagesMetadata([
    ...new Map(
      [...(recentPages.data?.pages ?? []), ...(commentAttention.data?.map(row => row.page) ?? [])].map(page => [
        page.id,
        page
      ])
    ).values()
  ])
  const rooms = [
    ...new Map(
      [...(recentRooms.data?.conversations ?? []), ...(attention.data ?? [])].map(room => [room.id, room])
    ).values()
  ]
  const entries = mergeRecentEntries(
    recentRows.map(page => ({ ...page, relevantUnread: unread.get(page.id) ?? 0 })),
    rooms
  ).slice(0, 8)
  const pending = recentPages.isPending && recentRooms.isPending
  return (
    <NavigationSection
      label={scopeLabels.recent}
      to={podLocation('/content/recent').pathname}
      open={open}
      onToggle={onToggle}
      onNavigate={onNavigate}>
      {pending ? (
        <ContentSkeleton variant="list" rows={3} className="pod-tree-empty" />
      ) : entries.length > 0 ? (
        <SidebarMenu>
          {entries.map(entry => {
            if (entry.kind === 'page') {
              const active = isSidebarSectionActive(activeSection, 'recent') && activePageID === entry.page.id
              return (
                <SidebarMenuItem key={`page:${entry.id}`}>
                  <SidebarMenuButton
                    render={
                      <SidebarLink
                        to={pageHref(entry.page.id, entry.page.title)}
                        state={{ sidebarSection: 'recent' } as never}
                        current={active}
                        activeProps={{}}
                        onClick={onNavigate}
                      />
                    }
                    className="pod-nav-link">
                    <SidebarMenuIcon>
                      <PageIcon page={entry.page} />
                    </SidebarMenuIcon>
                    <span className="min-w-0 flex-1 truncate" dir="auto">
                      {entry.page.title || t('pod.content.untitled')}
                    </span>
                    {!!entry.page.relevantUnread && (
                      <Badge variant="info" size="sm" title={t('pod.document.unread_comments')}>
                        {entry.page.relevantUnread}
                      </Badge>
                    )}
                  </SidebarMenuButton>
                </SidebarMenuItem>
              )
            }
            const target = conversationPath(entry.room)
            const active = isSidebarSectionActive(activeSection, 'recent') && pathname === target
            return (
              <SidebarMenuItem key={`chat:${entry.id}`}>
                <SidebarMenuButton
                  render={
                    <SidebarLink
                      to={target}
                      state={{ keepSidebarTab: 'home', sidebarSection: 'recent' } as never}
                      current={active}
                      activeProps={{}}
                      onClick={onNavigate}
                    />
                  }
                  className="pod-nav-link">
                  <SidebarMenuIcon>
                    <ConversationGlyph room={entry.room} />
                  </SidebarMenuIcon>
                  <span className="min-w-0 flex-1 truncate" dir="auto">
                    <ConversationTitle room={entry.room} />
                  </span>
                  <ChatRowStatus status={entry.room.rowStatus} />
                </SidebarMenuButton>
              </SidebarMenuItem>
            )
          })}
        </SidebarMenu>
      ) : (
        <p className="pod-tree-empty">{t('pod.sidebar.recent_empty')}</p>
      )}
    </NavigationSection>
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
  const pageHref = usePageHref()
  const { activeSection } = usePageTree()
  const routePageID = useParams({ strict: false, select: params => params.pageID })
  const activePageID = podPageRouteID(routePageID)
  const pages = usePagesMetadata(sourcePages)
  return (
    <NavigationSection
      label={scopeLabels.favorites}
      to={podLocation('/content/favorites').pathname}
      open={open}
      onToggle={onToggle}
      onNavigate={onNavigate}>
      {pages.length > 0 ? (
        <SidebarMenu>
          {pages.map(page => {
            const active = isSidebarSectionActive(activeSection, 'favorites') && activePageID === page.id
            return (
              <SidebarMenuItem key={page.id}>
                <SidebarMenuButton
                  render={
                    <SidebarLink
                      to={pageHref(page.id, page.title)}
                      state={{ sidebarSection: 'favorites' } as never}
                      current={active}
                      activeProps={{}}
                      onClick={onNavigate}
                    />
                  }
                  className="pod-nav-link">
                  <SidebarMenuIcon>
                    <PageIcon page={page} />
                  </SidebarMenuIcon>
                  <span dir="auto">{page.title || t('pod.content.untitled')}</span>
                </SidebarMenuButton>
              </SidebarMenuItem>
            )
          })}
        </SidebarMenu>
      ) : (
        <p className="pod-tree-empty">{t('pod.content.no_pages_yet')}</p>
      )}
    </NavigationSection>
  )
}

export function PageChildrenMenu({
  pageID,
  canCreate,
  scope,
  privateOwner,
  types
}: {
  types?: readonly ('doc' | 'base' | 'knowledge' | 'file')[]
  pageID: string
  canCreate: boolean
  scope?: 'space' | 'private'
  privateOwner?: string
}) {
  const { t } = useTranslation()
  const pageHref = usePageHref()
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
        <PopoverTrigger
          render={
            <Button
              size="icon-lg"
              variant="ghost"
              aria-label={t('pod.content.child_pages')}
              title={t('pod.content.child_pages')}
            />
          }>
          <TextBulletListTreeRegular />
        </PopoverTrigger>
        <PopoverContent
          align="end"
          className="max-h-[min(70vh,var(--available-height))] w-[min(24rem,calc(100vw-2rem))] overflow-y-auto">
          <PopoverTitle>{t('pod.content.child_pages')}</PopoverTitle>
          <ContentError error={children.error} retry={() => void children.refetch()} />
          {children.isPending ? (
            <ContentSkeleton variant="list" rows={3} />
          ) : (
            pages.length > 0 && (
              <ul className="grid gap-1">
                {pages.map(page => (
                  <li key={page.id}>
                    <Link
                      className="flex items-center gap-2 rounded-control px-2 py-1.5 text-sm text-foreground no-underline hover:bg-accent"
                      to={pageHref(page.id, page.title)}
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
              types={types}
              scope={effectiveScope}
              privateOwner={privateOwner}
              label={t('pod.sidebar.new_subpage')}
              onCreated={page => {
                setOpen(false)
                void navigate({ to: pageHref(page.id, page.title) })
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
      const source = cachedPageMap(client).get(sourceID)
      return operation === 'inside' && source && canMovePage(source) && (scope === 'space' ? canCreateSpace : owner)
        ? 'available'
        : 'not-available'
    },
    onDrop: ({ source }) => {
      const page = cachedPageMap(client).get(source)
      if (!page) return
      actions.move(page, rootRequest(scope, owner))
      if (!open) onToggleRoot()
    }
  })
  if (scope === 'private' && canCreatePrivate === false) return null
  const canManageSpace = pages.data?.pages[0]?.can_manage_space === true
  const canCreate = scope === 'private' || canCreateSpace
  return (
    <NavigationSection
      label={scopeLabels[scope]}
      to={podLocation(`/content/${scope}`).pathname}
      open={open}
      onToggle={onToggleRoot}
      onNavigate={onNavigate}
      headingRef={drop.targetRef}
      actions={
        ((scope === 'space' && canManageSpace) || canCreate) && (
          <>
            {scope === 'space' && <SpaceSettingsButton canManage={canManageSpace} />}
            {canCreate && <CreatePageButton scope={scope} privateOwner={owner} compact />}
          </>
        )
      }
      indicator={<TreeDropIndicator indication={drop.indication} />}>
      {pages.isPending ? (
        <ContentSkeleton variant="list" rows={2} className="px-3 py-2" />
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
      )}
    </NavigationSection>
  )
}

function PageTree({ pages, siblings, scope }: { pages: NavigationPage[]; siblings: Page[]; scope: NavigationScope }) {
  const { t } = useTranslation()
  return pages.length ? (
    <SidebarMenu className="pod-tree">
      {pages.map(page => (
        <PageTreeNode key={page.id} page={page} scope={scope} siblings={siblings} depth={0} />
      ))}
    </SidebarMenu>
  ) : (
    <p className="pod-tree-empty">{t('pod.content.no_pages_yet')}</p>
  )
}

/**
 * The nesting level that a child list gives its rows. Each of the first six levels indents 20px; every deeper level
 * indents 4px, so the title of a deeply nested page keeps its room.
 */
function childLevelStyle(depth: number): CSSProperties | undefined {
  const level = depth + 1
  return level > 6 ? ({ '--sidebar-menu-level': 6 + (level - 6) / 5 } as CSSProperties) : undefined
}

function PageTreeNode({
  page,
  scope,
  siblings,
  depth
}: {
  page: NavigationPage
  scope: NavigationScope
  siblings: Page[]
  depth: number
}) {
  useSignals()
  const { t } = useTranslation()
  const { activeSection, model, closePage, togglePage, ready, path } = usePageTree()
  const expanded = useComputed(() => model.preferences.value.expanded.has(page.id))
  // The child list moves when the person opens or closes this row with its arrow; a row that opens on its own, such as
  // a restored or revealed row, or by a drop, shows its rows at once.
  const [toggled, setToggled] = useState(false)
  const toggle = (byArrow: boolean) => {
    setToggled(byArrow)
    togglePage(page.id)
  }
  const active = useParams({
    strict: false,
    select: params => isSidebarSectionActive(activeSection, scope) && podPageRouteID(params.pageID) === page.id
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
    <SidebarMenuItem>
      <PageTreeRow
        page={page}
        siblings={siblings}
        scope={scope}
        open={open}
        pending={pending}
        active={active}
        toggled={toggled}
        onToggle={toggle}
      />
      {/* A list that the person opens waits for its rows, so its height runs to the loaded rows. */}
      <SidebarMenuSub
        open={open && (!toggled || !children.isPending)}
        instant={!toggled}
        className="pod-tree-children"
        style={childLevelStyle(depth)}>
        {!!children.error && (
          <li>
            <ContentError error={children.error} retry={() => void children.refetch()} />
          </li>
        )}
        {nested.map(child => (
          <PageTreeNode key={child.id} page={child} scope={scope} siblings={loaded} depth={depth + 1} />
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
      </SidebarMenuSub>
    </SidebarMenuItem>
  )
}

function PageTreeRow({
  page: sourcePage,
  siblings,
  scope,
  open,
  pending,
  active,
  toggled,
  onToggle
}: {
  page: NavigationPage
  siblings: Page[]
  scope: NavigationScope
  pending: boolean
  open: boolean
  active: boolean
  toggled: boolean
  onToggle(byArrow: boolean): void
}) {
  const { t } = useTranslation()
  const pageHref = usePageHref()
  const page = usePageMetadata(sourcePage)
  const { favorites, actions, onNavigate } = usePageTree()
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
  const [renameRequested, setRenaming] = useState(false)
  const renaming = renameRequested && canRenamePage(page)
  const [moving, setMoving] = useState(false)
  const [keepFocusInRow, menuFinalFocus] = useMenuFinalFocus()
  const label = page.title || t('pod.content.untitled')
  const canEdit = canCreateChild(page)
  const canMove = canMovePage(page)
  const drag = useTreeItemDrag<HTMLAnchorElement, HTMLDivElement>({
    tree: pageTree,
    id: page.id,
    label,
    canDrag: canMove,
    availability: (sourceID, operation) =>
      dropAvailability(cachedPages(client), cachedPageMap(client).get(sourceID), page, operation),
    onDrop: ({ source, operation }) => {
      const moving = cachedPageMap(client).get(source)
      if (!moving) return
      actions.move(moving, dropRequest(page, operation))
      if (operation === 'inside' && !open) onToggle(false)
    },
    onRestInside: () => {
      if (page.has_children && !open) onToggle(false)
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
          render={<SidebarMenuRow />}
          className="pod-tree-row data-dragging:opacity-45"
          data-active={active ? '' : undefined}
          data-dragging={drag.dragging ? '' : undefined}>
          {page.has_children && (
            <SidebarMenuToggle
              className="pod-tree-toggle"
              aria-label={label}
              aria-expanded={open}
              aria-busy={pending || undefined}
              instant={!toggled}
              onPointerEnter={prefetchTree}
              onPointerLeave={cancelTreeIntent}
              onFocus={prefetchTree}
              onBlur={cancelTreeIntent}
              onClick={() => {
                cancelTreeIntent()
                onToggle(true)
              }}>
              {pending ? <Spinner aria-hidden /> : <CaretRightFilled aria-hidden />}
              {pending && (
                <span role="status" className="sr-only">
                  {t('pod.content.loading')}
                </span>
              )}
            </SidebarMenuToggle>
          )}
          {renaming ? (
            <SidebarMenuButton render={<div />} className="h-auto min-h-8 cursor-auto overflow-visible">
              <SidebarMenuIcon>
                <PageIcon page={page} />
              </SidebarMenuIcon>
              <div className="min-w-0 flex-1">
                <PageRenameField page={page} onDone={() => setRenaming(false)} />
              </div>
            </SidebarMenuButton>
          ) : (
            <SidebarMenuButton
              render={
                <SidebarLink
                  ref={drag.handleRef}
                  to={pageHref(page.id, page.title)}
                  state={{ sidebarSection: scope } as never}
                  onClick={onNavigate}
                  current={active}
                  activeProps={{}}
                  title={stripBidi(label)}
                />
              }
              className="pod-tree-link">
              <SidebarMenuIcon>
                <PageIcon page={page} />
              </SidebarMenuIcon>
              <span dir="auto">
                <BdiLabel value={page.title} fallback={t('pod.content.untitled')} />
              </span>
            </SidebarMenuButton>
          )}
          {!renaming && (
            <SidebarMenuActions>
              <DropdownMenu>
                <DropdownMenuTrigger
                  render={
                    <SidebarMenuAction
                      aria-label={t('pod.sidebar.page_actions', { title: label })}
                      title={t('common.more_actions')}
                    />
                  }>
                  <MoreHorizontalRegular aria-hidden />
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
            </SidebarMenuActions>
          )}
          <TreeDropIndicator indication={drag.indication} />
        </ContextMenuTrigger>
        <ContextMenuContent finalFocus={menuFinalFocus}>{menu}</ContextMenuContent>
      </ContextMenu>
      {moving && <MovePageDialog page={page} close={() => setMoving(false)} />}
    </>
  )
}
