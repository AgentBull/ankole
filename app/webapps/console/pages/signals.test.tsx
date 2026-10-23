import { describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { parseRouterSearch, stringifyRouterSearch } from '../../common/router'
import type { AgentItem } from '../api/agents'
import { listSignalBindingsQueryKey } from '../api/v2/generated/@tanstack/react-query.gen'
import { listAgentsQueryKey } from '../api/v2/generated/@tanstack/react-query.gen'
import { finishSignalBindingSave, SignalBindingEditorPage, SignalsListPage } from './signals'

describe('Signal Routing editor navigation', () => {
  test('does not turn the binding owner into a list filter', async () => {
    const listHTML = await renderSignalsList('/signals', undefined)
    const editorHTML = await renderSignalEditor('/signals/new?agent=agent-a&adapter=lark&name=lark-main')

    expect(listHTML).toContain('href="/signals/new?agent=agent-a&amp;adapter=lark&amp;name=lark-main"')
    expect(listHTML).not.toContain('return_agent')
    expect(editorHTML).toContain('href="/signals"')
    expect(editorHTML).not.toContain('href="/signals?agent=agent-a"')
  })

  test('preserves an explicit list filter separately from the binding owner', async () => {
    const listHTML = await renderSignalsList('/signals?agent=agent-b', 'agent-b', 'agent-b')
    const editorHTML = await renderSignalEditor(
      '/signals/new?agent=agent-b&adapter=lark&name=lark-main&return_agent=agent-b'
    )

    expect(listHTML).toContain('return_agent=agent-b')
    expect(editorHTML).toContain('href="/signals?agent=agent-b"')
  })

  test('returns a successful save to its originating list scope', async () => {
    const rootRoute = createRootRoute()
    const catchAllRoute = createRoute({
      getParentRoute: () => rootRoute,
      path: '$',
      component: () => null
    })
    const router = createRouter({
      routeTree: rootRoute.addChildren([catchAllRoute]),
      history: createMemoryHistory({
        initialEntries: ['/signals/new?agent=agent-a&return_agent=agent-b']
      }),
      isServer: false,
      origin: 'http://localhost',
      parseSearch: parseRouterSearch,
      stringifySearch: stringifyRouterSearch
    })
    await router.load()

    await finishSignalBindingSave('Saved', '/signals?agent=agent-b', options => router.navigate(options))

    expect(`${router.state.location.pathname}${router.state.location.searchStr}`).toBe('/signals?agent=agent-b')
  })
})

describe('Signal Routing empty state', () => {
  test('routes the operator to Agent creation while the instance has no Agent', async () => {
    const html = await renderEmptySignalsList([])

    expect(html).toContain('href="/agents/new"')
    expect(html).not.toContain('href="/signals/new"')
  })

  test('offers rule creation in the empty state once an Agent exists', async () => {
    const html = await renderEmptySignalsList([agentItem('agent-a')])

    expect(html).toContain('href="/signals/new"')
    expect(html).not.toContain('href="/agents/new"')
  })
})

function renderEmptySignalsList(agents: AgentItem[]) {
  const queryClient = freshQueryClient()
  queryClient.setQueryData(listAgentsQueryKey(), {
    data: agents.map(({ uid, ...attributes }) => ({ id: uid, type: 'agent', attributes }))
  })
  queryClient.setQueryData(listSignalBindingsQueryKey({ query: { agent: undefined } }), {
    delivery_failures: [],
    signal_bindings: []
  })

  return renderRoute(queryClient, '/signals', 'signals', <SignalsListPage />)
}

function agentItem(uid: string): AgentItem {
  return {
    avatar_url: null,
    created_by: null,
    display_name: uid,
    group_memory_disclosure_mode: 'strict',
    inserted_at: '2026-08-14T00:00:00Z',
    options: {},
    owner_principal_uid: 'operator',
    role: 'assistant',
    status: 'active',
    type: 'ai_colleague',
    uid,
    handle: uid,
    updated_at: '2026-08-14T00:00:00Z'
  }
}

function renderSignalsList(initialEntry: string, agentUID: string | undefined, bindingAgentUID = 'agent-a') {
  const queryClient = freshQueryClient()
  queryClient.setQueryData(
    listSignalBindingsQueryKey({ query: { agent: agentUID } }),
    signalBindingResponse(bindingAgentUID)
  )

  return renderRoute(queryClient, initialEntry, 'signals', <SignalsListPage />)
}

function renderSignalEditor(initialEntry: string) {
  return renderRoute(freshQueryClient(), initialEntry, 'signals/new', <SignalBindingEditorPage />)
}

async function renderRoute(queryClient: QueryClient, initialEntry: string, path: string, element: React.ReactNode) {
  const rootRoute = createRootRoute()
  const route = createRoute({
    getParentRoute: () => rootRoute,
    path,
    component: () => element
  })
  const router = createRouter({
    routeTree: rootRoute.addChildren([route]),
    history: createMemoryHistory({ initialEntries: [initialEntry] }),
    parseSearch: parseRouterSearch,
    stringifySearch: stringifyRouterSearch
  })
  await router.load()
  return renderToStaticMarkup(
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  )
}

function freshQueryClient() {
  return new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
}

function signalBindingResponse(agentUID: string) {
  return {
    delivery_failures: [],
    signal_bindings: [
      {
        adapter: 'lark',
        agent_uid: agentUID,
        config_key: `signal:${agentUID}:lark:lark-main`,
        config_ref: 'app_configuration',
        enabled: true,
        name: 'lark-main',
        unaddressed_group_message_policy: 'record_only' as const,
        unavailable_reason: null
      }
    ]
  }
}
