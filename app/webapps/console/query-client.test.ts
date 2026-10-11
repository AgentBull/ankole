import { describe, expect, test } from 'bun:test'
import { MutationObserver, QueryClient, QueryObserver } from '@tanstack/react-query'
import { createConsoleMutationCache } from './query-client'

function client() {
  return new QueryClient({
    mutationCache: createConsoleMutationCache(),
    defaultOptions: {
      queries: { gcTime: Infinity, retry: false, staleTime: Infinity },
      mutations: { gcTime: Infinity, retry: false }
    }
  })
}

describe('Console mutation cache', () => {
  test('invalidates queries after a successful write', async () => {
    const queryClient = client()
    queryClient.setQueryData(['agents'], ['before'])
    const mutation = new MutationObserver(queryClient, { mutationFn: async () => 'saved' })

    await mutation.mutate()

    expect(queryClient.getQueryState(['agents'])?.isInvalidated).toBe(true)
    queryClient.clear()
  })

  test('keeps query data current for an explicitly skipped mutation', async () => {
    const queryClient = client()
    queryClient.setQueryData(['settings'], ['before'])
    const mutation = new MutationObserver(queryClient, {
      meta: { invalidates: false },
      mutationFn: async () => 'revealed'
    })

    await mutation.mutate()

    expect(queryClient.getQueryState(['settings'])?.isInvalidated).toBe(false)
    queryClient.clear()
  })

  test('leaves failure recovery to the mutation owner', async () => {
    const queryClient = client()
    queryClient.setQueryData(['settings'], ['before'])
    const mutation = new MutationObserver(queryClient, {
      mutationFn: async () => {
        throw new Error('write failed')
      }
    })

    await expect(mutation.mutate()).rejects.toThrow('write failed')

    expect(queryClient.getQueryState(['settings'])?.isInvalidated).toBe(false)
    queryClient.clear()
  })

  test('completes the mutation while an active query refetch remains pending', async () => {
    const queryClient = client()
    queryClient.setQueryData(['agents'], ['before'])
    let refetches = 0
    const query = new QueryObserver(queryClient, {
      queryKey: ['agents'],
      queryFn: () => {
        refetches += 1
        return new Promise<string[]>(() => {})
      }
    })
    const unsubscribe = query.subscribe(() => {})
    const mutation = new MutationObserver(queryClient, { mutationFn: async () => 'saved' })
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      const result = await Promise.race([
        mutation.mutate(),
        new Promise<'timeout'>(resolve => {
          timer = setTimeout(() => resolve('timeout'), 500)
        })
      ])
      expect(result).toBe('saved')
      expect(refetches).toBe(1)
      expect(queryClient.getQueryState(['agents'])?.fetchStatus).toBe('fetching')
      expect(mutation.getCurrentResult().isSuccess).toBe(true)
    } finally {
      clearTimeout(timer)
      unsubscribe()
      queryClient.clear()
    }
  })
})
