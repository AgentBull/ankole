import { createServer } from 'node:http'
import { expect, test } from '@playwright/test'
import { login, request, state } from './fixtures'

test.use({ actionTimeout: 15_000 })

test('administrator configures a connection and member can retry the same progressive consent after cancellation', async ({
  browser
}) => {
  const requests: URL[] = []
  const provider = createServer((req, res) => {
    const url = new URL(req.url!, 'http://127.0.0.1')
    requests.push(url)
    const callback = new URL('/oauth/connectors/callback', state.console_url)
    callback.searchParams.set('state', url.searchParams.get('state')!)
    callback.searchParams.set('error', 'access_denied')
    res.writeHead(302, { location: callback.href }).end()
  })
  await new Promise<void>(resolve => provider.listen(0, '127.0.0.1', resolve))
  const address = provider.address() as { port: number }
  const providerURL = `http://127.0.0.1:${address.port}`
  const adminContext = await browser.newContext()
  const memberContext = await browser.newContext()
  const admin = await adminContext.newPage()
  const member = await memberContext.newPage()
  const slug = `engineering-${Date.now()}`
  try {
    await admin.goto(`${state.base_url}/connectors`)
    await login(admin, state.owner)
    await admin.getByRole('button', { name: '添加连接', exact: true }).click()
    const dialog = admin.getByRole('dialog')
    await dialog.getByRole('combobox', { name: '平台', exact: true }).click()
    await admin.getByRole('option', { name: 'GitHub', exact: true }).click()
    await dialog.getByRole('combobox', { name: '认证方式', exact: true }).click()
    await admin.getByRole('option', { name: /Oauth2/i }).click()
    const catalog = await request<{ oauth_callback_url: string }>(admin, '/connectors')
    await expect(dialog.getByLabel('OAuth 回调地址')).toHaveValue(catalog.oauth_callback_url)
    await expect(dialog.getByText('连接账户前，请在外部应用的开发者后台将此地址登记为授权回调地址。')).toBeVisible()
    await dialog.getByLabel('显示名称', { exact: true }).fill('Engineering workspace')
    await dialog.getByLabel('连接名称', { exact: true }).fill(slug)
    await dialog.getByLabel('OAuth client ID', { exact: false }).fill(`app-${slug}`)
    await dialog.getByLabel('OAuth client secret', { exact: false }).fill('local-provider-secret')
    await dialog.getByLabel('GitHub website URL', { exact: false }).fill(providerURL)
    const connectionName = dialog.getByLabel('连接名称', { exact: true })
    await connectionName.fill('123-engineering')
    await dialog.getByRole('button', { name: '保存', exact: true }).click()
    await expect(connectionName).toBeFocused()
    await expect(dialog).toBeVisible()
    expect(await connectionName.evaluate((input: HTMLInputElement) => input.validity.patternMismatch)).toBe(true)
    await connectionName.fill(slug)
    await dialog.getByRole('button', { name: '保存', exact: true }).click()
    await expect(dialog).toBeHidden()
    const card = admin.locator('[data-slot="card"]').filter({ has: admin.getByText(slug, { exact: true }) })
    await card.getByRole('button', { name: '停用连接', exact: true }).click()
    await expect(card.getByRole('button', { name: '启用连接', exact: true })).toBeVisible()
    await card.getByRole('button', { name: '启用连接', exact: true }).click()
    await expect(card.getByRole('button', { name: '停用连接', exact: true })).toBeVisible()

    const intent = new URL('/connectors', state.base_url)
    intent.searchParams.set('connection', slug)
    intent.searchParams.set('scopes', 'repo workflow')
    await member.goto(intent.href)
    await login(member, state.member)
    await expect(member.getByRole('button', { name: '添加连接', exact: true })).toHaveCount(0)
    const personal = member.locator('[data-slot="card"]').filter({ has: member.getByText(slug, { exact: true }) })
    await expect(personal.getByRole('button', { name: '编辑凭证', exact: true })).toHaveCount(0)
    for (let attempt = 1; attempt <= 2; attempt++) {
      const callback = member.waitForResponse(
        response => new URL(response.url()).pathname === '/oauth/connectors/callback'
      )
      await personal.getByRole('button', { name: '连接个人账户', exact: true }).click()
      await callback
      await member.waitForURL(
        url =>
          url.origin === new URL(state.base_url).origin &&
          url.searchParams.get('connector_error') === 'oauth_authorization_cancelled'
      )
      await expect(member.getByText('已取消授权。你可以随时重新连接账户。')).toBeVisible()
      await expect.poll(() => requests.length).toBe(attempt)
      expect(requests[attempt - 1]!.searchParams.get('scope')?.split(' ')).toEqual(
        expect.arrayContaining(['repo', 'workflow'])
      )
      expect(new URL(member.url()).searchParams.get('connection')).toBe(slug)
      expect(new URL(member.url()).searchParams.get('scopes')).toBe('repo workflow')
    }
    await member.screenshot({ path: '/tmp/ankole-connectors-product-consent.png', fullPage: true })
  } finally {
    await adminContext.close()
    await memberContext.close()
    await new Promise<void>((resolve, reject) => provider.close(error => (error ? reject(error) : resolve())))
  }
})

