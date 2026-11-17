import { expect, test } from '@playwright/test'

const settings = {
  displayName: 'Fixture Pod',
  defaultLocale: 'en-US',
  allowExternalGuests: true,
  emailAvailable: true,
  loginPolicy: { allowed_email_domains: [], allow_email_otp: true }
}

// Browser unit coverage: hold API replies while exercising the actual settings forms.
test.beforeEach(async ({ page }) => {
  await page.route('**/api/v2/pod/admin/settings', route => route.fulfill({ json: settings }))
})

test('General settings preserve edits made during a save without resetting the pending request', async ({ page }) => {
  const submitted = Promise.withResolvers<Record<string, unknown>>()
  const response = Promise.withResolvers<void>()
  await page.route('**/api/v2/pod/admin/settings', async route => {
    if (route.request().method() === 'GET') return route.fulfill({ json: settings })
    submitted.resolve(route.request().postDataJSON().data)
    await response.promise
    await route.fulfill({ json: settings })
  })
  await page.goto('/integration/error-boundaries/index.html?surface=pod-settings')
  const name = page.getByLabel('Space name', { exact: true })
  await expect(name).toHaveValue('Fixture Pod')
  await name.fill('Saved name')
  const save = page.getByRole('button', { name: 'Save changes', exact: true })
  await save.click()
  expect(await submitted.promise).toMatchObject({ displayName: 'Saved name' })
  await name.fill('New unsaved name')
  await expect(save).toBeDisabled()
  response.resolve()
  await expect(save).toBeEnabled()
  await expect(name).toHaveValue('New unsaved name')
})

test('a pending member submission locks its fields and preserves its draft after rejection', async ({ page }) => {
  const submitted = Promise.withResolvers<void>()
  const response = Promise.withResolvers<void>()
  await page.route('**/api/v2/pod/admin/members', async route => {
    if (route.request().method() === 'GET') return route.fulfill({ json: { members: [] } })
    submitted.resolve()
    await response.promise
    await route.fulfill({ status: 422, json: { error: { message: 'Member email rejected' } } })
  })
  await page.goto('/integration/error-boundaries/index.html?surface=pod-settings')
  await page.getByRole('tab', { name: 'Members and administrators', exact: true }).click()
  await page.getByRole('button', { name: 'Create a pending member', exact: true }).click()
  const name = page.getByLabel('Your display name', { exact: true })
  const email = page.getByLabel('Email address', { exact: true })
  await name.fill('New colleague')
  await email.fill('person@example.com')
  await page.getByRole('button', { name: 'Create a pending member', exact: true }).click()
  await submitted.promise
  await expect(name).toBeDisabled()
  await expect(email).toBeDisabled()
  response.resolve()
  await expect(name).toBeEnabled()
  await expect(name).toHaveValue('New colleague')
  await expect(page.getByText('Member email rejected', { exact: true })).toBeVisible()
  await email.fill('another@example.com')
  await expect(page.getByText('Member email rejected', { exact: true })).toHaveCount(0)
})

test('an invitation locks during submission and a later field edit clears the rejected request', async ({ page }) => {
  const submitted = Promise.withResolvers<void>()
  const response = Promise.withResolvers<void>()
  await page.route('**/api/v2/pod/admin/invitations', async route => {
    if (route.request().method() === 'GET') return route.fulfill({ json: { invitations: [] } })
    submitted.resolve()
    await response.promise
    await route.fulfill({ status: 422, json: { error: { message: 'Invitation email rejected' } } })
  })
  await page.goto('/integration/error-boundaries/index.html?surface=pod-settings')
  await page.getByRole('tab', { name: 'Invitations', exact: true }).click()
  const email = page.locator('#invite-email')
  await email.fill('person@example.com')
  await page.getByRole('button', { name: 'Create invitation', exact: true }).click()
  await submitted.promise
  await expect(email).toBeDisabled()
  await expect(page.locator('#invite-uses')).toBeDisabled()
  response.resolve()
  await expect(email).toBeEnabled()
  await expect(email).toHaveValue('person@example.com')
  await expect(page.getByText('Invitation email rejected', { exact: true })).toBeVisible()
  await email.fill('another@example.com')
  await expect(page.getByText('Invitation email rejected', { exact: true })).toHaveCount(0)
})
