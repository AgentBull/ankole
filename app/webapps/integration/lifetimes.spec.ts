import { expect, test, type Page, type Route } from '@playwright/test'
import type { ConversationDetail, PodActivity } from '../pod/api'
import { conversationRoute } from './pod-browser/routes'

const base = '/api/v2/pod'
const oldID = '00112233-4455-6677-8899-aabbccddeeff'
const agent = {
  uid: 'agent-one',
  displayName: 'Research Agent',
  active: true,
  type: 'agent' as const,
  mayIntervene: true
}
function detail(id = oldID, text = 'Existing history'): ConversationDetail {
  return {
    activities: [],
    pendingQueues: [
      {
        agentUID: agent.uid,
        inputs: [],
        paused: false,
        queueVersion: 'fixture-version',
        workStatus: { state: 'idle', retryAt: null }
      }
    ],
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
      agents: [{ ...agent, active: true, type: 'agent', mayIntervene: true }],
      participants: [
        { uid: 'person', displayName: 'Person', active: true, type: 'human', role: 'owner', mayIntervene: false },
        { ...agent, active: true, type: 'agent', mayIntervene: true }
      ],
      pageID: null,
      id,
      title: id === oldID ? 'Existing conversation' : 'Created conversation',
      agent: { ...agent, active: true },
      lastActivityAt: '2026-10-16T00:00:00Z'
    },
    messages: [
      {
        id: 'old-message',
        seq: 1,
        authorType: 'agent',
        authorDisplayName: 'Fixture author',
        authorArchived: false,
        mentions: [],
        savedPages: [],
        authorUID: agent.uid,
        kind: 'message',
        links: [],
        attachments: [],
        text,
        createdAt: '2026-10-16T00:00:00Z',
        replyToMessageID: null,
        signalID: null
      }
    ]
  }
}
async function pod(page: Page) {
  await page.addInitScript(() => {
    const streams: EventTarget[] = []
    Object.assign(window, { testStreams: streams })
    window.EventSource = class extends EventTarget {
      onopen = null
      onerror = null
      closed = false
      constructor(public url: string) {
        super()
        streams.push(this)
      }
      close() {
        this.closed = true
      }
    } as unknown as typeof EventSource
  })
  let saved: ConversationDetail | undefined
  let current = detail()
  let readError: { status: number; json: unknown } | undefined
  const writes: Route[] = []
  await page.route(`**${base}/**`, async route => {
    const path = new URL(route.request().url()).pathname
    if (route.request().method() === 'POST') {
      writes.push(route)
      return
    }
    if (path.endsWith('/agents')) return route.fulfill({ json: { agents: [agent] } })
    if (path.endsWith('/conversations')) {
      return route.fulfill({ json: { conversations: [detail().conversation, ...(saved ? [saved.conversation] : [])] } })
    }
    if (readError) return route.fulfill(readError)
    return route.fulfill({ json: path.endsWith(oldID) ? current : (saved ?? detail()) })
  })
  return {
    writes,
    setDetail: (next: ConversationDetail) => {
      current = next
    },
    failReads: (status: number, json: unknown) => {
      readError = { status, json }
    },
    async complete(index = 0) {
      const route = writes[index]!
      const body = route.request().postDataJSON().data
      saved = detail(body.conversationID ?? oldID, body.text)
      saved.messages[0] = { ...saved.messages[0]!, id: body.messageID, authorType: 'human' }
      await route.fulfill({ json: saved })
      return saved
    }
  }
}

