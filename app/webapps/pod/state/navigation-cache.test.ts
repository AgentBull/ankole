import { pageMetadata } from './page-metadata'
import { expect, spyOn, test } from 'bun:test'
import { InfiniteQueryObserver, QueryClient, QueryObserver } from '@tanstack/react-query'
import {
  contentKeys,
  cachedPageMap,
  cachedPages,
  pagesByID,
  directoryCapabilitiesQuery,
  pageAPI,
  pageChildrenQuery,
  type NavigationPage
} from '../content-api'
import {
  applyTreeChange,
  directoryPages,
  navigationQuery,
  pageCreated,
  pageMoved,
  pageRemoved,
  updatePageCaches,
  updatePageMetadata
} from './navigation-cache'
import { pageHrefFor } from '../use-page-metadata'

const row = (id: string, parent_id: string | null = null, position = id): NavigationPage => ({
  id,
  name: id,
  parent_id,
  position,
  type: 'doc',
  title: id,
  inherit_permissions: true,
  metadata: {},
  actions: ['node_view'],
  role: 'view',
  has_children: false
})
const directory = (pages: NavigationPage[]) => ({
  pages,
  principal_uid: 'reader',
  can_create_private: false,
  can_create_space: false,
  can_manage_space: false,
  next_cursor: null
})

test('creation capabilities fetch from a cold cache and share the directory request without changing its data', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
  const response = { ...directory([row('root')]), can_create_space: true, can_create_private: true }
  const pending = Promise.withResolvers<typeof response>()
  const original = pageAPI.children
  const requests: Parameters<typeof pageAPI.children>[] = []
  pageAPI.children = (...args) => {
    requests.push(args)
    return pending.promise
  }
  const capabilities = new InfiniteQueryObserver(client, directoryCapabilitiesQuery())
  const anotherControl = new InfiniteQueryObserver(client, directoryCapabilitiesQuery())
  const roots = new InfiniteQueryObserver(client, pageChildrenQuery('space'))
  const subscriptions = [capabilities, anotherControl, roots].map(observer => observer.subscribe(() => {}))
  try {
    expect(capabilities.getCurrentResult().isPending).toBe(true)
    expect(requests).toHaveLength(1)
    expect(requests[0]?.slice(0, 3)).toEqual(['space', undefined, undefined])
    pending.resolve(response)
    await capabilities.getCurrentQuery().promise
    const expected = {
      principal_uid: 'reader',
      can_create_space: true,
      can_create_private: true,
      can_manage_space: false
    }
    expect(capabilities.getCurrentResult().data).toEqual(expected)
    expect(anotherControl.getCurrentResult().data).toEqual(expected)
    const cached = { pages: [response], pageParams: [undefined] }
    expect(roots.getCurrentResult().data).toEqual(cached)
    expect(client.getQueryData(contentKeys.children('space'))).toEqual(cached)
    expect(client.getQueryData(contentKeys.navigation())).toBeUndefined()
  } finally {
    pending.resolve(response)
    subscriptions.forEach(unsubscribe => unsubscribe())
    client.clear()
    pageAPI.children = original
  }
})

test('creation capabilities reuse fresh directory data and refresh on access invalidation without navigation', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
  client.setQueryData(contentKeys.children('space'), {
    pages: [{ ...directory([]), can_create_space: true }],
    pageParams: [undefined]
  })
  const original = pageAPI.children
  let requests = 0
  pageAPI.children = async () => {
    requests++
    return directory([])
  }
  const observer = new InfiniteQueryObserver(client, directoryCapabilitiesQuery())
  const unsubscribe = observer.subscribe(() => {})
  try {
    expect(observer.getCurrentResult().data?.can_create_space).toBe(true)
    expect(requests).toBe(0)
    await client.invalidateQueries({ queryKey: contentKeys.all })
    expect(requests).toBe(1)
    expect(observer.getCurrentResult().data?.can_create_space).toBe(false)
    expect(observer.getCurrentResult().data?.can_create_private).toBe(false)
  } finally {
    unsubscribe()
    client.clear()
    pageAPI.children = original
  }
})

