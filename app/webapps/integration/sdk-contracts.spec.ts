import { expect, test } from '@playwright/test'

test('same-table hooks refresh once per live event and do not read after revocation', async ({ page }) => {
  await page.goto('/integration/applet-frame/sdk/index.html')
  await expect(page.locator('[data-current]')).toHaveText('1')
  await expect(page.locator('[data-aggregate]')).toHaveText('1')
  const reads = page.locator('[data-base-reads]')
  await expect
    .poll(async () => {
      const report = await reads.innerText()
      return report ? JSON.parse(report) : undefined
    })
    .toEqual({ records: 1, aggregate: 1 })
  const before = JSON.parse(await reads.innerText())
  await page.getByRole('button', { name: 'Other client writes', exact: true }).click()
  await expect(page.locator('[data-current]')).toHaveText('42')
  const after = { records: before.records + 1, aggregate: before.aggregate + 1 }
  await expect.poll(async () => JSON.parse(await reads.innerText())).toEqual(after)
  await page.getByRole('button', { name: 'Revoke table access', exact: true }).click()
  await expect(page.locator('[data-current]')).toHaveText('')
  await expect(page.locator('[data-aggregate]')).toHaveText('')
  await expect.poll(async () => JSON.parse(await reads.innerText())).toEqual(after)
  await page.getByRole('button', { name: 'Restore table access', exact: true }).click()
  await page.getByRole('button', { name: 'Unmount SDK', exact: true }).click()
  await page.getByRole('button', { name: 'Remount SDK', exact: true }).click()
  await expect(page.locator('[data-current]')).toHaveText('42')
  await expect(page.locator('[data-aggregate]')).toHaveText('1')
})

test('a caught render failure can restart its Applet without reloading the Pod or discarding confirmed data', async ({
  page
}) => {
  await page.goto('/integration/applet-frame/sdk/index.html')
  await expect(page.locator('[data-current]')).toHaveText('1')
  await page.getByRole('button', { name: 'Other client writes', exact: true }).click()
  await expect(page.locator('[data-current]')).toHaveText('42')
  await page.getByRole('button', { name: 'Crash render', exact: true }).click()
  await expect(page.getByRole('alert')).toHaveText('The applet cannot be displayed. Reload it to continue.')
  await expect(page.getByRole('button', { name: 'Emit fixture event', exact: true })).toBeVisible()
  const retry = page.getByRole('button', { name: 'Reload applet', exact: true })
  await retry.focus()
  await retry.press('Enter')
  await expect(page.getByRole('alert')).toHaveCount(0)
  await expect(page.locator('[data-current]')).toHaveText('42')
  await expect
    .poll(async () => JSON.parse(await page.locator('[data-lifecycle]').innerText()))
    .toMatchObject({
      opens: 2,
      closes: 1,
      listeners: 1,
      nodes: 1
    })
})

test('record data keeps its identity across unrelated renders, including a pending edit', async ({ page }) => {
  await page.goto('/integration/applet-frame/sdk/index.html')
  await expect(page.locator('[data-current]')).toHaveText('1')
  for (const pending of [false, true]) {
    if (pending) {
      await page.getByRole('button', { name: 'Start edit', exact: true }).click()
      await page.getByRole('button', { name: 'Block next write', exact: true }).click()
      await page.getByRole('button', { name: 'Save original edit', exact: true }).click()
      await expect(page.locator('[data-current]')).toHaveText('9')
    }
    await page.getByRole('button', { name: 'Capture read result', exact: true }).click()
    await expect(page.locator('[data-read-identity]')).toHaveText('stable')
    await page.getByRole('button', { name: 'Emit fixture event', exact: true }).click()
    await expect(page.locator('[data-read-identity]')).toHaveText('stable')
  }
  await page.getByRole('button', { name: 'Release denied write', exact: true }).click()
  await expect(page.locator('[data-write-pending]')).toHaveText('')
  await expect(page.locator('[data-confirmed]')).toHaveText('9')
})

