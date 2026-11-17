import { expect, test, type Page, type Request, type Route, type WebSocketRoute } from '@playwright/test'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import type { ConversationDetail } from '../pod/api'
import type { PodAgentsResponse, PodPageCommentSummaryResponse } from '../pod/api/generated/types.gen'
import { conversationRoute, pageRoute } from './pod-browser/routes'

// Browser unit coverage: keep the real Pod routes and caches, and count the requests that opening a room or a Page
// sends at the HTTP and socket boundaries.

test.beforeEach(async ({ page }) => {
  await page.route('**/api/v2/browser/session', route =>
    route.fulfill({
      json: {
        authenticated: true,
        principalUID: 'person',
        displayName: 'Person',
        canManagePod: false,
        accounts: [],
        pendingAccounts: [],
        siteAuthentications: []
      } satisfies BrowserSessionResponse
    })
  )
})

function requestLog(page: Page) {
  const requests: string[] = []
  page.on('request', (request: Request) => {
    const url = new URL(request.url())
    if (url.pathname.startsWith('/api/v2/pod/')) {
      requests.push(`${request.method()} ${url.pathname.slice('/api/v2/pod'.length)}${url.search}`)
    }
  })
  return {
    count: (entry: string) => requests.filter(request => request === entry).length,
    matching: (pattern: RegExp) => requests.filter(request => pattern.test(request))
  }
}

const roomID = '019a2b00-0000-7000-8000-0000000000c1'
const agent = { uid: 'agent', displayName: 'Agent', active: true, type: 'agent', mayIntervene: true }

function roomDetail(lastReadSeq: number): ConversationDetail {
  return {
    conversation: {
      id: roomID,
      title: 'Quarterly review',
      accessScope: 'participants',
      canDelete: true,
      canManage: true,
      roomMode: 'dm',
      conversationKind: 'colleague_dm',
      titleCustomized: true,
      createdBy: 'person',
      lastMessageSeq: 2,
      lastNotifiableSeq: 2,
      lastActivityAt: '2026-11-13T00:00:00Z',
      rowStatus: lastReadSeq < 2 ? 'unread' : 'idle',
      viewer: { uid: 'person', pinned: false, muted: false, lastReadSeq },
      agents: [agent],
      participants: [
        { uid: 'person', displayName: 'Person', active: true, type: 'human', role: 'owner', mayIntervene: false },
        agent
      ]
    },
    messages: [
      {
        id: 'question',
        seq: 1,
        kind: 'message',
        authorType: 'human',
        authorUID: 'person',
        authorDisplayName: 'Person',
        authorArchived: false,
        text: 'How did the quarter go?',
        mentions: [],
        savedPages: [],
        links: [],
        attachments: [],
        createdAt: '2026-11-13T00:00:00Z',
        replyToMessageID: null,
        signalID: 'signal-1'
      },
      {
        id: 'answer',
        seq: 2,
        kind: 'message',
        authorType: 'agent',
        authorUID: 'agent',
        authorDisplayName: 'Agent',
        authorArchived: false,
        text: 'Revenue grew in every region.',
        mentions: [],
        savedPages: [],
        links: [],
        attachments: [],
        createdAt: '2026-11-13T00:00:01Z',
        replyToMessageID: 'question',
        signalID: 'signal-1'
      }
    ],
    activities: [],
    pendingInteractions: [],
    pendingQueues: [],
    linkedRuns: [],
    artifacts: { pageIDs: [], attachments: [] },
    editableInputs: [],
    removedMessageIDs: [],
    olderMessagesBeforeSeq: null,
    messageRange: { firstSeq: 1, lastSeq: 2 }
  }
}