test('creating a Page under a physical Space root refreshes the mounted root alias without guessing its rows', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
  const root = contentKeys.children('space')
  const privateRoot = contentKeys.children('private')
  const untouched = [
    contentKeys.children('space', 'other-parent'),
    ['pod-content', 'another-authentication', 'another-pod', 'pages', 'children', 'space', null]
  ]
  for (const key of [root, privateRoot, ...untouched]) {
    client.setQueryData(key, { pages: [directory([])], pageParams: [undefined] })
  }
  const created = { ...row('created', 'physical-space-root', 'a0'), private_owner_uid: null }
  const response = Promise.withResolvers<ReturnType<typeof directory>>()
  let requests = 0
  const observer = new InfiniteQueryObserver(client, {
    ...pageChildrenQuery('space'),
    queryFn: () => {
      requests++
      return response.promise
    }
  })
  const unsubscribe = observer.subscribe(() => {})
  try {
    expect(requests).toBe(0)
    pageCreated(client, created)
    expect(requests).toBe(1)
    expect(observer.getCurrentResult().data?.pages.flatMap(batch => batch.pages)).toEqual([])
    response.resolve(directory([created]))
    await observer.getCurrentQuery().promise
    expect(observer.getCurrentResult().data?.pages.flatMap(batch => batch.pages)).toEqual([created])
    expect(client.getQueryState(privateRoot)?.isInvalidated).toBe(true)
    for (const key of untouched) expect(client.getQueryState(key)?.isInvalidated).toBe(false)
  } finally {
    response.resolve(directory([created]))
    unsubscribe()
    client.clear()
  }
})

test('Private root creation, trash, and restore reconcile membership without copying a physical-root child into the alias', () => {
  const client = new QueryClient()
  const root = contentKeys.children('private')
  const space = contentKeys.children('space')
  const branch = contentKeys.children('private', 'unrelated-parent')
  const trash = contentKeys.list('trash')
  const kept = { ...row('kept', 'physical-private-root'), private_owner_uid: null }
  const created = { ...row('created', 'physical-private-root'), private_owner_uid: null }
  for (const key of [root, space, branch]) {
    client.setQueryData(key, { pages: [directory(key === root ? [kept] : [])], pageParams: [undefined] })
  }
  try {
    pageCreated(client, created)
    expect(client.getQueryData<{ pages: { pages: NavigationPage[] }[] }>(root)?.pages[0].pages).toEqual([kept])
    for (const key of [root, space]) expect(client.getQueryState(key)?.isInvalidated).toBe(true)

    client.setQueryData(root, { pages: [directory([kept, created])], pageParams: [undefined] })
    client.setQueryData(space, { pages: [directory([])], pageParams: [undefined] })
    pageRemoved(client, created)
    expect(client.getQueryData<{ pages: { pages: NavigationPage[] }[] }>(root)?.pages[0].pages).toEqual([kept])
    for (const key of [root, space]) expect(client.getQueryState(key)?.isInvalidated).toBe(true)

    client.setQueryData(root, { pages: [directory([kept])], pageParams: [undefined] })
    client.setQueryData(space, { pages: [directory([])], pageParams: [undefined] })
    client.setQueryData(trash, { pages: [created] })
    pageCreated(client, created)
    expect(client.getQueryData(trash)).toEqual({ pages: [] })
    expect(client.getQueryData<{ pages: { pages: NavigationPage[] }[] }>(root)?.pages[0].pages).toEqual([kept])
    for (const key of [root, space]) expect(client.getQueryState(key)?.isInvalidated).toBe(true)
    expect(client.getQueryState(branch)?.isInvalidated).toBe(false)
  } finally {
    client.clear()
  }
})

test('a nested creation with unknown scope inserts only into its exact parent while both roots reread membership', () => {
  const client = new QueryClient()
  const root = contentKeys.children('space')
  const privateRoot = contentKeys.children('private')
  const parent = contentKeys.children('space', 'parent')
  const subpages = contentKeys.subpages('space', 'parent')
  const unrelated = contentKeys.children('space', 'other-parent')
  for (const key of [root, privateRoot, parent, subpages, unrelated]) {
    client.setQueryData(key, { pages: [directory([])], pageParams: [undefined] })
  }
  try {
    const created = { ...row('created', 'parent'), private_owner_uid: null }
    pageCreated(client, created)
    for (const key of [parent, subpages]) {
      expect(client.getQueryData<{ pages: { pages: NavigationPage[] }[] }>(key)?.pages[0].pages).toEqual([created])
      expect(client.getQueryState(key)?.isInvalidated).toBe(true)
    }
    expect(client.getQueryData<{ pages: { pages: NavigationPage[] }[] }>(root)?.pages[0].pages).toEqual([])
    for (const key of [root, privateRoot]) expect(client.getQueryState(key)?.isInvalidated).toBe(true)
    expect(client.getQueryState(unrelated)?.isInvalidated).toBe(false)
  } finally {
    client.clear()
  }
})

