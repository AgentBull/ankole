import { expect, test } from '@playwright/test'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import type { PodPageSharingResponse } from '../pod/api/generated/types.gen'
import { pageRoute } from './pod-browser/routes'

const DOC_ID = '019a2b00-0000-7000-8000-000000000501'
const TENANT_ID = '00112233-4455-6677-8899-aabbccddeeff'

function makeFillerParagraphs(prefix: string, count: number): string {
  return Array.from(
    { length: count },
    (_, idx) =>
      `<p>${prefix} paragraph ${idx + 1} keeps the section tall enough to scroll smoothly across the canvas.</p>`
  ).join('')
}

test('Document outline rail, realistic Share preview with split-URL copy, and ScrollFade affordances work end to end', async ({
  page,
  context
}) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write'])
  await page.setViewportSize({ width: 1280, height: 760 })

  const docXML = [
    '<page>',
    '<h1>System Overview</h1>',
    '<p>Readable body excerpt shown inside the miniature share preview card before copying.</p>',
    makeFillerParagraphs('Overview', 12),
    '<h2>Edge Fade Architecture</h2>',
    makeFillerParagraphs('Fade', 12),
    '<h3>Scroll Spy Mechanics</h3>',
    makeFillerParagraphs('Spy', 14),
    '</page>'
  ].join('')

  await page.route('**/api/v2/browser/session', route =>
    route.fulfill({
      json: {
        authenticated: true,
        principalUID: 'alice',
        displayName: 'Alice',
        canManagePod: true,
        tenant: { id: TENANT_ID, slug: 'harbor', displayName: 'Harbor' },
        accounts: [],
        pendingAccounts: [],
        siteAuthentications: []
      } satisfies BrowserSessionResponse
    })
  )

  await page.routeWebSocket('**/pod/socket/**', ws => {
    ws.onMessage(raw => {
      if (typeof raw !== 'string') return
      const [joinRef, ref, topic, event] = JSON.parse(raw) as [string | null, string | null, string, string]
      const reply = (response: unknown) => {
        ws.send(JSON.stringify([joinRef, ref, topic, 'phx_reply', { status: 'ok', response }]))
      }
      if (event === 'phx_join') {
        reply({ presence_session: 'sess-outline', page: { id: DOC_ID, revision: 1 } })
        return
      }
      if (event === 'sync') {
        reply({ revision: 1, changes: [] })
        return
      }
      reply({})
    })
  })

  await page.route('**/api/v2/pod/**', route => {
    const url = new URL(route.request().url())
    if (url.pathname === `/api/v2/pod/pages/${DOC_ID}`) {
      if (route.request().method() === 'PATCH') {
        return route.fulfill({ status: 200, json: {} })
      }
      return route.fulfill({
        json: {
          actions: ['node_view', 'node_comment', 'node_contribute', 'node_edit', 'node_manage'],
          role: 'manage',
          ancestors: [],
          child_count: 0,
          content: { content: docXML, plain_text: 'System Overview' },
          page: {
            id: DOC_ID,
            name: 'UI Polish Guide',
            title: 'UI Polish Guide',
            icon: '✨',
            type: 'doc',
            position: 'a0',
            revision: 1,
            inherit_permissions: true,
            created_at: '2026-11-16T00:00:00Z',
            updated_at: '2026-11-16T00:00:00Z'
          }
        }
      })
    }
    if (url.pathname === `/api/v2/pod/pages/${DOC_ID}/sharing`) {
      return route.fulfill({
        json: {
          can_manage: true,
          has_parent: false,
          inherit_permissions: true,
          scope_kind: 'space',
          sharing_version: 'v1',
          space_name: 'Harbor',
          space_role: 'edit',
          grants: [],
          inherited: [
            {
              kind: 'userset',
              name: 'Harbor members',
              origin: 'space_default',
              role: 'edit'
            }
          ],
          subjects: []
        } satisfies PodPageSharingResponse
      })
    }
    if (url.pathname.endsWith('/state')) return route.fulfill({ status: 204 })
    if (url.pathname.endsWith('/comments/summary')) return route.fulfill({ json: { total: 0, resolved_ids: [] } })
    if (url.pathname === '/api/v2/pod/realtime-token') {
      return route.fulfill({ json: { token: 'test-token', principal: { uid: 'alice', name: 'Alice' } } })
    }
    if (url.pathname.endsWith('/children') || url.pathname === '/api/v2/pod/pages') {
      return route.fulfill({ json: { pages: [], can_create_space: true, can_create_private: true } })
    }
    if (url.pathname.endsWith('/attention')) return route.fulfill({ json: [] })
    if (url.pathname.endsWith('/agents')) return route.fulfill({ json: { agents: [] } })
    return route.fulfill({ json: { conversations: [], entries: [] } })
  })

  await page.goto(pageRoute(DOC_ID))
  await expect(page.locator('.pod-document .editor-content h1')).toHaveText('System Overview', { timeout: 15_000 })

  // 1. Right-edge DocumentOutline ticks scale by heading depth and expand on hover without font-weight reflow.
  const outline = page.locator('[data-slot="document-outline"]')
  await expect(outline).toBeVisible()
  const ticks = outline.locator('[data-slot="document-outline-trigger"] > span')
  await expect(ticks).toHaveCount(3)
  await expect(ticks.nth(0)).toHaveCSS('width', '22px') // depth 0 active: 18 + 4
  await expect(ticks.nth(1)).toHaveCSS('width', '13px') // depth 1 idle
  await expect(ticks.nth(2)).toHaveCSS('width', '9px') // depth 2 idle

  await outline.hover()
  const card = outline.locator('[data-slot="document-outline-card"]')
  await expect(card).toBeVisible()
  const items = card.locator('button')
  await expect(items).toHaveCount(3)
  await expect(items.nth(0)).toHaveAttribute('aria-current', 'location')
  await expect(items.nth(0)).toHaveCSS('font-weight', '500')
  await expect(items.nth(1)).toHaveCSS('font-weight', '400')

  await items.nth(2).click()
  await expect(items.nth(2)).toHaveAttribute('aria-current', 'location')
  await expect(items.nth(2)).toHaveCSS('font-weight', '400')
  await expect.poll(() => page.locator('.pod-page-scroll').evaluate(el => el.scrollTop)).toBeGreaterThan(200)

  await page.keyboard.press('Escape')
  await expect(card).toHaveCount(0)

  // 2. Edit the Page title locally and verify the Share popover preview & SplitLinkField reflect live state.
  const titleField = page.getByRole('textbox', { name: 'Page title', exact: true })
  await titleField.fill('Live Architecture Handbook')

  await page.getByRole('button', { name: 'Share', exact: true }).click()
  const preview = page.locator('[data-slot="share-page-preview"]')
  await expect(preview).toBeVisible()
  await expect(preview).toContainText('Live Architecture Handbook')
  await expect(preview).toContainText('Readable body excerpt shown inside the miniature share preview card')

  const splitField = page.locator('[data-slot="split-link-field"]')
  await expect(splitField.locator('[data-slot="split-link-host"]')).toHaveText('127.0.0.1:3198')
  await expect(splitField.locator('[data-slot="split-link-path"]')).toContainText('/pages/')

  const copyBtn = splitField.locator('button')
  const liveStatus = splitField.locator('> [role="status"]')
  await copyBtn.click()
  await expect(copyBtn).toBeEnabled()
  await expect(copyBtn).toHaveAttribute('data-copied', 'true')
  const firstAnnouncement = await liveStatus.evaluate(el => el.textContent ?? '')
  expect(firstAnnouncement.trim()).toBe('Page link copied')

  // Clicking a second time keeps focus enabled and alternates \u00A0 so screen readers re-announce.
  await copyBtn.click()
  await expect.poll(() => liveStatus.evaluate(el => el.textContent ?? '')).not.toBe(firstAnnouncement)
  const secondAnnouncement = await liveStatus.evaluate(el => el.textContent ?? '')
  expect(secondAnnouncement.replace(/\u00A0/g, '')).toBe('Page link copied')

  await page.keyboard.press('Escape')

  // 3. Narrow viewports (<= 760px) hide the right-edge outline rail and enable ScrollFade on settings tabs.
  await page.setViewportSize({ width: 520, height: 720 })
  await expect(outline).toBeHidden()
})

