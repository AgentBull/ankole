import { describe, expect, test } from 'bun:test'
import type { QueryClient } from '@tanstack/react-query'
import { setDataTenantSoft } from '../common/browser-session'
import { agentListOptions } from './api/agents'
import { backgroundAgentJobsOptions } from './api/background-agent-jobs'
import { resourceID } from './console-primitives'
import { createConsoleRouteLoaders } from './console-route-loaders'
import { conversationListOptions } from './pages/conversations'
import { getGlobalLibraryCapabilitiesOptions } from './api/v2/generated/@tanstack/react-query.gen'
import {
  listAiGatewayProvidersOptions,
  listControlPlanePluginsOptions
} from './api/v2-site/generated/@tanstack/react-query.gen'
import { tenantQueryOptions } from './state/tenant-scope'

describe('console route identifiers', () => {
  test('prefetches site library defaults without a tenant Agent catalog', async () => {
    const requests: unknown[] = []
    const queryClient = {
      ensureQueryData: (options: unknown) => {
        requests.push(options)
        return Promise.resolve({})
      }
    } as unknown as QueryClient
    await createConsoleRouteLoaders(queryClient).agentLibrary({ location: { searchStr: '?defaults_scope=global' } })
    expect(requests).toEqual([
      expect.objectContaining({
        queryKey: getGlobalLibraryCapabilitiesOptions({ query: { defaults_scope: 'global' } }).queryKey
      }),
      expect.objectContaining({ queryKey: listControlPlanePluginsOptions().queryKey })
    ])
  })
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

    await createConsoleRouteLoaders(queryClient).backgroundAgentJobs({
      location: { searchStr: '?agent=agent-a&q=quarterly+report' }
    })

    expect(requests).toHaveLength(1)
    expect(requests[0]).toMatchObject({
      queryKey: backgroundAgentJobsOptions({ agent_uid: 'agent-a', search: 'quarterly report', limit: 100 }).queryKey
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

    await createConsoleRouteLoaders(queryClient).conversations({
      location: { searchStr: '?agent=agent-a&q=hello&active=true&min_messages=0&cursor=abc' }
    })

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

  test('binds tenant-scoped loader prefetches to the active tenant cache key while keeping site queries unscoped', async () => {
    const previous = Object.getOwnPropertyDescriptor(globalThis, 'window')
    const backing = new Map<string, string>()
    Object.defineProperty(globalThis, 'window', {
      configurable: true,
      value: {
        sessionStorage: {
          getItem: (key: string) => backing.get(key) ?? null,
          setItem: (key: string, value: string) => backing.set(key, value),
          removeItem: (key: string) => backing.delete(key)
        }
      }
    })
    setDataTenantSoft('tenant-b')

    try {
      const requests: Array<{ queryKey: unknown }> = []
      const queryClient = {
        ensureQueryData: (options: { queryKey: unknown }) => {
          requests.push(options)
          return Promise.resolve({})
        }
      } as unknown as QueryClient

      const loaders = createConsoleRouteLoaders(queryClient)
      await loaders.home({ location: { searchStr: '' } })

      expect(requests.map(item => item.queryKey)).toContainEqual(
        tenantQueryOptions(agentListOptions(), 'tenant-b').queryKey
      )
      expect(requests.map(item => item.queryKey)).toContainEqual(listAiGatewayProvidersOptions().queryKey)
    } finally {
      if (previous) Object.defineProperty(globalThis, 'window', previous)
      else Reflect.deleteProperty(globalThis, 'window')
    }
  })
})
