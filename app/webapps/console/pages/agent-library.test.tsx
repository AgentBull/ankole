import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../../common/i18n'
import { parseRouterSearch, stringifyRouterSearch } from '../../common/router'
import { listControlPlanePluginsQueryKey } from '../api/v2-site/generated/@tanstack/react-query.gen'
import { getGlobalLibraryCapabilitiesQueryKey } from '../api/v2/generated/@tanstack/react-query.gen'
import { GLOBAL_LIBRARY_SCOPE } from '../state/agent-library-capabilities'
import { AgentLibraryPage } from './agent-library'

beforeAll(() => loadLocale('en-US'))

test.each(
  [GLOBAL_LIBRARY_SCOPE, 'agent-a'].flatMap(scope => [
    { scope, source: 'site plugins', key: listControlPlanePluginsQueryKey(), data: { control_plane_plugins: [] } },
    {
      scope,
      source: 'tenant defaults',
      key: getGlobalLibraryCapabilitiesQueryKey(),
      data: { agent_plugins: [], skills: [] }
    }
  ])
)('a cached $source error is visible only in its library scope ($scope)', async ({ scope, key, data }) => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
  client
    .getQueryCache()
    .build(client, { queryKey: key, initialData: data })
    .setState({ status: 'error', error: new Error('library unavailable') })
  const root = createRootRoute()
  const route = createRoute({ getParentRoute: () => root, path: '/agent-library', component: AgentLibraryPage })
  const router = createRouter({
    isServer: true,
    routeTree: root.addChildren([route]),
    history: createMemoryHistory({ initialEntries: [`/agent-library?scope=${scope}`] }),
    parseSearch: parseRouterSearch,
    stringifySearch: stringifyRouterSearch
  })
  await router.load()
  try {
    const html = renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    )
    expect(html.includes('library unavailable')).toBe(scope === GLOBAL_LIBRARY_SCOPE)
  } finally {
    client.clear()
  }
})
