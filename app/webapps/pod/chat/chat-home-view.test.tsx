import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../../common/i18n'
import { parseRouterSearch, stringifyRouterSearch } from '../../common/router'
import { conversationAttentionQuery, podKeys } from '../api'
import { commentAttentionQuery, pagesQuery } from '../content-api'
import { jobsSummaryQuery } from '../jobs-api'
import { ChatHomeView } from './chat-home-view'

async function renderChatHome(setup: (client: QueryClient) => Promise<void> | void): Promise<string> {
  await loadLocale('en-US')
  const client = new QueryClient({
    defaultOptions: { queries: { gcTime: Infinity, staleTime: Infinity, retry: false, retryOnMount: false } }
  })
  client.setQueryData(['pod-session', '', ''], { displayName: 'Ada' })
  await setup(client)

  const rootRoute = createRootRoute({
    component: () => (
      <ChatHomeView composer={<div data-slot="test-composer" />} onSuggestion={() => {}} showSuggestions={false} />
    )
  })
  const router = createRouter({
    routeTree: rootRoute,
    history: createMemoryHistory({ initialEntries: ['/'] }),
    parseSearch: parseRouterSearch,
    stringifySearch: stringifyRouterSearch
  })
  await router.load()
  try {
    return renderToStaticMarkup(
      <I18nextProvider i18n={i18n}>
        <QueryClientProvider client={client}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      </I18nextProvider>
    )
  } finally {
    client.clear()
  }
}

describe('ChatHomeView error surfaces', () => {
  test('surfaces attention and favorites query failures with retry controls instead of hiding those sections', async () => {
    const html = await renderChatHome(async client => {
      client.setQueryData(conversationAttentionQuery.queryKey, [])
      client.setQueryData(commentAttentionQuery.queryKey, [])
      client.setQueryData(pagesQuery('recent').queryKey, { pages: [] })
      client.setQueryData([...podKeys.conversations, 'recent'], { conversations: [] })

      await client
        .fetchQuery({
          queryKey: jobsSummaryQuery.queryKey,
          queryFn: async () => {
            throw new Error('Jobs summary unavailable')
          }
        })
        .catch(() => {})

      await client
        .fetchQuery({
          queryKey: pagesQuery('favorites').queryKey,
          queryFn: async () => {
            throw new Error('Favorites service unavailable')
          }
        })
        .catch(() => {})
    })

    expect(html).toContain('data-slot="home-needs-attention"')
    expect(html).toContain('Jobs summary unavailable')
    expect(html).toContain('data-slot="home-favorites"')
    expect(html).toContain('Favorites service unavailable')
    expect(html).toContain(i18n.t('common.retry'))
  })

  test('omits needs-attention and favorites sections when all queries succeed with zero items', async () => {
    const html = await renderChatHome(client => {
      client.setQueryData(conversationAttentionQuery.queryKey, [])
      client.setQueryData(commentAttentionQuery.queryKey, [])
      client.setQueryData(jobsSummaryQuery.queryKey, { attentionCount: 0 })
      client.setQueryData(pagesQuery('recent').queryKey, { pages: [] })
      client.setQueryData([...podKeys.conversations, 'recent'], { conversations: [] })
      client.setQueryData(pagesQuery('favorites').queryKey, { pages: [] })
    })

    expect(html).not.toContain('data-slot="home-needs-attention"')
    expect(html).not.toContain('data-slot="home-favorites"')
  })
})
