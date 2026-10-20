import { state } from './fixtures'
import { pageRoute, conversationRoute } from './routes'
import { mkdirSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { expect, test, type CDPSession, type Page } from '@playwright/test'
import type { ConversationDetail, Conversations } from '../../common/api/generated/types.gen'

const outputDirectory = process.env.POD_PERFORMANCE_OUTPUT
const scenario = process.env.POD_PERFORMANCE_SCENARIO ?? 'load'
if (!['load', 'early-input', 'without-cn-font'].includes(scenario)) {
  throw new Error(`Unknown performance scenario: ${scenario}`)
}

const profiles = [
  { name: 'desktop', viewport: { width: 1440, height: 900 }, mobile: false, cpu: 1, latency: 40, mbps: 10 },
  { name: 'mobile', viewport: { width: 390, height: 844 }, mobile: true, cpu: 4, latency: 150, mbps: 1.6 }
] as const

type Resource = {
  url: string
  type: string
  status?: number
  mimeType?: string
  contentType?: string
  contentEncoding?: string
  cacheControl?: string
  encodedBytes?: number
  diskCache?: boolean
  serviceWorker?: boolean
  servedFromCache?: boolean
  failure?: string
}

async function podRequest<T = unknown>(page: Page, resource: string, method = 'GET', body?: unknown): Promise<T> {
  return page.evaluate(
    async ({ resource, method, body }) => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content
      const response = await fetch(`/.internal-apis/pod${resource}`, {
        method,
        headers: {
          'content-type': 'application/json',
          'x-ankole-authentication': meta('ankole-authentication')!,
          'x-ankole-pod': meta('ankole-pod')!,
          'x-csrf-token': meta('csrf-token')!
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      })
      if (!response.ok) throw new Error(`Performance fixture ${method} ${resource}: ${response.status}`)
      return response.status === 204 ? null : response.json()
    },
    { resource, method, body }
  )
}

async function instrument(page: Page, cdp: CDPSession, profile: (typeof profiles)[number]) {
  const resources = new Map<string, Resource>()
  cdp.on('Network.requestWillBeSent', event => {
    const url = new URL(event.request.url)
    resources.set(event.requestId, {
      url: url.origin === state.base_url ? url.pathname : url.origin + url.pathname,
      type: event.type ?? 'Other'
    })
  })
  cdp.on('Network.responseReceived', event => {
    const header = (name: string) =>
      Object.entries(event.response.headers).find(([key]) => key.toLowerCase() === name)?.[1]
    Object.assign(resources.get(event.requestId) ?? {}, {
      status: event.response.status,
      mimeType: event.response.mimeType,
      contentType: header('content-type'),
      contentEncoding: header('content-encoding'),
      cacheControl: header('cache-control'),
      diskCache: event.response.fromDiskCache ?? false,
      serviceWorker: event.response.fromServiceWorker ?? false
    })
  })
  cdp.on('Network.loadingFinished', event => {
    const resource = resources.get(event.requestId)
    if (resource) resource.encodedBytes = event.encodedDataLength
  })
  cdp.on('Network.requestServedFromCache', event => {
    const resource = resources.get(event.requestId)
    if (resource) resource.servedFromCache = true
  })
  cdp.on('Network.loadingFailed', event => {
    const resource = resources.get(event.requestId)
    if (resource) resource.failure = event.errorText
  })
  await cdp.send('Network.enable')
  await cdp.send('Network.clearBrowserCache')
  await cdp.send('Network.setCacheDisabled', { cacheDisabled: true })
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: profile.cpu })
  await cdp.send('Network.emulateNetworkConditions', {
    offline: false,
    latency: profile.latency,
    downloadThroughput: (profile.mbps * 1_000_000) / 8,
    uploadThroughput: 750_000 / 8,
    connectionType: profile.mobile ? 'cellular4g' : 'wifi'
  })
  await page.addInitScript(() => {
    const metrics = {
      cls: 0,
      shifts: [] as { value: number; startTime: number; recentInput: boolean }[],
      lcp: [] as { startTime: number; size: number; tag: string; id: string }[],
      events: [] as {
        name: string
        startTime: number
        duration: number
        inputDelay: number
        processingTime: number
        interactionID: number
      }[],
      longTasks: [] as { startTime: number; duration: number }[]
    }
    Object.assign(window, { __podPerformance: metrics })
    let sessionStart = 0,
      sessionLast = 0,
      sessionValue = 0
    new PerformanceObserver(list => {
      for (const raw of list.getEntries()) {
        const entry = raw as PerformanceEntry & { value: number; hadRecentInput: boolean }
        metrics.shifts.push({ value: entry.value, startTime: entry.startTime, recentInput: entry.hadRecentInput })
        if (entry.hadRecentInput) continue
        if (entry.startTime - sessionLast < 1000 && entry.startTime - sessionStart < 5000) {
          sessionValue += entry.value
        } else {
          sessionStart = entry.startTime
          sessionValue = entry.value
        }
        sessionLast = entry.startTime
        metrics.cls = Math.max(metrics.cls, sessionValue)
      }
    }).observe({ type: 'layout-shift', buffered: true })
    new PerformanceObserver(list => {
      for (const raw of list.getEntries()) {
        const entry = raw as PerformanceEntry & { size: number; element?: Element }
        metrics.lcp.push({
          startTime: entry.startTime,
          size: entry.size,
          tag: entry.element?.tagName ?? '',
          id: entry.element?.id ?? ''
        })
      }
    }).observe({ type: 'largest-contentful-paint', buffered: true })
    new PerformanceObserver(list => {
      for (const raw of list.getEntries()) {
        const entry = raw as PerformanceEntry & {
          interactionId: number
          processingStart: number
          processingEnd: number
        }
        if (!entry.interactionId) continue
        metrics.events.push({
          name: entry.name,
          startTime: entry.startTime,
          duration: entry.duration,
          inputDelay: entry.processingStart - entry.startTime,
          processingTime: entry.processingEnd - entry.processingStart,
          interactionID: entry.interactionId
        })
      }
    }).observe({ type: 'event', buffered: true, durationThreshold: 16 } as PerformanceObserverInit)
    new PerformanceObserver(list => {
      for (const entry of list.getEntries()) {
        metrics.longTasks.push({ startTime: entry.startTime, duration: entry.duration })
      }
    }).observe({ type: 'longtask', buffered: true })
  })
  return resources
}