test('workspace administrator reuses saved application credentials for enterprise sign-in', async ({ browser }) => {
  const context = await browser.newContext()
  const page = await context.newPage()
  const slug = `company-${Date.now()}`
  try {
    await page.goto(`${state.base_url}/connectors`)
    await login(page, state.owner)
    await page.getByRole('button', { name: '添加连接', exact: true }).click()
    const dialog = page.getByRole('dialog')
    await dialog.getByLabel('显示名称', { exact: true }).fill('Company identity')
    await dialog.getByLabel('连接名称', { exact: true }).fill(slug)
    await dialog.getByLabel('App ID', { exact: false }).fill(`cli_${slug}`)
    await dialog.getByLabel('App Secret', { exact: false }).fill('local-company-secret')
    await dialog.getByRole('button', { name: '保存', exact: true }).click()
    await expect(dialog).toBeHidden()

    await page.goto(`${state.base_url}/settings`)
    await page.getByRole('tab', { name: '企业 SSO 与通讯录', exact: true }).click()
    await page.getByRole('button', { name: '新增身份源提供商', exact: true }).click()
    await page.getByRole('combobox', { name: '企业身份提供方', exact: true }).click()
    await page.getByRole('option', { name: '飞书', exact: true }).click()
    await page.getByRole('combobox', { name: '连接', exact: true }).click()
    await page.getByRole('option', { name: `Company identity · ${slug}`, exact: true }).click()
    await expect(page.getByLabel('App Secret', { exact: false })).toHaveCount(0)
    await expect(page.getByLabel('App ID', { exact: false })).toHaveCount(0)
    await page.getByRole('button', { name: /高级设置/ }).click()
    await page.getByRole('switch', { name: '实时同步通讯录变更', exact: false }).uncheck()
    await page.getByRole('switch', { name: '同步通讯录', exact: true }).uncheck()
    const saved = page.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname.includes('/identity-providers/')
    )
    await page.getByRole('button', { name: '新增身份源提供商', exact: true }).click()
    expect((await saved).ok()).toBe(true)
    await expect(page.getByRole('combobox', { name: '连接', exact: true })).toHaveCount(0)
    const providers = await request<{ providers: { config: { authConfigId?: string } }[] }>(
      page,
      '/admin/identity-providers'
    )
    const connections = await request<{ connections: { id: string; slug: string }[] }>(page, '/connectors/auth-configs')
    const connection = connections.connections.find(item => item.slug === slug)!
    expect(providers.providers.some(provider => provider.config.authConfigId === connection.id)).toBe(true)
    await page.screenshot({ path: '/tmp/ankole-connectors-product-identity.png', fullPage: true })
  } finally {
    await context.close()
  }
})