test('a completed create updates the actual sidebar without replacing the conversation the user opened', async ({
  page
}) => {
  const server = await pod(page)
  await page.goto('/')
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('First message')
  await page.getByRole('button', { name: 'Send message', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  await page.getByRole('link', { name: 'Existing conversation', exact: true }).click()
  await expect(page.getByText('Existing history', { exact: true })).toBeVisible()
  await server.complete()
  await expect(page.getByRole('link', { name: 'Created conversation', exact: true })).toBeVisible()
  await expect(page).toHaveURL(url => url.pathname === conversationRoute(oldID))
  await expect(page.getByText('Existing history', { exact: true })).toBeVisible()
})

test('returning to a new page preserves its separate draft when the old create finishes', async ({ page }) => {
  const server = await pod(page)
  await page.goto('/')
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('First message')
  await page.getByRole('button', { name: 'Send message', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  await page.getByRole('link', { name: 'Existing conversation', exact: true }).click()
  await expect(page.getByText('Existing history', { exact: true })).toBeVisible()
  await page.getByRole('link', { name: 'New conversation', exact: true }).click()
  await expect(page.getByRole('heading', { level: 1, name: /What can we work on/ })).toBeVisible()
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('Separate draft')
  await server.complete()
  await expect(page.getByRole('link', { name: 'Created conversation', exact: true })).toBeVisible()
  await expect(page).toHaveURL(url => url.pathname === '/')
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveValue('Separate draft')
})

test('a create that stays on its page still navigates, and retry preserves the submitted IDs', async ({ page }) => {
  const server = await pod(page)
  await page.goto('/')
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('First message')
  await page.getByRole('button', { name: 'Send message', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  const original = server.writes[0]!.request().postDataJSON().data
  await server.writes[0]!.fulfill({ status: 503, json: { error: 'temporarily unavailable' } })
  await page.getByRole('button', { name: 'Retry sending', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(2)
  expect(server.writes[1]!.request().postDataJSON().data).toEqual(original)
  const saved = await server.complete(1)
  await expect(page).toHaveURL(url => url.pathname === conversationRoute(saved.conversation.id))
  await expect(page.getByText('First message', { exact: true })).toBeVisible()
})

test('a failed first create remains reachable from New and retries its original IDs without clearing the newer draft', async ({
  page
}) => {
  const server = await pod(page)
  await page.goto('/')
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('Recover this first create')
  await page.getByRole('button', { name: 'Send message', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  const original = server.writes[0]!.request().postDataJSON().data
  await page.getByRole('link', { name: 'Existing conversation', exact: true }).click()
  await page.getByRole('link', { name: 'New conversation', exact: true }).click()
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('Newer local draft')
  await server.writes[0]!.fulfill({ status: 503, json: { error: 'unavailable' } })
  const recovery = page.getByRole('region', { name: 'Retained chat text' })
  await expect(recovery.getByRole('textbox')).toHaveValue('Recover this first create')
  await recovery.getByRole('button', { name: 'Restore', exact: true }).click()
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveValue('Recover this first create')
  await page.getByRole('button', { name: 'Retry sending', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(2)
  expect(server.writes[1]!.request().postDataJSON().data).toMatchObject({
    conversationID: original.conversationID,
    messageID: original.messageID,
    text: original.text
  })
  await page.getByRole('link', { name: 'New conversation', exact: true }).click()
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveValue('Newer local draft')
  await server.complete(1)
  await expect(page.getByRole('link', { name: 'Created conversation', exact: true })).toBeVisible()
  await expect(page).toHaveURL(url => url.pathname === '/')
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveValue('Newer local draft')
})

async function providers(page: Page) {
  const writes: Route[] = []
  const pool = { strategy: 'fill_first', entries: [] }
  const provider = {
    provider_id: 'openai',
    provider_kind: 'openai',
    base_url: 'initial',
    connection_options: {},
    disabled_at: null,
    credential_pool: pool
  }
  const resource = (record: typeof provider) => ({
    id: record.provider_id,
    type: 'ai_gateway_provider',
    attributes: { ...record, provider_metadata: {} }
  })
  await page.route('**/api/v2/site/ai-gateway/provider-kinds', route =>
    route.fulfill({
      json: {
        provider_kinds: [
          { provider_kind: 'openai', label: { default: 'OpenAI' }, default_base_url: 'initial', settings: [] }
        ]
      }
    })
  )
  await page.route('**/api/v2/site/ai-gateway/providers**', async route => {
    const path = new URL(route.request().url()).pathname
    if (route.request().method() === 'PATCH') {
      writes.push(route)
      return
    }
    if (path.endsWith('/providers')) return route.fulfill({ json: { data: [resource(provider)] } })
    return route.fulfill({ json: { data: resource(provider) } })
  })
  return {
    writes,
    // The path names the saved provider; the body gives its attributes.
    complete: (index: number) =>
      writes[index]!.fulfill({
        json: {
          data: resource({
            ...provider,
            provider_id: decodeURIComponent(new URL(writes[index]!.request().url()).pathname.split('/').at(-1)!),
            base_url: writes[index]!.request().postDataJSON().data.attributes.base_url
          })
        }
      })
  }
}

test('Provider save acknowledges only sent input, then a clean new-provider save still navigates', async ({ page }) => {
  const server = await providers(page)
  await page.goto('/providers/new')
  const input = page.getByRole('textbox', { name: 'Base URL', exact: true })
  await input.fill('https://sent-a.test')
  await page.getByRole('button', { name: 'Save', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  await input.fill('https://unsent-b.test')
  await server.complete(0)
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible()
  await expect(input).toHaveValue('https://unsent-b.test')
  await expect(page).toHaveURL(/\/providers\/new$/)
  await page.getByRole('button', { name: 'Save', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(2)
  expect(server.writes[1]!.request().postDataJSON().data.attributes.base_url).toBe('https://unsent-b.test')
  await server.complete(1)
  await expect(page).toHaveURL(/\/providers\/openai-2$/)
  await expect(page.getByText('Unsaved changes', { exact: true })).not.toBeVisible()
})

async function streamEvent(page: Page, event = 'conversation') {
  await page.evaluate(event => {
    const streams = (window as unknown as { testStreams: EventTarget[] }).testStreams
    streams.at(-1)!.dispatchEvent(new MessageEvent(event))
  }, event)
}

test('SSE confirmation keeps POST pending and a late failure does not revive the confirmed send', async ({ page }) => {
  const server = await pod(page)
  await page.goto(conversationRoute(oldID))
  await expect(page.getByText('Existing history', { exact: true })).toBeVisible()
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('Already committed')
  await page.getByRole('button', { name: 'Send message', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  const body = server.writes[0]!.request().postDataJSON().data
  const snapshot = detail(oldID, 'Already committed')
  snapshot.messages[0] = { ...snapshot.messages[0]!, id: body.messageID, authorType: 'human' }
  server.setDetail(snapshot)
  await streamEvent(page)
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveValue('')
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeDisabled()
  await expect(page.getByText('Already committed', { exact: true })).toBeVisible()
  await server.writes[0]!.fulfill({ status: 503, json: { error: 'lost acknowledgement' } })
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled()
  await expect(page.getByText('Send not confirmed', { exact: true })).not.toBeVisible()
  expect(server.writes).toHaveLength(1)
})

test('a late POST failure after reopening cannot fail the newer send or change its retry IDs', async ({ page }) => {
  const server = await pod(page)
  await page.goto(conversationRoute(oldID))
  await expect(page.getByText('Existing history', { exact: true })).toBeVisible()
  const composer = page.getByRole('textbox', { name: 'Message', exact: true })
  await composer.fill('Same text')
  await page.getByRole('button', { name: 'Send message', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  const first = server.writes[0]!.request().postDataJSON().data
  const snapshot = detail(oldID, first.text)
  snapshot.messages[0] = { ...snapshot.messages[0]!, id: first.messageID, authorType: 'human' }
  server.setDetail(snapshot)
  await page.getByRole('link', { name: 'New conversation', exact: true }).click()
  await expect(page.getByRole('heading', { level: 1, name: /What can we work on/ })).toBeVisible()
  await page.getByRole('link', { name: 'Existing conversation', exact: true }).click()
  await streamEvent(page)
  await expect(page.getByText('Same text', { exact: true })).toBeVisible()
  await expect(composer).toHaveValue('')
  await composer.fill('Same text')
  await page.getByRole('button', { name: 'Send message', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(2)
  const second = server.writes[1]!.request().postDataJSON().data
  expect(second.messageID).not.toBe(first.messageID)
  await server.writes[0]!.fulfill({ status: 503, json: { error: 'lost first acknowledgement' } })
  await expect(composer).toBeDisabled()
  await expect(composer).toHaveValue(second.text)
  await expect(page.getByRole('button', { name: 'Retry sending', exact: true })).not.toBeVisible()
  await server.writes[1]!.fulfill({ status: 503, json: { error: 'lost second acknowledgement' } })
  await page.getByRole('button', { name: 'Retry sending', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(3)
  expect(server.writes[2]!.request().postDataJSON().data).toEqual(second)
})

test('a precise GET gone response hides history and composer and closes the mounted stream', async ({ page }) => {
  const server = await pod(page)
  await page.goto(conversationRoute(oldID))
  await expect(page.getByText('Existing history', { exact: true })).toBeVisible()
  server.failReads(404, { error: { code: 'conversation_not_found', message: 'Conversation not found' } })
  await streamEvent(page)
  await expect(
    page.getByText('This conversation is unavailable or you do not have access.', { exact: true })
  ).toBeVisible()
  await expect(page.getByText('Existing history', { exact: true })).not.toBeVisible()
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveCount(0)
  await expect
    .poll(() =>
      page.evaluate(() =>
        (window as unknown as { testStreams: { closed: boolean }[] }).testStreams.every(stream => stream.closed)
      )
    )
    .toBe(true)
})

test('an independent POST gone response closes the stream even while detail remains cached', async ({ page }) => {
  const server = await pod(page)
  await page.goto(conversationRoute(oldID))
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('No longer allowed')
  await page.getByRole('button', { name: 'Send message', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  await server.writes[0]!.fulfill({
    status: 404,
    json: { error: { code: 'conversation_not_found', message: 'Conversation not found' } }
  })
  await expect(
    page.getByText('This conversation is unavailable or you do not have access.', { exact: true })
  ).toBeVisible()
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveCount(0)
  await expect
    .poll(() =>
      page.evaluate(() =>
        (window as unknown as { testStreams: { closed: boolean }[] }).testStreams.every(stream => stream.closed)
      )
    )
    .toBe(true)
})

test('Provider completion from an old visit cannot navigate or clear a new visit', async ({ page }) => {
  const server = await providers(page)
  await page.goto('/providers/new')
  await page.getByRole('textbox', { name: 'Base URL', exact: true }).fill('https://old-visit.test')
  await page.getByRole('button', { name: 'Save', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  await page.getByRole('link', { name: 'Back', exact: true }).click()
  await expect(page).toHaveURL(/\/providers$/)
  await page.getByRole('link', { name: 'New provider', exact: true }).click()
  await expect(page).toHaveURL(/\/providers\/new$/)
  await page.getByRole('textbox', { name: 'Base URL', exact: true }).fill('https://new-visit.test')
  await server.complete(0)
  await expect(page.getByRole('textbox', { name: 'Base URL', exact: true })).toHaveValue('https://new-visit.test')
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible()
  await expect(page).toHaveURL(/\/providers\/new$/)
})

test('current activity survives reconnect snapshots, clears at completion, and never reloads history per update', async ({
  page
}) => {
  const server = await pod(page)
  let reads = 0
  page.on('request', request => {
    if (request.method() === 'GET' && new URL(request.url()).pathname === `${base}/conversations/${oldID}`) reads++
  })
  await page.goto(conversationRoute(oldID))
  await expect(page.getByText('Existing history', { exact: true })).toBeVisible()
  const emit = (snapshot: Record<string, unknown>) =>
    page.evaluate(value => {
      const stream = (window as unknown as { testStreams: EventSource[] }).testStreams.at(-1)!
      stream.dispatchEvent(new MessageEvent('activity', { data: JSON.stringify(value) }))
    }, snapshot)
  const snapshot: PodActivity = {
    conversationID: oldID,
    agentUID: agent.uid,
    sessionID: `conversation:${oldID}`,
    signalID: 'signal-one',
    responseID: 'response-one',
    epoch: 1,
    revision: 1,
    state: 'active',
    phase: { operation_id: 'turn', label: 'Waiting for computer capacity' },
    tools: []
  }
  server.setDetail({
    ...detail(),
    activities: [snapshot]
  })
  const before = reads
  await emit(snapshot)
  await expect(page.getByText('Waiting for computer capacity', { exact: true })).toBeVisible()
  await page.evaluate(() => {
    const stream = (window as unknown as { testStreams: EventSource[] }).testStreams.at(-1)!
    stream.onerror?.call(stream, new Event('error'))
  })
  await expect(page.getByText('Waiting for computer capacity', { exact: true })).not.toBeVisible()
  await page.evaluate(() => {
    const stream = (window as unknown as { testStreams: EventSource[] }).testStreams.at(-1)!
    stream.onopen?.call(stream, new Event('open'))
  })
  await emit(snapshot)
  await expect(page.getByText('Waiting for computer capacity', { exact: true })).toBeVisible()
  const afterReconnect = reads
  await emit({ ...snapshot, state: 'unavailable', phase: null, tools: [] })
  await emit(snapshot)
  await expect(page.getByText('Waiting for computer capacity', { exact: true })).not.toBeVisible()
  await emit({
    ...snapshot,
    revision: 2,
    phase: null,
    tools: [
      { operation_id: 'read', label: 'Reading the report' },
      { operation_id: 'search', label: 'Searching source material' }
    ]
  })
  await expect(page.getByText('Reading the report', { exact: true })).toBeVisible()
  await expect(page.getByText('Searching source material', { exact: true })).toBeVisible()
  await emit({ ...snapshot, revision: 3, state: 'settled', phase: null })
  await emit({ ...snapshot, revision: 99 })
  await expect(page.getByText('Waiting for computer capacity', { exact: true })).not.toBeVisible()
  await expect(page.getByText('Reading the report', { exact: true })).not.toBeVisible()
  expect(reads).toBe(afterReconnect)
  // Disconnect and reconnect each refresh once; activity frames never do.
  expect(afterReconnect - before).toBeLessThanOrEqual(2)
})

test('an in-flight detail cannot restore unavailable activity, while a fresh reconnect snapshot can', async ({
  page
}) => {
  const server = await pod(page)
  const snapshot: PodActivity = {
    conversationID: oldID,
    agentUID: agent.uid,
    sessionID: `conversation:${oldID}`,
    signalID: 'signal-one',
    responseID: 'response-one',
    epoch: 1,
    revision: 7,
    state: 'active',
    phase: { operation_id: 'turn', label: 'Still waiting for computer capacity' },
    tools: []
  }
  server.setDetail({ ...detail(), activities: [snapshot] })
  await page.goto(conversationRoute(oldID))
  await expect(page.getByText('Still waiting for computer capacity', { exact: true })).toBeVisible()
  let held: Route | undefined
  const hold = (route: Route) => {
    held = route
  }
  const detailURL = (url: URL) => url.pathname === `${base}/conversations/${oldID}`
  await page.route(detailURL, hold)
  await page.evaluate(() => {
    const stream = (window as unknown as { testStreams: EventSource[] }).testStreams.at(-1)!
    stream.onerror?.call(stream, new Event('error'))
  })
  await expect.poll(() => !!held).toBe(true)
  // The live unavailable frame invalidates the GET already in flight.
  await page.evaluate(
    value => {
      const stream = (window as unknown as { testStreams: EventSource[] }).testStreams.at(-1)!
      stream.dispatchEvent(new MessageEvent('activity', { data: JSON.stringify(value) }))
    },
    { ...snapshot, state: 'unavailable', phase: null, tools: [] }
  )
  await held!.fulfill({ json: { ...detail(), activities: [snapshot] } })
  await expect(page.getByText('Still waiting for computer capacity', { exact: true })).not.toBeVisible()
  await page.unroute(detailURL, hold)
  await page.evaluate(value => {
    const stream = (window as unknown as { testStreams: EventSource[] }).testStreams.at(-1)!
    stream.onopen?.call(stream, new Event('open'))
    stream.dispatchEvent(new MessageEvent('activity', { data: JSON.stringify(value) }))
  }, snapshot)
  await expect(page.getByText('Still waiting for computer capacity', { exact: true })).toBeVisible()
})
