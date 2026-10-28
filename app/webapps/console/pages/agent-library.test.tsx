import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import i18n, { loadLocale } from '../../common/i18n'
import { parseRouterSearch, stringifyRouterSearch } from '../../common/router'
import { listControlPlanePluginsQueryKey } from '../api/v2-site/generated/@tanstack/react-query.gen'
import { getGlobalLibraryCapabilitiesQueryKey } from '../api/v2/generated/@tanstack/react-query.gen'
import { listAgentsQueryKey } from '../api/v2/generated/@tanstack/react-query.gen'
import { GLOBAL_LIBRARY_SCOPE } from '../state/agent-library-capabilities'
import { AgentLibraryPage } from './agent-library'

beforeAll(() => loadLocale('en-US'))

test.each(
  [GLOBAL_LIBRARY_SCOPE, 'agent-a'].flatMap(scope =>
    (['tenant', 'global'] as const).flatMap(defaultsScope => [
      {
        scope,
        defaultsScope,
        source: 'site plugins',
        visible: scope === GLOBAL_LIBRARY_SCOPE,
        key: listControlPlanePluginsQueryKey(),
        data: { control_plane_plugins: [] }
      },
      {
        scope,
        defaultsScope,
        source: 'defaults',
        visible: scope === GLOBAL_LIBRARY_SCOPE,
        key: getGlobalLibraryCapabilitiesQueryKey({ query: { defaults_scope: defaultsScope } }),
        data: { agent_plugins: [], skills: [] }
      },
      {
        scope,
        defaultsScope,
        source: 'Agent selector',
        visible: defaultsScope === 'tenant' || scope === 'agent-a',
        key: listAgentsQueryKey(),
        data: { data: [] }
      }
    ])
  )
)(
  'a cached $source error is visible only in its library scope ($defaultsScope/$scope)',
  async ({ scope, defaultsScope, key, data, visible }) => {
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
      history: createMemoryHistory({
        initialEntries: [`/agent-library?scope=${scope}&defaults_scope=${defaultsScope}`]
      }),
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
      expect(html.includes('library unavailable')).toBe(visible)
      expect(html.includes(`aria-label="${i18n.t('console.agent_library_capabilities.scope')}"`)).toBe(
        !(scope === GLOBAL_LIBRARY_SCOPE && defaultsScope === 'global')
      )
    } finally {
      client.clear()
    }
  }
)
