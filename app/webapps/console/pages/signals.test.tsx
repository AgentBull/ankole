import { describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { createMemoryRouter, MemoryRouter, Route, Routes } from 'react-router'
import { ankoleWebSignalBindingControllerIndexQueryKey } from '../api/generated/@tanstack/react-query.gen'
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
        confidential_memory: false,
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
