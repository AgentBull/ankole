import { expect, test } from 'bun:test'
import { InfiniteQueryObserver, QueryClient } from '@tanstack/react-query'
import { listBrainObjectsInfiniteOptions } from './v2/generated/@tanstack/react-query.gen'
import { createClient } from './v2/generated/client'
import { fromDocument, nextPageParams } from './json-api'

test('following the API continuation preserves search and the previously loaded objects', async () => {
  const requests: URL[] = []
  const api = createClient({
    baseUrl: 'https://ankole.example',
    fetch: (async request => {
      const url = new URL(request instanceof Request ? request.url : String(request))
      requests.push(url)
      const after = url.searchParams.get('page[after]')
      return Response.json({
        data: [{ type: 'brain_object', id: after ? 'older' : 'newer', attributes: { title: 'Match' } }],
        links: { next: after ? null : 'https://ankole.example/api/v2/brain/objects?page[after]=opaque-token' }
      })
    }) as typeof fetch
  })
  const cache = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } })
  const query = new InfiniteQueryObserver(cache, {
    ...listBrainObjectsInfiniteOptions({ client: api, query: { search: 'Match', prefix: 'notes/' } }),
    initialPageParam: {},
    getNextPageParam: nextPageParams,
    select: data => data.pages.flatMap(document => fromDocument(document))
  })
  try {
    await query.fetchNextPage()
    expect(query.getCurrentResult().hasNextPage).toBe(true)
    await query.fetchNextPage()
    expect(query.getCurrentResult().data?.map(object => object.id)).toEqual(['newer', 'older'])
    expect(query.getCurrentResult().hasNextPage).toBe(false)
    expect(requests).toHaveLength(2)
    expect(requests[1]?.searchParams.get('page[after]')).toBe('opaque-token')
    for (const request of requests) {
      expect(request.searchParams.get('search')).toBe('Match')
      expect(request.searchParams.get('prefix')).toBe('notes/')
    }
  } finally {
    cache.clear()
  }
})
