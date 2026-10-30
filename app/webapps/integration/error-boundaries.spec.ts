import { expect, test } from '@playwright/test'
import type { ConversationDetail } from '../pod/api'
import { conversationRoute } from './pod-browser/routes'

test('a crashed Pod sidebar exposes recovery on desktop and mobile without reloading the workspace', async ({
  page
}) => {
  await page.route('**/api/v2/browser/sessions/current', route =>
    route.fulfill({ json: { authenticated: true, principalUID: 'person', displayName: 'Person', canManagePod: false } })
  )
  await page.route('**/api/v2/pod/**', route =>
    route.fulfill({ json: { agents: [], conversations: [], pages: [], has_more: false } })
  )
  for (const viewport of [
    { width: 1440, height: 900 },
    { width: 390, height: 844 }
  ]) {
    await page.setViewportSize(viewport)
    await page.goto('/integration/error-boundaries/index.html?surface=pod-sidebar')
    const boot = await page.evaluate(() => window.__bootMarker)
    if (viewport.width < 768) await page.getByRole('button', { name: 'Show sidebar', exact: true }).click()
    await page.getByRole('button', { name: /^Account menu:/ }).click()
    const fallback = page.locator('.pod-shell > [data-error-boundary="panel"]')
    await expect(fallback).toBeVisible()
    await expect(fallback).toContainText('Sidebar render failure')
    await page.evaluate(() => {
      window.__sidebarFailure = false
    })
    await fallback.getByRole('button', { name: 'Reload section' }).click()
    await expect(fallback).toHaveCount(0)
    if (viewport.width < 768) await page.getByRole('button', { name: 'Show sidebar', exact: true }).click()
    await expect(page.getByRole('button', { name: /^Account menu:/ })).toBeVisible()
    expect(await page.evaluate(() => window.__bootMarker)).toBe(boot)
  }
})

test('panel boundary isolates crashes, uses calm render copy in English and Chinese, protects drafts, and resets via Retry or resetKeys without reloading', async ({
  page
}) => {
  await page.goto('/integration/error-boundaries/index.html')
  await expect(page.getByRole('heading', { name: 'Workspace Shell' })).toBeVisible()
  const bootMarker = await page.evaluate(() => (window as { __bootMarker?: string }).__bootMarker)
  expect(bootMarker).toBeTruthy()

  // Sibling regions and unsaved state remain intact while the crashing panel degrades locally.
  await expect(page.getByTestId('healthy-sibling')).toContainText('Healthy sibling remains interactive (alpha)')
  const draftInput = page.getByLabel('Draft editor')
  await expect(draftInput).toHaveValue('Unsaved architecture notes')

  const panelFallback = page.locator('[data-error-boundary="panel"]')
  await expect(panelFallback).toBeVisible()
  await expect(panelFallback).toContainText('This section could not be displayed')
  await expect(panelFallback).not.toContainText('Request failed')
  await expect(panelFallback.locator('code')).toHaveText("Cannot read properties of undefined (reading 'filter')")

  // Draft export escape hatch stays actionable inside the degraded panel.
  await draftInput.fill('Edited unsaved notes before recovery')
  await panelFallback.getByRole('button', { name: 'Export draft' }).click()
  await expect(page.getByTestId('exported-draft')).toHaveText('Edited unsaved notes before recovery')

  // Switching to zh-Hans-CN renders localized render-error copy ("此区域暂时无法显示"), never "请求失败".
  await page.getByRole('button', { name: 'Toggle locale' }).click()
  await expect(panelFallback).toContainText('此区域暂时无法显示')
  await expect(panelFallback).not.toContainText('请求失败')
  await page.getByRole('button', { name: 'Toggle locale' }).click()

  // Local Retry remounts only the crashed subtree without a full-page reload.
  await page.getByRole('button', { name: 'Arm recovery' }).click()
  await panelFallback.getByRole('button', { name: 'Reload section' }).click()
  await expect(page.getByTestId('panel-healthy')).toBeVisible()
  await expect(draftInput).toHaveValue('Edited unsaved notes before recovery')
  expect(await page.evaluate(() => (window as { __bootMarker?: string }).__bootMarker)).toBe(bootMarker)

  // Re-injecting a crash and changing resetKeys (context navigation) automatically clears the boundary.
  await page.getByRole('button', { name: 'Inject crash' }).click()
  await expect(panelFallback).toBeVisible()
  await page.getByRole('button', { name: 'Arm recovery' }).click()
  await page.getByRole('button', { name: 'Switch context' }).click()
  await expect(page.getByTestId('panel-healthy')).toBeVisible()
  await expect(page.getByTestId('healthy-sibling')).toContainText('Healthy sibling remains interactive (beta)')
})

