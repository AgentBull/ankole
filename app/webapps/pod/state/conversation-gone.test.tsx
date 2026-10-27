import { describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider, QueryObserver } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { SidebarProvider } from '@ankole/uikit'
import { InternalAPIError } from '../../common/internal-api-client'
import { parseRouterSearch, stringifyRouterSearch } from '../../common/router'
import { ChatPage, ChatRoute } from '../chat-page'
import { ChatDraftProvider, useChatDrafts } from '../chat-drafts'
import type { ChatModel } from './chat'
import i18n, { loadLocale } from '../../common/i18n'
import { conversationNotFound, conversationQuery, podKeys, type ConversationDetail } from '../api'
import { podLocation } from '../../common/browser-context'

const conversationID = '00112233-4455-6677-8899-aabbccddeeff'

const notFound = new InternalAPIError(404, 'Not Found', {
  error: { code: 'conversation_not_found', message: 'Conversation unavailable' }
})

function conversationFixture(): ConversationDetail {
  return {
    activities: [],
    pendingQueues: [],
    pendingInteractions: [],
    linkedRuns: [],
    artifacts: { pageIDs: [], attachments: [] },
    removedMessageIDs: [],
    olderMessagesBeforeSeq: null,
    messageRange: { firstSeq: 1, lastSeq: 1 },
    conversation: {
      accessScope: 'participants',
      canDelete: true,
      canManage: true,
      roomMode: 'dm',
      titleCustomized: false,
      createdBy: 'person',
      lastMessageSeq: 1,
      rowStatus: 'idle',
      viewer: { uid: 'person', pinned: false, muted: false, lastReadSeq: 1 },
      agents: [{ uid: 'agent', displayName: 'Agent', active: true, type: 'agent', mayIntervene: true }],
      participants: [
        { uid: 'person', displayName: 'Person', active: true, type: 'human', role: 'owner', mayIntervene: false },
        { uid: 'agent', displayName: 'Agent', active: true, type: 'agent', mayIntervene: true }
      ],
      pageID: null,
      id: conversationID,
      title: 'Private title',
      agent: { uid: 'agent', displayName: 'Agent', active: true },
      lastActivityAt: '2026-10-14T00:00:00Z'
    },
    messages: [
      {
        id: 'private-message',
        seq: 1,
        authorType: 'human',
        authorDisplayName: 'Fixture author',
        authorArchived: false,
        mentions: [],
        savedPages: [],
        authorUID: 'person',
        kind: 'message',
        links: [],
        attachments: [],
        text: 'Previously cached private text',
        createdAt: '2026-10-14T00:00:00Z',
        replyToMessageID: null,
        signalID: null
      }
    ]
  }
}

