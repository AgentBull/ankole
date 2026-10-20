import { expect, test } from '@playwright/test'

test('bootstrap validates on submit and then on input', async ({ page }) => {
  let submitted: { activationCode: string; locale: string } | undefined
  await page.route('**/.internal-apis/setup/**', async route => {
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
      submitted = route.request().postDataJSON()
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
  await expect.poll(() => submitted).toEqual({ activationCode: 'ABC', locale: 'en-US' })
})

test('the first administrator form reports field errors and a password mismatch', async ({ page }) => {
  let created: { email: string; password: string; display_name?: string } | undefined
  await page.route('**/.internal-apis/setup/**', async route => {
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
    if (path.endsWith('/identity-provider-adapters')) {
      return route.fulfill({
        json: {
          adapters: [
            {
              adapterID: 'local',
              defaultProviderID: 'local',
              displayName: { default: 'Local account' },
              fields: [],
              pluginID: 'local'
            }
          ]
        }
      })
    }
    if (path.endsWith('/identity-providers/local') && route.request().method() === 'PUT') {
      return route.fulfill({ json: {} })
    }
    if (path.endsWith('/local-admin') && route.request().method() === 'POST') {
      created = route.request().postDataJSON()
      return route.fulfill({ json: { returnTo: '/sessions/new' } })
    }
    return route.fulfill({ status: 404, json: {} })
  })

  await page.goto('/setup-repair')
  await page.getByRole('button', { name: 'Save plugin selection', exact: true }).click()
  await page.getByRole('button', { name: 'Save industry selection', exact: true }).click()
  const email = page.getByRole('textbox', { name: 'Administrator email' })
  const password = page.getByLabel('Password', { exact: true })
  const confirm = page.getByLabel('Confirm password', { exact: true })
  await email.fill('not-an-email')
  await expect(page.getByRole('alert')).toHaveCount(0)
  await page.getByRole('button', { name: 'Create administrator and finish setup', exact: true }).click()
  await expect(page.getByRole('alert')).toContainText(['Enter a valid email address.', 'Use at least 6 characters.'])
  await email.fill('ada@example.com')
  await password.fill('123456')
  await confirm.fill('12345')
  await expect(page.getByRole('alert')).toHaveText("The passwords don't match.")
  await confirm.fill('123456')
  await expect(page.getByRole('alert')).toHaveCount(0)
  await page.getByRole('button', { name: 'Create administrator and finish setup', exact: true }).click()
  await expect.poll(() => created).toEqual({ email: 'ada@example.com', password: '123456' })
})