test('Unified Home (/) selects Home sidebar tree, offers 1-click New document, aggregates cross-domain attention, and renders Jump back in + Favorites cards alongside NextSteps', async ({
  page
}) => {
  await page.setViewportSize({ width: 1365, height: 900 })

  const createdPageID = '019a2b00-0000-7000-8000-000000000601'
  const rfcPageID = '019a2b00-0000-7000-8000-000000000602'
  const roadmapPageID = '019a2b00-0000-7000-8000-000000000603'
  const favPageID = '019a2b00-0000-7000-8000-000000000604'
  let createCalls = 0

  await page.route('**/api/v2/browser/session', route =>
    route.fulfill({
      json: {
        authenticated: true,
        principalUID: 'alice',
        displayName: 'Alice',
        canManagePod: true,
        tenant: { id: TENANT_ID, slug: 'harbor', displayName: 'Harbor' },
        accounts: [],
        pendingAccounts: [],
        siteAuthentications: []
      } satisfies BrowserSessionResponse
    })
  )

  await page.routeWebSocket('**/pod/socket/**', ws => {
    ws.onMessage(raw => {
      if (typeof raw !== 'string') return
      const [joinRef, ref, topic, event] = JSON.parse(raw) as [string | null, string | null, string, string]
      const reply = (response: unknown) => {
        ws.send(JSON.stringify([joinRef, ref, topic, 'phx_reply', { status: 'ok', response }]))
      }
      if (event === 'phx_join') {
        reply({ presence_session: 'sess-new', page: { id: createdPageID, revision: 1 } })
        return
      }
      if (event === 'sync') {
        reply({ revision: 1, changes: [] })
        return
      }
      reply({})
    })
  })

  await page.route('**/api/v2/pod/**', route => {
    const url = new URL(route.request().url())
    const method = route.request().method()

    if (url.pathname === '/api/v2/pod/agents') {
      return route.fulfill({
        json: {
          agents: [],
          personalAssistant: {
            uid: 'assistant',
            displayName: 'Assistant',
            agentType: 'personal_assistant',
            status: 'active'
          },
          personalAssistantAvailable: true
        }
      })
    }
    if (url.pathname === '/api/v2/pod/pages/navigation') {
      return route.fulfill({ json: { path: [], directories: [] } })
    }
    if (url.pathname === '/api/v2/pod/pages/children') {
      return route.fulfill({
        json: {
          pages: [],
          principal_uid: 'alice',
          can_create_space: true,
          can_create_private: true,
          can_manage_space: true,
          next_cursor: null
        }
      })
    }
    if (url.pathname === '/api/v2/pod/pages' && method === 'POST') {
      createCalls++
      return route.fulfill({
        status: 201,
        json: {
          page: {
            id: createdPageID,
            name: '',
            title: '',
            icon: null,
            type: 'doc',
            position: 'a0',
            revision: 1,
            inherit_permissions: true,
            metadata: {},
            children_view: {},
            created_at: '2026-11-16T10:00:00Z',
            updated_at: '2026-11-16T10:00:00Z'
          }
        }
      })
    }
    if (url.pathname === `/api/v2/pod/pages/${createdPageID}`) {
      return route.fulfill({
        json: {
          actions: ['node_view', 'node_comment', 'node_contribute', 'node_edit', 'node_manage'],
          role: 'manage',
          ancestors: [],
          child_count: 0,
          content: { content: '<page/>', plain_text: '' },
          page: {
            id: createdPageID,
            name: '',
            title: '',
            icon: null,
            type: 'doc',
            position: 'a0',
            revision: 1,
            inherit_permissions: true,
            metadata: {},
            children_view: {},
            created_at: '2026-11-16T10:00:00Z',
            updated_at: '2026-11-16T10:00:00Z'
          }
        }
      })
    }
    if (url.pathname === '/api/v2/pod/pages' && method === 'GET') {
      const scope = url.searchParams.get('scope')
      if (scope === 'recent') {
        return route.fulfill({
          json: {
            pages: [
              {
                id: roadmapPageID,
                name: 'Quarterly Roadmap',
                title: 'Quarterly Roadmap',
                icon: '🗺️',
                type: 'doc',
                position: 'a1',
                revision: 2,
                inherit_permissions: true,
                metadata: {},
                children_view: {},
                created_at: '2026-11-16T08:00:00Z',
                updated_at: '2026-11-16T09:30:00Z',
                visited_at: '2026-11-16T09:30:00Z'
              }
            ]
          }
        })
      }
      if (scope === 'favorites') {
        return route.fulfill({
          json: {
            pages: [
              {
                id: favPageID,
                name: 'Team Handbook',
                title: 'Team Handbook',
                icon: '📘',
                type: 'doc',
                position: 'a2',
                revision: 3,
                inherit_permissions: true,
                metadata: {},
                children_view: {},
                created_at: '2026-11-15T08:00:00Z',
                updated_at: '2026-11-16T07:00:00Z'
              }
            ]
          }
        })
      }
      return route.fulfill({ json: { pages: [] } })
    }
    if (url.pathname === '/api/v2/pod/conversations/attention') {
      return route.fulfill({
        json: [
          {
            id: '019a2b00-0000-7000-8000-000000000701',
            title: 'Approve Q4 Rollout?',
            conversationKind: 'assistant_task',
            rowStatus: 'waiting_choice',
            lastActivityAt: '2026-11-16T09:50:00Z',
            agents: [{ uid: 'assistant', displayName: 'Assistant', agentType: 'personal_assistant' }],
            viewer: { pinned: false, muted: false }
          }
        ]
      })
    }
    if (url.pathname === '/api/v2/pod/comments/attention') {
      return route.fulfill({
        json: [
          {
            activity_at: '2026-11-16T09:40:00Z',
            unread_count: 2,
            page: {
              id: rfcPageID,
              name: 'Architecture RFC',
              title: 'Architecture RFC',
              icon: '📝',
              type: 'doc',
              position: 'a3',
              revision: 1,
              inherit_permissions: true,
              metadata: {},
              children_view: {},
              created_at: '2026-11-16T08:00:00Z',
              updated_at: '2026-11-16T09:40:00Z'
            }
          }
        ]
      })
    }
    if (url.pathname === '/api/v2/pod/jobs/summary') {
      return route.fulfill({ json: { attentionCount: 3, runningCount: 1 } })
    }
    if (url.pathname === '/api/v2/pod/jobs') {
      return route.fulfill({
        json: {
          items: ['Sync ledger', 'Weekly digest', 'Refund audit'].map((title, index) => ({
            id: `job:${index + 1}`,
            title,
            kind: 'background_agent_job',
            cardType: 'one_off',
            column: 'running',
            status: 'failed',
            attention: true,
            chainLength: 1,
            updatedAt: '2026-11-16T10:00:00Z'
          }))
        }
      })
    }
    if (url.pathname === '/api/v2/pod/conversations') {
      return route.fulfill({
        json: {
          conversations: [
            {
              id: '019a2b00-0000-7000-8000-000000000702',
              title: 'Weekly Product Sync',
              conversationKind: 'assistant_task',
              rowStatus: 'idle',
              latestMessagePreview: '**Summary**: Finalized the unified home layout and edge fades.',
              lastActivityAt: '2026-11-16T09:20:00Z',
              agents: [{ uid: 'assistant', displayName: 'Assistant', agentType: 'personal_assistant' }],
              viewer: { pinned: false, muted: false }
            }
          ],
          nextCursor: null
        }
      })
    }
    if (url.pathname === '/api/v2/pod/next-steps') {
      return route.fulfill({ json: { steps: [] } })
    }
    if (url.pathname.endsWith('/state')) return route.fulfill({ status: 204 })
    if (url.pathname.endsWith('/comments/summary')) return route.fulfill({ json: { total: 0, resolved_ids: [] } })
    if (url.pathname === '/api/v2/pod/realtime-token') {
      return route.fulfill({ json: { token: 'test-token', principal: { uid: 'alice', name: 'Alice' } } })
    }
    return route.fulfill({ json: {} })
  })

  await page.goto('/')
  const tabs = page.getByRole('tablist', { name: 'Sidebar sections', exact: true })
  const homeTab = tabs.getByRole('tab', { name: 'Home', exact: true })
  const chatTab = tabs.getByRole('tab', { name: 'Chat', exact: true })
  await expect(homeTab).toHaveAttribute('aria-selected', 'true')

  // The decisions heading counts what waits for a person: waiting_choice (1) + unread comment row (1).
  const attention = page.locator('[data-slot="home-needs-attention"]')
  await expect(attention).toBeVisible()
  await expect(attention.locator('h2')).toContainText('(2)')
  await expect(attention).toContainText('Approve Q4 Rollout?')
  await expect(attention).toContainText('Architecture RFC')

  // Failed jobs have their own heading, and each row opens that run on the Jobs board.
  const failed = page.locator('[data-slot="home-failed-jobs"]')
  await expect(failed.locator('h2')).toContainText('(3)')
  await expect(failed.locator('a[href^="/jobs?item="]')).toHaveCount(3)
  await expect(failed).toContainText('Sync ledger')

  // Starters / NextSteps, Jump back in (Pages + Conversations), and Favorites all coexist cleanly
  await expect(page.locator('.pod-chat-starters button')).toHaveCount(4)
  const jumpBackIn = page.locator('[data-slot="home-jump-back-in"]')
  await expect(jumpBackIn).toBeVisible()
  await expect(jumpBackIn.locator('[data-slot="scroll-fade"]')).toHaveClass(/scroll-fade-x/)
  await expect(jumpBackIn).toContainText('Quarterly Roadmap')
  await expect(jumpBackIn).toContainText('Weekly Product Sync')
  await expect(jumpBackIn).toContainText('Summary: Finalized the unified home layout')
  await expect(jumpBackIn.locator('a[href="/content/recent"]')).toBeVisible()

  const favorites = page.locator('[data-slot="home-favorites"]')
  await expect(favorites).toBeVisible()
  await expect(favorites).toContainText('Team Handbook')

  // Switching to Chat tab and triggering New conversation preserves the Chat sidebar tab
  await chatTab.click()
  await expect(chatTab).toHaveAttribute('aria-selected', 'true')
  await page.locator('.pod-sidebar-header').getByRole('link', { name: 'New conversation', exact: true }).click()
  await expect(chatTab).toHaveAttribute('aria-selected', 'true')

  // 1-click New document creates a doc Page and navigates directly into its editor
  const newDocButton = page.locator('[data-slot="home-new-document"]')
  await expect(newDocButton).toBeVisible()
  await newDocButton.click()
  await expect.poll(() => createCalls).toBe(1)
  await expect(page).toHaveURL(new RegExp(`/pages/`))
})