test('opening an unread room reads it once after connecting and clears the sidebar dot from the confirmed read', async ({
  page
}) => {
  await page.setViewportSize({ width: 1365, height: 900 })
  await page.addInitScript(() => {
    const streams: EventTarget[] = []
    Object.assign(window, { testStreams: streams })
    window.EventSource = class extends EventTarget {
      onopen: ((event: Event) => void) | null = null
      onerror: ((event: Event) => void) | null = null
      constructor(public url: string) {
        super()
        streams.push(this)
      }
      close() {}
    } as unknown as typeof EventSource
  })
  const log = requestLog(page)
  let markRead: Route | undefined
  let read = false
  const unread = roomDetail(1)
  // Rereads keep returning the position from before the read, as a read that started before the commit would.
  await page.route('**/api/v2/pod/**', route => {
    const url = new URL(route.request().url())
    const path = url.pathname
    const method = route.request().method()
    if (path === '/api/v2/pod/realtime-token') return new Promise<void>(() => {})
    if (path === `/api/v2/pod/conversations/${roomID}` && method === 'PATCH') {
      markRead = route
      return
    }
    if (path === `/api/v2/pod/conversations/${roomID}`) return route.fulfill({ json: unread })
    // The lists follow the server's read position.
    const row = (read ? roomDetail(2) : unread).conversation
    if (path === '/api/v2/pod/conversations/attention') return route.fulfill({ json: [row] })
    if (path === '/api/v2/pod/conversations') {
      return route.fulfill({
        json: { conversations: url.searchParams.get('imOnly') === 'true' ? [] : [row], nextCursor: null }
      })
    }
    if (path.endsWith('/agents')) {
      return route.fulfill({
        json: { agents: [agent], personalAssistant: null, personalAssistantAvailable: false } as PodAgentsResponse
      })
    }
    if (path.endsWith('/runner-devices')) return route.fulfill({ json: { colleagues: [], devices: [] } })
    if (path.endsWith('/pages/navigation')) return route.fulfill({ json: { path: [], directories: [] } })
    return route.fulfill({ json: [] })
  })

  await page.goto(conversationRoute(roomID))
  await expect(page.getByText('Revenue grew in every region.')).toBeVisible()
  const row = page.getByRole('link', { name: /^Agent @agent/ })
  const unreadDot = row.getByRole('img', { name: 'Unread messages', exact: true })
  await expect(unreadDot).toBeVisible()
  await expect.poll(() => markRead !== undefined).toBe(true)
  expect(markRead!.request().postDataJSON()).toEqual({ data: { lastReadSeq: 2 } })

  read = true
  await markRead!.fulfill({ json: roomDetail(2) })
  await expect(unreadDot).toHaveCount(0)

  // The stream connects after the first read started, so Ankole reads the room once more after connecting.
  await page.evaluate(() => {
    const events = (window as unknown as { testStreams: EventSource[] }).testStreams.at(-1)!
    events.onopen?.(new Event('open'))
  })
  await expect.poll(() => log.count(`GET /conversations/${roomID}?loadedFirstSeq=1`)).toBe(1)
  // A committed room change rereads the room; the Pod's coalesced event owns the conversation lists.
  await page.evaluate(id => {
    const events = (window as unknown as { testStreams: EventSource[] }).testStreams.at(-1)!
    events.dispatchEvent(new MessageEvent('conversation', { data: JSON.stringify({ conversationID: id }) }))
  }, roomID)
  await expect.poll(() => log.count(`GET /conversations/${roomID}?loadedFirstSeq=1`)).toBe(2)
  await page.waitForTimeout(300)

  expect(log.count(`GET /conversations/${roomID}`)).toBe(1)
  expect(log.count(`GET /conversations/${roomID}?loadedFirstSeq=1`)).toBe(2)
  expect(log.count(`PATCH /conversations/${roomID}`)).toBe(1)
  expect(log.count('GET /conversations/attention')).toBe(1)
  expect(log.count('GET /conversations?limit=40&query=')).toBe(1)
  expect(log.count('GET /conversations?limit=40&query=&imOnly=true')).toBe(1)
  await expect(unreadDot).toHaveCount(0)
})

/** Answers the Phoenix socket the way the control plane does for the `content` and `page:<id>` topics. */
function phoenixSocket(replies: Record<string, unknown>) {
  return (socket: WebSocketRoute) => {
    socket.onMessage(message => {
      const [joinRef, ref, topic, event] = JSON.parse(String(message)) as [string | null, string, string, string]
      const response = event === 'phx_join' ? (replies[topic] ?? {}) : {}
      socket.send(JSON.stringify([joinRef, ref, topic, 'phx_reply', { status: 'ok', response }]))
    })
  }
}

const docID = '019a2b00-0000-7000-8000-0000000000d1'

function docDetail() {
  return {
    actions: ['node_view', 'node_comment', 'node_edit'],
    role: 'edit',
    ancestors: [],
    child_count: 0,
    content: { content: '<page><p>Quarter notes</p></page>', plain_text: 'Quarter notes' },
    page: {
      id: docID,
      title: 'Quarter notes',
      type: 'doc',
      position: 'a0',
      revision: 1,
      inherit_permissions: true,
      created_at: '2026-11-13T00:00:00Z',
      updated_at: '2026-11-13T00:00:00Z'
    }
  }
}

function summary(unread: number): PodPageCommentSummaryResponse {
  return { unread_count: unread, open_count: unread, resolved_ids: [], activity_at: '2026-11-13T00:00:00Z' }
}

