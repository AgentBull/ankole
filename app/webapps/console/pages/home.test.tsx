import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { MemoryRouter } from 'react-router'
import { loadLocale } from '../../common/i18n'
import {
  ankoleWebBackgroundAgentJobControllerHealthQueryKey,
  ankoleWebBackgroundAgentJobControllerIndexQueryKey
} from '../api/generated/@tanstack/react-query.gen'
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
