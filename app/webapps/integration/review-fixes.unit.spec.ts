import { expect, test, type Page } from '@playwright/test'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import { podLocation } from '../common/browser-context'
import type { ConversationDetail } from '../pod/api'
import type {
  PodAgentsResponse,
  PodAppletEnvsResponse,
  PodAppletFunctionsResponse,
  PodPageNavigationResponse,
  PodPageReadResponse
} from '../pod/api/generated/types.gen'

const PNG_1X1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  'base64'
)

const HARBOR_ID = '00112233-4455-6677-8899-aabbccddeeff'
const BEACON_ID = '11223344-5566-7788-99aa-bbccddeeff00'
const APPLET_PAGE_ID = '019a2b00-0000-7000-8000-000000000099'
const CONVERSATION_ID = '019a2b00-0000-7000-8000-000000000088'

function makeAppletDetail(): PodPageReadResponse {
  return {
    page: {
      id: APPLET_PAGE_ID,
      name: 'Research Console',
      title: 'Research Console',
      icon: '🧪',
      type: 'applet',
      position: 'a0',
      inherit_permissions: true,
      metadata: {},
      revision: 1,
      children_view: {},
      created_at: '2026-11-08T00:00:00Z',
      updated_at: '2026-11-08T00:00:00Z',
      deleted_at: null,
      actions: ['node_view', 'node_comment', 'node_contribute', 'node_edit', 'node_manage'],
      role: 'edit'
    },
    ancestors: [],
    actions: ['node_view', 'node_comment', 'node_contribute', 'node_edit', 'node_manage'],
    role: 'edit',
    child_count: 0
  }
}

async function installDocumentIdentity(page: Page, podID = HARBOR_ID, authRef = 'auth-harbor', principal = 'alice') {
  await page.addInitScript(
    ({ pod, auth, uid }) => {
      const upsertMeta = (name: string, content: string) => {
        let el = document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)
        if (!el) {
          el = document.createElement('meta')
          el.name = name
          document.head.append(el)
        }
        el.content = content
      }
      const apply = () => {
        upsertMeta('ankole-pod', pod)
        upsertMeta('ankole-authentication', auth)
        upsertMeta('ankole-principal', uid)
      }
      if (document.head) {
        apply()
      } else {
        document.addEventListener('DOMContentLoaded', apply, { once: true })
      }
    },
    { pod: podID, auth: authRef, uid: principal }
  )
}

