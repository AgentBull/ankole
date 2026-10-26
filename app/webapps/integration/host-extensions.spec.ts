import { expect, test } from '@playwright/test'

test('FixturePodModule loads on selection and returns to General when its feature disappears', async ({ page }) => {
  let requests = 0
  await page.route('**/api/v2/pod/admin/settings', route =>
    route.fulfill({
      json: {
        displayName: 'Fixture Pod',
        allowExternalGuests: true,
        emailAvailable: true,
        loginPolicy: { allowed_email_domains: [], allow_email_otp: true }
      }
    })
  )
  await page.route('**/api/v2/saas-pod/fixture-settings', route => {
    requests++
    return route.fulfill({ json: { tenantID: 'fixture-tenant' } })
  })
  await page.goto('/integration/host-extensions/index.html')
  const tab = page.getByRole('tab', { name: 'Fixture settings', exact: true })
  await expect(tab).toBeVisible()
  await expect(page.getByTestId('ungated-slot')).toBeVisible()
  expect(requests).toBe(0)
  await tab.click()
  await expect(page.getByTestId('fixture-settings')).toContainText('fixture-tenant')
  expect(requests).toBe(1)
  await page.getByRole('button', { name: 'Toggle fixture feature' }).click()
  await expect(tab).toHaveCount(0)
  await expect(page.getByTestId('ungated-slot')).toBeVisible()
  await expect(page.getByRole('tab', { name: 'General and sign-in', exact: true })).toHaveAttribute(
    'aria-selected',
    'true'
  )
  await expect(page.getByTestId('fixture-settings')).toHaveCount(0)
})

test('FixtureAuthChallenge binds headers to an attempt and resets on send, resend and email change', async ({
  page
}) => {
  const headers: string[] = []
  await page.route('**/api/v2/browser/sessions/email-otp/challenges', route => {
    headers.push(route.request().headers()['x-fixture-challenge'] ?? '')
    return route.fulfill({ json: { challengeID: 'fixture-code', expiresAt: '2099-01-01T00:00:00Z' } })
  })
  await page.goto('/integration/host-extensions/index.html?auth')
  await page.getByLabel('Email address', { exact: true }).fill('fixture@example.test')
  const send = page.getByRole('button', { name: 'Send code', exact: true })
  await expect(send).toBeDisabled()
  const challenge = page.getByTestId('fixture-challenge')
  await challenge.click()
  await expect(send).toBeEnabled()
  await page.getByLabel('Email address', { exact: true }).fill('edited@example.test')
  await page.getByLabel('Email address', { exact: true }).fill('fixture@example.test')
  await expect(send).toBeDisabled()
  const first = await challenge.getAttribute('data-attempt')
  await challenge.click()
  await send.click()
  await expect(page.getByRole('button', { name: 'Resend code' })).toBeDisabled()
  await expect(challenge).not.toHaveAttribute('data-attempt', first!)
  expect(headers).toEqual([first])
  const code = page.getByLabel('6-digit email code', { exact: true })
  await code.fill('123456')
  await page.getByRole('button', { name: 'Toggle fixture feature' }).click()
  await expect(challenge).toHaveCount(0)
  await expect(code).toHaveValue('123456')
  await expect(page.getByLabel('Email address', { exact: true })).toHaveValue('fixture@example.test')
  await expect(page.getByRole('button', { name: 'Verify and continue', exact: true })).toBeEnabled()
  await page.getByRole('button', { name: 'Toggle fixture feature' }).click()
  await expect(challenge).toBeVisible()
  await expect(code).toHaveValue('123456')
  await expect(page.getByRole('button', { name: 'Resend code' })).toBeDisabled()
  const second = await challenge.getAttribute('data-attempt')
  await challenge.click()
  await page.getByRole('button', { name: 'Resend code' }).click()
  await expect.poll(() => headers).toEqual([first, second])
  await expect(page.getByRole('button', { name: 'Resend code' })).toBeDisabled()
  await page.getByRole('button', { name: 'Use another email' }).click()
  await page.getByLabel('Email address', { exact: true }).fill('changed@example.test')
  await expect(send).toBeDisabled()
  await page.getByRole('button', { name: 'Toggle fixture feature' }).click()
  await expect(challenge).toHaveCount(0)
  await expect(send).toBeEnabled()
  await send.click()
  await expect.poll(() => headers.length).toBe(3)
  expect(headers[2]).toBe('')
})

test('inactive Plugins contribute neither Pod tabs nor a login challenge', async ({ page }) => {
  await page.route('**/api/v2/pod/admin/settings', route =>
    route.fulfill({
      json: {
        displayName: 'Fixture Pod',
        allowExternalGuests: true,
        emailAvailable: true,
        loginPolicy: { allowed_email_domains: [], allow_email_otp: true }
      }
    })
  )
  await page.goto('/integration/host-extensions/index.html?inactive')
  await expect(page.getByRole('tab', { name: 'Fixture settings', exact: true })).toHaveCount(0)
  await expect(page.getByTestId('ungated-slot')).toHaveCount(0)
  await page.goto('/integration/host-extensions/index.html?auth&inactive')
  await page.getByLabel('Email address', { exact: true }).fill('fixture@example.test')
  await expect(page.getByTestId('fixture-challenge')).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Send code', exact: true })).toBeEnabled()
})