async function connectorProvider() {
  if (!state.connector_provider_url) throw new Error('Set POD_BROWSER_CONNECTOR_PROVIDER_URL on the real Pod fixture')
  const received: { path: string; authorization?: string; body: Record<string, unknown> }[] = []
  const slackAppID = `A_BROWSER_${Date.now()}`
  const server = createServer(async (req, res) => {
    const url = new URL(req.url!, state.connector_provider_url)
    let text = ''
    for await (const chunk of req) text += chunk
    const body = text
      ? req.headers['content-type']?.includes('application/json')
        ? JSON.parse(text)
        : Object.fromEntries(new URLSearchParams(text))
      : {}
    received.push({ path: url.pathname, authorization: req.headers.authorization, body })
    const responses: Record<string, unknown> = {
      '/auth.test': { ok: true, user_id: 'U_BROWSER', bot_id: 'B_BROWSER', team_id: 'T_BROWSER' },
      '/bots.info': { ok: true, bot: { app_id: slackAppID } },
      '/open-apis/authen/v2/oauth/token': {
        code: 0,
        access_token: 'browser-lark-user-token',
        refresh_token: 'browser-lark-refresh-token',
        expires_in: 7200,
        scope: 'calendar:calendar.event:read offline_access contact:user.employee_id:readonly'
      },
      '/open-apis/authen/v1/user_info': { code: 0, data: { user_id: 'browser-lark-employee' } }
    }
    const response = /^\/open-apis\/calendar\/v4\/calendars\/[^/]+\/events\/unsubscription$/.test(url.pathname)
      ? { code: 0, data: {} }
      : responses[url.pathname]
    res.writeHead(response ? 200 : 404, { 'content-type': 'application/json' }).end(JSON.stringify(response ?? {}))
  })
  const endpoint = new URL(state.connector_provider_url)
  await new Promise<void>(resolve => server.listen(Number(endpoint.port), endpoint.hostname, resolve))
  return {
    received,
    close: () => new Promise<void>((resolve, reject) => server.close(error => (error ? reject(error) : resolve())))
  }
}

test('administrator adds sign-in credentials to the same Slack application without re-entering bot credentials', async ({
  browser
}) => {
  const provider = await connectorProvider()
  const context = await browser.newContext()
  const page = await context.newPage()
  const slug = `shared-slack-${Date.now()}`
  try {
    await page.goto(`${state.base_url}/connectors`)
    await login(page, state.owner)
    await page.getByRole('button', { name: '添加连接', exact: true }).click()
    const dialog = page.getByRole('dialog')
    await dialog.getByRole('combobox', { name: '平台', exact: true }).click()
    await page.getByRole('option', { name: 'Slack Adapter', exact: true }).click()
    await expect(dialog.getByLabel('Client ID', { exact: false })).toHaveCount(0)
    await dialog.getByLabel('显示名称', { exact: true }).fill('Shared Slack application')
    await dialog.getByLabel('连接名称', { exact: true }).fill(slug)
    await dialog.getByLabel('Bot token', { exact: false }).fill('xoxb-browser-saved')
    await dialog.getByLabel('App token', { exact: false }).fill('xapp-browser-saved')
    await dialog.getByRole('button', { name: '保存', exact: true }).click()
    await expect(dialog).toBeHidden()
    const card = page.locator('[data-slot="card"]').filter({ has: page.getByText(slug, { exact: true }) })
    await card.getByRole('button', { name: '编辑凭证', exact: true }).click()
    await expect(dialog.getByLabel('Bot User OAuth Token', { exact: false })).toHaveCount(1)
    await expect(dialog.getByLabel('Bot User OAuth Token', { exact: false })).toHaveValue('')
    await dialog.getByLabel('Client ID', { exact: false }).fill(`${slug}-client`)
    await dialog.getByLabel('Client secret', { exact: false }).fill('browser-slack-secret')
    const saved = page.waitForResponse(
      response =>
        response.request().method() === 'PATCH' &&
        new URL(response.url()).pathname.includes('/connectors/auth-configs/')
    )
    await dialog.getByRole('button', { name: '保存', exact: true }).click()
    expect((await saved).ok()).toBe(true)
    await expect(dialog).toBeHidden()
    expect(
      provider.received
        .filter(item => item.path === '/auth.test')
        .every(item => item.authorization === 'Bearer xoxb-browser-saved')
    ).toBe(true)
    expect(provider.received.filter(item => item.path === '/auth.test').length).toBeGreaterThan(1)
    await card.getByRole('button', { name: '编辑凭证', exact: true }).click()
    await expect(dialog.getByLabel('Client ID', { exact: false })).toHaveValue(`${slug}-client`)
    await expect(dialog.getByLabel('Client secret', { exact: false })).toHaveValue('')
    await expect(dialog).toBeVisible()
    await page.screenshot({
      path: '/tmp/ankole-connectors-product-shared-credentials.png',
      fullPage: true,
      animations: 'disabled'
    })
  } finally {
    await context.close()
    await provider.close()
  }
})

