import { describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { createMemoryRouter, RouterProvider } from 'react-router'
import {
  ankoleWebAgentControllerIndexQueryKey,
  ankoleWebSignalBindingControllerIndexQueryKey
} from '../api/generated/@tanstack/react-query.gen'
import type { AgentItem } from '../api/generated/types.gen'
import { finishSignalBindingSave, SignalBindingEditorPage, SignalsListPage } from './signals'

describe('Signal Routing editor navigation', () => {
  test('does not turn the binding owner into a list filter', () => {
    const listHTML = renderSignalsList('/signals', undefined)
    const editorHTML = renderSignalEditor('/signals/new?agent=agent-a&adapter=lark&name=lark-main')

    expect(listHTML).toContain('href="/signals/new?agent=agent-a&amp;adapter=lark&amp;name=lark-main"')
    expect(listHTML).not.toContain('return_agent')
    expect(editorHTML).toContain('href="/signals"')
    expect(editorHTML).not.toContain('href="/signals?agent=agent-a"')
  })

  test('preserves an explicit list filter separately from the binding owner', () => {
    const listHTML = renderSignalsList('/signals?agent=agent-b', 'agent-b', 'agent-b')
    const editorHTML = renderSignalEditor('/signals/new?agent=agent-b&adapter=lark&name=lark-main&return_agent=agent-b')

    expect(listHTML).toContain('return_agent=agent-b')
    expect(editorHTML).toContain('href="/signals?agent=agent-b"')
  })

  test('invalidates Signal data and returns a successful save to its originating list scope', () => {
    const queryClient = freshQueryClient()
    const queryKey = ['signal-bindings']
    queryClient.setQueryData(queryKey, { signal_bindings: [] })
    const router = createMemoryRouter([{ path: '*', element: null }], {
      initialEntries: ['/signals/new?agent=agent-a&return_agent=agent-b']
    })

    finishSignalBindingSave('Saved', '/signals?agent=agent-b', queryClient, path => router.navigate(path))

    expect(queryClient.getQueryState(queryKey)?.isInvalidated).toBe(true)
    expect(`${router.state.location.pathname}${router.state.location.search}`).toBe('/signals?agent=agent-b')
  })
})

describe('Signal Routing empty state', () => {
  test('routes the operator to Agent creation while the instance has no Agent', () => {
    const html = renderEmptySignalsList([])

    expect(html).toContain('href="/agents/new"')
    expect(html).not.toContain('href="/signals/new"')
  })

  test('offers rule creation in the empty state once an Agent exists', () => {
    const html = renderEmptySignalsList([agentItem('agent-a')])

    expect(html).toContain('href="/signals/new"')
    expect(html).not.toContain('href="/agents/new"')
  })
})

function renderEmptySignalsList(agents: AgentItem[]) {
  const queryClient = freshQueryClient()
  queryClient.setQueryData(ankoleWebAgentControllerIndexQueryKey(), { agents })
  queryClient.setQueryData(ankoleWebSignalBindingControllerIndexQueryKey({ query: { agent: undefined } }), {
    delivery_failures: [],
    signal_bindings: []
  })

  return renderRoute(queryClient, '/signals', 'signals', <SignalsListPage />)
}

function agentItem(uid: string): AgentItem {
  return {
    avatar_url: null,
    created_by_principal_uid: null,
    display_name: uid,
    group_memory_disclosure_mode: 'strict',
    inserted_at: '2026-08-14T00:00:00Z',
    options: {},
    owner_principal_uid: 'operator',
    role: 'assistant',
    status: 'active',
    type: 'ai_colleague',
    uid,
    updated_at: '2026-08-14T00:00:00Z'
  }
}

function renderSignalsList(initialEntry: string, agentUID: string | undefined, bindingAgentUID = 'agent-a') {
  const queryClient = freshQueryClient()
  queryClient.setQueryData(
    ankoleWebSignalBindingControllerIndexQueryKey({ query: { agent: agentUID } }),
    signalBindingResponse(bindingAgentUID)
  )

  return renderRoute(queryClient, initialEntry, 'signals', <SignalsListPage />)
}

function renderSignalEditor(initialEntry: string) {
  return renderRoute(freshQueryClient(), initialEntry, 'signals/new', <SignalBindingEditorPage />)
}

function renderRoute(queryClient: QueryClient, initialEntry: string, path: string, element: React.ReactNode) {
  // A data router, because the editor frame's dirty-draft guard uses useBlocker.
  const router = createMemoryRouter([{ path, element }], { initialEntries: [initialEntry] })
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
