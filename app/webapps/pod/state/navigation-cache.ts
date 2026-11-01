import { positionOrder } from './page-move'
import type { QueryClient, Query, QueryKey, InfiniteData } from '@tanstack/react-query'
import { contentKeys, pageAPI, type NavigationPage, type Page, type PageDetail } from '../content-api'
import type {
  PodPageNavigationResponse,
  PodPageChildrenResponse,
  PodPageListResponse,
  PodPageSearchResponse
} from '../api/generated/types.gen'
import type { NavigationScope } from './navigation'
import { pageMetadata } from './page-metadata'

export type DirectoryLocation = { parent_id?: string | null; scope?: NavigationScope }
type NavigationPath = Pick<PodPageNavigationResponse, 'path'>
type PageUpdate = <P extends Page>(page: P) => P | null

export const navigationQuery = (client: QueryClient, activePageID?: string) => ({
  queryKey: contentKeys.navigation(),
  staleTime: Infinity,
  queryFn: async ({ signal }: { signal: AbortSignal }) => {
    const result = await pageMetadata(client).read(
      () => pageAPI.navigation(activePageID, signal),
      result => [...result.path, ...result.directories.flatMap(directory => directory.pages)]
    )
    signal.throwIfAborted()
    for (const directory of result.directories) {
      const key = contentKeys.children(directory.scope as NavigationScope, directory.parent_id ?? undefined)
      // Pagination owns an existing directory, including its freshness and loaded cursors.
      if (client.getQueryData(key) === undefined) {
        client.setQueryData(key, { pages: [directory], pageParams: [undefined] })
      }
    }
    return { path: result.path }
  }
})

/** Include the active path even when its next node is beyond the first directory page. */
export function directoryPages(
  pages: NavigationPage[],
  path: NavigationPage[],
  scope: NavigationScope,
  parentID?: string
) {
  const rows = new Map(
    path
      .filter(
        page =>
          (page.parent_id ?? undefined) === parentID &&
          (parentID || (page.private_owner_uid ? 'private' : 'space') === scope)
      )
      .map(page => [page.id, page])
  )
  for (const page of pages) rows.set(page.id, page)
  return [...rows.values()].sort(positionOrder)
}

function updateCachedQuery<T>(client: QueryClient, key: QueryKey, update: (data: T) => T) {
  const state = client.getQueryState<T>(key)
  if (state?.status !== 'success' || state.isInvalidated || state.data === undefined) return
  const data = update(state.data)
  if (data !== state.data) client.setQueryData(key, data, { updatedAt: state.dataUpdatedAt })
}

function mapPages<P extends Page>(pages: P[], update: PageUpdate): P[] {
  const next = pages.flatMap(page => {
    const updated = update(page)
    return updated ? [updated] : []
  })
  return next.length === pages.length && next.every((page, index) => page === pages[index]) ? pages : next
}

function mapPageList<T extends { pages: Page[] }>(data: T, update: PageUpdate): T {
  const pages = mapPages(data.pages, update)
  return pages === data.pages ? data : { ...data, pages }
}

/** A local patch changes known fields; only a server read can validate a stale list. */
export function updatePageCaches(client: QueryClient, update: PageUpdate) {
  for (const query of client.getQueryCache().findAll({ queryKey: contentKeys.lists })) {
    switch (query.queryKey[contentKeys.lists.length]) {
      case 'children':
        updateCachedQuery<InfiniteData<PodPageChildrenResponse>>(client, query.queryKey, data => {
          const pages = data.pages.map(batch => mapPageList(batch, update))
          return pages.every((batch, index) => batch === data.pages[index]) ? data : { ...data, pages }
        })
        break
      case 'navigation':
        updateCachedQuery<NavigationPath>(client, query.queryKey, data => {
          const path = mapPages(data.path, update)
          return path === data.path ? data : { ...data, path }
        })
        break
      case 'search':
        updateCachedQuery<PodPageSearchResponse>(client, query.queryKey, data => {
          const result = mapPageList(data, update)
          const ancestors = mapPages(data.ancestors, update)
          return ancestors === data.ancestors ? result : { ...result, ancestors }
        })
        break
      default:
        updateCachedQuery<PodPageListResponse>(client, query.queryKey, data => mapPageList(data, update))
    }
  }
  // A removed ancestor must also leave the paths carried by cached Page reads.
  for (const query of client.getQueryCache().findAll({ predicate: isPageRead })) {
    updateCachedQuery<PageDetail>(client, query.queryKey, data => {
      const ancestors = mapPages(data.ancestors, update)
      return ancestors === data.ancestors ? data : { ...data, ancestors }
    })
  }
}

