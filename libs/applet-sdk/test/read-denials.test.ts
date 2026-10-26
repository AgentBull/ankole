import { expect, spyOn, test } from 'bun:test'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createReadDenials } from '../src/index'
import type { AppletRuntime } from '../src/types'

test('read denial survives manual cache data and a temporary failure until a real read succeeds', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } })
  const cache = client.getQueryCache()
  const denials = createReadDenials(cache)
  const denied = Object.assign(new Error('Forbidden'), { status: 403 })
  const unavailable = Object.assign(new Error('Unavailable'), { status: 503 })
  const queryKey = ['read-denial']
  try {
    await expect(client.fetchQuery({ queryKey, queryFn: () => Promise.reject(denied) })).rejects.toBe(denied)
    const query = cache.find({ queryKey })!
    expect(denials.get(query)).toBe(denied)
    client.setQueryData(queryKey, { value: 99 })
    expect(denials.get(query)).toBe(denied)
    await expect(client.fetchQuery({ queryKey, queryFn: () => Promise.reject(unavailable) })).rejects.toBe(unavailable)
    expect(denials.get(query)).toBe(denied)
    await client.fetchQuery({ queryKey, queryFn: async () => ({ value: 1 }) })
    expect(denials.get(query)).toBeUndefined()
  } finally {
    denials.dispose()
    client.clear()
  }
})

test('the host reads an existing denial and drops it when the cached query is removed', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } })
  const cache = client.getQueryCache()
  const denied = Object.assign(new Error('Forbidden'), { status: 403 })
  const queryKey = ['existing-denial']
  await expect(client.fetchQuery({ queryKey, queryFn: () => Promise.reject(denied) })).rejects.toBe(denied)
  const query = cache.find({ queryKey })!
  const denials = createReadDenials(cache)
  try {
    expect(denials.get(query)).toBe(denied)
    client.removeQueries({ queryKey })
    expect(denials.get(query)).toBeUndefined()
  } finally {
    denials.dispose()
    client.clear()
  }
})

test('distinct SDK generations use one host cache subscription that the host can dispose', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } })
  const cache = client.getQueryCache()
  const subscribe = spyOn(cache, 'subscribe')
  const denials = createReadDenials(cache)
  const unused = async () => {
    throw new Error('This fixture exercises route reads')
  }
  const runtime: AppletRuntime = {
    pageID: 'generation-fixture',
    instanceID: 'generation-fixture',
    actions: ['page_view'],
    revision: 1,
    queryClient: client,
    readDenial: denials.get,
    routes: { key: () => ['generation-fixture'], call: unused },
    base: {
      key: () => ['generation-fixture', 'table'],
      schema: unused,
      records: unused,
      aggregate: unused,
      write: unused,
      subscribe: () => () => {}
    },
    pod: { request: unused },
    channel() {
      throw new Error('This fixture exercises route reads')
    }
  }
  let previous: typeof import('../src/index') | undefined
  try {
    for (let generation = 0; generation < 4; generation++) {
      const sdk: typeof import('../src/index') = await import(`../src/index.tsx?generation=${generation}`)
      expect(sdk).not.toBe(previous)
      previous = sdk
      function Probe() {
        sdk.useRoute('GET /probe')
        return null
      }
      renderToStaticMarkup(
        createElement(QueryClientProvider, {
          client,
          children: createElement(sdk.AppletRuntimeProvider, { runtime, children: createElement(Probe) })
        })
      )
      expect(subscribe).toHaveBeenCalledTimes(1)
    }
    expect(cache.hasListeners()).toBe(true)
    denials.dispose()
    expect(cache.hasListeners()).toBe(false)
  } finally {
    denials.dispose()
    subscribe.mockRestore()
    client.clear()
  }
})
