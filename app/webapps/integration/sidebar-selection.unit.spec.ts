import { expect, test, type Page, type Route } from '@playwright/test'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import type { MetaSkillsResponse, PodAgentsResponse, PodPageNavigationResponse } from '../pod/api/generated/types.gen'

function mockPodSession(page: Page) {
  return page.route('**/api/v2/browser/session', route =>
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
}

// Browser unit coverage: keep the real Pod shell and keyboard controls, and hold the agents query at its HTTP boundary.
for (const mobile of [false, true]) {
  test(`agents arriving after keyboard selection preserve the ${mobile ? 'mobile' : 'desktop'} sidebar tab and render Meta Ankole collapsed in Home`, async ({
    page
  }) => {
    await page.setViewportSize(mobile ? { width: 390, height: 844 } : { width: 1365, height: 900 })
    await mockPodSession(page)
    let release!: (route: Route) => void
    const agents = new Promise<Route>(resolve => {
      release = resolve
    })
    await page.route('**/api/v2/pod/**', route => {
      const path = new URL(route.request().url()).pathname
      if (path.endsWith('/agents')) {
        release(route)
        return
      }
      if (path.endsWith('/pages/navigation')) {
        return route.fulfill({ json: { path: [], directories: [] } satisfies PodPageNavigationResponse })
      }
      return route.fulfill({
        json: path.endsWith('/conversations')
          ? { conversations: [], nextCursor: null }
          : path.startsWith('/api/v2/pod/pages')
            ? {
                pages: [],
                can_create_space: false,
                can_create_private: false,
                can_manage_space: false,
                next_cursor: null
              }
            : []
      })
    })
    await page.goto('/')
    if (mobile) await page.getByRole('button', { name: 'Show sidebar', exact: true }).click()
    const tabs = page.getByRole('tablist', { name: 'Sidebar sections', exact: true })
    const chat = tabs.getByRole('tab', { name: 'Chat', exact: true })
    const home = tabs.getByRole('tab', { name: 'Home', exact: true })
    await expect(chat).toHaveAttribute('aria-selected', 'true')
    await chat.focus()
    await chat.press('ArrowLeft')
    await expect(home).toBeFocused()
    await expect(home).toHaveAttribute('aria-selected', 'true')
    await expect(page).toHaveURL(url => url.pathname === '/')

    await (
      await agents
    ).fulfill({
      json: { agents: [], personalAssistant: null, personalAssistantAvailable: true } satisfies PodAgentsResponse
    })
    await expect(tabs.getByRole('tab')).toHaveCount(2)
    await expect(tabs.getByRole('tab', { name: 'Meta Ankole', exact: true })).toHaveCount(0)
    await expect(home).toHaveAttribute('aria-selected', 'true')
    await expect(home).toBeFocused()
    await expect(page).toHaveURL(url => url.pathname === '/')

    const meta = page.getByRole('region', { name: 'Meta Ankole', exact: true })
    const metaToggle = meta.getByRole('button', { name: 'Meta Ankole', exact: true })
    await expect(metaToggle).toHaveAttribute('aria-expanded', 'false')
    await expect(meta.getByRole('link', { name: 'Brain', exact: true })).toHaveCount(0)

    await metaToggle.click()
    await expect(metaToggle).toHaveAttribute('aria-expanded', 'true')
    for (const branch of ['Brain', 'Skills', 'Agents']) {
      await expect(meta.getByRole('button', { name: branch, exact: true })).toHaveAttribute('aria-expanded', 'false')
      await expect(meta.getByRole('link', { name: branch, exact: true })).toBeVisible()
    }
    if (mobile) {
      const linkHeights = await meta
        .locator('.pod-tree-link')
        .evaluateAll(elements => elements.map(element => element.getBoundingClientRect().height))
      expect(linkHeights.length).toBe(3)
      expect(linkHeights.every(height => height >= 40)).toBe(true)
      const toggleSizes = await meta.locator('.pod-tree-toggle').evaluateAll(elements =>
        elements.map(element => {
          const bounds = element.getBoundingClientRect()
          const icon = element.querySelector('svg')!
          const iconStyle = getComputedStyle(icon)
          return {
            width: Number(bounds.width.toFixed(3)),
            height: Number(bounds.height.toFixed(3)),
            iconWidth: iconStyle.width,
            iconHeight: iconStyle.height
          }
        })
      )
      for (const size of toggleSizes) {
        expect(size.width).toBeGreaterThanOrEqual(32)
        expect(size.height).toBeGreaterThanOrEqual(32)
        expect(size.iconWidth).toBe('16px')
        expect(size.iconHeight).toBe('16px')
      }
    }
  })
}

test('Meta Ankole routes select Home, keep Meta Ankole collapsed until toggled, and highlight only the active tree row', async ({
  page
}) => {
  await page.setViewportSize({ width: 1365, height: 900 })
  await mockPodSession(page)
  await page.route('**/api/v2/pod/**', route => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/agents')) {
      return route.fulfill({
        json: { agents: [], personalAssistant: null, personalAssistantAvailable: true } satisfies PodAgentsResponse
      })
    }
    if (path.endsWith('/meta/skills')) {
      return route.fulfill({
        json: {
          can_create: false,
          can_create_workspace: false,
          skills: [
            {
              id: 'skill-1',
              slug: 'ops-guide',
              name: 'Ops Guide',
              description: 'Operational handbook',
              source_kind: 'custom',
              agent_uids: [],
              runtime_agent_uids: [],
              can_bind_all: false,
              can_delete: false,
              can_edit: false,
              can_publish: false,
              colleague_count: 0,
              assistant_enabled: false,
              runtime_assistant_enabled: false,
              enabled_for_all: false,
              manifest_markdown: '# Ops Guide',
              manifest_xml: '<page><p>Ops Guide</p></page>',
              metadata: {},
              revision: 1
            }
          ]
        } satisfies MetaSkillsResponse
      })
    }
    if (path.endsWith('/pages/navigation')) {
      return route.fulfill({ json: { path: [], directories: [] } satisfies PodPageNavigationResponse })
    }
    return route.fulfill({
      json: path.endsWith('/conversations')
        ? { conversations: [], nextCursor: null }
        : path.startsWith('/api/v2/pod/pages')
          ? {
              pages: [],
              can_create_space: false,
              can_create_private: false,
              can_manage_space: false,
              next_cursor: null
            }
          : []
    })
  })

  await page.goto('/meta/skills')
  const tabs = page.getByRole('tablist', { name: 'Sidebar sections', exact: true })
  await expect(tabs.getByRole('tab', { name: 'Home', exact: true })).toHaveAttribute('aria-selected', 'true')

  const meta = page.getByRole('region', { name: 'Meta Ankole', exact: true })
  const metaToggle = meta.getByRole('button', { name: 'Meta Ankole', exact: true })
  await expect(metaToggle).toHaveAttribute('aria-expanded', 'false')

  await metaToggle.click()
  await expect(metaToggle).toHaveAttribute('aria-expanded', 'true')
  const skillsLink = meta.getByRole('link', { name: 'Skills', exact: true })
  await expect(skillsLink).toHaveAttribute('aria-current', 'page')
  await expect(meta.locator('a[aria-current="page"]')).toHaveCount(1)
  await expect(skillsLink.locator('..')).toHaveAttribute('data-active', '')

  await meta.getByRole('button', { name: 'Skills', exact: true }).click()
  await expect(meta.getByRole('link', { name: 'ops-guide', exact: true })).toBeVisible()

  await page.getByRole('tab', { name: 'Chat', exact: true }).click()
  await page.getByRole('tab', { name: 'Home', exact: true }).click()
  await expect(meta.getByRole('button', { name: 'Skills', exact: true })).toHaveAttribute('aria-expanded', 'true')
})