test('member starts a personal calendar subscription, cancels then completes consent and resumes the same draft', async ({
  browser
}) => {
  const provider = await connectorProvider()
  const adminContext = await browser.newContext()
  const memberContext = await browser.newContext()
  const admin = await adminContext.newPage()
  const member = await memberContext.newPage()
  const slug = `calendar-${Date.now()}`
  const calendar = `feishu.cn_${slug}@group.calendar.feishu.cn`
  const authorizations: URL[] = []
  await member.route('https://accounts.feishu.cn/open-apis/authen/v1/authorize?*', async route => {
    const url = new URL(route.request().url())
    authorizations.push(url)
    const callback = new URL(url.searchParams.get('redirect_uri')!)
    callback.searchParams.set('state', url.searchParams.get('state')!)
    callback.searchParams.set(
      authorizations.length === 1 ? 'error' : 'code',
      authorizations.length === 1 ? 'access_denied' : 'browser-authorization-code'
    )
    await route.fulfill({ status: 302, headers: { location: callback.href }, body: '' })
  })
  try {
    await admin.goto(`${state.base_url}/connectors`)
    await login(admin, state.owner)
    await admin.getByRole('button', { name: '添加连接', exact: true }).click()
    const adminDialog = admin.getByRole('dialog')
    await adminDialog.getByLabel('显示名称', { exact: true }).fill('Personal calendar application')
    await adminDialog.getByLabel('连接名称', { exact: true }).fill(slug)
    await adminDialog.getByLabel('App ID', { exact: false }).fill(`cli_${slug}`)
    await adminDialog.getByLabel('App Secret', { exact: false }).fill('browser-calendar-secret')
    await adminDialog.getByRole('button', { name: '保存', exact: true }).click()
    await expect(adminDialog).toBeHidden()
    await member.goto(`${state.base_url}/connectors`)
    await login(member, state.member)
    const card = member.locator('[data-slot="card"]').filter({ has: member.getByText(slug, { exact: true }) })
    await card.getByRole('button', { name: '添加事件订阅', exact: true }).click()
    const dialog = member.getByRole('dialog')
    await dialog.getByRole('combobox', { name: '事件类型', exact: true }).click()
    await member.getByRole('option', { name: 'Personal calendar', exact: true }).click()
    await dialog.getByLabel('Calendar ID', { exact: true }).fill(calendar)
    await expect(dialog.getByRole('combobox', { name: '个人账户', exact: true })).toHaveCount(0)
    await dialog.getByRole('button', { name: '授权并继续', exact: true }).click()
    await expect(dialog.getByText('已取消授权，订阅草稿已保留。你可以继续授权。')).toBeVisible()
    await expect(dialog.getByLabel('Calendar ID', { exact: true })).toHaveValue(calendar)
    await expect(dialog.getByRole('combobox', { name: '事件类型', exact: true })).toContainText('Personal calendar')
    await expect(dialog.getByRole('button', { name: '授权并继续', exact: true })).toBeEnabled()
    await member.screenshot({
      path: '/tmp/ankole-connectors-product-calendar-draft.png',
      fullPage: true,
      animations: 'disabled'
    })
    await dialog.getByRole('button', { name: '授权并继续', exact: true }).click()
    await expect(dialog.getByText('账户已授权，请确认后添加订阅。')).toBeVisible()
    await expect(dialog.getByLabel('Calendar ID', { exact: true })).toHaveValue(calendar)
    await expect(dialog.getByRole('combobox', { name: '个人账户', exact: true })).toContainText('browser-lark-employee')
    const created = member.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname.endsWith('/connectors/triggers')
    )
    await dialog.getByRole('button', { name: '添加事件订阅', exact: true }).click()
    expect((await created).ok()).toBe(true)
    await expect(dialog).toBeHidden()
    await expect(member.getByText(`lark_calendar · ${calendar}`, { exact: true })).toBeVisible()
    expect(authorizations).toHaveLength(2)
    for (const authorization of authorizations) {
      expect(authorization.searchParams.get('scope')?.split(' ')).toContain('calendar:calendar.event:read')
      expect(authorization.searchParams.get('scope')?.split(' ')).not.toContain('calendar:calendar')
    }
    const token = provider.received.find(item => item.path === '/open-apis/authen/v2/oauth/token')!
    expect(token.body).toMatchObject({
      client_id: `cli_${slug}`,
      client_secret: 'browser-calendar-secret',
      code: 'browser-authorization-code',
      grant_type: 'authorization_code'
    })
    expect(token.body.code_verifier).toEqual(expect.any(String))
    expect(provider.received.find(item => item.path === '/open-apis/authen/v1/user_info')?.authorization).toBe(
      'Bearer browser-lark-user-token'
    )
    const result = await request<{
      triggers: { scope_key: string; trigger_type: string; connected_account_id: string }[]
    }>(member, '/connectors/triggers')
    expect(result.triggers.find(item => item.scope_key === calendar)).toMatchObject({
      trigger_type: 'lark_calendar',
      connected_account_id: expect.any(String)
    })
    const subscriptionCard = member.locator('[data-slot="card"]').filter({
      has: member.getByText(`lark_calendar · ${calendar}`, { exact: true })
    })
    await card.getByRole('button', { name: '断开账户', exact: true }).click()
    await subscriptionCard.getByRole('button', { name: '授权并继续', exact: true }).click()
    await expect(member.getByText('账户已授权，请重试下方的原订阅。', { exact: true })).toBeVisible()
    await member.getByText('账户已授权，请重试下方的原订阅。', { exact: true }).scrollIntoViewIfNeeded()
    await member.screenshot({
      path: '/tmp/ankole-connectors-product-calendar-authorized.png',
      fullPage: true,
      animations: 'disabled'
    })
    await expect(member.getByRole('dialog')).toHaveCount(0)
    expect(new URL(member.url()).searchParams.get('trigger_id')).toEqual(expect.any(String))
    const retried = member.waitForResponse(
      response => response.request().method() === 'POST' && new URL(response.url()).pathname.endsWith('/retry')
    )
    await subscriptionCard.getByRole('button', { name: '重试', exact: true }).click()
    expect((await retried).ok()).toBe(true)
    await expect
      .poll(async () => {
        const latest = await request<{ triggers: { scope_key: string; status: string; last_error: unknown }[] }>(
          member,
          '/connectors/triggers'
        )
        const subscription = latest.triggers.find(item => item.scope_key === calendar)
        return { status: subscription?.status, last_error: subscription?.last_error }
      })
      .toEqual({ status: 'paused', last_error: null })
    expect(
      provider.received.some(
        item => item.path.endsWith('/events/unsubscription') && item.authorization === 'Bearer browser-lark-user-token'
      )
    ).toBe(true)
    expect(authorizations).toHaveLength(3)
    await expect(subscriptionCard.getByText('已暂停', { exact: true })).toBeVisible()
    await member.screenshot({ path: '/tmp/ankole-connectors-product-calendar.png', fullPage: true })
  } finally {
    await adminContext.close()
    await memberContext.close()
    await provider.close()
  }
})