test('moving from a nested Space directory to Private and back refreshes the two roots and exact nested parent', () => {
  const client = new QueryClient()
  const space = contentKeys.children('space')
  const privateRoot = contentKeys.children('private')
  const source = contentKeys.children('space', 'source-parent')
  const unrelated = contentKeys.children('space', 'other-parent')
  const foreign = ['pod-content', 'another-authentication', 'another-pod', 'pages', 'children', 'space', null]
  const previous = { ...row('moving', 'source-parent'), private_owner_uid: null }
  const moved = { ...previous, parent_id: 'physical-private-root', private_owner_uid: null }
  for (const key of [space, privateRoot, source, unrelated, foreign]) {
    client.setQueryData(key, { pages: [directory(key === source ? [previous] : [])], pageParams: [undefined] })
  }
  try {
    pageMoved(client, moved, previous)
    for (const key of [space, privateRoot, source]) expect(client.getQueryState(key)?.isInvalidated).toBe(true)
    for (const key of [source, privateRoot]) {
      expect(client.getQueryData<{ pages: { pages: NavigationPage[] }[] }>(key)?.pages[0].pages).toEqual([])
    }

    for (const key of [space, privateRoot, source]) {
      client.setQueryData(key, { pages: [directory(key === privateRoot ? [moved] : [])], pageParams: [undefined] })
    }
    pageMoved(client, previous, moved)
    for (const key of [space, privateRoot, source]) expect(client.getQueryState(key)?.isInvalidated).toBe(true)
    expect(client.getQueryData<{ pages: { pages: NavigationPage[] }[] }>(privateRoot)?.pages[0].pages).toEqual([])
    for (const key of [unrelated, foreign]) expect(client.getQueryState(key)?.isInvalidated).toBe(false)
  } finally {
    client.clear()
  }
})

test('an active path beyond the first page stays ordered and is not duplicated when pagination reaches it', () => {
  const active = row('active', 'parent', 'Z')
  const first = row('first', 'parent', 'A')
  expect(directoryPages([first], [active], 'space', 'parent').map(page => page.id)).toEqual(['first', 'active'])
  expect(directoryPages([first, active], [active], 'space', 'parent')).toHaveLength(2)
  expect(directoryPages([first], [row('foreign', 'elsewhere')], 'space', 'parent')).toEqual([first])
})

test('an unscoped directory event reconciles both roots and leaves unrelated nested branches and identities fresh', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity } } })
  const root = row('parent')
  const rootsKey = contentKeys.children('space')
  const privateKey = contentKeys.children('private')
  const changedKey = contentKeys.children('space', 'parent')
  const otherKey = contentKeys.children('space', 'other')
  const foreignKey = ['pod-content', 'another-authentication', 'another-pod', 'pages', 'children', 'space', 'parent']
  for (const key of [rootsKey, privateKey, changedKey, otherKey, foreignKey]) {
    client.setQueryData(key, { pages: [directory(key === rootsKey ? [root] : [])], pageParams: [undefined] })
  }
  await applyTreeChange(client, {
    directories: [{ parent_id: 'parent' }],
    parents: [{ id: 'parent', has_children: true }],
    page_id: 'new-child'
  })
  for (const key of [rootsKey, privateKey, changedKey]) expect(client.getQueryState(key)?.isInvalidated).toBe(true)
  for (const key of [otherKey, foreignKey]) expect(client.getQueryState(key)?.isInvalidated).toBe(false)
  expect(client.getQueryData<{ pages: { pages: NavigationPage[] }[] }>(rootsKey)?.pages[0].pages[0].has_children).toBe(
    true
  )
  client.clear()
})

test('an explicit Private directory event leaves the Space root and unrelated branches fresh', async () => {
  const client = new QueryClient()
  const privateRoot = contentKeys.children('private')
  const parent = contentKeys.children('private', 'parent')
  const untouched = [contentKeys.children('space'), contentKeys.children('private', 'other-parent')]
  for (const key of [privateRoot, parent, ...untouched]) {
    client.setQueryData(key, { pages: [directory([])], pageParams: [undefined] })
  }
  try {
    await applyTreeChange(client, { directories: [{ parent_id: 'parent', scope: 'private' }], parents: [] })
    for (const key of [privateRoot, parent]) expect(client.getQueryState(key)?.isInvalidated).toBe(true)
    for (const key of untouched) expect(client.getQueryState(key)?.isInvalidated).toBe(false)
  } finally {
    client.clear()
  }
})

