import { expect, test, type Page, type Route } from '@playwright/test'
import type { ConversationDetail } from '../pod/api'

const base = '/.internal-apis/pod'
const oldID = 'existing-conversation'
const agent = { uid: 'agent-one', displayName: 'Research Agent' }
function detail(id = oldID, text = 'Existing history'): ConversationDetail {
  return {
    conversation: {
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
        authorUID: agent.uid,
        kind: 'message',
        text,
        createdAt: '2026-10-16T00:00:00Z',
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
      const body = route.request().postDataJSON()
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
  await page.goto('/pod')
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('First message')
  await page.getByRole('button', { name: 'Send message', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  await page.getByRole('link', { name: 'Existing conversation', exact: true }).click()
  await expect(page.getByText('Existing history', { exact: true })).toBeVisible()
  await server.complete()
  await expect(page.getByRole('link', { name: 'Created conversation', exact: true })).toBeVisible()
  await expect(page).toHaveURL(new RegExp(`/pod/conversations/${oldID}$`))
  await expect(page.getByText('Existing history', { exact: true })).toBeVisible()
})

test('returning to a new page preserves its separate draft when the old create finishes', async ({ page }) => {
  const server = await pod(page)
  await page.goto('/pod')
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('First message')
  await page.getByRole('button', { name: 'Send message', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  await page.getByRole('link', { name: 'Existing conversation', exact: true }).click()
  await expect(page.getByText('Existing history', { exact: true })).toBeVisible()
  await page.getByRole('link', { name: 'New conversation', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Start a conversation', exact: true })).toBeVisible()
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('Separate draft')
  await server.complete()
  await expect(page.getByRole('link', { name: 'Created conversation', exact: true })).toBeVisible()
  await expect(page).toHaveURL(/\/pod\/?$/)
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveValue('Separate draft')
})

test('a create that stays on its page still navigates, and retry preserves the submitted IDs', async ({ page }) => {
  const server = await pod(page)
  await page.goto('/pod')
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('First message')
  await page.getByRole('button', { name: 'Send message', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  const original = server.writes[0]!.request().postDataJSON()
  await server.writes[0]!.fulfill({ status: 503, json: { error: 'temporarily unavailable' } })
  await page.getByRole('button', { name: 'Retry sending', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(2)
  expect(server.writes[1]!.request().postDataJSON()).toEqual(original)
  const saved = await server.complete(1)
  await expect(page).toHaveURL(new RegExp(`/pod/conversations/${saved.conversation.id}$`))
  await expect(page.getByText('First message', { exact: true })).toBeVisible()
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
  await page.route('**/api/v1/site/ai-gateway/**', async route => {
    const path = new URL(route.request().url()).pathname
    if (route.request().method() === 'PUT') {
      writes.push(route)
      return
    }
    if (path.endsWith('/provider-kinds')) {
      return route.fulfill({
        json: {
          provider_kinds: [
            { provider_kind: 'openai', label: { default: 'OpenAI' }, default_base_url: 'initial', settings: [] }
          ]
        }
      })
    }
    if (path.endsWith('/providers')) return route.fulfill({ json: { ai_gateway_providers: [provider] } })
    return route.fulfill({ json: { ai_gateway_provider: provider } })
  })
  return {
    writes,
    complete: (index: number) =>
      writes[index]!.fulfill({
        json: {
          ai_gateway_provider: {
            ...provider,
            provider_id: writes[index]!.request().postDataJSON().provider_id,
            base_url: writes[index]!.request().postDataJSON().base_url
          }
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
  expect(server.writes[1]!.request().postDataJSON().base_url).toBe('https://unsent-b.test')
  await server.complete(1)
  await expect(page).toHaveURL(/\/providers\/openai-2$/)
  await expect(page.getByText('Unsaved changes', { exact: true })).not.toBeVisible()
})

async function streamEvent(page: Page, event = 'message') {
  await page.evaluate(event => {
    const streams = (window as unknown as { testStreams: EventTarget[] }).testStreams
    streams.at(-1)!.dispatchEvent(new MessageEvent(event))
  }, event)
}

test('SSE confirmation keeps POST pending and a late failure does not revive the confirmed send', async ({ page }) => {
  const server = await pod(page)
  await page.goto(`/pod/conversations/${oldID}`)
  await expect(page.getByText('Existing history', { exact: true })).toBeVisible()
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('Already committed')
  await page.getByRole('button', { name: 'Send message', exact: true }).click()
  await expect.poll(() => server.writes.length).toBe(1)
  const body = server.writes[0]!.request().postDataJSON()
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

test('a precise GET gone response hides history and composer and closes the mounted stream', async ({ page }) => {
  const server = await pod(page)
  await page.goto(`/pod/conversations/${oldID}`)
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
  await page.goto(`/pod/conversations/${oldID}`)
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
  await page.goto(`/pod/conversations/${oldID}`)
  await expect(page.getByText('Existing history', { exact: true })).toBeVisible()
  const emit = (snapshot: Record<string, unknown>) =>
    page.evaluate(value => {
      const stream = (window as unknown as { testStreams: EventSource[] }).testStreams.at(-1)!
      stream.dispatchEvent(new MessageEvent('activity', { data: JSON.stringify(value) }))
    }, snapshot)
  const snapshot = {
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
    status: { ...detail().status, activity: snapshot as ConversationDetail['status']['activity'] }
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
  const snapshot: ConversationDetail['status']['activity'] = {
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
  server.setDetail({ ...detail(), status: { ...detail().status, activity: snapshot } })
  await page.goto(`/pod/conversations/${oldID}`)
  await expect(page.getByText('Still waiting for computer capacity', { exact: true })).toBeVisible()
  let held: Route | undefined
  const hold = (route: Route) => {
    held = route
  }
  await page.route(`**${base}/conversations/${oldID}`, hold)
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
  await held!.fulfill({ json: { ...detail(), status: { ...detail().status, activity: snapshot } } })
  await expect(page.getByText('Still waiting for computer capacity', { exact: true })).not.toBeVisible()
  await page.unroute(`**${base}/conversations/${oldID}`, hold)
  await page.evaluate(value => {
    const stream = (window as unknown as { testStreams: EventSource[] }).testStreams.at(-1)!
    stream.onopen?.call(stream, new Event('open'))
    stream.dispatchEvent(new MessageEvent('activity', { data: JSON.stringify(value) }))
  }, snapshot)
  await expect(page.getByText('Still waiting for computer capacity', { exact: true })).toBeVisible()
})
