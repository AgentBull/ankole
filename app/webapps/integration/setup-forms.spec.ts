import { expect, test } from '@playwright/test'

test('bootstrap validates on submit and then on input', async ({ page }) => {
  let submitted: { activation_code: string; locale: string } | undefined
  await page.route('**/api/v2/browser/setup/**', async route => {
    const path = new URL(route.request().url()).pathname
    if (path.endsWith('/state')) {
      return route.fulfill({
        json: {
          authenticated: false,
          completed: false,
          currentLocale: 'en-US',
          availableLocales: ['en-US', 'zh-Hans-CN'],
          publicBaseURL: 'https://example.test'
        }
      })
    }
    if (path.endsWith('/sessions') && route.request().method() === 'POST') {
      submitted = route.request().postDataJSON().data
      return route.fulfill({ json: {} })
    }
    return route.fulfill({ status: 404, json: {} })
  })

  await page.goto('/setup-repair')
  const code = page.getByRole('textbox')
  await code.fill('ab')
  await expect(page.getByRole('alert')).toHaveCount(0)
  await code.fill('')
  await page.getByRole('button', { name: 'Continue', exact: true }).click()
  await expect(page.getByRole('alert')).toContainText('Bootstrap activation code')
  await expect(page.getByRole('alert')).toContainText('is required')
  await code.fill('abc')
  await expect(page.getByRole('alert')).toHaveCount(0)
  await page.getByRole('button', { name: 'Continue', exact: true }).click()
  await expect.poll(() => submitted).toEqual({ activation_code: 'ABC', locale: 'en-US' })
})

test('the first administrator completes setup only after SMTP configuration and code verification', async ({
  page
}) => {
  let sent: Record<string, unknown> | undefined
  let verified: Record<string, unknown> | undefined
  await page.route('**/api/v2/browser/setup/**', async route => {
    const url = new URL(route.request().url())
    const path = url.pathname
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
    if (path.endsWith('/plugins')) return route.fulfill({ json: { plugins: [], enabledPluginIDs: [] } })
    if (path.endsWith('/brain-packs')) {
      return route.fulfill({ json: { packs: [{ name: 'general', required: true }], selected: ['general'] } })
    }
    if (path.endsWith('/identity-provider-adapters')) return route.fulfill({ json: { adapters: [] } })
    if (path.endsWith('/email-otp/challenges')) {
      sent = route.request().postDataJSON().data
      return route.fulfill({ status: 201, json: { challengeID: '018f0000-0000-7000-8000-000000000001' } })
    }
    if (path.endsWith('/email-otp/verifications')) {
      verified = route.request().postDataJSON().data
      return route.fulfill({ status: 201, json: { returnTo: '/sessions/new' } })
    }
    return route.fulfill({ status: 404, json: {} })
  })

  await page.goto('/setup-repair')
  await page.getByRole('button', { name: 'Save plugin selection', exact: true }).click()
  await page.getByRole('button', { name: 'Save industry selection', exact: true }).click()
  await page.getByRole('textbox', { name: 'SMTP server', exact: true }).fill('smtp.example.test')
  await page.getByLabel('Port', { exact: true }).fill('587')
  await page.getByRole('textbox', { name: 'Sender email', exact: true }).fill('login@example.test')
  await page.getByRole('textbox', { name: 'Administrator email', exact: true }).fill('ada@example.com')
  await page.getByRole('button', { name: 'Send code', exact: true }).click()
  await expect
    .poll(() => sent)
    .toMatchObject({
      email: 'ada@example.com',
      mail: { server: 'smtp.example.test', port: 587, from: 'login@example.test' }
    })
  expect(verified).toBeUndefined()
  await page.getByRole('textbox', { name: '6-digit email code', exact: true }).fill('123456')
  await page.getByRole('button', { name: 'Verify code and complete setup', exact: true }).click()
  await expect
    .poll(() => verified)
    .toMatchObject({ challengeID: '018f0000-0000-7000-8000-000000000001', code: '123456' })
})