test('dragging can resolve an active path node beyond the loaded directory page', () => {
  const client = new QueryClient()
  const active = row('active', 'parent', 'Z')
  client.setQueryData(contentKeys.navigation(), {
    path: [row('parent'), active]
  })
  expect(cachedPages(client).find(page => page.id === active.id)).toEqual(active)
  client.clear()
})

test('metadata updates preserve directory caches and refresh details, history, insights, and search membership', () => {
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity } } })
  const page = row('page')
  const list = contentKeys.list('favorites')
  const tree = contentKeys.children('space')
  const bootstrap = contentKeys.navigation()
  const detail = contentKeys.page('page')
  const comments = contentKeys.comments('page')
  const history = contentKeys.history('page')
  const insights = contentKeys.insights('page')
  const tables = [...contentKeys.page('page'), 'tables']
  const search = contentKeys.search('child')
  client.setQueryData(list, directory([page]))
  client.setQueryData(tree, { pages: [directory([page])], pageParams: [undefined] })
  client.setQueryData(bootstrap, { path: [page] })
  client.setQueryData(detail, { page, ancestors: [], actions: page.actions, role: page.role })
  client.setQueryData(comments, { comments: [] })
  client.setQueryData(history, { versions: [] })
  client.setQueryData(insights, { views: 1 })
  client.setQueryData(tables, { tables: [] })
  client.setQueryData(search, { pages: [row('child', 'page')], ancestors: [page] })
  updatePageMetadata(client, { id: 'page', title: 'Renamed' })
  for (const key of [list, tree, bootstrap]) {
    expect(JSON.stringify(client.getQueryData(key))).not.toContain('Renamed')
    expect(client.getQueryState(key)?.isInvalidated).toBe(false)
  }
  expect(pageMetadata(client).collection.get('page')?.title).toBe('Renamed')
  expect(client.getQueryData<{ page: NavigationPage }>(detail)?.page.title).toBe(page.title)
  expect(client.getQueryState(detail)?.isInvalidated).toBe(true)
  for (const key of [search, history, insights]) expect(client.getQueryState(key)?.isInvalidated).toBe(true)
  expect(JSON.stringify(client.getQueryData(search))).not.toContain('Renamed')
  for (const key of [comments, tables]) expect(client.getQueryState(key)?.isInvalidated).toBe(false)
  expect(client.getQueryData(comments)).toEqual({ comments: [] })
  client.clear()
})

test('restoring a Page removes it from every cached Trash filter while preserving other rows', async () => {
  const client = new QueryClient()
  const restored = row('restored')
  const remaining = row('remaining')
  const keys = [contentKeys.list('trash'), contentKeys.list('trash', 'restored')]
  for (const key of keys) client.setQueryData(key, { pages: [restored, remaining] })
  // A real-time invalidation may arrive before the mutation response.
  await client.invalidateQueries({ queryKey: contentKeys.list('trash') })
  pageCreated(client, restored)
  for (const key of keys) {
    expect(client.getQueryData(key)).toEqual({ pages: [remaining] })
    expect(client.getQueryState(key)?.isInvalidated).toBe(true)
  }
  expect(client.getQueryData(contentKeys.list('trash', 'unvisited'))).toBeUndefined()
  client.clear()
})

test('a metadata patch preserves an invalidated closed branch until reopening fetches its current visibility', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
  const key = contentKeys.children('space', 'parent')
  client.setQueryData(key, { pages: [directory([row('revoked', 'parent')])], pageParams: [undefined] })
  let requests = 0
  const options = {
    ...pageChildrenQuery('space', 'parent'),
    queryFn: async () => {
      requests++
      return directory([])
    }
  }
  const observer = new InfiniteQueryObserver(client, { ...options, enabled: false })
  const unsubscribe = observer.subscribe(() => {})
  try {
    await client.invalidateQueries({ queryKey: contentKeys.all })
    updatePageMetadata(client, { id: 'unrelated', title: 'Renamed' })
    expect(client.getQueryState(key)?.isInvalidated).toBe(true)
    observer.setOptions({ ...options, enabled: true })
    await observer.getCurrentQuery().promise
    expect(requests).toBe(1)
    expect(observer.getCurrentResult().data?.pages.flatMap(batch => batch.pages)).toEqual([])
  } finally {
    unsubscribe()
    client.clear()
  }
})