test('a failed pending write preserves a newer realtime read when its final refetch also fails', async ({ page }) => {
  await page.goto('/integration/applet-frame/sdk/index.html')
  await expect(page.locator('[data-current]')).toHaveText('1')
  await page.getByRole('button', { name: 'Start edit', exact: true }).click()
  await page.getByRole('button', { name: 'Block next write', exact: true }).click()
  await page.getByRole('button', { name: 'Save original edit', exact: true }).click()
  await expect(page.locator('[data-write-pending]')).toHaveText('pending')
  await expect(page.locator('[data-current]')).toHaveText('9')
  await expect(page.locator('[data-confirmed]')).toHaveText('1')
  await page.getByRole('button', { name: 'Other client writes', exact: true }).click()
  await expect(page.locator('[data-confirmed]')).toHaveText('42')
  await page.getByRole('button', { name: 'Fail pending write and reads', exact: true }).click()
  await expect(page.locator('[data-write-pending]')).toHaveText('')
  await expect(page.getByRole('alert')).toHaveText('Fixture write failure')
  await expect(page.locator('[data-read-error]')).toHaveText('503')
  await expect(page.locator('[data-current]')).toHaveText('42')
  await expect(page.locator('[data-confirmed]')).toHaveText('42')
})

test('real SDK writes keep the caller edit snapshot after refetch, and channel/root lifecycle cleans up', async ({
  page
}) => {
  const errors: string[] = []
  page.on('pageerror', error => errors.push(error.message))
  await page.goto('/integration/applet-frame/sdk/index.html')
  await expect(page.locator('[data-current]')).toHaveText('1')
  await page.getByRole('button', { name: 'Emit fixture event' }).click()
  await expect(page.locator('[data-received]')).toHaveText('1')
  await page.getByRole('button', { name: 'Start edit' }).click()
  await page.getByRole('button', { name: 'Other client writes' }).click()
  await expect(page.locator('[data-current]')).toHaveText('42')
  await page.getByRole('button', { name: 'Save original edit' }).click()
  await expect(page.getByRole('alert')).toHaveText('Edit conflict')
  await expect(page.locator('[data-current]')).toHaveText('42')
  await expect(page.locator('[data-request]')).toContainText('"expected_versions":{"amount":1}')
  for (let index = 0; index < 3; index++) {
    await page.getByRole('button', { name: 'Unmount SDK' }).click()
    await expect(page.locator('#applet > div')).toHaveCount(0)
    await expect(page.locator('[data-lifecycle]')).toContainText('"listeners":0')
    await page.getByRole('button', { name: 'Remount SDK' }).click()
    await expect(page.locator('#applet > div')).toHaveCount(1)
    await page.getByRole('button', { name: 'Emit fixture event' }).click()
    await expect(page.locator('[data-received]')).toHaveText('1')
  }
  expect(errors).toEqual([])
})

test('real SDK reads hide denied cached rows and aggregates while transient failures retain them', async ({ page }) => {
  await page.goto('/integration/applet-frame/sdk/index.html')
  const rows = page.locator('[data-current]')
  const aggregate = page.locator('[data-aggregate]')
  await expect(rows).toHaveText('1')
  await expect(aggregate).toHaveText('1')
  await page.getByRole('button', { name: 'Start edit', exact: true }).click()
  await page.getByRole('button', { name: 'Read status 503', exact: true }).click()
  await expect(page.locator('[data-read-error]')).toHaveText('503')
  await expect(page.locator('[data-aggregate-error]')).toHaveText('503')
  await expect(rows).toHaveText('1')
  await expect(aggregate).toHaveText('1')
  for (const status of [401, 403, 404]) {
    await page.getByRole('button', { name: `Read status ${status}`, exact: true }).click()
    await expect(page.locator('[data-read-error]')).toHaveText(String(status))
    await expect(page.locator('[data-aggregate-error]')).toHaveText(String(status))
    await expect(rows).toHaveText('')
    await expect(aggregate).toHaveText('')
    if (status === 403) {
      await page.getByRole('button', { name: 'Save original edit', exact: true }).click()
      await expect(page.locator('[data-write-pending]')).toHaveText('pending')
      await expect(rows).toHaveText('')
      await page.getByRole('button', { name: 'Release denied write', exact: true }).click()
      await expect(page.locator('[data-write-pending]')).toHaveText('')
      await expect(rows).toHaveText('')
    }
    await page.getByRole('button', { name: 'Read status 200', exact: true }).click()
    await expect(rows).toHaveText('1')
    await expect(aggregate).toHaveText('1')
  }
})

