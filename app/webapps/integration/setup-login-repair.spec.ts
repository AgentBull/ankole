import { expect, test } from '@playwright/test'

test('Setup freezes pending choices and back navigation restores the acknowledged pack selection', async ({ page }) => {
  let selected = ['general']
  let release!: () => void
  let started!: () => void
  const saved = new Promise<void>(resolve => {
    started = resolve
  })
  const gate = new Promise<void>(resolve => {
    release = resolve
  })
  await page.route('**/api/v2/browser/setup/**', async route => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/state')) {
      return route.fulfill({
        json: {
          authenticated: true,
          completed: false,
          currentLocale: 'en-US',
          availableLocales: ['en-US'],
          publicBaseURL: 'https://example.test'
        }
      })
    }
    if (path.endsWith('/plugins/enabled')) return route.fulfill({ json: { pluginIDs: [] } })
    if (path.endsWith('/plugins')) {
      return route.fulfill({
        json: route.request().method() === 'GET' ? { plugins: [], enabledPluginIDs: [] } : { pluginIDs: [] }
      })
    }
    if (path.endsWith('/identity-provider-adapters')) return route.fulfill({ json: { adapters: [] } })
    if (path.endsWith('/brain-packs')) {
      if (route.request().method() === 'GET') {
        return route.fulfill({
          json: {
            packs: [
              { name: 'general', required: true },
              { name: 'finance', required: false }
            ],
            selected
          }
        })
      }
      selected = route.request().postDataJSON().data.packs
      started()
      await gate
      return route.fulfill({ json: { packs: selected } })
    }
    return route.fulfill({ status: 404, json: {} })
  })
  try {
    await page.goto('/setup-repair')
    await page.getByRole('button', { name: 'Save plugin selection', exact: true }).click()
    const optional = page.getByRole('checkbox').nth(1)
    await optional.check()
    await page.getByRole('button', { name: 'Save industry selection', exact: true }).click()
    await saved
    await expect(optional).toBeDisabled()
    await expect(page.getByRole('navigation').getByRole('button').filter({ hasText: 'Plugins' })).toBeDisabled()
    release()
    await expect(page.getByRole('navigation').getByRole('button').filter({ hasText: 'User sign-in' })).toHaveAttribute(
      'aria-current',
      'step'
    )
    await page
      .getByRole('navigation')
      .getByRole('button')
      .filter({ hasText: /Industry/ })
      .click()
    await expect(page.getByRole('checkbox').nth(1)).toBeChecked()
    expect(selected).toContain('finance')
  } finally {
    release()
  }
})

test('an in-flight code request freezes the email and a late lockout clears when the email changes', async ({
  page
}) => {
  let release!: () => void
  let started!: () => void
  const pending = new Promise<void>(resolve => {
    started = resolve
  })
  const gate = new Promise<void>(resolve => {
    release = resolve
  })
  await page.route('**/api/v2/browser/sessions/email-otp/challenges', async route => {
    expect(route.request().postDataJSON().data.email).toBe('account-a@example.test')
    started()
    await gate
    return route.fulfill({
      status: 429,
      json: {
        errors: [
          { status: '429', code: 'rate_limited', detail: 'rate_limited', meta: { details: { retryAfterSeconds: 60 } } }
        ]
      }
    })
  })
  try {
    await page.goto('/login-repair')
    const email = page.getByRole('textbox', { name: 'Email address', exact: true })
    await email.fill('account-a@example.test')
    await page.getByRole('button', { name: 'Send code', exact: true }).click()
    await pending
    await expect(email).toBeDisabled()
    release()
    await expect(email).toBeEnabled()
    await expect(page.getByRole('alert')).toBeVisible()
    await email.fill('account-b@example.test')
    await expect(page.getByRole('alert')).toHaveCount(0)
    await expect(page.getByRole('button', { name: 'Send code', exact: true })).toBeEnabled()
  } finally {
    release()
  }
})