test('Applet settings keeps one Create Job draft across Automation, Webhooks, Run logs, and Functions preset switches', async ({
  page
}) => {
  await page.setViewportSize({ width: 1365, height: 900 })
  await installDocumentIdentity(page)

  const createdPayloads: Record<string, unknown>[] = []
  let jobs: Record<string, unknown>[] = []

  await page.route('**/api/v2/browser/session', route =>
    route.fulfill({
      json: {
        authenticated: true,
        principalUID: 'alice',
        displayName: 'Alice',
        canManagePod: true,
        tenant: { id: HARBOR_ID, slug: 'harbor', displayName: 'Harbor' },
        accounts: [],
        pendingAccounts: [],
        siteAuthentications: []
      } satisfies BrowserSessionResponse
    })
  )

  await page.route('**/api/v2/pod/**', route => {
    const url = new URL(route.request().url())
    const path = url.pathname
    const method = route.request().method()

    if (path.endsWith('/events')) {
      return route.fulfill({ contentType: 'text/event-stream', body: ': connected\n\n' })
    }
    if (path.endsWith('/agents')) {
      return route.fulfill({
        json: { agents: [], personalAssistant: null, personalAssistantAvailable: true } satisfies PodAgentsResponse
      })
    }
    if (path.endsWith('/pages/navigation')) {
      return route.fulfill({ json: { path: [], directories: [] } satisfies PodPageNavigationResponse })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}`) {
      return route.fulfill({ json: makeAppletDetail() })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/envs`) {
      return route.fulfill({ json: { can_decrypt: true, envs: [] } satisfies PodAppletEnvsResponse })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/functions`) {
      return route.fulfill({
        json: {
          revision: 1,
          has_backend: true,
          routes: [],
          actions: [
            { key: 'sync_digest', concurrency: 'serial_coalesce', idempotent: true, max_slices: 8 },
            { key: 'rebuild_index', concurrency: 'parallel', idempotent: false, max_slices: 4 }
          ]
        } satisfies PodAppletFunctionsResponse
      })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/job-actions`) {
      return route.fulfill({ json: { actions: ['sync_digest', 'rebuild_index'] } })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/jobs` && method === 'GET') {
      return route.fulfill({ json: { jobs } })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/jobs` && method === 'POST') {
      const body = route.request().postDataJSON() as { data: Record<string, unknown> }
      createdPayloads.push(body)
      const created = {
        id: 101,
        page_id: APPLET_PAGE_ID,
        action_key: body.data.action_key ?? 'sync_digest',
        label: body.data.label ?? 'Morning Digest',
        authorization_kind: body.data.authorization_kind ?? 'human',
        human_uid: 'alice',
        status: 'active',
        config: body.data.config ?? {}
      }
      jobs = [created]
      return route.fulfill({ json: { job: created } })
    }
    if (path.includes(`/jobs/101/`)) {
      return route.fulfill({ json: { schedules: [], webhooks: [], runs: [] } })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/files`) {
      return route.fulfill({ json: { revision: 1, files: [] } })
    }
    if (path.endsWith('/conversations')) {
      return route.fulfill({ json: { conversations: [], nextCursor: null } })
    }
    if (path.startsWith('/api/v2/pod/pages')) {
      return route.fulfill({
        json: {
          pages: [],
          can_create_space: true,
          can_create_private: true,
          can_manage_space: true,
          next_cursor: null
        }
      })
    }
    return route.fulfill({ json: [] })
  })

  await page.goto(podLocation(`/pages/${APPLET_PAGE_ID}`).pathname)
  await page.getByRole('button', { name: 'Applet settings', exact: true }).click()

  const dialog = page.getByRole('dialog', { name: 'Applet settings', exact: true })
  await expect(dialog).toBeVisible()

  await dialog.getByRole('tab', { name: 'Automation', exact: true }).click()
  const newJobButton = dialog.getByRole('button', { name: 'New Job', exact: true })
  await expect(newJobButton).toHaveCount(1)
  await expect(newJobButton).toHaveAttribute('aria-expanded', 'false')

  await newJobButton.click()
  await expect(newJobButton).toHaveAttribute('aria-expanded', 'true')
  await expect(dialog.getByRole('button', { name: 'Create Job', exact: true })).toHaveCount(1)
  await expect(dialog.locator('input[name="label"]')).toHaveCount(1)

  const nameInput = dialog.getByRole('textbox', { name: 'Name', exact: true })
  const configInput = dialog.getByRole('textbox', { name: 'Job settings (JSON)', exact: true })
  await nameInput.fill('Morning Digest')
  await configInput.fill('{"channel":"ops"}')

  // Switching across keepMounted Webhooks and Run logs tabs keeps the single draft mounted without duplication
  await dialog.getByRole('tab', { name: 'Webhooks', exact: true }).click()
  await expect(dialog.getByRole('button', { name: 'Create Job', exact: true })).toHaveCount(1)
  await expect(dialog.locator('input[name="label"]')).toHaveCount(1)
  await expect(nameInput).toHaveValue('Morning Digest')
  await expect(configInput).toHaveValue('{"channel":"ops"}')

  await dialog.getByRole('tab', { name: 'Run logs', exact: true }).click()
  await expect(dialog.getByRole('button', { name: 'Create Job', exact: true })).toHaveCount(1)
  await expect(dialog.locator('input[name="label"]')).toHaveCount(1)
  await expect(nameInput).toHaveValue('Morning Digest')
  await expect(configInput).toHaveValue('{"channel":"ops"}')

  // Clicking Create Job for rebuild_index in Functions resets the draft to that preset action
  await dialog.getByRole('tab', { name: 'Functions', exact: true }).click()
  await dialog.getByRole('button', { name: 'Create Job rebuild_index', exact: true }).click()
  await expect(nameInput).toHaveValue('rebuild_index')
  await nameInput.fill('Nightly Rebuild')
  await configInput.fill('{"full":true}')

  // Switch back to Run logs and submit the shared Create Job form from there
  await dialog.getByRole('tab', { name: 'Run logs', exact: true }).click()
  await dialog.getByRole('button', { name: 'Create Job', exact: true }).click()

  await expect.poll(() => createdPayloads.length).toBe(1)
  expect(createdPayloads[0]).toEqual({
    data: {
      action_key: 'rebuild_index',
      label: 'Nightly Rebuild',
      authorization_kind: 'human',
      config: { full: true }
    }
  })
})

test('.env batch import refreshes once, retains only failed entries on partial failure, and shows one summary toast on completion', async ({
  page
}) => {
  await page.setViewportSize({ width: 1365, height: 900 })
  await installDocumentIdentity(page)

  let envListFetches = 0
  let failSecondKey = true
  const stored = new Map<string, { secret: boolean; value: string | null }>()

  await page.route('**/api/v2/browser/session', route =>
    route.fulfill({
      json: {
        authenticated: true,
        principalUID: 'alice',
        displayName: 'Alice',
        canManagePod: true,
        tenant: { id: HARBOR_ID, slug: 'harbor', displayName: 'Harbor' },
        accounts: [],
        pendingAccounts: [],
        siteAuthentications: []
      } satisfies BrowserSessionResponse
    })
  )

  await page.route('**/api/v2/pod/**', route => {
    const url = new URL(route.request().url())
    const path = url.pathname
    const method = route.request().method()

    if (path.endsWith('/events')) {
      return route.fulfill({ contentType: 'text/event-stream', body: ': connected\n\n' })
    }
    if (path.endsWith('/agents')) {
      return route.fulfill({
        json: { agents: [], personalAssistant: null, personalAssistantAvailable: true } satisfies PodAgentsResponse
      })
    }
    if (path.endsWith('/pages/navigation')) {
      return route.fulfill({ json: { path: [], directories: [] } satisfies PodPageNavigationResponse })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}`) {
      return route.fulfill({ json: makeAppletDetail() })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/envs` && method === 'GET') {
      envListFetches += 1
      return route.fulfill({
        json: {
          can_decrypt: true,
          envs: [...stored.entries()].map(([name, item]) => ({
            name,
            secret: item.secret,
            required: false,
            declared: false,
            description: null,
            present: true,
            source: 'applet',
            inherited_source: null,
            value: item.secret ? null : item.value
          }))
        } satisfies PodAppletEnvsResponse
      })
    }
    if (path.startsWith(`/api/v2/pod/pages/${APPLET_PAGE_ID}/envs/`) && method === 'PUT') {
      const name = decodeURIComponent(path.slice(`/api/v2/pod/pages/${APPLET_PAGE_ID}/envs/`.length))
      if (name === 'SECOND_BAD' && failSecondKey) {
        return route.fulfill({
          status: 422,
          json: { error: { code: 'invalid_env', message: 'Upstream secret rejected' } }
        })
      }
      const payload = (route.request().postDataJSON() as { data: { value: string; secret: boolean } }).data
      stored.set(name, { secret: payload.secret, value: payload.value })
      return route.fulfill({ json: { ok: true } })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/job-actions`) {
      return route.fulfill({ json: { actions: [] } })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/jobs`) {
      return route.fulfill({ json: { jobs: [] } })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/files`) {
      return route.fulfill({ json: { revision: 1, files: [] } })
    }
    if (path.endsWith('/conversations')) {
      return route.fulfill({ json: { conversations: [], nextCursor: null } })
    }
    if (path.startsWith('/api/v2/pod/pages')) {
      return route.fulfill({
        json: {
          pages: [],
          can_create_space: true,
          can_create_private: true,
          can_manage_space: true,
          next_cursor: null
        }
      })
    }
    return route.fulfill({ json: [] })
  })

  await page.goto(podLocation(`/pages/${APPLET_PAGE_ID}`).pathname)
  await page.getByRole('button', { name: 'Applet settings', exact: true }).click()

  const dialog = page.getByRole('dialog', { name: 'Applet settings', exact: true })
  await expect(dialog).toBeVisible()
  await expect.poll(() => envListFetches).toBeGreaterThanOrEqual(1)
  const fetchesBeforeImport = envListFetches

  await dialog.getByRole('button', { name: 'Paste .env', exact: true }).click()
  const dotenvArea = dialog.getByLabel('Environment entries (.env)', { exact: true })
  await dotenvArea.fill('FIRST_OK=alpha\nSECOND_BAD="line 1\\nline 2"\nTHIRD_OK=omega')
  await dialog.getByRole('button', { name: 'Import 3 variables', exact: true }).click()

  const alert = dialog.getByRole('alert')
  await expect(alert).toContainText('FIRST_OK, THIRD_OK')
  await expect(alert).toContainText('SECOND_BAD (Upstream secret rejected)')
  await expect(dotenvArea).toHaveValue('SECOND_BAD="line 1\\nline 2"')
  // Only 1 refresh batch after the 3-entry import (instead of N per-item refetches)
  expect(envListFetches - fetchesBeforeImport).toBe(1)

  // Retry the remaining entry once the upstream error clears -> closes panel and shows 1 summary toast
  failSecondKey = false
  await dialog.getByRole('button', { name: 'Import 1 variable', exact: true }).click()
  await expect(dotenvArea).toBeHidden()
  await expect(page.getByText('Imported 1 variable.', { exact: true })).toBeVisible()
})

