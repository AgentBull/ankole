import { expect, test } from '@playwright/test'

// Browser unit coverage: the real dialog and SDK retain IDs when the transport outcome is uncertain.
test.beforeEach(async ({ page }) => {
  await page.route('**/api/v2/pod/agents', route => route.fulfill({ json: { agents: [] } }))
  await page.route('**/api/v2/pod/teammates*', route => route.fulfill({ json: { teammates: [] } }))
})

test('retrying an unchanged uncertain group creation reuses IDs while editing mints fresh IDs without keeping stale errors', async ({
  page
}) => {
  const attempts: Array<Record<string, unknown>> = []
  await page.route('**/api/v2/pod/conversations', async route => {
    attempts.push(route.request().postDataJSON().data)
    await route.fulfill({
      status: attempts.length === 2 ? 422 : 503,
      json: { error: { message: 'Response unavailable' } }
    })
  })
  await page.goto('/integration/new-group/index.html')
  await page.getByRole('textbox', { name: 'Group name' }).fill('Architecture Sync')
  await page.getByRole('textbox', { name: 'First message' }).fill('Review the design')
  await page.getByRole('button', { name: 'Create group', exact: true }).click()
  await expect(page.getByText('Response unavailable', { exact: true })).toBeVisible()

  // Retrying the identical submission after an uncertain transport failure reuses the same IDs.
  await page.getByRole('button', { name: 'Create group', exact: true }).click()
  await expect.poll(() => attempts.length).toBe(2)
  expect(attempts[0]).toMatchObject({
    title: 'Architecture Sync',
    text: 'Review the design',
    participantUIDs: ['colleague']
  })
  expect(attempts[1]).toMatchObject({
    conversationID: attempts[0]!.conversationID,
    messageID: attempts[0]!.messageID,
    title: 'Architecture Sync',
    text: 'Review the design'
  })

  // Editing the title or first message clears stale errors and mints fresh IDs so edits cannot hit 409 or be ignored.
  await expect(page.getByRole('textbox', { name: 'First message' })).toBeEnabled()
  await page.getByRole('textbox', { name: 'Group name' }).fill('Architecture Review')
  await expect(page.getByText('Response unavailable', { exact: true })).not.toBeVisible()
  await page.getByRole('textbox', { name: 'First message' }).fill('Review the latest design')
  await page.getByRole('button', { name: 'Create group', exact: true }).click()
  await expect.poll(() => attempts.length).toBe(3)
  expect(attempts[2]).toMatchObject({
    title: 'Architecture Review',
    text: 'Review the latest design'
  })
  expect(attempts[2]!.conversationID).not.toBe(attempts[0]!.conversationID)
  expect(attempts[2]!.messageID).not.toBe(attempts[0]!.messageID)

  // Retrying that edited draft unchanged reuses the newly minted IDs.
  await page.getByRole('button', { name: 'Create group', exact: true }).click()
  await expect.poll(() => attempts.length).toBe(4)
  expect(attempts[3]!.conversationID).toBe(attempts[2]!.conversationID)
  expect(attempts[3]!.messageID).toBe(attempts[2]!.messageID)
})

test('retrying an unchanged rejected attempt keeps IDs while edits mint fresh IDs', async ({ page }) => {
  const attempts: Array<Record<string, unknown>> = []
  await page.route('**/api/v2/pod/conversations', async route => {
    attempts.push(route.request().postDataJSON().data)
    await route.fulfill({ status: 422, json: { error: { message: 'Choose another first message' } } })
  })
  await page.goto('/integration/new-group/index.html')
  await page.getByRole('textbox', { name: 'First message' }).fill('First draft')
  await page.getByRole('button', { name: 'Create group', exact: true }).click()
  await expect(page.getByText('Choose another first message', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Create group', exact: true }).click()
  await expect.poll(() => attempts.length).toBe(2)
  expect(attempts[1]!.conversationID).toBe(attempts[0]!.conversationID)
  expect(attempts[1]!.messageID).toBe(attempts[0]!.messageID)

  await page.getByRole('textbox', { name: 'First message' }).fill('Corrected draft')
  await expect(page.getByText('Choose another first message', { exact: true })).not.toBeVisible()
  await page.getByRole('button', { name: 'Create group', exact: true }).click()
  await expect.poll(() => attempts.length).toBe(3)
  expect(attempts[2]!.conversationID).not.toBe(attempts[0]!.conversationID)
  expect(attempts[2]!.messageID).not.toBe(attempts[0]!.messageID)
})
