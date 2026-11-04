import { expect, test, type Route } from '@playwright/test'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import type { PodAgentsResponse, PodPageNavigationResponse } from '../pod/api/generated/types.gen'

// Browser unit coverage: keep the real Pod shell and keyboard controls, and hold the agents query at its HTTP boundary.
for (const mobile of [false, true]) {
  test(`agents arriving after keyboard selection preserve the ${mobile ? 'mobile' : 'desktop'} sidebar tab`, async ({
    page
  }) => {
    await page.setViewportSize(mobile ? { width: 390, height: 844 } : { width: 1365, height: 900 })
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
    await expect(tabs.getByRole('tab', { name: 'Meta Ankole', exact: true })).toBeVisible()
    await expect(home).toHaveAttribute('aria-selected', 'true')
    await expect(home).toBeFocused()
    await expect(page).toHaveURL(url => url.pathname === '/')
  })
}