test('AccountMenu renders each Space avatar from its own Pod origin and authenticationRef', async ({ page }) => {
  await page.setViewportSize({ width: 1365, height: 900 })
  await installDocumentIdentity(page, HARBOR_ID, 'auth-harbor')

  await page.route('**/api/v2/browser/session', route =>
    route.fulfill({
      json: {
        authenticated: true,
        principalUID: 'alice',
        displayName: 'Alice Reviewer',
        canManagePod: false,
        tenant: {
          id: HARBOR_ID,
          slug: 'harbor',
          displayName: 'Harbor Pod',
          avatarURL: '/api/v2/pod/avatars/space?v=harbor-v1'
        },
        accounts: [
          {
            authenticationRef: 'auth-harbor',
            podURL: 'https://harbor.pod.example',
            principalUID: 'alice',
            displayName: 'Alice Reviewer',
            providerID: 'email_otp',
            tenant: {
              id: HARBOR_ID,
              slug: 'harbor',
              displayName: 'Harbor Pod',
              avatarURL: '/api/v2/pod/avatars/space?v=harbor-v1'
            }
          },
          {
            authenticationRef: 'auth-beacon',
            podURL: 'https://beacon.pod.example',
            principalUID: 'alice',
            displayName: 'Alice Reviewer',
            providerID: 'email_otp',
            tenant: {
              id: BEACON_ID,
              slug: 'beacon',
              displayName: 'Beacon Pod',
              avatarURL: '/api/v2/pod/avatars/space?v=beacon-v1'
            }
          }
        ],
        pendingAccounts: [],
        siteAuthentications: []
      } satisfies BrowserSessionResponse
    })
  )

  await page.route('**/api/v2/pod/**', route => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/events')) return route.fulfill({ contentType: 'text/event-stream', body: ': connected\n\n' })
    if (path.endsWith('/agents')) {
      return route.fulfill({
        json: { agents: [], personalAssistant: null, personalAssistantAvailable: true } satisfies PodAgentsResponse
      })
    }
    if (path.endsWith('/pages/navigation')) {
      return route.fulfill({ json: { path: [], directories: [] } satisfies PodPageNavigationResponse })
    }
    if (path.endsWith('/conversations')) {
      return route.fulfill({ json: { conversations: [], nextCursor: null } })
    }
    if (path.startsWith('/api/v2/pod/pages')) {
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
    return route.fulfill({ json: [] })
  })

  await page.route('https://*.pod.example/**', route =>
    route.fulfill({ status: 200, contentType: 'image/png', body: PNG_1X1 })
  )

  await page.goto('/')
  const trigger = page.locator('button.pod-account-trigger')
  await expect(trigger.locator('img')).toHaveAttribute(
    'src',
    'https://harbor.pod.example/api/v2/pod/avatars/space?v=harbor-v1&authentication_ref=auth-harbor'
  )

  await trigger.click()
  const menu = page.locator('.pod-account-menu')
  await expect(menu).toBeVisible()
  const optionImages = await menu
    .locator('.pod-account-option img')
    .evaluateAll(imgs => imgs.map(img => img.getAttribute('src')))
  expect(optionImages).toEqual([
    'https://harbor.pod.example/api/v2/pod/avatars/space?v=harbor-v1&authentication_ref=auth-harbor',
    'https://beacon.pod.example/api/v2/pod/avatars/space?v=beacon-v1&authentication_ref=auth-beacon'
  ])
})

