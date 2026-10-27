import { expect, test } from '@playwright/test'

test('an Agent override names its capability and the plugin detail names the tab', async ({ page }) => {
  await page.route(
    url => url.pathname.startsWith('/api/v2/'),
    async route => {
      const path = new URL(route.request().url()).pathname
      if (path.endsWith('/library-capabilities')) {
        return route.fulfill({
          json: {
            agent_plugins: [
              {
                id: 'office',
                description: 'Office tools',
                version: '1',
                global_default_enabled: true,
                effective_enabled: true,
                override_enabled: null,
                skills: []
              }
            ],
            skills: []
          }
        })
      }
      if (path.endsWith('/agents')) {
        return route.fulfill({
          json: { data: [{ type: 'agent', id: 'agent-one', attributes: { handle: 'agent-one' } }] }
        })
      }
      if (path.endsWith('/skill-lessons')) return route.fulfill({ json: { data: [] } })
      return route.fulfill({ status: 404, json: {} })
    }
  )

  await page.goto('/agent-library?scope=agent-one')
  const overrideName = 'Set override for \u2068Office\u2069'
  await expect(page.getByRole('combobox', { name: overrideName, exact: true })).toBeVisible()
  await page.goto('/agent-library/agent-plugins/office?scope=agent-one')
  await expect(page).toHaveTitle('Office · Ankole Console')
  await expect(page.getByRole('combobox', { name: overrideName, exact: true })).toBeVisible()
})
