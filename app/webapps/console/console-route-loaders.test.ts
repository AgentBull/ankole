import { describe, expect, test } from 'bun:test'
import type { QueryClient } from '@tanstack/react-query'
import type { LoaderFunctionArgs } from 'react-router'
import { ankoleWebBackgroundAgentJobControllerIndexOptions } from './api/generated/@tanstack/react-query.gen'
import { resourceID } from './console-primitives'
import { createConsoleRouteLoaders } from './console-route-loaders'
import { conversationListOptions } from './pages/conversations'

describe('console route identifiers', () => {
  test('uses the lower bound from the owning API', () => {
    expect(resourceID('999', 1)).toBe(999)
    expect(resourceID('999', 1000)).toBeUndefined()
    expect(resourceID('1000', 1000)).toBe(1000)
  })

  test('rejects values that are not positive safe decimal integers', () => {
    expect(resourceID('0', 1)).toBeUndefined()
    expect(resourceID('-1', 1)).toBeUndefined()
    expect(resourceID('1e3', 1)).toBeUndefined()
    expect(resourceID('9007199254740992', 1)).toBeUndefined()
  })

  test('prefetches the URL-backed Background Agent Job search', async () => {
    const requests: unknown[] = []
    const queryClient = {
      ensureQueryData: (options: unknown) => {
        requests.push(options)
        return Promise.resolve({})
      }
    } as unknown as QueryClient
    const request = new Request('http://localhost/console/background-agent-jobs?agent=agent-a&q=quarterly+report')

    await createConsoleRouteLoaders(queryClient).backgroundAgentJobs({ request } as LoaderFunctionArgs)

    expect(requests).toHaveLength(1)
    expect(requests[0]).toMatchObject({
      queryKey: ankoleWebBackgroundAgentJobControllerIndexOptions({
        query: { agent: 'agent-a', q: 'quarterly report', limit: 100 }
      }).queryKey
    })
  })

  test('prefetches the conversation search on the page query cache key', async () => {
    const requests: unknown[] = []
    const queryClient = {
      ensureQueryData: (options: unknown) => {
        requests.push(options)
        return Promise.resolve({})
      }
    } as unknown as QueryClient
    const request = new Request(
      'http://localhost/console/conversations?agent=agent-a&q=hello&active=true&min_messages=0&cursor=abc'
    )

    await createConsoleRouteLoaders(queryClient).conversations({ request } as LoaderFunctionArgs)

    expect(requests).toHaveLength(1)
    expect(requests[0]).toMatchObject({
      queryKey: conversationListOptions({
        q: 'hello',
        subject: 'agent-a',
        active: 'true',
        showAll: true,
        cursor: 'abc'
      }).queryKey
    })
  })
})
