import { t } from 'i18next'
import { Button, Dialog, DialogContent, DialogFooter, DialogTitle, Input, toast } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState, type RefObject } from 'react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { Link, NavLink, useNavigate, useParams } from 'react-router'
import {
  RiAddLine,
  RiArrowRightSLine,
  RiDeleteBinLine,
  RiFolderLine,
  RiHistoryLine,
  RiLockLine,
  RiShareLine,
  RiStarLine
} from '@remixicon/react'
import { authenticationRef, podID, podLocation, podRouteID } from '../common/browser-context'
import { NavigationModel, type NavigationScope } from './state/navigation'
import { contentKeys, pageAPI, pagesQuery, type Page, type PageScope, type PageType } from './content-api'
import { Choice, ContentError, TextField, typeLabels } from './content-primitives'
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
  return (
    <div className="space-y-5 text-[13px]">
      <nav aria-label={t('pod.content.page_navigation')} className="space-y-0.5">
        {(['shared', 'recent', 'favorites', 'trash'] as const).map(scope => {
          const Icon = scopeIcons[scope]
          return (
            <NavLink key={scope} className="pod-nav-link" to={podLocation(`/content/${scope}`)} onClick={onNavigate}>
              <Icon aria-hidden />
              <span>{scopeLabels[scope]}</span>
            </NavLink>
          )
        })}
      </nav>
      {(['space', 'private'] as const).map(scope => (
        <NavigationTree
          key={scope}
          scope={scope}
          open={preferences.rootOpen[scope]}
          collapsed={preferences.collapsed}
          onToggleRoot={() => model.toggleRoot(scope)}
          onTogglePage={model.togglePage}
          onNavigate={onNavigate}
        />
      ))}
    </div>
  )
}

function NavigationTree({
  scope,
  open,
  collapsed,
  onToggleRoot,
  onTogglePage,
  onNavigate
}: {
  scope: NavigationScope
  open: boolean
  collapsed: Set<string>
  onToggleRoot(): void
  onTogglePage(id: string): void
  onNavigate?: () => void
}) {
  const pages = useQuery(pagesQuery(scope))
  return (
    <section aria-label={scopeLabels[scope]}>
      <div className="pod-nav-section-heading">
        <button
          type="button"
          className="pod-tree-toggle"
          aria-label={scopeLabels[scope]}
          aria-expanded={open}
          onClick={onToggleRoot}>
          <RiArrowRightSLine aria-hidden className={open ? 'rotate-90' : ''} />
        </button>
        <Link className="min-w-0 flex-1 truncate" to={podLocation(`/content/${scope}`)} onClick={onNavigate}>
          {scopeLabels[scope]}
        </Link>
        <div className="pod-nav-actions flex items-center">
          {scope === 'space' && <SpaceSettingsButton />}
          <CreatePageButton scope={scope} privateOwner={pages.data?.principal_uid} compact />
        </div>
      </div>
      {open &&
        (pages.isPending ? (
          <p role="status" className="px-3 py-2">
            {t('pod.content.loading')}
          </p>
        ) : pages.error ? (
          <ContentError error={pages.error} retry={() => void pages.refetch()} />
        ) : (
          <PageTree
            pages={pages.data?.pages ?? []}
            collapsed={collapsed}
            onTogglePage={onTogglePage}
            onNavigate={onNavigate}
          />
        ))}
    </section>
  )
}

export function PageTree({
  pages,
  collapsed,
  onTogglePage,
  onNavigate
}: {
  pages: Page[]
  collapsed: Set<string>
  onTogglePage(id: string): void
  onNavigate?: () => void
}) {
  const { pageID: routePageID } = useParams()
  const pageID = podRouteID(routePageID)
  const ids = new Set(pages.map(page => page.id))
  const roots = pages.filter(page => !page.parent_id || !ids.has(page.parent_id))
  const children = new Map<string, Page[]>()
  for (const page of pages) {
    if (!page.parent_id) continue
    const siblings = children.get(page.parent_id)
    if (siblings) siblings.push(page)
    else children.set(page.parent_id, [page])
  }
  for (const siblings of children.values()) siblings.sort(positionOrder)
  const branch = (page: Page, ancestors: Set<string>) => {
    if (ancestors.has(page.id)) return null
    ancestors.add(page.id)
    const nested = children.get(page.id) ?? []
    const open = !collapsed.has(page.id)
    const childNodes = open ? nested.map(child => branch(child, ancestors)) : []
    ancestors.delete(page.id)
    return (
      <li key={page.id} className="min-w-0">
        <div className="pod-tree-row" data-active={pageID === page.id ? '' : undefined}>
          {nested.length ? (
            <button
              type="button"
              className="pod-tree-toggle"
              aria-label={page.title || t('pod.content.untitled')}
              aria-expanded={open}
              onClick={() => onTogglePage(page.id)}>
              <RiArrowRightSLine aria-hidden className={open ? 'rotate-90' : ''} />
            </button>
          ) : (
            <span className="pod-tree-spacer size-5 shrink-0" />
          )}
          <Link
            className="pod-tree-link"
            to={podLocation(`/pages/${page.id}`)}
            onClick={onNavigate}
            aria-current={pageID === page.id ? 'page' : undefined}
            title={page.title || t('pod.content.untitled')}>
            <PageIcon page={page} />
            <span className="truncate">{page.title || t('pod.content.untitled')}</span>
          </Link>
          {page.type === 'doc' && page.role !== 'view' && (
            <span className="pod-row-action">
              <CreatePageButton parentID={page.id} compact />
            </span>
          )}
        </div>
        {nested.length > 0 && open && <ul className="pl-3.5">{childNodes}</ul>}
      </li>
    )
  }
  return roots.length ? (
    <ul className="space-y-px">{roots.sort(positionOrder).map(page => branch(page, new Set()))}</ul>
  ) : (
    <p className="px-3 py-2 text-xs text-fg-tertiary">{t('pod.content.no_pages_yet')}</p>
  )
}

export function positionOrder(a: Page, b: Page): number {
  return a.position === b.position ? (a.id < b.id ? -1 : a.id === b.id ? 0 : 1) : a.position < b.position ? -1 : 1
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
      else navigate(podLocation(`/pages/${page.id}`))
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
  const { scope = 'space' } = useParams()
  const effectiveScope: PageScope =
    scope === 'search' ? 'all' : Object.hasOwn(scopeLabels, scope) ? (scope as PageScope) : 'space'
  const search = scope === 'search'
  const trash = effectiveScope === 'trash'
  const [searchDraft, setSearchDraft] = useState({ scope, query: '' })
  const query = searchDraft.scope === scope ? searchDraft.query : ''
  const pages = useQuery(pagesQuery(effectiveScope, search ? query : ''))
  const client = useQueryClient()
  const navigate = useNavigate()
  const restore = useMutation({
    mutationFn: pageAPI.restore,
    onSuccess: async ({ page }) => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      toast.success(t('pod.content.page_restored'), {
        action: { label: t('pod.content.open_page'), onClick: () => navigate(podLocation(`/pages/${page.id}`)) }
      })
    }
  })
  const visible =
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
        )
          return
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
        {effectiveScope !== 'trash' && (
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
                  to={podLocation(`/pages/${page.id}`)}>
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