describe('Pod unavailable conversations', () => {
  test('retained draft labels display their local message number', async () => {
    await loadLocale('en-US')
    expect(i18n.t('pod.chat_drafts.message', { number: 2 })).toBe('Local text 2')
  })

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

  test('a 404 hides cached history and the composer immediately and offers a new conversation', async () => {
    const client = new QueryClient({
      defaultOptions: { queries: { gcTime: Infinity, retry: false, staleTime: Infinity } }
    })
    const cached = conversationFixture()
    client.setQueryData(podKeys.detail(conversationID), cached)
    client
      .getQueryCache()
      .find({ queryKey: podKeys.detail(conversationID), exact: true })!
      .setState({ status: 'error', error: notFound })
    const rootRoute = createRootRoute()
    const conversationRoute = createRoute({
      getParentRoute: () => rootRoute,
      path: '/conversations/$conversationID',
      component: ChatRoute
    })
    const router = createRouter({
      routeTree: rootRoute.addChildren([conversationRoute]),
      history: createMemoryHistory({
        initialEntries: [podLocation(`/conversations/${conversationID}`).pathname]
      }),
      parseSearch: parseRouterSearch,
      stringifySearch: stringifyRouterSearch
    })
    await router.load()
    try {
      const html = renderToStaticMarkup(
        <QueryClientProvider client={client}>
          <SidebarProvider>
            <ChatDraftProvider>
              <RouterProvider router={router} />
            </ChatDraftProvider>
          </SidebarProvider>
        </QueryClientProvider>
      )
      expect(html).toContain('role="alert"')
      expect(html).toContain('href="/"')
      expect(html).not.toContain('Previously cached private text')
      expect(html).not.toContain('Private title')
      expect(html).not.toContain('<textarea')
      expect(html).not.toContain('data-slot="input-group"')
      expect(html).toContain('data-slot="sidebar-trigger"')
    } finally {
      client.clear()
    }
  })

  test('an embedded page conversation 404 stays inside the page panel instead of linking away to root', async () => {
    const client = new QueryClient({
      defaultOptions: { queries: { gcTime: Infinity, retry: false, staleTime: Infinity } }
    })
    const cached = conversationFixture()
    cached.conversation.pageID = 'page-1'
    client.setQueryData(podKeys.detail(conversationID), cached)
    client
      .getQueryCache()
      .find({ queryKey: podKeys.detail(conversationID), exact: true })!
      .setState({ status: 'error', error: notFound })
    const rootRoute = createRootRoute({
      component: () => (
        <ChatPage
          conversationID={conversationID}
          pageID="page-1"
          pageHeader={<header className="pod-page-chat-header">Page chat</header>}
          onExitConversation={() => {}}
        />
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
      const html = renderToStaticMarkup(
        <QueryClientProvider client={client}>
          <SidebarProvider>
            <ChatDraftProvider>
              <RouterProvider router={router} />
            </ChatDraftProvider>
          </SidebarProvider>
        </QueryClientProvider>
      )
      expect(html).toContain('pod-page-chat-header')
      expect(html).toContain('role="alert"')
      expect(html).not.toContain('href="/"')
      expect(html).not.toContain('Previously cached private text')
      expect(html).not.toContain('data-slot="sidebar-trigger"')
    } finally {
      client.clear()
    }
  })

  test('removing an Agent hides its retained live answer and active work while the current room stays idle', async () => {
    await loadLocale('en-US')
    const client = new QueryClient({
      defaultOptions: { queries: { gcTime: Infinity, retry: false, staleTime: Infinity } }
    })
    const cached = conversationFixture()
    cached.conversation.roomMode = 'group'
    cached.pendingQueues = [
      { agentUID: 'agent', inputs: [], paused: false, queueVersion: 'current', workStatus: { state: 'idle' } }
    ]
    client.setQueryData(podKeys.detail(conversationID), cached)
    client.setQueryData(podKeys.agents, { agents: cached.conversation.agents })
    let retained: InstanceType<typeof ChatModel> | undefined
    function RetainedDraft() {
      const model = useChatDrafts().get(conversationID)
      retained = model
      model.liveStreams.value = {
        'removed-agent': {
          agentUID: 'removed-agent',
          agentName: 'Removed Agent',
          responseID: 'removed-response',
          signalIDs: ['removed-signal'],
          text: 'Removed Agent live answer',
          thinkingSummary: 'Removed Agent private thinking'
        }
      }
      model.observeActivity({
        conversationID,
        agentUID: 'removed-agent',
        sessionID: `conversation:${conversationID}`,
        signalID: 'removed-signal',
        responseID: 'removed-response',
        epoch: 1,
        revision: 1,
        state: 'active',
        phase: { operation_id: 'removed-work', label: 'Removed Agent active work' },
        tools: []
      })
      return null
    }
    const rootRoute = createRootRoute()
    const conversationRoute = createRoute({
      getParentRoute: () => rootRoute,
      path: '/conversations/$conversationID',
      component: ChatRoute
    })
    const router = createRouter({
      routeTree: rootRoute.addChildren([conversationRoute]),
      history: createMemoryHistory({
        initialEntries: [podLocation(`/conversations/${conversationID}`).pathname]
      }),
      parseSearch: parseRouterSearch,
      stringifySearch: stringifyRouterSearch
    })
    await router.load()
    try {
      const html = renderToStaticMarkup(
        <QueryClientProvider client={client}>
          <SidebarProvider>
            <ChatDraftProvider>
              <RetainedDraft />
              <RouterProvider router={router} />
            </ChatDraftProvider>
          </SidebarProvider>
        </QueryClientProvider>
      )
      expect(html).toContain('Private title')
      expect(html).toContain('Previously cached private text')
      expect(html).toContain('<textarea')
      expect(html).not.toContain('Removed Agent')
      expect(html).not.toContain('data-live-agent')
      expect(html).not.toContain('pod-chat-work')
      expect(html).not.toContain(i18n.t('pod.chat.replying'))
      expect(retained!.liveStreams.peek()['removed-agent']?.text).toBe('Removed Agent live answer')
      expect(retained!.activities.peek()['removed-agent']?.state).toBe('active')
    } finally {
      client.clear()
    }
  })

  test('room readers see a clarification but need its Agent chat permission to answer', async () => {
    await loadLocale('en-US')
    for (const callable of [false, true]) {
      const client = new QueryClient({
        defaultOptions: { queries: { gcTime: Infinity, retry: false, staleTime: Infinity } }
      })
      const cached = conversationFixture()
      const source = cached.messages[0]!
      cached.messages = [
        {
          ...source,
          id: 'question',
          authorType: 'agent',
          authorUID: 'agent',
          text: 'Choose the next step.',
          richContent: {
            clarify: {
              question: 'Which report?',
              interaction_id: 'decision',
              choices: [{ id: 'report', label: 'Read the report' }],
              allow_free_text: true,
              state: 'pending',
              tool_call_id: 'question-call'
            }
          }
        }
      ]
      client.setQueryData(podKeys.detail(conversationID), cached)
      client.setQueryData(podKeys.agents, { agents: callable ? cached.conversation.agents : [] })
      const rootRoute = createRootRoute()
      const roomRoute = createRoute({
        getParentRoute: () => rootRoute,
        path: '/conversations/$conversationID',
        component: ChatRoute
      })
      const router = createRouter({
        routeTree: rootRoute.addChildren([roomRoute]),
        history: createMemoryHistory({ initialEntries: [podLocation(`/conversations/${conversationID}`).pathname] }),
        parseSearch: parseRouterSearch,
        stringifySearch: stringifyRouterSearch
      })
      await router.load()
      try {
        const html = renderToStaticMarkup(
          <QueryClientProvider client={client}>
            <SidebarProvider>
              <ChatDraftProvider>
                <RouterProvider router={router} />
              </ChatDraftProvider>
            </SidebarProvider>
          </QueryClientProvider>
        )
        expect(html).toContain('Which report?')
        const choice = html.match(/<button[^>]*class="[^"]*pod-chat-choice[^"]*"[^>]*>/)?.[0]
        expect(choice).toBeDefined()
        expect(/\sdisabled(?:=|\s|>)/.test(choice!)).toBe(!callable)
        expect(html.includes(i18n.t('pod.chat_room.answer_unavailable'))).toBe(!callable)
      } finally {
        client.clear()
      }
    }
  })

  test('editing the last request uses its persisted targets, including a silent Agent', async () => {
    await loadLocale('en-US')
    for (const targets of [['agent'], ['agent', 'colleague']]) {
      const client = new QueryClient({
        defaultOptions: { queries: { gcTime: Infinity, retry: false, staleTime: Infinity } }
      })
      const cached = conversationFixture()
      cached.conversation.roomMode = 'group'
      cached.conversation.agents.push({
        uid: 'colleague',
        displayName: 'Colleague',
        active: true,
        type: 'agent',
        mayIntervene: false
      })
      cached.pendingQueues = cached.conversation.agents.map(agent => ({
        agentUID: agent.uid,
        inputs: [],
        paused: false,
        queueVersion: agent.uid,
        workStatus: { state: 'idle' }
      }))
      cached.latestInput = {
        messageID: cached.messages[0]!.id,
        authorUID: cached.conversation.viewer.uid,
        agentUIDs: targets
      }
      cached.messages.push(
        ...['agent'].map((author, index) => ({
          ...cached.messages[0]!,
          id: `reply-${index}`,
          seq: index + 2,
          authorType: 'agent' as const,
          authorUID: author,
          authorDisplayName: author,
          replyToMessageID: cached.messages[0]!.id,
          text: `Agent reply ${index}`
        }))
      )
      client.setQueryData(podKeys.detail(conversationID), cached)
      client.setQueryData(podKeys.agents, { agents: cached.conversation.agents })
      const rootRoute = createRootRoute()
      const conversationRoute = createRoute({
        getParentRoute: () => rootRoute,
        path: '/conversations/$conversationID',
        component: ChatRoute
      })
      const router = createRouter({
        routeTree: rootRoute.addChildren([conversationRoute]),
        history: createMemoryHistory({ initialEntries: [podLocation(`/conversations/${conversationID}`).pathname] }),
        parseSearch: parseRouterSearch,
        stringifySearch: stringifyRouterSearch
      })
      await router.load()
      try {
        const html = renderToStaticMarkup(
          <QueryClientProvider client={client}>
            <SidebarProvider>
              <ChatDraftProvider>
                <RouterProvider router={router} />
              </ChatDraftProvider>
            </SidebarProvider>
          </QueryClientProvider>
        )
        const edit = html.match(/<button\b[^>]*aria-label="Edit and regenerate"[^>]*>/)?.[0]
        expect(edit).toBeDefined()
        if (targets.length > 1) {
          expect(edit).toContain('aria-disabled="true"')
          expect(edit).toContain(`aria-description="${i18n.t('pod.chat_timeline.multi_agent_edit')}"`)
          expect(edit).not.toContain('tabindex="-1"')
        } else {
          expect(edit).not.toContain('aria-disabled="true"')
          expect(edit).not.toContain(i18n.t('pod.chat_timeline.multi_agent_edit'))
        }
      } finally {
        client.clear()
      }
    }
  })

  test('a queued request remains visible while another Agent waits for a future retry', async () => {
    await loadLocale('en-US')
    const client = new QueryClient({
      defaultOptions: { queries: { gcTime: Infinity, retry: false, staleTime: Infinity } }
    })
    const cached = conversationFixture()
    cached.conversation.roomMode = 'group'
    const colleague = { ...cached.conversation.agents[0]!, uid: 'colleague', displayName: 'Colleague' }
    cached.conversation.agents.push(colleague)
    cached.conversation.participants.push({ ...colleague, role: 'agent' })
    cached.conversation.lastMessageSeq = 2
    cached.messages.push({
      ...cached.messages[0]!,
      id: 'teammate-message',
      seq: 2,
      authorUID: 'teammate',
      authorDisplayName: 'Another teammate',
      text: 'Their request'
    })
    cached.messageRange.lastSeq = 2
    cached.latestInput = { messageID: 'teammate-message', authorUID: 'teammate', agentUIDs: ['agent'] }
    cached.conversation.viewer.lastReadSeq = 2
    cached.pendingQueues = [
      { agentUID: 'agent', inputs: [], paused: false, queueVersion: 'queued', workStatus: { state: 'queued' } },
      {
        agentUID: 'colleague',
        inputs: [],
        paused: false,
        queueVersion: 'retrying',
        workStatus: { state: 'retrying', retryAt: '2026-10-25T03:00:00Z' }
      }
    ]
    client.setQueryData(podKeys.detail(conversationID), cached)
    client.setQueryData(podKeys.agents, { agents: cached.conversation.agents })
    const rootRoute = createRootRoute()
    const conversationRoute = createRoute({
      getParentRoute: () => rootRoute,
      path: '/conversations/$conversationID',
      component: ChatRoute
    })
    const router = createRouter({
      routeTree: rootRoute.addChildren([conversationRoute]),
      history: createMemoryHistory({ initialEntries: [podLocation(`/conversations/${conversationID}`).pathname] }),
      parseSearch: parseRouterSearch,
      stringifySearch: stringifyRouterSearch
    })
    await router.load()
    try {
      const html = renderToStaticMarkup(
        <QueryClientProvider client={client}>
          <SidebarProvider>
            <ChatDraftProvider>
              <RouterProvider router={router} />
            </ChatDraftProvider>
          </SidebarProvider>
        </QueryClientProvider>
      )
      expect(html).toContain('Private title')
      expect(html).toContain(i18n.t('pod.chat_timeline.queued'))
      expect(html).not.toContain(i18n.t('pod.chat.replying'))
      const messages = html.match(/<article\b[\s\S]*?<\/article>/g) ?? []
      expect(messages.find(message => message.includes('Previously cached private text'))).toContain(
        'pod-chat-own-message'
      )
      expect(messages.find(message => message.includes('Their request'))).not.toContain('pod-chat-own-message')
    } finally {
      client.clear()
    }
  })
})