function isPageRead(query: Query) {
  const page = contentKeys.page('')
  return (
    query.queryKey.length === page.length && page.slice(0, -1).every((value, index) => query.queryKey[index] === value)
  )
}

function isPageList(query: Query) {
  return contentKeys.lists.every((value, index) => query.queryKey[index] === value)
}

export function updatePageMetadata(
  client: QueryClient,
  patch: Pick<Page, 'id'> & Partial<Pick<Page, 'title' | 'icon' | 'children_view' | 'updated_at'>>
) {
  const hasIcon = 'icon' in patch && patch.icon !== undefined
  pageMetadata(client).update({
    id: patch.id,
    ...(patch.title !== undefined ? { title: patch.title } : {}),
    ...(hasIcon ? { icon: patch.icon } : {}),
    ...(patch.updated_at !== undefined ? { updated_at: patch.updated_at } : {})
  })
  const childrenView = patch.children_view
  if (childrenView !== undefined) {
    updateCachedQuery<PageDetail>(client, contentKeys.page(patch.id), data => ({
      ...data,
      page: { ...data.page, children_view: childrenView }
    }))
  }
  // Page details, history and insights also carry timestamps and attribution.
  if (patch.title !== undefined || hasIcon) {
    void client.invalidateQueries({ queryKey: contentKeys.page(patch.id), exact: true })
    void client.invalidateQueries({ queryKey: contentKeys.history(patch.id) })
    void client.invalidateQueries({ queryKey: contentKeys.insights(patch.id) })
  }
  if (patch.title !== undefined) {
    void client.invalidateQueries({ queryKey: [...contentKeys.lists, 'search'] })
  }
}

function matchesDirectory(query: Query, location: DirectoryLocation) {
  const suffix = query.queryKey.slice(contentKeys.lists.length)
  return (
    isPageList(query) &&
    suffix[0] === 'children' &&
    suffix[2] === (location.parent_id ?? null) &&
    (!!location.parent_id || suffix[1] === location.scope)
  )
}

export async function refreshDirectories(client: QueryClient, locations: DirectoryLocation[]) {
  await Promise.all([
    client.invalidateQueries({ predicate: query => locations.some(location => matchesDirectory(query, location)) }),
    client.invalidateQueries({
      predicate: query => {
        const suffix = query.queryKey.slice(contentKeys.lists.length)
        return isPageList(query) && suffix[0] !== 'children' && suffix[0] !== 'navigation'
      }
    })
  ])
}

export async function applyTreeChange(
  client: QueryClient,
  change: {
    directories: DirectoryLocation[]
    parents: { id: string; has_children: boolean; child_count?: number }[]
    page_id?: string | null
    removed?: boolean
  }
) {
  const parents = new Map(change.parents.map(parent => [parent.id, parent]))
  updatePageCaches(client, page => {
    const parent = parents.get(page.id)
    return parent ? { ...page, has_children: parent.has_children } : page
  })
  for (const parent of change.parents) {
    if (parent.child_count === undefined) continue
    const childCount = parent.child_count
    updateCachedQuery<PageDetail>(client, contentKeys.page(parent.id), data => ({ ...data, child_count: childCount }))
  }
  await Promise.all([
    refreshDirectories(client, change.directories),
    client.invalidateQueries({
      predicate: query => {
        if (!isPageList(query) || query.queryKey[contentKeys.lists.length] !== 'navigation') return false
        const data = query.state.data as NavigationPath | undefined
        return (
          data?.path.some(
            page =>
              page.id === change.page_id ||
              (change.removed &&
                change.directories.some(location => (page.parent_id ?? null) === (location.parent_id ?? null)))
          ) ?? false
        )
      }
    })
  ])
}

