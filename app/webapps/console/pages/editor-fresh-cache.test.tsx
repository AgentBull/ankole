import { beforeAll, describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider, QueryObserver } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../../common/i18n'
import { MemoryRouter, Route, Routes } from 'react-router'
import {
  ankoleWebAgentControllerIndexQueryKey,
  ankoleWebAgentControllerShowQueryKey,
  ankoleWebIdentityProviderControllerIndexQueryKey
} from '../api/generated/@tanstack/react-query.gen'
import { agentEditorDetailOptions, AgentEditorPage } from './agents'
import { IdentityProviderEditorPage } from './identity'
import { permissionGrantDetailOptions } from './permission-grant-editor'

// Catalogs load on demand; these assertions render translated en-US copy.
beforeAll(() => loadLocale('en-US'))

describe('resource editor lookup with fresh caches', () => {
  test('does not declare a newly created Agent missing before its show request answers', () => {
    const queryClient = freshQueryClient()
    queryClient.setQueryData(ankoleWebAgentControllerIndexQueryKey(), { agents: [] })

    const html = renderEditor(queryClient, '/agents/newly-created', 'agents/:uid', <AgentEditorPage />)

    expect(html).not.toContain('Page not found')
    expect(html).not.toContain('Agent newly-created was not found.')
  })

  test('treats a disabled Agent as deleted instead of reopening its editor', () => {
    const queryClient = freshQueryClient()
    queryClient.setQueryData(ankoleWebAgentControllerShowQueryKey({ path: { agent_uid: 'disabled-agent' } }), {
      agent: {
        avatar_url: null,
        created_by_principal_uid: null,
        display_name: 'Disabled Agent',
        inserted_at: '2026-08-14T00:00:00Z',
        options: {},
        role: 'assistant',
        status: 'disabled',
        type: 'ai_colleague',
        uid: 'disabled-agent',
        updated_at: '2026-08-14T00:00:00Z'
      }
    })

    const html = renderEditor(queryClient, '/agents/disabled-agent', 'agents/:uid', <AgentEditorPage />)

    expect(html).toContain('Page not found')
    expect(html).toContain('disabled-agent')
    expect(html).toContain('was not found.')
    expect(html).not.toContain('<form')
  })

  test('refreshes a fresh Agent detail cache when the editor mounts', async () => {
    const queryClient = freshQueryClient()
    const options = agentEditorDetailOptions('cached-agent')
    queryClient.setQueryData(options.queryKey, agentResponse('cached-agent', 'active'))
    let fetches = 0
    const observer = new QueryObserver(queryClient, {
      ...options,
      queryFn: async () => {
        fetches += 1
        return agentResponse('cached-agent', 'disabled')
      }
    })

    const unsubscribe = observer.subscribe(() => undefined)
    await Promise.resolve()
    await Promise.resolve()

    expect(fetches).toBe(1)
    expect(observer.getCurrentResult().data?.agent.status).toBe('disabled')
    unsubscribe()
  })

  test('does not declare a newly created identity provider missing while its list refreshes', () => {
    const queryClient = freshQueryClient()
    queryClient.setQueryData(ankoleWebIdentityProviderControllerIndexQueryKey(), { identity_providers: [] })

    const html = renderEditor(
      queryClient,
      '/identity/newly-created',
      'identity/:providerID',
      <IdentityProviderEditorPage />
    )

    expect(html).not.toContain('Page not found')
  })

  test('refreshes a fresh permission grant cache when the editor mounts', async () => {
    const queryClient = freshQueryClient()
    const options = permissionGrantDetailOptions('cached-grant')
    queryClient.setQueryData(options.queryKey, {
      permission_grant: {
        action: 'read',
        condition: 'true',
        description: null,
        group_id: null,
        id: 'cached-grant',
        inserted_at: '2026-08-14T00:00:00Z',
        principal_uid: 'operator',
        resource_pattern: 'workspace:**',
        updated_at: '2026-08-14T00:00:00Z'
      }
    })
    let fetches = 0
    const notFound = { error: { code: 'not_found', message: 'permission grant was not found' } }
    const observer = new QueryObserver(queryClient, {
      ...options,
      queryFn: async () => {
        fetches += 1
        throw notFound
      }
    })

    const unsubscribe = observer.subscribe(() => undefined)
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(fetches).toBe(1)
    expect(observer.getCurrentResult().error).toEqual(notFound)
    unsubscribe()
  })
})

function freshQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: { retry: false, staleTime: 60_000 }
    }
  })
}

function agentResponse(uid: string, status: 'active' | 'disabled') {
  return {
    agent: {
      avatar_url: null,
      created_by_principal_uid: null,
      display_name: 'Cached Agent',
      inserted_at: '2026-08-14T00:00:00Z',
      options: {},
      role: 'assistant',
      status,
      type: 'ai_colleague' as const,
      uid,
      updated_at: '2026-08-14T00:00:00Z'
    }
  }
}

function renderEditor(queryClient: QueryClient, initialEntry: string, path: string, element: React.ReactNode) {
  return renderToStaticMarkup(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={[initialEntry]}>
        <Routes>
          <Route path={path} element={element} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}
