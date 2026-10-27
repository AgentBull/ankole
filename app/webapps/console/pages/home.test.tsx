import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../../common/i18n'
import { parseRouterSearch, stringifyRouterSearch } from '../../common/router'
import {
  getConsoleReadinessQueryKey,
  getBackgroundAgentJobHealthQueryKey
} from '../api/v2/generated/@tanstack/react-query.gen'
import { backgroundAgentJobsOptions } from '../api/background-agent-jobs'
import type { ConsoleReadinessResponse } from '../api/runtime-types'
import { listAiGatewayProvidersQueryKey } from '../api/v2-site/generated/@tanstack/react-query.gen'
import { HomePage } from './home'

beforeAll(() => loadLocale('en-US'))

test('shows global job counts independently of the recent jobs page', async () => {
  const client = new QueryClient()
  client.setQueryData(getBackgroundAgentJobHealthQueryKey(), { running_count: 12, queued_count: 17 })
  client.setQueryData(backgroundAgentJobsOptions({ limit: 20 }).queryKey, { data: [] })

  const html = await providerHTML(client)
  const jobMetric = html.match(/<a[^>]*href="\/background-agent-jobs"[^>]*>[\s\S]*?<\/a>/)?.[0]
  expect(jobMetric).toContain('>12<')
  expect(jobMetric).toContain('17 queued')
  client.clear()
})

function providerClient(complete: boolean) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
  client.setQueryData(listAiGatewayProvidersQueryKey(), {
    data: [
      {
        id: 'search-row',
        type: 'ai_gateway_provider',
        attributes: { provider_id: 'search', provider_kind: 'jina_search', disabled_at: null }
      }
    ]
  })
  const readiness: ConsoleReadinessResponse = {
    ready: complete,
    completed_core_steps: complete ? 4 : 3,
    total_core_steps: 4,
    provider: { complete, provider_id: complete ? 'llm' : null },
    agent: { complete: true, uid: null, display_name: null },
    model_profiles: { complete: true, agent_uid: null, missing_profiles: [] },
    worker: { complete: true, ready_count: 1 }
  }
  client.setQueryData(getConsoleReadinessQueryKey(), readiness)
  return client
}
async function providerHTML(client: QueryClient) {
  const rootRoute = createRootRoute()
  const indexRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: '/',
    component: HomePage
  })
  const router = createRouter({
    routeTree: rootRoute.addChildren([indexRoute]),
    history: createMemoryHistory({ initialEntries: ['/'] }),
    parseSearch: parseRouterSearch,
    stringifySearch: stringifyRouterSearch
  })
  await router.load()
  return renderToStaticMarkup(
    <QueryClientProvider client={client}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  )
}
test('warns about missing usable LLM credentials while enabled non-LLM providers retain their count', async () => {
  const client = providerClient(false)
  const html = await providerHTML(client)
  expect(html).toContain('No usable LLM provider')
  expect(html).toContain('href="/providers"')
  const providerMetric = html.match(/<a[^>]*href="\/providers"[^>]*>[\s\S]*?<\/a>/g)?.find(item => item.includes('>1<'))
  expect(providerMetric).toContain('>1<')
  client.clear()
})
test('has no provider warning after the readiness snapshot confirms usable LLM credentials', async () => {
  const client = providerClient(true)
  expect(await providerHTML(client)).not.toContain('No usable LLM provider')
  client.clear()
})
test('shows a readiness error without a provider warning when a refetch fails with old data', async () => {
  const client = providerClient(false)
  client
    .getQueryCache()
    .find({ queryKey: getConsoleReadinessQueryKey() })
    ?.setState({
      status: 'error',
      error: new Error('readiness unavailable')
    })
  const html = await providerHTML(client)
  expect(html).toContain('readiness unavailable')
  expect(html).not.toContain('No usable LLM provider')
  client.clear()
})
