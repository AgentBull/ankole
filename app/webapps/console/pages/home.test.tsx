import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { MemoryRouter } from 'react-router'
import { loadLocale } from '../../common/i18n'
import {
  ankoleWebConsoleReadinessControllerShowQueryKey,
  ankoleWebAiGatewayProviderControllerIndexQueryKey,
  ankoleWebBackgroundAgentJobControllerHealthQueryKey,
  ankoleWebBackgroundAgentJobControllerIndexQueryKey
} from '../api/generated/@tanstack/react-query.gen'
import type { ConsoleReadinessResponse } from '../api/generated/types.gen'
import { HomePage } from './home'

beforeAll(() => loadLocale('en-US'))

test('shows global job counts independently of the recent jobs page', () => {
  const client = new QueryClient()
  client.setQueryData(ankoleWebBackgroundAgentJobControllerHealthQueryKey(), { running_count: 12, queued_count: 17 })
  client.setQueryData(ankoleWebBackgroundAgentJobControllerIndexQueryKey({ query: { limit: 20 } }), { jobs: [] })

  const html = renderToStaticMarkup(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <HomePage />
      </MemoryRouter>
    </QueryClientProvider>
  )
  const jobMetric = html.match(/<a[^>]*href="\/background-agent-jobs"[^>]*>[\s\S]*?<\/a>/)?.[0]
  expect(jobMetric).toContain('>12<')
  expect(jobMetric).toContain('17 queued')
  client.clear()
})

function providerClient(complete: boolean) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
  client.setQueryData(ankoleWebAiGatewayProviderControllerIndexQueryKey(), {
    ai_gateway_providers: [{ provider_id: 'search', provider_kind: 'jina_search', disabled_at: null }]
  })
  const readiness: ConsoleReadinessResponse = {
    ready: complete,
    completed_core_steps: complete ? 5 : 4,
    total_core_steps: 5,
    provider: { complete, provider_id: complete ? 'llm' : null },
    agent: { complete: true, uid: null, display_name: null },
    model_profiles: { complete: true, agent_uid: null, missing_profiles: [] },
    worker: { complete: true, ready_count: 1 },
    signal_route: { complete: true }
  }
  client.setQueryData(ankoleWebConsoleReadinessControllerShowQueryKey(), readiness)
  return client
}
function providerHTML(client: QueryClient) {
  return renderToStaticMarkup(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <HomePage />
      </MemoryRouter>
    </QueryClientProvider>
  )
}
test('warns about missing usable LLM credentials while enabled non-LLM providers retain their count', () => {
  const client = providerClient(false)
  const html = providerHTML(client)
  expect(html).toContain('No usable LLM provider')
  expect(html).toContain('href="/providers"')
  const providerMetric = html.match(/<a[^>]*href="\/providers"[^>]*>[\s\S]*?<\/a>/g)?.find(item => item.includes('>1<'))
  expect(providerMetric).toContain('>1<')
  client.clear()
})
test('has no provider warning after the readiness snapshot confirms usable LLM credentials', () => {
  const client = providerClient(true)
  expect(providerHTML(client)).not.toContain('No usable LLM provider')
  client.clear()
})
test('shows a readiness error without a provider warning when a refetch fails with old data', () => {
  const client = providerClient(false)
  client
    .getQueryCache()
    .find({ queryKey: ankoleWebConsoleReadinessControllerShowQueryKey() })
    ?.setState({
      status: 'error',
      error: new Error('readiness unavailable')
    })
  const html = providerHTML(client)
  expect(html).toContain('readiness unavailable')
  expect(html).not.toContain('No usable LLM provider')
  client.clear()
})
