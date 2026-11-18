import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../../common/i18n'
import { parseRouterSearch, stringifyRouterSearch } from '../../common/router'
import { conversationAttentionQuery, podKeys } from '../api'
import { commentAttentionQuery, pagesQuery } from '../content-api'
import { jobsBoardQuery, type JobBoardItem } from '../jobs-api'
import { ChatHomeView } from './chat-home-view'

function failedJob(id: number, overrides: Partial<JobBoardItem> = {}): JobBoardItem {
  return {
    id: `job:${id}`,
    rawID: String(id),
    kind: 'background_agent_job',
    cardType: 'one_off',
    column: 'running',
    status: 'failed',
    title: 'Build the todo Applet',
    attention: true,
    attentionReason: 'failed',
    agentUID: 'pa-alice',
    agentName: 'Alice Assistant',
    stoppable: false,
    manageable: true,
    canMessage: false,
    stepCount: 0,
    chainLength: 1,
    createdAt: '2026-11-15T07:00:00Z',
    updatedAt: `2026-11-15T07:0${id}:00Z`,
    ...overrides
  }
}

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
          queryKey: jobsBoardQuery.queryKey,
          queryFn: async () => {
            throw new Error('Jobs board unavailable')
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
    expect(html).toContain('Jobs board unavailable')
    expect(html).toContain('data-slot="home-favorites"')
    expect(html).toContain('Favorites service unavailable')
    expect(html).toContain(i18n.t('common.retry'))
  })

  test('omits needs-attention and favorites sections when all queries succeed with zero items', async () => {
    const html = await renderChatHome(client => {
      client.setQueryData(conversationAttentionQuery.queryKey, [])
      client.setQueryData(commentAttentionQuery.queryKey, [])
      client.setQueryData(jobsBoardQuery.queryKey, { items: [], agents: [] })
      client.setQueryData(pagesQuery('recent').queryKey, { pages: [] })
      client.setQueryData([...podKeys.conversations, 'recent'], { conversations: [] })
      client.setQueryData(pagesQuery('favorites').queryKey, { pages: [] })
    })

    expect(html).not.toContain('data-slot="home-needs-attention"')
    expect(html).not.toContain('data-slot="home-favorites"')
  })
})

describe('ChatHomeView attention jobs', () => {
  function setup(items: JobBoardItem[]) {
    return (client: QueryClient) => {
      client.setQueryData(conversationAttentionQuery.queryKey, [])
      client.setQueryData(commentAttentionQuery.queryKey, [])
      client.setQueryData(jobsBoardQuery.queryKey, { items, agents: [] })
      client.setQueryData(pagesQuery('recent').queryKey, { pages: [] })
      client.setQueryData([...podKeys.conversations, 'recent'], { conversations: [] })
      client.setQueryData(pagesQuery('favorites').queryKey, { pages: [] })
    }
  }

  test('lists failed runs under their own heading, each opening its own execution, apart from a same-named success', async () => {
    const html = await renderChatHome(
      setup([
        failedJob(1),
        failedJob(2),
        failedJob(3),
        failedJob(4, { column: 'completed', status: 'succeeded', attention: false, attentionReason: null })
      ])
    )
    const t = i18n.getFixedT('en-US')

    expect(html).not.toContain('data-slot="home-needs-attention"')
    expect(html).toContain(`${t('pod.chat_room.section_failed')} (3)`)
    expect(html.match(/href="\/jobs\?item=job%3A\d"/g)).toEqual([
      'href="/jobs?item=job%3A3"',
      'href="/jobs?item=job%3A2"',
      'href="/jobs?item=job%3A1"'
    ])
    expect(html.split(`>${t('pod.jobs.attention_failed')}<`).length - 1).toBe(3)
  })

  test('keeps jobs waiting on a person under the decision heading and caps each list at three rows', async () => {
    const html = await renderChatHome(
      setup([
        failedJob(1, { status: 'waiting_on_user', attentionReason: 'waiting_on_user' }),
        ...[2, 3, 4, 5].map(id => failedJob(id))
      ])
    )
    const t = i18n.getFixedT('en-US')

    expect(html).toContain(`${t('pod.chat_room.section_needs_input')} (1)`)
    expect(html).toContain(t('pod.chat_timeline.execution_waiting_user'))
    expect(html).toContain(`${t('pod.chat_room.section_failed')} (4)`)
    expect(html.match(/href="\/jobs\?item=job%3A\d"/g)).toHaveLength(4)
    expect(html).toContain(t('pod.chat_room.view_all_count', { count: 4 }))
  })
})