test('metadata patches preserve directory freshness and leave unrelated query state untouched', () => {
  const client = new QueryClient()
  const changed = contentKeys.children('space', 'parent')
  const unrelated = contentKeys.children('space', 'other')
  for (const key of [changed, unrelated]) {
    client.setQueryData(
      key,
      { pages: [directory([row(key === changed ? 'child' : 'other')])], pageParams: [undefined] },
      { updatedAt: 1 }
    )
  }
  const before = client.getQueryState(unrelated)
  updatePageMetadata(client, { id: 'child', title: 'Renamed' })
  expect(client.getQueryState(changed)?.dataUpdatedAt).toBe(1)
  expect(client.getQueryState(unrelated)).toBe(before)
  client.clear()
})

test('navigation revalidation preserves loaded pages and stores only the active path', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
  const key = contentKeys.children('space', 'parent')
  const path = [row('parent'), row('active', 'parent', 'Z')]
  const first = { ...directory([row('first', 'parent', 'A')]), next_cursor: 'second' }
  const second = directory([row('second', 'parent', 'B')])
  const loaded = { pages: [first, second], pageParams: [undefined, 'second'] }
  client.setQueryData(key, loaded)
  const original = pageAPI.navigation
  pageAPI.navigation = async () => ({
    directories: [
      { ...first, scope: 'space', parent_id: 'parent' },
      { ...directory([]), scope: 'private', parent_id: null }
    ],
    path
  })
  try {
    await client.fetchQuery(navigationQuery(client, 'active'))
    expect(client.getQueryData(key)).toEqual(loaded)
    expect(client.getQueryData(contentKeys.navigation())).toEqual({ path })
    expect(client.getQueryData(contentKeys.children('private'))).toEqual({
      pages: [{ ...directory([]), scope: 'private', parent_id: null }],
      pageParams: [undefined]
    })
  } finally {
    pageAPI.navigation = original
    client.clear()
  }
})

test('subpages directory queries and parent child_count stay synchronized across tree mutations and children_view patches', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity } } })
  const parent = row('parent')
  const parentDetail = contentKeys.page('parent')
  const subpagesKey = contentKeys.subpages('space', 'parent')

  client.setQueryData(parentDetail, {
    page: { ...parent, children_view: {} },
    ancestors: [],
    actions: ['node_view', 'node_edit'],
    role: 'edit',
    child_count: 0
  })
  client.setQueryData(subpagesKey, { pages: [directory([])], pageParams: [undefined] })

  updatePageMetadata(client, { id: 'parent', children_view: { collapsed: true, view: 'grid' } })
  expect(
    client.getQueryData<{ page: { children_view?: Record<string, unknown> } }>(parentDetail)?.page.children_view
  ).toEqual({ collapsed: true, view: 'grid' })
  // Pure presentation patches do not force an extra GET /pages/:id roundtrip.
  expect(client.getQueryState(parentDetail)?.isInvalidated).toBe(false)

  const child = row('child-1', 'parent', 'a0')
  pageCreated(client, child)
  expect(client.getQueryData<{ child_count: number }>(parentDetail)?.child_count).toBe(1)
  expect(client.getQueryState(subpagesKey)?.isInvalidated).toBe(true)

  await applyTreeChange(client, {
    directories: [{ parent_id: 'parent' }],
    parents: [{ id: 'parent', has_children: true, child_count: 3 }]
  })
  expect(client.getQueryData<{ child_count: number }>(parentDetail)?.child_count).toBe(3)

  pageRemoved(client, child)
  expect(client.getQueryData<{ child_count: number }>(parentDetail)?.child_count).toBe(2)
  client.clear()
})