test('opening a document reads its comment summary once and takes the fresh summary from the join reply', async ({
  page
}) => {
  await page.setViewportSize({ width: 1365, height: 900 })
  const log = requestLog(page)
  await page.routeWebSocket(
    '**/pod/socket/**',
    phoenixSocket({ [`page:${docID}`]: { ...docDetail(), presence_session: 'session', comment_summary: summary(2) } })
  )
  await page.route('**/api/v2/pod/**', route => {
    const url = new URL(route.request().url())
    const path = url.pathname
    if (path === '/api/v2/pod/realtime-token') {
      return route.fulfill({ json: { token: 'token', principal: { uid: 'person', name: 'Person' } } })
    }
    if (path === '/api/v2/pod/versions') {
      return route.fulfill({ json: { pages: [{ id: docID, revision: 1 }], tables: [] } })
    }
    if (path === `/api/v2/pod/pages/${docID}`) return route.fulfill({ json: docDetail() })
    if (path === `/api/v2/pod/pages/${docID}/comments/summary`) return route.fulfill({ json: summary(1) })
    if (path === `/api/v2/pod/pages/${docID}/user-state`) return route.fulfill({ json: {} })
    if (path.endsWith('/pages/navigation')) return route.fulfill({ json: { path: [], directories: [] } })
    if (path === '/api/v2/pod/pages/children' || path === '/api/v2/pod/pages') {
      return route.fulfill({
        json: {
          pages: [],
          can_create_space: true,
          can_create_private: true,
          can_manage_space: false,
          next_cursor: null
        }
      })
    }
    if (path.endsWith('/agents')) {
      return route.fulfill({ json: { agents: [], personalAssistant: null, personalAssistantAvailable: false } })
    }
    if (path.endsWith('/conversations')) return route.fulfill({ json: { conversations: [], nextCursor: null } })
    return route.fulfill({ json: [] })
  })

  await page.goto(pageRoute(docID))
  // The first visit compiles the Page route and the block editor in the Vite server.
  await expect(page.getByRole('textbox', { name: 'Page title', exact: true })).toBeVisible({ timeout: 20_000 })
  const unreadComments = page.getByRole('status', { name: 'Unread comments', exact: true })
  // The badge first shows the HTTP read, then the summary that Ankole read after the channel subscribed.
  await expect(unreadComments).toHaveText('2')
  await page.waitForTimeout(500)
  expect(log.count(`GET /pages/${docID}/comments/summary`)).toBe(1)
})

const baseID = '019a2b00-0000-7000-8000-0000000000e1'
const childID = '019a2b00-0000-7000-8000-0000000000e2'

test('a reader opening a Page with subpages loads the subpage menu only when it opens', async ({ page }) => {
  await page.setViewportSize({ width: 1365, height: 900 })
  const log = requestLog(page)
  const child = {
    id: childID,
    title: 'Regional detail',
    type: 'base',
    position: 'a0',
    parent_id: baseID,
    has_children: false,
    created_at: '2026-11-13T00:00:00Z',
    updated_at: '2026-11-13T00:00:00Z'
  }
  await page.route('**/api/v2/pod/**', route => {
    const url = new URL(route.request().url())
    const path = url.pathname
    if (path === '/api/v2/pod/realtime-token') return new Promise<void>(() => {})
    if (path === `/api/v2/pod/pages/${baseID}`) {
      return route.fulfill({
        json: {
          actions: ['node_view'],
          role: 'view',
          ancestors: [],
          child_count: 1,
          page: {
            id: baseID,
            title: 'Regional sales',
            type: 'base',
            position: 'a0',
            revision: 1,
            inherit_permissions: true,
            created_at: '2026-11-13T00:00:00Z',
            updated_at: '2026-11-13T00:00:00Z'
          }
        }
      })
    }
    if (path === `/api/v2/pod/bases/${baseID}`) {
      return route.fulfill({ json: { base: { id: baseID, tables: [] }, tables: [] } })
    }
    if (path === `/api/v2/pod/pages/${baseID}/user-state`) return route.fulfill({ json: {} })
    if (path.endsWith('/pages/navigation')) return route.fulfill({ json: { path: [], directories: [] } })
    if (path === '/api/v2/pod/pages/children') {
      const listed = url.searchParams.get('parent_id') === baseID ? [child] : []
      return route.fulfill({
        json: {
          pages: listed,
          can_create_space: false,
          can_create_private: false,
          can_manage_space: false,
          next_cursor: null
        }
      })
    }
    if (path === '/api/v2/pod/pages') {
      return route.fulfill({
        json: {
          pages: [],
          can_create_space: false,
          can_create_private: false,
          can_manage_space: false,
          next_cursor: null
        }
      })
    }
    if (path.endsWith('/agents')) {
      return route.fulfill({ json: { agents: [], personalAssistant: null, personalAssistantAvailable: false } })
    }
    if (path.endsWith('/conversations')) return route.fulfill({ json: { conversations: [], nextCursor: null } })
    return route.fulfill({ json: [] })
  })

  await page.goto(pageRoute(baseID))
  const menu = page.getByRole('button', { name: 'Subpages', exact: true })
  await expect(menu).toBeVisible({ timeout: 20_000 })
  await page.waitForTimeout(500)
  expect(log.matching(new RegExp(`^GET /pages/children\\?parent_id=${baseID}&limit=200$`))).toEqual([])

  await menu.click()
  await expect(page.getByRole('link', { name: 'Regional detail' })).toBeVisible()
  expect(log.matching(new RegExp(`^GET /pages/children\\?parent_id=${baseID}&limit=200$`))).toHaveLength(1)
})
