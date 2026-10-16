import { describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider, QueryObserver } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { createMemoryRouter, RouterProvider } from 'react-router'
import { InternalAPIError } from '../../common/internal-api-client'
import { ChatRoute } from '../chat-page'
import { conversationNotFound, conversationQuery, podKeys, type ConversationDetail } from '../api'

const notFound = new InternalAPIError(404, 'Not Found', {
  error: { code: 'conversation_not_found', message: 'Conversation unavailable' }
})

describe('Pod unavailable conversations', () => {
  test('a missing-conversation read is terminal on its first response', async () => {
    const client = new QueryClient({ defaultOptions: { queries: { gcTime: Infinity } } })
    let calls = 0
    const query = new QueryObserver(client, {
      ...conversationQuery('conversation'),
      queryFn: async () => {
        calls += 1
        throw notFound
      }
    })
    try {
      const result = await query.refetch()
      expect(calls).toBe(1)
      expect(result.isError).toBe(true)
      expect(result.error).toBe(notFound)
    } finally {
      query.destroy()
      client.clear()
    }
  })
  test('only the declared missing-conversation response is terminal', () => {
    expect(conversationNotFound(notFound)).toBe(true)
    expect(
      conversationNotFound(
        new InternalAPIError(500, 'Internal Server Error', { error: { code: 'conversation_not_found' } })
      )
    ).toBe(false)
    expect(
      conversationNotFound(new InternalAPIError(404, 'Not Found', { error: { code: 'other_resource_not_found' } }))
    ).toBe(false)
    expect(conversationNotFound(new Error('Connection lost'))).toBe(false)
  })

  test('a 404 hides cached history and the composer immediately and offers a new conversation', () => {
    const client = new QueryClient({
      defaultOptions: { queries: { gcTime: Infinity, retry: false, staleTime: Infinity } }
    })
    const cached: ConversationDetail = {
      conversation: {
        id: 'conversation',
        title: 'Private title',
        agent: { uid: 'agent', displayName: 'Agent', active: true },
        lastActivityAt: '2026-10-14T00:00:00Z'
      },
      messages: [
        {
          id: 'private-message',
          seq: 1,
          authorType: 'human',
          authorUID: 'person',
          kind: 'message',
          text: 'Previously cached private text',
          createdAt: '2026-10-14T00:00:00Z',
          replyToMessageID: null,
          signalID: null
        }
      ],
      status: {
        state: 'idle',
        retryAt: null,
        activity: {
          conversationID: 'conversation',
          agentUID: 'agent',
          sessionID: 'conversation:conversation',
          signalID: null,
          responseID: null,
          epoch: 0,
          revision: 0,
          state: 'unavailable',
          phase: null,
          tools: []
        }
      }
    }
    client.setQueryData(podKeys.detail('conversation'), cached)
    client
      .getQueryCache()
      .find({ queryKey: podKeys.detail('conversation'), exact: true })!
      .setState({ status: 'error', error: notFound })
    const router = createMemoryRouter([{ path: '/conversations/:conversationID', element: <ChatRoute /> }], {
      initialEntries: ['/conversations/conversation']
    })
    try {
      const html = renderToStaticMarkup(
        <QueryClientProvider client={client}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      )
      expect(html).toContain('role="alert"')
      expect(html).toContain('href="/"')
      expect(html).not.toContain('Previously cached private text')
      expect(html).not.toContain('Private title')
      expect(html).not.toContain('<textarea')
      expect(html).not.toContain('data-slot="input-group"')
    } finally {
      router.dispose()
      client.clear()
    }
  })
})