test('route hooks preserve query options, selection, key dimensions and explicit mutation invalidation', async ({
  page
}) => {
  await page.goto('/integration/applet-frame/sdk/index.html')
  const report = page.locator('[data-route-report]')
  await expect(report).toContainText('"calls":[]')
  await page.getByRole('button', { name: 'Enable route', exact: true }).click()
  await expect(page.locator('[data-route-value]')).toHaveText('1')
  await expect(report).toContainText('"path":"/orders/a%2Fb%20%E4%B8%AD%E6%96%87"')
  await expect(report).toContainText('"query":{"tag":["one","two"]}')
  await page.getByRole('button', { name: 'Save route', exact: true }).click()
  await expect(page.locator('[data-route-success]')).toHaveText('1')
  await expect(report).toContainText('"method":"POST"')
  await expect(report).toContainText('"body":{"note":"Keep draft"}')
  // A route mutation has no automatic invalidation or optimistic update.
  await expect(page.locator('[data-route-value]')).toHaveText('1')
  await page.getByRole('button', { name: 'Refresh routes', exact: true }).click()
  await expect(page.locator('[data-route-value]')).toHaveText('2')
  await page.getByRole('button', { name: 'Change route parameter', exact: true }).click()
  await expect(report).toContainText('"path":"/orders/next"')
  await expect(page.locator('[data-route-value]')).toHaveText('2')
})

test('route query access loss hides cached data, outages retain it, and unmount aborts pending reads', async ({
  page
}) => {
  await page.goto('/integration/applet-frame/sdk/index.html')
  await page.getByRole('button', { name: 'Enable route', exact: true }).click()
  const value = page.locator('[data-route-value]')
  await expect(value).toHaveText('1')
  await page.getByRole('button', { name: 'Route status 503', exact: true }).click()
  await expect(page.locator('[data-route-error]')).toHaveText('503')
  await expect(value).toHaveText('1')
  for (const status of [401, 403, 404]) {
    await page.getByRole('button', { name: `Route status ${status}`, exact: true }).click()
    await expect(page.locator('[data-route-error]')).toHaveText(String(status))
    await expect(value).toHaveText('')
    await page.getByRole('button', { name: 'Route status 200', exact: true }).click()
    await expect(value).toHaveText('1')
  }
  await page.getByRole('button', { name: 'Hold route request', exact: true }).click()
  await expect(page.locator('[data-route-pending]')).toHaveText('pending')
  await page.getByRole('button', { name: 'Unmount SDK', exact: true }).click()
  await expect(page.locator('[data-route-report]')).toContainText('"aborted":1')
})

