import { expect, test, type Page, type WebSocketRoute } from '@playwright/test'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import type { ConversationDetail } from '../pod/api'
import { conversationRoute } from './pod-browser/routes'

type Recorded = { title: string; body?: string; tag?: string; requireInteraction?: boolean }

const room = {
  id: '00112233-4455-6677-8899-aabbccddeeff',
  title: 'Quarterly report',
  accessScope: 'participants',
  canDelete: true,
  canManage: true,
  roomMode: 'group',
  conversationKind: 'group',
  titleCustomized: true,
  createdBy: 'person',
  lastMessageSeq: 3,
  lastNotifiableSeq: 3,
  lastActivityAt: '2026-11-17T00:00:00Z',
  latestMessagePreview: 'Draft is ready',
  rowStatus: 'streaming',
  viewer: { uid: 'person', pinned: false, muted: false, lastReadSeq: 2 },
  agents: [{ uid: 'researcher', displayName: 'Researcher', active: true, type: 'agent', mayIntervene: false }],
  participants: []
} satisfies ConversationDetail['conversation'] & { latestMessagePreview: string }

/** Records notifications instead of showing them, with the permission the test chooses. */
async function fakeNotifications(page: Page, permission: NotificationPermission) {
  await page.addInitScript(initial => {
    const shown: unknown[] = []
    let current = initial
    Object.assign(window, { __notifications: shown })
    class RecordedNotification {
      onclick: (() => void) | null = null
      static get permission() {
        return current
      }
      static async requestPermission() {
        current = 'granted'
        return current
      }
      constructor(title: string, options: NotificationOptions = {}) {
        shown.push({ title, ...options })
      }
      close() {}
    }
    Object.defineProperty(window, 'Notification', { value: RecordedNotification, configurable: true })
  }, permission)
}

/** Answers the Phoenix joins of the Pod socket and lets the test push `content` events. */
async function fakeSocket(page: Page) {
  let socket: WebSocketRoute | undefined
  let joined: () => void
  const ready = new Promise<void>(resolve => (joined = resolve))
  await page.routeWebSocket(/\/pod\/socket/, ws => {
    socket = ws
    ws.onMessage(message => {
      const [joinRef, ref, topic, event] = JSON.parse(String(message)) as [string, string, string, string]
      if (event === 'phx_join' || event === 'heartbeat') {
        ws.send(JSON.stringify([joinRef, ref, topic, 'phx_reply', { status: 'ok', response: {} }]))
        if (topic === 'content') joined()
      }
    })
  })
  return {
    ready,
    push: (event: string) => socket!.send(JSON.stringify([null, null, 'content', event, {}]))
  }
}

async function podRoutes(page: Page, attention: () => unknown[], detail?: ConversationDetail) {
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
  await page.route('**/api/v2/pod/**', route => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/realtime-token')) return route.fulfill({ json: { token: 't', principal: { uid: 'person' } } })
    if (path.endsWith('/agents')) return route.fulfill({ json: { agents: [], personalAssistantAvailable: false } })
    if (path.endsWith('/conversations/attention')) return route.fulfill({ json: attention() })
    if (path.endsWith('/conversations')) return route.fulfill({ json: { conversations: [], nextCursor: null } })
    if (path.endsWith('/events')) return route.fulfill({ contentType: 'text/event-stream', body: ': connected\n\n' })
    if (path.endsWith('/runner-devices')) return route.fulfill({ json: { colleagues: [], devices: [] } })
    if (path.endsWith('/me')) {
      return route.fulfill({ json: { uid: 'person', displayName: 'Person', credentials: [], managed: false } })
    }
    if (detail && path.includes('/conversations/')) return route.fulfill({ json: detail })
    return route.fulfill({ json: [] })
  })
}

test('an Agent reply that arrives in another tab notifies once and badges the title', async ({ page }) => {
  await fakeNotifications(page, 'granted')
  const socket = await fakeSocket(page)
  let rows: unknown[] = [room]
  await podRoutes(page, () => rows)
  await page.goto('/')
  await socket.ready
  // The join refreshes every list, so the first snapshot lands only once those reads finish.
  await page.waitForLoadState('networkidle')
  await page.waitForTimeout(500)

  rows = [{ ...room, rowStatus: 'unread', lastMessageSeq: 4, lastNotifiableSeq: 4 }]
  socket.push('conversations_changed')
  await expect
    .poll(() => page.evaluate(() => (window as unknown as { __notifications: Recorded[] }).__notifications))
    .toEqual([expect.objectContaining({ title: 'Quarterly report', body: 'Draft is ready', tag: room.id }) as Recorded])
  await expect.poll(() => page.title()).toMatch(/^\(1\) /)

  // A process card that keeps the room unread does not notify again.
  rows = [{ ...room, rowStatus: 'unread', lastMessageSeq: 5, lastNotifiableSeq: 4 }]
  socket.push('conversations_changed')
  await page.waitForTimeout(2500)
  expect(
    await page.evaluate(() => (window as unknown as { __notifications: Recorded[] }).__notifications)
  ).toHaveLength(1)

  // A decision notifies and stays until the Human handles it.
  rows = [{ ...room, rowStatus: 'waiting_choice', lastMessageSeq: 6, lastNotifiableSeq: 6 }]
  socket.push('conversations_changed')
  await expect
    .poll(() => page.evaluate(() => (window as unknown as { __notifications: Recorded[] }).__notifications.at(-1)))
    .toEqual(expect.objectContaining({ tag: room.id, requireInteraction: true }) as Recorded)
})

test('the composer offers notifications until the Human turns them on', async ({ page }, testInfo) => {
  await fakeNotifications(page, 'default')
  await fakeSocket(page)
  const detail: ConversationDetail = {
    conversation: { ...room, rowStatus: 'idle' },
    messages: [],
    activities: [],
    pendingInteractions: [],
    pendingQueues: [],
    linkedRuns: [],
    artifacts: { pageIDs: [], attachments: [] },
    editableInputs: [],
    removedMessageIDs: [],
    olderMessagesBeforeSeq: null,
    messageRange: { firstSeq: 0, lastSeq: 0 }
  }
  await podRoutes(page, () => [], detail)
  await page.goto(conversationRoute(room.id))
  const offer = page.getByText('Get notified when Agents reply or need your input.')
  await expect(offer).toBeVisible()
  await page.locator('.pod-chat-composer-dock').screenshot({ path: testInfo.outputPath('notification-prompt.png') })
  await page.getByRole('button', { name: 'Turn on', exact: true }).click()
  await expect(offer).toBeHidden()
})

test('personal settings switch this device on and send a test notification', async ({ page }, testInfo) => {
  await fakeNotifications(page, 'granted')
  await fakeSocket(page)
  await podRoutes(page, () => [])
  await page.goto('/me?section=notifications')
  const toggle = page.getByRole('switch', { name: 'Notify me on this device' })
  await expect(toggle).toBeChecked()
  await page.getByRole('button', { name: 'Send a test notification' }).click()
  await expect
    .poll(() => page.evaluate(() => (window as unknown as { __notifications: Recorded[] }).__notifications.length))
    .toBe(1)
  await page.screenshot({ path: testInfo.outputPath('notification-settings.png') })
  await toggle.click()
  await expect(toggle).not.toBeChecked()
  await expect(page.getByRole('button', { name: 'Send a test notification' })).toBeHidden()
})