test('renaming a Page updates shared metadata without rewriting descendant read snapshots', () => {
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity } } })
  const childDetail = contentKeys.page('child')
  client.setQueryData(childDetail, {
    page: row('child', 'parent', 'a0'),
    ancestors: [row('root'), row('parent', 'root', 'a0')],
    actions: ['node_view'],
    role: 'view',
    child_count: 0
  })
  updatePageMetadata(client, { id: 'parent', title: 'Renamed parent' })
  expect(pageMetadata(client).collection.get('parent')?.title).toBe('Renamed parent')
  const ancestors = client.getQueryData<{ ancestors: { id: string; title: string }[] }>(childDetail)?.ancestors
  expect(ancestors?.map(page => [page.id, page.title])).toEqual([
    ['root', row('root').title],
    ['parent', 'parent']
  ])
})

test('known pages stay indexed until the content cache changes', () => {
  const client = new QueryClient()
  const id = '019a0000-0000-7000-8000-000000000001'
  const page = row(id)
  client.setQueryData(contentKeys.navigation(), { path: [page] })
  const first = cachedPages(client)
  expect(cachedPages(client)).toBe(first)
  expect(cachedPageMap(client).get(id)).toEqual(page)
  const renamed = { ...page, title: 'Renamed' }
  client.setQueryData(contentKeys.navigation(), { path: [renamed] })
  expect(cachedPages(client)).not.toBe(first)
  expect(cachedPageMap(client).get(id)?.title).toBe('Renamed')
  const indexed = cachedPageMap(client)
  const stored = indexed.get(id)
  expect(stored).toBeDefined()
  expect(pagesByID(client, [stored!])).toBe(indexed)
  expect(pageHrefFor(client, id, 'Renamed')).toContain('/pages/')
  client.clear()
  expect(cachedPages(client)).toEqual([])
})

test('subscribing a closed directory does not rebuild the page index', () => {
  const client = new QueryClient()
  const id = '019a0000-0000-7000-8000-000000000002'
  client.setQueryData(contentKeys.navigation(), { path: [row(id)] })
  const indexed = cachedPages(client)
  const observer = new QueryObserver(client, {
    queryKey: contentKeys.children('space', id),
    queryFn: () => ({ pages: [], pageParams: [] }),
    enabled: false
  })
  const stop = observer.subscribe(() => {})
  expect(cachedPages(client)).toBe(indexed)
  stop()
  client.clear()
})

test('page index rebuilds only when read after a burst of cache updates', () => {
  const client = new QueryClient()
  for (let index = 0; index < 200; index++) {
    client.setQueryData(contentKeys.search(`query ${index}`), {
      pages: [row('shared'), ...Array.from({ length: 9 }, (_, offset) => row(`${index}:${offset}`))],
      ancestors: []
    })
  }
  const scans = spyOn(client, 'getQueriesData')
  const subscriptions = spyOn(client.getQueryCache(), 'subscribe')
  try {
    expect(cachedPages(client)).toHaveLength(1801)
    expect(scans).toHaveBeenCalledTimes(1)
    for (const title of ['Renamed', 'Renamed again']) {
      const previousScans = scans.mock.calls.length
      updatePageCaches(client, page => (page.id === 'shared' ? { ...page, title } : page))
      expect(scans).toHaveBeenCalledTimes(previousScans)
      expect(cachedPageMap(client).get('shared')?.title).toBe(title)
      const pages = cachedPages(client)
      expect(cachedPages(client)).toBe(pages)
      expect(scans).toHaveBeenCalledTimes(previousScans + 1)
      expect(subscriptions).toHaveBeenCalledTimes(1)
    }
    client.clear()
    expect(scans).toHaveBeenCalledTimes(3)
    expect(cachedPages(client)).toEqual([])
    expect(scans).toHaveBeenCalledTimes(4)
    expect(subscriptions).toHaveBeenCalledTimes(1)
  } finally {
    scans.mockRestore()
    subscriptions.mockRestore()
    client.clear()
  }
})

test('page index follows initial query data, direct state updates and resets', async () => {
  const client = new QueryClient()
  try {
    expect(cachedPages(client)).toEqual([])
    const observer = new QueryObserver(client, {
      queryKey: contentKeys.navigation(),
      enabled: false,
      initialData: { path: [row('seeded')] }
    })
    expect(cachedPageMap(client).get('seeded')?.title).toBe('seeded')
    observer.getCurrentQuery().setState({ data: { path: [{ ...row('seeded'), title: 'Renamed' }] } })
    expect(cachedPageMap(client).get('seeded')?.title).toBe('Renamed')
    await client.resetQueries({ queryKey: contentKeys.navigation() })
    expect(cachedPageMap(client).get('seeded')?.title).toBe('seeded')
  } finally {
    client.clear()
  }
})