test('mobile PageChat Sheet supports double-Escape timeline backtrack, ArrowUp navigation, Enter inline edit, and Escape cancel without dismissing the Sheet', async ({
  page
}) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await installDocumentIdentity(page)

  const assistant = {
    uid: 'assistant',
    displayName: 'Assistant',
    agentType: 'personal_assistant' as const,
    active: true,
    type: 'agent' as const,
    mayIntervene: true
  }

  const detail: ConversationDetail = {
    conversation: {
      id: CONVERSATION_ID,
      title: 'Page review',
      titleCustomized: false,
      accessScope: 'participants',
      canDelete: true,
      canManage: true,
      roomMode: 'dm',
      conversationKind: 'assistant_task',
      createdBy: 'alice',
      lastMessageSeq: 4,
      lastActivityAt: '2026-11-08T00:00:04Z',
      rowStatus: 'idle',
      pageID: APPLET_PAGE_ID,
      viewer: { uid: 'alice', pinned: false, muted: false, lastReadSeq: 4 },
      agents: [assistant],
      participants: [
        { uid: 'alice', displayName: 'Alice', active: true, type: 'human', role: 'owner', mayIntervene: false },
        assistant
      ]
    },
    messages: [
      {
        id: 'turn-1',
        seq: 1,
        authorType: 'human',
        authorUID: 'alice',
        authorDisplayName: 'Alice',
        authorArchived: false,
        kind: 'message',
        text: 'First prompt in mobile sheet',
        createdAt: '2026-11-08T00:00:01Z',
        signalID: null,
        replyToMessageID: null,
        mentions: [],
        links: [],
        attachments: [],
        savedPages: []
      },
      {
        id: 'reply-1',
        seq: 2,
        authorType: 'agent',
        authorUID: 'assistant',
        authorDisplayName: 'Assistant',
        authorArchived: false,
        kind: 'message',
        text: 'First reply',
        createdAt: '2026-11-08T00:00:02Z',
        signalID: 'sig-1',
        replyToMessageID: 'turn-1',
        mentions: [],
        links: [],
        attachments: [],
        savedPages: []
      },
      {
        id: 'turn-2',
        seq: 3,
        authorType: 'human',
        authorUID: 'alice',
        authorDisplayName: 'Alice',
        authorArchived: false,
        kind: 'message',
        text: 'Second prompt in mobile sheet',
        createdAt: '2026-11-08T00:00:03Z',
        signalID: null,
        replyToMessageID: null,
        mentions: [],
        links: [],
        attachments: [],
        savedPages: []
      },
      {
        id: 'reply-2',
        seq: 4,
        authorType: 'agent',
        authorUID: 'assistant',
        authorDisplayName: 'Assistant',
        authorArchived: false,
        kind: 'message',
        text: 'Second reply',
        createdAt: '2026-11-08T00:00:04Z',
        signalID: 'sig-2',
        replyToMessageID: 'turn-2',
        mentions: [],
        links: [],
        attachments: [],
        savedPages: []
      }
    ],
    latestInput: { messageID: 'turn-2', authorUID: 'alice', agentUIDs: ['assistant'] },
    editableInputs: [
      { messageID: 'turn-1', agentUIDs: ['assistant'], supersededByParticipant: false },
      { messageID: 'turn-2', agentUIDs: ['assistant'], supersededByParticipant: false }
    ],
    removedMessageIDs: [],
    olderMessagesBeforeSeq: null,
    messageRange: { firstSeq: 1, lastSeq: 4 },
    activities: [],
    pendingInteractions: [],
    pendingQueues: [
      {
        agentUID: 'assistant',
        inputs: [],
        paused: false,
        queueVersion: 'v1',
        workStatus: { state: 'idle', retryAt: null }
      }
    ],
    linkedRuns: [],
    artifacts: { pageIDs: [], attachments: [] }
  }

  await page.route('**/api/v2/browser/session', route =>
    route.fulfill({
      json: {
        authenticated: true,
        principalUID: 'alice',
        displayName: 'Alice',
        canManagePod: false,
        tenant: { id: HARBOR_ID, slug: 'harbor', displayName: 'Harbor' },
        accounts: [],
        pendingAccounts: [],
        siteAuthentications: []
      } satisfies BrowserSessionResponse
    })
  )

  await page.route('**/api/v2/pod/**', route => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/events')) return route.fulfill({ contentType: 'text/event-stream', body: ': connected\n\n' })
    if (path.endsWith('/agents')) {
      return route.fulfill({
        json: {
          agents: [assistant],
          personalAssistant: assistant,
          personalAssistantAvailable: true
        } satisfies PodAgentsResponse
      })
    }
    if (path.endsWith('/pages/navigation')) {
      return route.fulfill({ json: { path: [], directories: [] } satisfies PodPageNavigationResponse })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}`) {
      return route.fulfill({ json: makeAppletDetail() })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/envs`) {
      return route.fulfill({ json: { can_decrypt: true, envs: [] } satisfies PodAppletEnvsResponse })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/files`) {
      return route.fulfill({ json: { revision: 1, files: [] } })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/conversations`) {
      return route.fulfill({ json: { conversations: [detail.conversation] } })
    }
    if (path === `/api/v2/pod/conversations/${CONVERSATION_ID}`) {
      return route.fulfill({ json: detail })
    }
    if (path.endsWith('/conversations')) {
      return route.fulfill({ json: { conversations: [detail.conversation], nextCursor: null } })
    }
    if (path.startsWith('/api/v2/pod/pages')) {
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
    return route.fulfill({ json: [] })
  })

  const pagePath = podLocation(`/pages/${APPLET_PAGE_ID}`).pathname
  const shortConv = podLocation(`/conversations/${CONVERSATION_ID}`).pathname.split('/').at(-1)!
  await page.goto(`${pagePath}?chat=${shortConv}`)

  const sheetDialog = page.getByRole('dialog', { name: 'Assistant', exact: true })
  await expect(sheetDialog).toBeVisible()

  const composer = sheetDialog.getByRole('textbox', { name: 'Message', exact: true })
  await expect(composer).toBeVisible()
  await composer.focus()

  // First Escape arms backtrack without dismissing the mobile Sheet dialog
  await page.keyboard.press('Escape')
  await expect(sheetDialog).toBeVisible()

  // Second Escape within 600ms enters backtrack on turn-2
  await page.keyboard.press('Escape')
  await expect(sheetDialog).toBeVisible()
  const turn2 = sheetDialog.locator('[data-chat-message-id="turn-2"]')
  const turn1 = sheetDialog.locator('[data-chat-message-id="turn-1"]')
  await expect(turn2).toBeFocused()
  await expect(turn2).toContainText('↑↓ Select message')

  // ArrowUp inside the Sheet dialog steps backtrack to turn-1
  await page.keyboard.press('ArrowUp')
  await expect(turn1).toBeFocused()
  await expect(turn1).toContainText('↑↓ Select message')

  // Escape exits backtrack back to the composer while keeping the Sheet open
  await page.keyboard.press('Escape')
  await expect(sheetDialog).toBeVisible()
  await expect(composer).toBeFocused()
  await expect(turn1).not.toContainText('↑↓ Select message')

  // Double-Escape + Enter opens the inline message editor, and Escape cancels it without closing the Sheet
  await page.keyboard.press('Escape')
  await page.keyboard.press('Escape')
  await expect(turn2).toBeFocused()
  await page.keyboard.press('Enter')

  const inlineEditor = turn2.locator('textarea')
  await expect(inlineEditor).toBeVisible()
  await inlineEditor.focus()
  await page.keyboard.press('Escape')
  await expect(inlineEditor).toHaveCount(0)
  await expect(sheetDialog).toBeVisible()
})

