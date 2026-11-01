import { expect, test } from 'bun:test'
import { createCollection, eq, liveQueryCollectionOptions } from '@tanstack/db'
import { InfiniteQueryObserver, QueryClient } from '@tanstack/react-query'
import { pageAPI, pageChildrenQuery, contentKeys, type NavigationPage } from '../content-api'
import { updatePageMetadata } from './navigation-cache'
import { createPageMetadata, pageMetadata } from './page-metadata'

const row = (id: string): NavigationPage => ({
  id,
  name: id,
  title: id,
  icon: '📄',
  type: 'doc',
  position: id,
  inherit_permissions: true,
  has_children: false,
  actions: ['node_view'],
  role: 'view'
})
const directory = (pages: NavigationPage[], next_cursor: string | null = null) => ({
  pages,
  next_cursor,
  principal_uid: 'reader',
  can_create_private: false,
  can_create_space: false,
  can_manage_space: false
})

test('a rename reaches each live view without rewriting list snapshots or notifying another Page', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity } } })
  const metadata = pageMetadata(client)
  const original = directory([row('parent'), row('other')])
  await metadata.read(
    async () => original,
    result => result.pages
  )
  const key = contentKeys.list('favorites')
  client.setQueryData(key, original)
  const snapshot = client.getQueryState(key)
  const view = (id: string) =>
    createCollection(
      liveQueryCollectionOptions({
        query: q => q.from({ page: metadata.collection }).where(({ page }) => eq(page.id, id)),
        startSync: true
      })
    )
  const sidebar = view('parent')
  const breadcrumb = view('parent')
  const unrelated = view('other')
  await Promise.all([sidebar.preload(), breadcrumb.preload(), unrelated.preload()])
  let unrelatedUpdates = 0
  const subscription = unrelated.subscribeChanges(() => unrelatedUpdates++)
  try {
    updatePageMetadata(client, { id: 'parent', title: 'Renamed', icon: null })
    await Promise.resolve()
    for (const view of [sidebar, breadcrumb]) {
      expect([...view.values()].map(({ id, title, icon }) => ({ id, title, icon }))).toEqual([
        { id: 'parent', title: 'Renamed', icon: null }
      ])
    }
    expect(unrelatedUpdates).toBe(0)
    expect(client.getQueryState(key)).toBe(snapshot)
  } finally {
    subscription.unsubscribe()
    await Promise.all([sidebar.cleanup(), breadcrumb.cleanup(), unrelated.cleanup()])
    metadata.dispose()
    client.clear()
  }
})

test('an in-flight read cannot undo a confirmed metadata edit; the next read can refresh it', async () => {
  const metadata = createPageMetadata()
  const pending = Promise.withResolvers<{ pages: NavigationPage[] }>()
  const request = metadata.read(
    () => pending.promise,
    result => result.pages
  )
  metadata.update({ id: 'page', title: 'New title', icon: null })
  pending.resolve({ pages: [row('page'), row('other')] })
  await request
  expect(metadata.collection.get('page')).toMatchObject({ id: 'page', title: 'New title', icon: null })
  expect(metadata.collection.get('other')?.title).toBe('other')
  await metadata.read(
    async () => ({ pages: [{ ...row('page'), title: 'Remote edit' }] }),
    result => result.pages
  )
  expect(metadata.collection.get('page')?.title).toBe('Remote edit')
  metadata.dispose()
})

test('loading a second directory cursor does not replay stale metadata from the first cursor', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity, retry: false } } })
  const original = pageAPI.children
  pageAPI.children = async (_scope, _parent, cursor) =>
    cursor ? directory([row('second')]) : directory([row('first')], 'next')
  const observer = new InfiniteQueryObserver(client, pageChildrenQuery('space'))
  const unsubscribe = observer.subscribe(() => {})
  try {
    await observer.getCurrentQuery().promise
    updatePageMetadata(client, { id: 'first', title: 'Renamed first' })
    await observer.fetchNextPage()
    const metadata = pageMetadata(client)
    expect(observer.getCurrentResult().data?.pages).toHaveLength(2)
    expect(metadata.collection.get('first')?.title).toBe('Renamed first')
    expect(metadata.collection.get('second')?.title).toBe('second')
  } finally {
    unsubscribe()
    pageAPI.children = original
    pageMetadata(client).dispose()
    client.clear()
  }
})

test('query clients have separate metadata and a disposed session ignores its late response', async () => {
  const first = new QueryClient()
  const second = new QueryClient()
  const metadata = pageMetadata(first)
  metadata.update({ id: 'page', title: 'Private title' })
  expect(pageMetadata(second).collection.get('page')).toBeUndefined()
  const pending = Promise.withResolvers<NavigationPage[]>()
  const request = metadata.read(
    () => pending.promise,
    pages => pages
  )
  metadata.dispose()
  pending.resolve([row('late')])
  await request
  expect(metadata.collection.get('late')).toBeUndefined()
  pageMetadata(second).dispose()
  first.clear()
  second.clear()
})

test('older updated_at snapshots do not overwrite newer metadata and partial updates preserve existing icons', async () => {
  const metadata = createPageMetadata()
  try {
    await metadata.read(
      async () => [
        {
          ...row('page'),
          title: 'Newest title',
          icon: '🚀',
          updated_at: '2026-10-30T12:00:05.000000Z'
        }
      ],
      pages => pages
    )
    await metadata.read(
      async () => [
        {
          ...row('page'),
          title: 'Stale title',
          icon: '📄',
          updated_at: '2026-10-30T12:00:01.000000Z'
        }
      ],
      pages => pages
    )
    expect(metadata.collection.get('page')).toMatchObject({
      id: 'page',
      title: 'Newest title',
      icon: '🚀',
      updated_at: '2026-10-30T12:00:05.000000Z'
    })

    metadata.update({ id: 'page', title: 'Renamed without icon field' })
    expect(metadata.collection.get('page')).toMatchObject({
      id: 'page',
      title: 'Renamed without icon field',
      icon: '🚀'
    })
  } finally {
    metadata.dispose()
  }
})
