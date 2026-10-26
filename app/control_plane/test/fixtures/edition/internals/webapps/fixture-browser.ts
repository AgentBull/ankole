import { chromium, expect } from '@playwright/test'

const [port, tenantID, principalUID, mode, inbox] = process.argv.slice(2)
const enabled = mode !== 'disabled'
const browser = await chromium.launch({ args: [`--host-resolver-rules=MAP *.example.test 127.0.0.1:${port}`] })
const context = await browser.newContext({
  ignoreHTTPSErrors: true,
  proxy: { server: 'http://127.0.0.1:9', bypass: '.example.test' }
})
const page = await context.newPage()
const errors: string[] = []
const failures: string[] = []
page.on('requestfailed', request => failures.push(`${request.url()} ${request.failure()?.errorText}`))
page.on('console', message => {
  if (message.type() === 'error') failures.push(message.text())
})
page.on('pageerror', error => errors.push(error.message))
try {
  const shell = await page.goto(`https://pod.example.test:${port}/fixture-browser/pod/${principalUID}`)
  expect(shell?.status()).toBe(200)
  expect(shell?.headers()['cache-control']).toBe('private, no-store')
  const activePlugins = JSON.parse(
    (await page.locator('meta[name="ankole-active-plugins"]').getAttribute('content')) ?? '[]'
  )
  expect(activePlugins).toEqual(expect.arrayContaining(['fixture-pod-settings', 'fixture-challenge', 'fixture-quota']))
  const flags = JSON.parse((await page.locator('meta[name="ankole-features"]').getAttribute('content')) ?? '{}')
  expect(flags['fixture.pod-module']).toBe(enabled)
  await expect(page.getByRole('tab', { name: 'General and sign-in', exact: true })).toBeVisible()
  const tab = page.getByRole('tab', { name: 'Private catalog build fixture', exact: true })
  if (enabled) {
    await expect(tab).toBeVisible()
    const settings = page.waitForResponse(response => response.url().endsWith('/api/v2/saas-pod/fixture-settings'))
    await tab.click()
    const response = await settings
    expect(response.status()).toBe(200)
    expect(await response.json()).toEqual({ tenantID, principalUID })
    await expect(page.getByTestId('fixture-settings')).toContainText(tenantID!)
  } else {
    await expect(tab).toHaveCount(0)
  }

  await context.clearCookies()
  await page.goto(`https://site.example.test:${port}/site-admin-console`)
  await page.getByLabel('Email address', { exact: true }).fill('fixture-browser@example.test')
  const send = page.getByRole('button', { name: 'Send code', exact: true })
  const challengeButton = page.getByRole('button', { name: 'Pass fixture challenge', exact: true })
  if (enabled) {
    await expect(send).toBeDisabled()
    await challengeButton.click()
  } else {
    await expect(challengeButton).toHaveCount(0)
  }
  await expect(send).toBeEnabled()
  const challenge = page.waitForResponse(response =>
    response.url().endsWith('/api/v2/browser/sessions/email-otp/challenges')
  )
  await send.click()
  const sent = await challenge
  expect(sent.request().headers()['x-fixture-challenge']).toBe(enabled ? 'passed' : undefined)
  expect(sent.status()).toBe(201)
  expect((await sent.json()).challengeID).toBeTruthy()
  await expect(page.getByRole('button', { name: 'Resend code', exact: true })).toBeEnabled({ enabled: !enabled })

  await expect.poll(() => Bun.file(inbox!).exists()).toBe(true)
  const message = await Bun.file(inbox!).text()
  const code = /verification code is (\d{6})/.exec(message)?.[1]
  expect(code).toBeTruthy()
  await page.getByLabel('6-digit email code', { exact: true }).fill(code!)
  const verification = page.waitForResponse(response =>
    response.url().endsWith('/api/v2/browser/sessions/email-otp/verifications')
  )
  await page.getByRole('button', { name: 'Verify and continue', exact: true }).click()
  const verified = await verification
  expect(verified.status()).toBe(201)
  await page.waitForURL(`https://site.example.test:${port}/site-admin-console`)
  await expect(page.getByText('Ankole Console', { exact: true })).toBeVisible()
  const session = await page.evaluate(async () => {
    const authentication = document.querySelector('meta[name="ankole-authentication"]')?.getAttribute('content')
    const response = await fetch('/api/v2/browser/session', {
      headers: {
        accept: 'application/vnd.api+json',
        ...(authentication ? { 'x-ankole-authentication': authentication } : {})
      }
    })
    return { status: response.status, body: await response.json() }
  })
  expect(session.status).toBe(200)
  expect(session.body).toMatchObject({
    authenticated: true,
    accounts: expect.arrayContaining([expect.objectContaining({ principalUID })]),
    siteAuthentications: expect.arrayContaining([
      expect.objectContaining({ providerID: 'email_otp', identifier: 'fixture-browser@example.test' })
    ])
  })

  const libraryResponses = [
    '/api/v2/agents',
    '/api/v2/agent-library/capabilities',
    '/api/v2/site/control-plane-plugins'
  ].map(path => page.waitForResponse(response => new URL(response.url()).pathname === path))
  await page.goto(`https://site.example.test:${port}/site-admin-console/agent-library`)
  await page.getByRole('tab', { name: /Control Plane Plugins/ }).click()
  await expect(page.locator('[data-slot="card-title"]').filter({ hasText: 'fixture-pod-settings' })).toHaveText(
    'fixture-pod-settings'
  )
  for (const response of await Promise.all(libraryResponses)) {
    expect(response.status()).toBe(200)
    await response.finished()
  }

  expect(errors).toEqual([])
  expect(failures).toEqual([])
  process.stdout.write('edition-browser-verified\n')
} catch (error) {
  console.error(JSON.stringify({ errors, failures, url: page.url(), body: await page.locator('body').innerText() }))
  throw error
} finally {
  await browser.close()
}