test('Auth login and Pod settings extension boundaries isolate broken slots without blocking sibling sign-in methods or tabs', async ({
  page
}) => {
  await page.route(/\/api\/v2\/browser\/identity-providers/, route =>
    route.fulfill({
      json: {
        identities: [],
        providers: [
          {
            adapterID: 'email_otp',
            providerID: 'email_otp',
            kind: 'email_otp',
            displayName: { 'en-US': 'Email OTP' },
            loginPath: ''
          },
          {
            adapterID: 'oidc',
            providerID: 'oidc-okta',
            kind: 'oidc',
            displayName: { 'en-US': 'Okta SSO' },
            loginPath: '/auth/oidc/okta'
          }
        ]
      }
    })
  )

  await page.goto('/integration/error-boundaries/index.html?surface=auth')
  // Broken challenge slot inside EmailOtpForm is caught silently by SlotBoundary; SSO and email input remain usable.
  await expect(page.getByRole('button', { name: /Sign in with .*Okta SSO/ })).toBeVisible()
  await expect(page.getByLabel('Email address', { exact: true })).toBeVisible()

  await page.route('**/api/v2/pod/admin/settings', route =>
    route.fulfill({
      json: {
        displayName: 'Fixture Pod',
        defaultLocale: 'en-US',
        allowExternalGuests: true,
        emailAvailable: true,
        loginPolicy: { allowed_email_domains: [], allow_email_otp: true }
      }
    })
  )

  await page.goto('/integration/error-boundaries/index.html?surface=pod-settings')
  await page.getByRole('tab', { name: 'Broken extension', exact: true }).click()
  const settingsFallback = page.locator('[data-error-boundary="panel"]')
  await expect(settingsFallback).toBeVisible()
  await expect(settingsFallback).toContainText('This section could not be displayed')
  await expect(settingsFallback.locator('code')).toHaveText('Extension settings render failure')

  // Switching back to built-in General tab still works cleanly.
  await page.getByRole('tab', { name: 'General and sign-in', exact: true }).click()
  await expect(page.getByLabel('Space name')).toHaveValue('Fixture Pod')
})