test('Applet settings keeps Create Job pending and disabled across tab switches while POST /jobs is in flight', async ({
  page
}) => {
  await page.setViewportSize({ width: 1365, height: 900 })
  await installDocumentIdentity(page)

  const createdPayloads: Record<string, unknown>[] = []
  let jobs: Record<string, unknown>[] = []
  let releaseCreateJob: (() => void) | null = null
  const createJobHeld = new Promise<void>(resolve => {
    releaseCreateJob = resolve
  })

  await page.route('**/api/v2/browser/session', route =>
    route.fulfill({
      json: {
        authenticated: true,
        principalUID: 'alice',
        displayName: 'Alice',
        canManagePod: true,
        tenant: { id: HARBOR_ID, slug: 'harbor', displayName: 'Harbor' },
        accounts: [],
        pendingAccounts: [],
        siteAuthentications: []
      } satisfies BrowserSessionResponse
    })
  )

  await page.route('**/api/v2/pod/**', async route => {
    const url = new URL(route.request().url())
    const path = url.pathname
    const method = route.request().method()

    if (path.endsWith('/events')) {
      return route.fulfill({ contentType: 'text/event-stream', body: ': connected\n\n' })
    }
    if (path.endsWith('/agents')) {
      return route.fulfill({
        json: { agents: [], personalAssistant: null, personalAssistantAvailable: true } satisfies PodAgentsResponse
      })
    }
    if (path.endsWith('/pages/navigation')) {
      return route.fulfill({ json: { path: [], directories: [] } satisfies PodPageNavigationResponse })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}`) {
      return route.fulfill({ json: makeAppletDetail() })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/envs`) {
      return route.fulfill({ json: { can_decrypt: true, envs: [] } satisfies PodAppletEnvsResponse })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/functions`) {
      return route.fulfill({
        json: {
          revision: 1,
          has_backend: true,
          routes: [],
          actions: [
            { key: 'sync_digest', concurrency: 'serial_coalesce', idempotent: true, max_slices: 8 },
            { key: 'rebuild_index', concurrency: 'parallel', idempotent: false, max_slices: 4 }
          ]
        } satisfies PodAppletFunctionsResponse
      })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/job-actions`) {
      return route.fulfill({ json: { actions: ['sync_digest', 'rebuild_index'] } })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/jobs` && method === 'GET') {
      return route.fulfill({ json: { jobs } })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/jobs` && method === 'POST') {
      const body = route.request().postDataJSON() as { data: Record<string, unknown> }
      createdPayloads.push(body)
      await createJobHeld
      const created = {
        id: 202,
        page_id: APPLET_PAGE_ID,
        action_key: body.data.action_key ?? 'sync_digest',
        label: body.data.label ?? 'Single Flight Digest',
        authorization_kind: body.data.authorization_kind ?? 'human',
        human_uid: 'alice',
        status: 'active',
        config: body.data.config ?? {}
      }
      jobs = [created]
      return route.fulfill({ json: { job: created } })
    }
    if (path.includes(`/jobs/202/`)) {
      return route.fulfill({ json: { schedules: [], webhooks: [], runs: [] } })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/files`) {
      return route.fulfill({ json: { revision: 1, files: [] } })
    }
    if (path.endsWith('/conversations')) {
      return route.fulfill({ json: { conversations: [], nextCursor: null } })
    }
    if (path.startsWith('/api/v2/pod/pages')) {
      return route.fulfill({
        json: {
          pages: [],
          can_create_space: true,
          can_create_private: true,
          can_manage_space: true,
          next_cursor: null
        }
      })
    }
    return route.fulfill({ json: [] })
  })

  await page.goto(podLocation(`/pages/${APPLET_PAGE_ID}`).pathname)
  await page.getByRole('button', { name: 'Applet settings', exact: true }).click()

  const dialog = page.getByRole('dialog', { name: 'Applet settings', exact: true })
  await expect(dialog).toBeVisible()

  await dialog.getByRole('tab', { name: 'Automation', exact: true }).click()
  const newJobButton = dialog.getByRole('button', { name: 'New Job', exact: true })
  await newJobButton.click()

  const nameInput = dialog.getByRole('textbox', { name: 'Name', exact: true })
  await nameInput.fill('Single Flight Digest')

  const createJobButton = dialog.getByRole('button', { name: 'Create Job', exact: true })
  await createJobButton.click()

  await expect.poll(() => createdPayloads.length).toBe(1)
  await expect(createJobButton).toBeDisabled()
  await expect(newJobButton).toBeDisabled()

  // Switching across Webhooks, Run logs, Functions, and back to Automation must NOT reset pending state
  await dialog.getByRole('tab', { name: 'Webhooks', exact: true }).click()
  await expect(createJobButton).toBeDisabled()
  await expect(newJobButton).toBeDisabled()

  await dialog.getByRole('tab', { name: 'Run logs', exact: true }).click()
  await expect(createJobButton).toBeDisabled()

  await dialog.getByRole('tab', { name: 'Functions', exact: true }).click()
  await expect(dialog.getByText('rebuild_index', { exact: true })).toBeVisible()
  await expect(dialog.getByRole('button', { name: 'Create Job rebuild_index', exact: true })).toHaveCount(0)

  await dialog.getByRole('tab', { name: 'Automation', exact: true }).click()
  await expect(createJobButton).toBeDisabled()

  // Even a programmatic submit event on the form while pending is ignored
  await dialog.locator('input[name="label"]').evaluate(input => {
    input.closest('form')?.requestSubmit()
  })
  expect(createdPayloads).toHaveLength(1)

  releaseCreateJob!()
  await expect(createJobButton).toHaveCount(0)
  expect(createdPayloads).toHaveLength(1)
})

test('.env batch import preserves newer .env and single-entry drafts edited while an earlier import request is in flight', async ({
  page
}) => {
  await page.setViewportSize({ width: 1365, height: 900 })
  await installDocumentIdentity(page)

  const stored = new Map<string, { secret: boolean; value: string | null }>()
  const heldPuts = new Map<string, () => void>()

  const holdKey = (targetName: string) =>
    new Promise<void>(resolve => {
      heldPuts.set(targetName, resolve)
    })

  const gates = new Map<string, Promise<void>>([
    ['FIRST_OK', holdKey('FIRST_OK')],
    ['SECOND_BAD', holdKey('SECOND_BAD')],
    ['BG_OK', holdKey('BG_OK')]
  ])

  await page.route('**/api/v2/browser/session', route =>
    route.fulfill({
      json: {
        authenticated: true,
        principalUID: 'alice',
        displayName: 'Alice',
        canManagePod: true,
        tenant: { id: HARBOR_ID, slug: 'harbor', displayName: 'Harbor' },
        accounts: [],
        pendingAccounts: [],
        siteAuthentications: []
      } satisfies BrowserSessionResponse
    })
  )

  await page.route('**/api/v2/pod/**', async route => {
    const url = new URL(route.request().url())
    const path = url.pathname
    const method = route.request().method()

    if (path.endsWith('/events')) {
      return route.fulfill({ contentType: 'text/event-stream', body: ': connected\n\n' })
    }
    if (path.endsWith('/agents')) {
      return route.fulfill({
        json: { agents: [], personalAssistant: null, personalAssistantAvailable: true } satisfies PodAgentsResponse
      })
    }
    if (path.endsWith('/pages/navigation')) {
      return route.fulfill({ json: { path: [], directories: [] } satisfies PodPageNavigationResponse })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}`) {
      return route.fulfill({ json: makeAppletDetail() })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/envs` && method === 'GET') {
      return route.fulfill({
        json: {
          can_decrypt: true,
          envs: [...stored.entries()].map(([name, item]) => ({
            name,
            secret: item.secret,
            required: false,
            declared: false,
            description: null,
            present: true,
            source: 'applet',
            inherited_source: null,
            value: item.secret ? null : item.value
          }))
        } satisfies PodAppletEnvsResponse
      })
    }
    if (path.startsWith(`/api/v2/pod/pages/${APPLET_PAGE_ID}/envs/`) && method === 'PUT') {
      const name = decodeURIComponent(path.slice(`/api/v2/pod/pages/${APPLET_PAGE_ID}/envs/`.length))
      const gate = gates.get(name)
      if (gate) {
        gates.delete(name)
        await gate
      }
      if (name === 'SECOND_BAD') {
        return route.fulfill({
          status: 422,
          json: { error: { code: 'invalid_env', message: 'Upstream secret rejected' } }
        })
      }
      const payload = (route.request().postDataJSON() as { data: { value: string; secret: boolean } }).data
      stored.set(name, { secret: payload.secret, value: payload.value })
      return route.fulfill({ json: { ok: true } })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/job-actions`) {
      return route.fulfill({ json: { actions: [] } })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/jobs`) {
      return route.fulfill({ json: { jobs: [] } })
    }
    if (path === `/api/v2/pod/pages/${APPLET_PAGE_ID}/files`) {
      return route.fulfill({ json: { revision: 1, files: [] } })
    }
    if (path.endsWith('/conversations')) {
      return route.fulfill({ json: { conversations: [], nextCursor: null } })
    }
    if (path.startsWith('/api/v2/pod/pages')) {
      return route.fulfill({
        json: {
          pages: [],
          can_create_space: true,
          can_create_private: true,
          can_manage_space: true,
          next_cursor: null
        }
      })
    }
    return route.fulfill({ json: [] })
  })

  await page.goto(podLocation(`/pages/${APPLET_PAGE_ID}`).pathname)
  await page.getByRole('button', { name: 'Applet settings', exact: true }).click()

  const dialog = page.getByRole('dialog', { name: 'Applet settings', exact: true })
  await expect(dialog).toBeVisible()

  // 1. Full-success import finishing after user typed NEXT_BATCH=beta keeps panel open with NEXT_BATCH=beta intact
  await dialog.getByRole('button', { name: 'Paste .env', exact: true }).click()
  const dotenvArea = dialog.getByLabel('Environment entries (.env)', { exact: true })
  await dotenvArea.fill('FIRST_OK=alpha')
  await dialog.getByRole('button', { name: 'Import 1 variable', exact: true }).click()

  await dotenvArea.fill('NEXT_BATCH=beta')
  heldPuts.get('FIRST_OK')!()

  await expect(page.getByText('Imported 1 variable.', { exact: true })).toBeVisible()
  await expect(dotenvArea).toBeVisible()
  await expect(dotenvArea).toHaveValue('NEXT_BATCH=beta')
  expect(stored.get('FIRST_OK')).toBeDefined()
  expect(stored.get('NEXT_BATCH')).toBeUndefined()

  // 2. Partial-failure import finishing after user typed KEEP_ME=charlie surfaces error alert without overwriting KEEP_ME=charlie
  await dotenvArea.fill('SECOND_OK=bravo\nSECOND_BAD=boom')
  await dialog.getByRole('button', { name: 'Import 2 variables', exact: true }).click()

  await dotenvArea.fill('KEEP_ME=charlie')
  heldPuts.get('SECOND_BAD')!()

  const alert = dialog.getByRole('alert')
  await expect(alert).toContainText('SECOND_OK')
  await expect(alert).toContainText('SECOND_BAD (Upstream secret rejected)')
  await expect(dotenvArea).toBeVisible()
  await expect(dotenvArea).toHaveValue('KEEP_ME=charlie')

  // 3. Switching to Single variable while .env import is in flight preserves the Single variable draft when import finishes
  await dotenvArea.fill('BG_OK=delta')
  await dialog.getByRole('button', { name: 'Import 1 variable', exact: true }).click()

  await dialog.getByRole('button', { name: 'Single variable', exact: true }).click()
  const singleNameInput = dialog.getByLabel('Name', { exact: true })
  const singleValueInput = dialog.getByLabel('Value', { exact: true })
  await singleNameInput.fill('SINGLE_DRAFT')
  await singleValueInput.fill('single-secret-val')

  heldPuts.get('BG_OK')!()
  await expect.poll(() => stored.has('BG_OK')).toBe(true)
  await expect(singleNameInput).toBeVisible()
  await expect(singleNameInput).toHaveValue('SINGLE_DRAFT')
  await expect(singleValueInput).toHaveValue('single-secret-val')
})