const pageDirectory = (page: Page): DirectoryLocation => ({
  parent_id: page.parent_id,
  scope: page.private_owner_uid ? 'private' : 'space'
})

function adjustCachedChildCount(client: QueryClient, parentID: string | null | undefined, delta: number) {
  if (!parentID) return
  updateCachedQuery<PageDetail>(client, contentKeys.page(parentID), data => ({
    ...data,
    child_count: Math.max(0, data.child_count + delta)
  }))
}

/** Apply committed changes now; mounted queries reconcile in the background. */
export function pageCreated(client: QueryClient, page: Page) {
  pageMetadata(client).update({ id: page.id, title: page.title, icon: page.icon ?? null })
  updatePageCaches(client, item => (item.id === page.parent_id ? { ...item, has_children: true } : item))
  client.setQueriesData<PodPageListResponse>({ queryKey: contentKeys.list('trash') }, data =>
    data ? mapPageList(data, item => (item.id === page.id ? null : item)) : data
  )
  adjustCachedChildCount(client, page.parent_id, 1)
  if (page.actions && page.role) {
    const row: NavigationPage = {
      ...page,
      name: page.name ?? page.title,
      actions: page.actions,
      role: page.role,
      has_children: false
    }
    client.setQueriesData<InfiniteData<PodPageChildrenResponse>>(
      {
        predicate: query => matchesDirectory(query, pageDirectory(page))
      },
      data => {
        if (!data?.pages.length || data.pages.some(batch => batch.pages.some(item => item.id === page.id))) return data
        const tail = data.pages.at(-1)!
        if (tail.next_cursor && positionOrder(tail.pages.at(-1)!, page) < 0) return data
        const pages = [...data.pages]
        pages[pages.length - 1] = {
          ...tail,
          pages: directoryPages(
            [...tail.pages, row],
            [],
            page.private_owner_uid ? 'private' : 'space',
            page.parent_id ?? undefined
          )
        }
        return { ...data, pages }
      }
    )
  }
  void refreshDirectories(client, [pageDirectory(page)])
}

export function pageRemoved(client: QueryClient, page: Page) {
  updatePageCaches(client, item => (item.id === page.id ? null : item))
  adjustCachedChildCount(client, page.parent_id, -1)
  client.removeQueries({ queryKey: contentKeys.page(page.id) })
  void refreshDirectories(client, [pageDirectory(page)])
}

export function pageMoved(client: QueryClient, page: Page, previous: Page) {
  updatePageCaches(client, item =>
    item.id === page.id ? null : item.id === page.parent_id ? { ...item, has_children: true } : item
  )
  const parentChanged = (previous.parent_id ?? null) !== (page.parent_id ?? null)
  if (parentChanged) {
    adjustCachedChildCount(client, previous.parent_id, -1)
    adjustCachedChildCount(client, page.parent_id, 1)
  }
  void Promise.all([
    refreshDirectories(client, [pageDirectory(previous), pageDirectory(page)]),
    client.invalidateQueries({ queryKey: contentKeys.page(page.id) }),
    ...(parentChanged && previous.parent_id
      ? [client.invalidateQueries({ queryKey: contentKeys.page(previous.parent_id) })]
      : []),
    ...(parentChanged && page.parent_id
      ? [client.invalidateQueries({ queryKey: contentKeys.page(page.parent_id) })]
      : [])
  ])
}
