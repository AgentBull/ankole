import { t } from 'i18next'
import {
  Button,
  ContextMenu,
  ContextMenuContent,
  ContextMenuTrigger,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuTrigger,
  Input,
  toast,
  TreeDropIndicator,
  useTreeAutoScroll,
  useTreeItemDrag
} from '@ankole/uikit'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type RefObject } from 'react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { Link, useNavigate, useParams } from '@tanstack/react-router'
import {
  RiAddLine,
  RiArrowRightSLine,
  RiDeleteBinLine,
  RiFolderLine,
  RiHistoryLine,
  RiLockLine,
  RiMoreFill,
  RiShareLine,
  RiStarLine
} from '@remixicon/react'
import { authenticationRef, podID, podLocation, podRouteID } from '../common/browser-context'
import { requestErrorMessage } from '../common/request-errors'
import { NavigationModel, type NavigationScope } from './state/navigation'
import { dropAvailability, dropRequest, rootRequest } from './state/page-move'
import {
  contentKeys,
  pageAPI,
  pagesQuery,
  pageChildrenQuery,
  pageSearchQuery,
  cachedPages,
  type Page,
  type PageScope,
  type PageType
} from './content-api'
import { contentError } from './content-errors'
import { Choice, ContentError, TextField, typeLabels } from './content-primitives'
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
  private: 'Private',
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
  const pages = useInfiniteQuery({ ...pageChildrenQuery(scope), enabled: open })
  const known = pages.data?.pages.flatMap(batch => batch.pages) ?? []
  const owner = pages.data?.pages[0]?.principal_uid
  const canCreatePrivate = pages.data?.pages[0]?.can_create_private
  const drop = useTreeItemDrag<HTMLElement, HTMLDivElement>({
    tree: pageTree,
    id: `root:${scope}`,
    availability: (sourceID, operation) => {
      const source = cachedPages(client).find(page => page.id === sourceID)
      return operation === 'inside' && source && source.role !== 'view' && (scope === 'space' || owner)
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
          <CreatePageButton scope={scope} privateOwner={owner} compact />
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
  const children = useInfiniteQuery({ ...pageChildrenQuery(scope, page.id), enabled: open && page.type === 'doc' })
  const nested = children.data?.pages.flatMap(batch => batch.pages) ?? []
  return (
    <li className="min-w-0">
      <PageTreeRow
        page={page}
        siblings={siblings}
        hasChildren={page.type === 'doc'}
        open={open}
        active={podRouteID(routePageID) === page.id}
      />
      {open && page.type === 'doc' && (
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
      )}
    </li>
  )
}

function PageTreeRow({
  page,
  siblings,
  hasChildren,
  open,
  active
}: {
  page: Page
  siblings: Page[]
  hasChildren: boolean
  open: boolean
  active: boolean
}) {
  const { favorites, actions, togglePage, onNavigate } = usePageTree()
  const client = useQueryClient()
  const pages = siblings
  const [renaming, setRenaming] = useState(false)
  const [dialog, setDialog] = useState<'create' | 'move'>()
  const keepFocusInRow = useRef(false)
  const menuFinalFocus = () => {
    const restore = !keepFocusInRow.current
    keepFocusInRow.current = false
    return restore
  }
  const label = page.title || t('pod.content.untitled')
  const edit = page.role !== 'view'
  const drag = useTreeItemDrag<HTMLAnchorElement, HTMLDivElement>({
    tree: pageTree,
    id: page.id,
    label,
    canDrag: edit,
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
      if (operation === 'inside' && hasChildren && !open) togglePage(page.id)
    },
    onRestInside: () => {
      if (hasChildren && !open) togglePage(page.id)
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
      onCreateChild={() => setDialog('create')}
      onMoveTo={() => setDialog('move')}
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
          {hasChildren ? (
            <button
              type="button"
              className="pod-tree-toggle"
              aria-label={label}
              aria-expanded={open}
              onClick={() => togglePage(page.id)}>
              <RiArrowRightSLine aria-hidden className={open ? 'rotate-90' : ''} />
            </button>
          ) : (
            <span className="pod-tree-spacer" />
          )}
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
              {page.type === 'doc' && edit && <CreatePageButton parentID={page.id} compact />}
            </span>
          )}
          <TreeDropIndicator indication={drag.indication} />
        </ContextMenuTrigger>
        <ContextMenuContent finalFocus={menuFinalFocus}>{menu}</ContextMenuContent>
      </ContextMenu>
      {dialog === 'create' && <CreatePageDialog parentID={page.id} onClose={() => setDialog(undefined)} />}
      {dialog === 'move' && <MovePageDialog page={page} close={() => setDialog(undefined)} />}
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

type CreatePageOptions = {
  parentID?: string
  scope?: 'space' | 'private'
  privateOwner?: string
  onCreated?: (page: Page) => void
  returnFocus?: RefObject<HTMLElement | null>
}

export function CreatePageButton({
  parentID,
  scope = 'space',
  privateOwner,
  compact = false,
  onCreated
}: CreatePageOptions & { compact?: boolean }) {
  const [open, setOpen] = useState(false)
  const waitingForIdentity = !parentID && scope === 'private' && !privateOwner
  return (
    <>
      <Button
        variant={compact ? 'ghost' : 'outline'}
        size={compact ? 'icon-sm' : 'sm'}
        aria-label={t('pod.content.new_page')}
        title={t('pod.content.new_page')}
        disabled={waitingForIdentity}
        onClick={() => setOpen(true)}>
        {compact ? <RiAddLine aria-hidden className="size-4" /> : t('pod.content.new_page')}
      </Button>
      {open && (
        <CreatePageDialog
          parentID={parentID}
          scope={scope}
          privateOwner={privateOwner}
          onCreated={onCreated}
          onClose={() => setOpen(false)}
        />
      )}
    </>
  )
}

export function CreatePageDialog({
  parentID,
  scope = 'space',
  privateOwner,
  onCreated,
  onClose,
  returnFocus
}: CreatePageOptions & { onClose(): void }) {
  const [type, setType] = useState<PageType>('doc')
  const [title, setTitle] = useState('')
  const navigate = useNavigate()
  const client = useQueryClient()
  const waitingForIdentity = !parentID && scope === 'private' && !privateOwner
  const create = useMutation({
    mutationFn: () => {
      if (waitingForIdentity) throw new Error(t('pod.content.your_private_identity_is_not_available_yet_wait_for_the'))
      return pageAPI.create({
        type,
        title: title.trim(),
        ...(parentID ? { parent_id: parentID } : scope === 'private' ? { private_owner_uid: privateOwner } : {})
      })
    },
    onSuccess: async ({ page }) => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      onClose()
      if (onCreated) onCreated(page)
      else void navigate({ to: podLocation(`/pages/${page.id}`).pathname })
    }
  })
  return (
    <Dialog open onOpenChange={next => !create.isPending && !next && onClose()}>
      <DialogContent
        className="pod-dialog"
        closeLabel={t('common.close')}
        finalFocus={returnFocus}
        showCloseButton={!create.isPending}
        render={
          <form
            onSubmit={event => {
              event.preventDefault()
              if (!waitingForIdentity && !create.isPending) create.mutate()
            }}
          />
        }>
        <DialogTitle>{t('pod.content.new_page')}</DialogTitle>
        <TextField label={t('pod.content.title')} value={title} onChange={setTitle} disabled={create.isPending} />
        <Choice
          label={t('pod.content.page_type')}
          value={type}
          onChange={setType}
          options={typeLabels}
          disabled={create.isPending}
        />
        <ContentError error={create.error} />
        <DialogFooter>
          <Button type="button" variant="ghost" disabled={create.isPending} onClick={onClose}>
            {t('pod.content.cancel')}
          </Button>
          <Button type="submit" variant="outline" disabled={waitingForIdentity || create.isPending}>
            {create.isPending ? t('pod.content.creating') : t('pod.content.create')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function ContentListRoute() {
  const { scope = 'space' } = useParams({ strict: false })
  const effectiveScope: PageScope =
    scope === 'search' ? 'all' : Object.hasOwn(scopeLabels, scope) ? (scope as PageScope) : 'space'
  const search = scope === 'search' || effectiveScope === 'all'
  const trash = effectiveScope === 'trash'
  const [searchDraft, setSearchDraft] = useState({ scope, query: '' })
  const query = searchDraft.scope === scope ? searchDraft.query : ''
  const rootScope = !search && (effectiveScope === 'space' || effectiveScope === 'private')
  const listing = useQuery({ ...pagesQuery(effectiveScope), enabled: !rootScope && !search })
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
  const visible: Page[] | undefined =
    trash && query.trim()
      ? pages.data?.pages.filter(page => page.title.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()))
      : pages.data?.pages
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
        {effectiveScope !== 'trash' && (effectiveScope !== 'private' || pages.data?.can_create_private !== false) && (
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
          value={query}
          onChange={event => setSearchDraft({ scope, query: event.target.value })}
        />
      )}
      <ContentError error={pages.error || restore.error} retry={() => void pages.refetch()} />
      {pages.isPending ? (
        <p role="status">{t('pod.content.loading')}</p>
      ) : (
        <ul className="space-y-1">
          {visible?.map(page => (
            <li key={page.id} className={trash ? 'flex min-h-8 items-center justify-between gap-3 py-0.5' : undefined}>
              {trash ? (
                <span className="flex min-w-0 flex-1 items-center gap-3 px-3">
                  <PageIcon page={page} />
                  <span id={`pod-trash-title-${page.id}`} className="min-w-0 flex-1 truncate">
                    {page.title || t('pod.content.untitled')}
                  </span>
                  <span className="shrink-0 text-xs text-fg-tertiary">{typeLabels[page.type]}</span>
                </span>
              ) : (
                <Link
                  data-pod-list-item
                  className="pod-content-list-link flex min-h-8 min-w-0 items-center gap-3 rounded-control px-3 py-1 text-[13px] leading-5 text-foreground no-underline hover:bg-accent focus-visible:bg-accent focus-visible:outline-2 focus-visible:outline-ring"
                  aria-label={page.title || t('pod.content.untitled')}
                  aria-description={typeLabels[page.type]}
                  to={podLocation(`/pages/${page.id}`).pathname}>
                  <PageIcon page={page} />
                  <span className="min-w-0 flex-1 truncate">{page.title || t('pod.content.untitled')}</span>
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
      {!pages.isPending && !pages.error && !visible?.length && (
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