test('Pod chat timeline isolates a single malformed message without unmounting healthy turns or the composer', async ({
  page
}) => {
  const conversationID = '00112233-4455-6677-8899-aabbccddeeff'
  const agent = {
    uid: 'agent-one',
    displayName: 'Research Agent',
    active: true,
    type: 'agent' as const,
    mayIntervene: true
  }
  let fixBrokenMessage = false

  await page.addInitScript(() => {
    ;(window as { __podBoot?: string }).__podBoot = crypto.randomUUID()
    window.EventSource = class extends EventTarget {
      onopen = null
      onerror = null
      onmessage = null
      readyState = 1
      url: string
      withCredentials = false
      CONNECTING = 0 as const
      OPEN = 1 as const
      CLOSED = 2 as const
      constructor(url: string | URL) {
        super()
        this.url = String(url)
      }
      close() {}
    } as unknown as typeof EventSource
  })

  await page.route('**/api/v2/browser/sessions/current', route =>
    route.fulfill({
      json: {
        authenticated: true,
        principalUID: 'person',
        canManagePod: false
      }
    })
  )

  await page.route('**/api/v2/pod/**', route => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/agents')) {
      return route.fulfill({ json: { agents: [agent] } })
    }
    if (path.endsWith('/conversations')) {
      return route.fulfill({
        json: {
          conversations: [
            {
              id: conversationID,
              title: 'Fault-isolated chat',
              accessScope: 'participants',
              canDelete: true,
              canManage: true,
              roomMode: 'dm',
              titleCustomized: true,
              createdBy: 'person',
              lastMessageSeq: 2,
              rowStatus: 'idle',
              viewer: { uid: 'person', pinned: false, muted: false, lastReadSeq: 2 },
              agents: [agent],
              participants: [
                {
                  uid: 'person',
                  displayName: 'Person',
                  active: true,
                  type: 'human',
                  role: 'owner',
                  mayIntervene: false
                },
                agent
              ],
              pageID: null,
              agent,
              lastActivityAt: '2026-10-16T00:00:00Z'
            }
          ]
        }
      })
    }
    if (path.includes('/pages')) {
      return route.fulfill({ json: { pages: [], has_more: false } })
    }
    const payload: ConversationDetail = {
      activities: [],
      pendingQueues: [
        {
          agentUID: agent.uid,
          inputs: [],
          paused: false,
          queueVersion: 'v1',
          workStatus: { state: 'idle', retryAt: null }
        }
      ],
      pendingInteractions: [],
      linkedRuns: [],
      artifacts: { pageIDs: [], attachments: [] },
      removedMessageIDs: [],
      olderMessagesBeforeSeq: null,
      messageRange: { firstSeq: 1, lastSeq: 2 },
      conversation: {
        id: conversationID,
        title: 'Fault-isolated chat',
        accessScope: 'participants',
        canDelete: true,
        canManage: true,
        roomMode: 'dm',
        titleCustomized: true,
        createdBy: 'person',
        lastMessageSeq: 2,
        rowStatus: 'idle',
        viewer: { uid: 'person', pinned: false, muted: false, lastReadSeq: 2 },
        agents: [agent],
        participants: [
          { uid: 'person', displayName: 'Person', active: true, type: 'human', role: 'owner', mayIntervene: false },
          agent
        ],
        pageID: null,
        agent,
        lastActivityAt: '2026-10-16T00:00:00Z'
      },
      messages: [
        {
          id: 'broken-turn',
          seq: 1,
          authorType: 'agent',
          authorDisplayName: 'Research Agent',
          authorArchived: false,
          mentions: [],
          savedPages: [],
          authorUID: agent.uid,
          kind: 'message',
          // Triggers `Cannot read properties of undefined (reading 'filter')` inside CommittedMessage until repaired.
          links: (fixBrokenMessage ? [] : undefined) as unknown as [],
          attachments: [],
          text: 'Recovered first reply',
          createdAt: '2026-10-16T00:00:00Z',
          replyToMessageID: null,
          signalID: null
        },
        {
          id: 'healthy-turn',
          seq: 2,
          authorType: 'agent',
          authorDisplayName: 'Research Agent',
          authorArchived: false,
          mentions: [],
          savedPages: [],
          authorUID: agent.uid,
          kind: 'message',
          links: [],
          attachments: [],
          text: 'Healthy second reply remains readable',
          createdAt: '2026-10-16T00:01:00Z',
          replyToMessageID: null,
          signalID: null
        }
      ]
    }
    return route.fulfill({ json: payload })
  })

  await page.goto(conversationRoute(conversationID))
  const bootID = await page.evaluate(() => (window as { __podBoot?: string }).__podBoot)

  // Healthy second turn, room header, and composer stay alive while turn #1 degrades inline.
  await expect(page.getByText('Healthy second reply remains readable')).toBeVisible({ timeout: 15_000 })
  await expect(page.locator('.pod-chat-composer textarea')).toBeVisible()
  const inlineError = page.locator('[data-chat-message-id="broken-turn"] [data-error-boundary="inline"]')
  await expect(inlineError).toBeVisible()
  await expect(inlineError).toContainText('This content could not be displayed')
  await expect(page.locator('.pod-chat').getByText('Request failed')).toHaveCount(0)

  // Repairing server data and clicking Retry on the single turn recovers it in-place without reloading the page.
  fixBrokenMessage = true
  await inlineError.getByRole('button', { name: 'Retry' }).click()
  await expect(page.getByText('Recovered first reply')).toBeVisible()
  expect(await page.evaluate(() => (window as { __podBoot?: string }).__podBoot)).toBe(bootID)
})