for (const status of [401, 403, 404, 503]) {
  test(`SDK reads expose the first ${status} during a delayed retry with coherent state`, async ({ page }) => {
    await page.clock.install()
    await page.goto('/integration/applet-frame/sdk/index.html?retry=1&notify-data-only=1')
    await page.getByRole('button', { name: 'Enable route', exact: true }).click()
    for (const selector of ['[data-current]', '[data-aggregate]', '[data-route-value]']) {
      await expect(page.locator(selector)).toHaveText('1')
    }
    await page.getByRole('button', { name: `Read status ${status}`, exact: true }).click()
    await page.getByRole('button', { name: `Route status ${status}`, exact: true }).click()
    const cache = page.locator('[data-cache-read-states]')
    await expect
      .poll(async () => JSON.parse((await cache.textContent()) || '{}'))
      .toEqual({
        records: {
          error: null,
          failureReason: status,
          status: 'success',
          data: true,
          failures: 1,
          fetchStatus: 'fetching'
        },
        aggregate: {
          error: null,
          failureReason: status,
          status: 'success',
          data: true,
          failures: 1,
          fetchStatus: 'fetching'
        },
        route: {
          error: null,
          failureReason: status,
          status: 'success',
          data: true,
          failures: 1,
          fetchStatus: 'fetching'
        }
      })
    const denied = status !== 503
    for (const selector of ['[data-current]', '[data-aggregate]', '[data-route-value]']) {
      await expect(page.locator(selector)).toHaveText(denied ? '' : '1')
    }
    for (const selector of ['[data-read-result]', '[data-aggregate-result]', '[data-route-result]']) {
      const result = JSON.parse((await page.locator(selector).textContent()) || '{}')
      expect(result).toMatchObject({
        status: denied ? 'error' : 'success',
        isError: denied,
        isSuccess: !denied,
        isPending: false,
        isLoading: false,
        data: !denied,
        error: denied ? status : null
      })
      if (denied) expect(result).toMatchObject({ isLoadingError: true, isRefetchError: false })
    }
    // Keep the configured retry: recover the adapter without invalidating its query.
    await page.getByRole('button', { name: 'Recover reads without refetch', exact: true }).click()
    await page.clock.fastForward(10_000)
    for (const selector of ['[data-current]', '[data-aggregate]', '[data-route-value]']) {
      await expect(page.locator(selector)).toHaveText('1')
    }
    for (const selector of ['[data-read-result]', '[data-aggregate-result]', '[data-route-result]']) {
      await expect
        .poll(async () => JSON.parse((await page.locator(selector).textContent()) || '{}'))
        .toMatchObject({
          status: 'success',
          isSuccess: true,
          isError: false,
          data: true,
          error: null
        })
    }
  })
}

test('denial survives a failed retry, manual cache data, and SDK remount until a real read succeeds', async ({
  page
}) => {
  await page.clock.install()
  await page.goto('/integration/applet-frame/sdk/index.html?retry=1&notify-data-only=1')
  await page.getByRole('button', { name: 'Enable route', exact: true }).click()
  await expect(page.locator('[data-route-value]')).toHaveText('1')
  await page.getByRole('button', { name: 'Read status 403', exact: true }).click()
  await page.getByRole('button', { name: 'Route status 403', exact: true }).click()
  for (const selector of ['[data-current]', '[data-aggregate]', '[data-route-value]']) {
    await expect(page.locator(selector)).toHaveText('')
  }
  await page.getByRole('button', { name: 'Write manual cache data', exact: true }).click()
  await expect(page.locator('[data-confirmed]')).toHaveText('99')
  for (const selector of ['[data-current]', '[data-aggregate]', '[data-route-value]']) {
    await expect(page.locator(selector)).toHaveText('')
  }
  await page.getByRole('button', { name: 'Make retry unavailable', exact: true }).click()
  await page.clock.fastForward(10_000)
  await expect
    .poll(async () => JSON.parse((await page.locator('[data-cache-read-states]').textContent()) || '{}'))
    .toMatchObject({
      records: { error: 503, failureReason: 503, failures: 2, fetchStatus: 'idle' },
      aggregate: { error: 503, failureReason: 503, failures: 2, fetchStatus: 'idle' },
      route: { error: 503, failureReason: 503, failures: 2, fetchStatus: 'idle' }
    })
  await page.getByRole('button', { name: 'Unmount SDK', exact: true }).click()
  await page.getByRole('button', { name: 'Remount SDK', exact: true }).click()
  for (const selector of ['[data-current]', '[data-aggregate]', '[data-route-value]']) {
    await expect(page.locator(selector)).toHaveText('')
  }
  for (const selector of ['[data-read-result]', '[data-aggregate-result]', '[data-route-result]']) {
    await expect
      .poll(async () => JSON.parse((await page.locator(selector).textContent()) || '{}'))
      .toMatchObject({
        status: 'error',
        isSuccess: false,
        isError: true,
        data: false,
        error: 403
      })
  }
  await page.getByRole('button', { name: 'Enable route', exact: true }).click()
  await page.getByRole('button', { name: 'Read status 200', exact: true }).click()
  await page.getByRole('button', { name: 'Route status 200', exact: true }).click()
  for (const selector of ['[data-current]', '[data-aggregate]', '[data-route-value]']) {
    await expect(page.locator(selector)).toHaveText('1')
  }
})