async function snapshot(page: Page) {
  return page.evaluate(() => {
    const metrics = (window as Window & { __podPerformance?: unknown }).__podPerformance
    return {
      metrics,
      now: performance.now(),
      navigation: performance.getEntriesByType('navigation').map(entry => entry.toJSON()),
      paints: performance.getEntriesByType('paint').map(entry => entry.toJSON()),
      resources: performance.getEntriesByType('resource').map(raw => {
        const entry = raw as PerformanceResourceTiming
        const url = new URL(entry.name)
        return {
          url: url.origin === location.origin ? url.pathname : url.origin + url.pathname,
          startTime: entry.startTime,
          responseEnd: entry.responseEnd,
          transferSize: entry.transferSize,
          encodedBodySize: entry.encodedBodySize,
          decodedBodySize: entry.decodedBodySize,
          initiatorType: entry.initiatorType
        }
      }),
      fontStatus: document.fonts.status,
      fontFamilies: [...document.fonts].map(font => ({ family: font.family, status: font.status })),
      bodyFontFamily: getComputedStyle(document.body).fontFamily
    }
  })
}

test.describe('Pod laboratory performance measurement', () => {
  test.skip(!outputDirectory, 'Set POD_PERFORMANCE_OUTPUT to collect cold-browser performance evidence')
  test.describe.configure({ mode: 'serial' })
  let documentID = ''
  let conversationID = ''
  let conversationFixture: { selection: string; id: string; pageBound: boolean; messageCount: number } | undefined

  test.beforeAll(async ({ browser }) => {
    if (!outputDirectory) return
    mkdirSync(outputDirectory, { recursive: true })
    const context = await browser.newContext()
    await context.addCookies(state.owner.cookies)
    const page = await context.newPage()
    try {
      await page.goto(`${state.base_url}/`)
      const { conversations } = await podRequest<Conversations>(page, '/conversations')
      const candidates = conversations
        .filter(conversation => conversation.agent.uid === state.agent_uid && conversation.agent.active)
        .sort((a, b) => a.lastActivityAt.localeCompare(b.lastActivityAt) || a.id.localeCompare(b.id))
      const conversation =
        candidates.find(candidate => candidate.id === state.conversation_id) ??
        candidates.find(candidate => candidate.pageID === null) ??
        candidates[0]
      if (conversation) {
        const detail = await podRequest<ConversationDetail>(page, `/conversations/${conversation.id}`)
        expect(detail.messages.length, 'Measure an existing conversation with history').toBeGreaterThan(0)
        conversationID = conversation.id
        conversationFixture = {
          selection:
            conversationID === state.conversation_id
              ? 'seed conversation'
              : 'oldest remaining conversation for the fixture Agent, preferring standalone',
          id: conversationID,
          pageBound: conversation.pageID !== null,
          messageCount: detail.messages.length
        }
      }
      const created = await podRequest<{ page: { id: string } }>(page, '/pages', 'POST', {
        type: 'doc',
        title: 'Performance probe',
        private_owner_uid: state.owner.uid
      })
      documentID = created.page.id
      await podRequest(page, `/pages/${documentID}/content`, 'PUT', {
        base_revision: 0,
        xml: '<page><p>性能基准文档。人类和 Agent 可以在 Pod 中持续编辑页面。</p><p>这是一份短中文文档，用于检查冷启动、字体交换和编辑响应。</p></page>'
      })
    } finally {
      await context.close()
    }
  })

  test.afterAll(async ({ browser }) => {
    if (!documentID) return
    const context = await browser.newContext()
    await context.addCookies(state.owner.cookies)
    const page = await context.newPage()
    try {
      await page.goto(`${state.base_url}/`)
      await podRequest(page, `/pages/${documentID}`, 'DELETE')
    } finally {
      await context.close()
    }
  })

  for (const profile of profiles) {
    for (const route of ['page', 'chat'] as const) {
      test(`${profile.name} cold ${route}`, async ({ browser }) => {
        test.setTimeout(180_000)
        const context = await browser.newContext({
          viewport: profile.viewport,
          isMobile: profile.mobile,
          hasTouch: profile.mobile,
          deviceScaleFactor: profile.mobile ? 3 : 1,
          serviceWorkers: 'block'
        })
        await context.addCookies(state.owner.cookies)
        const page = await context.newPage()
        if (scenario === 'without-cn-font') {
          await page.route('**/assets/fonts/IBMPlexSansCN*.woff2', route => route.abort('failed'))
        }
        const errors: string[] = []
        page.on('pageerror', error => errors.push(error.message))
        const cdp = await context.newCDPSession(page)
        const requests = await instrument(page, cdp, profile)
        try {
          if (route === 'chat' && !conversationID) {
            throw new Error('Performance fixture needs an existing conversation with history for its Agent')
          }
          const resourceID = route === 'page' ? documentID : conversationID
          await page.goto(
            `${state.base_url}${route === 'page' ? pageRoute(resourceID) : conversationRoute(resourceID)}`,
            { waitUntil: 'domcontentloaded' }
          )
          const editable =
            route === 'page'
              ? page.locator('.editor-content')
              : page.getByRole('textbox', { name: '消息', exact: true })
          await expect(editable).toBeVisible({ timeout: 90_000 })
          const usableAt = await page.evaluate(() => performance.now())
          if (scenario !== 'early-input') {
            await page.evaluate(() => document.fonts.ready)
            await page.waitForLoadState('networkidle', { timeout: 90_000 })
          }
          const initial = await snapshot(page)
          const initialRequestIDs = [...requests.keys()]
          const actions: { name: string; startTime: number; readyAt: number; endTime: number }[] = []
          const action = async (name: string, run: () => Promise<unknown>) => {
            const startTime = await page.evaluate(() => performance.now())
            await run()
            const readyAt = await page.evaluate(() => performance.now())
            await page.waitForTimeout(250)
            actions.push({ name, startTime, readyAt, endTime: await page.evaluate(() => performance.now()) })
          }
          await action('focus editor', () => editable.click())
          if (route === 'page') {
            await page.keyboard.press('ControlOrMeta+End')
            await action('type character', () => page.keyboard.type('x'))
            await expect(editable).toContainText('x')
            await action('undo character', () => page.keyboard.press('ControlOrMeta+z'))
            await expect(editable).not.toContainText('x')
            await action('open page chat', async () => {
              await page.getByRole('button', { name: '页面对话', exact: true }).click()
              await expect(page.getByRole('textbox', { name: '消息', exact: true })).toBeVisible()
            })
          } else {
            await action('type draft', () => editable.pressSequentially('Performance probe'))
            await expect(editable).toHaveValue('Performance probe')
            await action('clear draft', async () => {
              await editable.press('ControlOrMeta+a')
              await editable.press('Backspace')
            })
          }
          if (scenario === 'early-input') {
            await page.evaluate(() => document.fonts.ready)
            await page.waitForLoadState('networkidle', { timeout: 90_000 })
          }
          const final = await snapshot(page)
          const initialRequests = initialRequestIDs.map(id => ({ ...requests.get(id)! }))
          const report = {
            observedAt: new Date().toISOString(),
            chromiumVersion: browser.version(),
            profile,
            route,
            scenario,
            ...(route === 'chat' ? { conversationFixture } : {}),
            usableAt,
            initial,
            initialRequests,
            actions,
            final,
            allRequests: [...requests.values()],
            errors,
            caveat:
              'Laboratory samples on a local fixture. Event Timing records scripted interactions; this is not field INP or a real-user p75. Cache is disabled and fresh contexts are used. No synthetic score is calculated. The without-cn-font scenario is a diagnostic fallback-font experiment, not product performance. Early-input samples interact before fonts settle, so their LCP lifecycle differs from load-only samples.',
            definitions: [
              'https://web.dev/articles/vitals',
              'https://web.dev/articles/cls',
              'https://web.dev/articles/inp',
              'https://web.dev/articles/lcp'
            ]
          }
          const target = path.join(outputDirectory!, `${profile.name}-${route}.json`)
          writeFileSync(target, JSON.stringify(report, null, 2))
          await test.info().attach('performance-measurement', { path: target, contentType: 'application/json' })
          await page.screenshot({ path: path.join(outputDirectory!, `${profile.name}-${route}.png`) })
          expect(initialRequests.filter(request => request.status === 304)).toEqual([])
          expect(
            initialRequests.filter(request => request.diskCache || request.serviceWorker || request.servedFromCache)
          ).toEqual([])
          if (process.env.POD_PERFORMANCE_EXPECT_GZIP === '1') {
            const scriptsAndStyles = initialRequests.filter(
              request => /^\/assets\/.+\.(js|css)$/.test(request.url) && request.status === 200
            )
            expect(scriptsAndStyles.length).toBeGreaterThan(0)
            expect(scriptsAndStyles.filter(request => request.contentEncoding !== 'gzip')).toEqual([])
          }
          expect(errors).toEqual([])
          console.log(`Pod laboratory ${profile.name}/${route}: ${target}`)
        } finally {
          await context.close()
        }
      })
    }
  }
})
