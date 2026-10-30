import { state, request as podRequest } from './fixtures'
import { pageRoute, conversationRoute } from './routes'
import { mkdirSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { expect, test } from '@playwright/test'
import { profiles, instrument, snapshot, finalSnapshot } from './performance-measurement'
import type { ConversationDetail } from '../../pod/api'
import type { PodConversationsResponse as Conversations } from '../../pod/api/generated/types.gen'

const outputDirectory = process.env.POD_PERFORMANCE_OUTPUT
const scenario = process.env.POD_PERFORMANCE_SCENARIO ?? 'load'
if (!['load', 'early-input', 'without-cn-font'].includes(scenario)) {
  throw new Error(`Unknown performance scenario: ${scenario}`)
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
        .filter(conversation => conversation.agents.some(agent => agent.uid === state.agent_uid && agent.active))
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
          const final = await finalSnapshot(page)
          const initialRequests = initialRequestIDs.map(id => ({ ...requests.get(id)! }))
          const report = {
            observedAt: new Date().toISOString(),
            browserVersion: browser.version(),
            browserChannel: process.env.POD_BROWSER_CHANNEL ?? 'chromium',
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
