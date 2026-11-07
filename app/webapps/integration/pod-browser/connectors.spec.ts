import { createServer } from 'node:http'
import { expect, test } from '@playwright/test'
import { login, request, state } from './fixtures'
import { pageRoute } from './routes'

test.use({ actionTimeout: 15_000 })

test('administrator retries credential verification without creating another connection', async ({ browser }) => {
  const provider = createServer((req, res) => {
    if (req.url !== '/api/0/organizations/') {
      res.writeHead(404).end()
      return
    }
    const accepted = req.headers.authorization === 'Bearer accepted-browser-token'
    res
      .writeHead(accepted ? 200 : 401, { 'content-type': 'application/json' })
      .end(
        JSON.stringify(accepted ? [{ id: 'browser-org', name: 'Browser organization' }] : { detail: 'Invalid token' })
      )
  })
  await new Promise<void>(resolve => provider.listen(0, '127.0.0.1', resolve))
  const address = provider.address() as { port: number }
  const context = await browser.newContext()
  const page = await context.newPage()
  const slug = `sentry-retry-${Date.now()}`
  try {
    await context.addCookies(state.owner.cookies)
    await page.goto(`${state.base_url}/connectors`)
    await page.getByRole('button', { name: '添加连接', exact: true }).click()
    const dialog = page.getByRole('dialog')
    await dialog.getByRole('combobox', { name: '平台', exact: true }).click()
    await page.getByRole('option', { name: 'Sentry', exact: true }).click()
    await dialog.getByLabel('显示名称', { exact: true }).fill('Retry Sentry credentials')
    await dialog.getByLabel('连接名称', { exact: true }).fill(slug)
    await dialog.getByLabel('Platform URL', { exact: false }).fill(`http://127.0.0.1:${address.port}`)
    const token = dialog.getByLabel('Access token', { exact: false })
    await token.fill('rejected-browser-token')
    const rejected = page.waitForResponse(response => response.url().endsWith('/connectors/accounts/connect-team'))
    await dialog.getByRole('button', { name: '保存', exact: true }).click()
    expect((await rejected).ok()).toBe(false)
    await expect(dialog).toBeVisible()
    await expect(token).toHaveValue('rejected-browser-token')
    await expect(dialog.getByLabel('连接名称', { exact: true })).toHaveValue(slug)
    const saved = await request<{ connections: { id: string; slug: string }[] }>(page, '/connectors/auth-configs')
    const original = saved.connections.find(connection => connection.slug === slug)!
    expect(original.id).toBeTruthy()
    await token.fill('accepted-browser-token')
    await dialog.getByRole('button', { name: '保存', exact: true }).click()
    await expect(dialog).toBeHidden()
    const retried = await request<{ connections: { id: string; slug: string }[] }>(page, '/connectors/auth-configs')
    expect(retried.connections.filter(connection => connection.slug === slug).map(connection => connection.id)).toEqual(
      [original.id]
    )

    await page.goto(`${state.base_url}/connectors?connection=${slug}&auth_mode=team_credentials`)
    const bindingToken = dialog.getByLabel('Access token', { exact: false })
    await bindingToken.fill('another-rejected-token')
    const bindRejected = page.waitForResponse(response => response.url().endsWith('/connectors/accounts/connect-team'))
    await dialog.getByRole('button', { name: '验证并绑定', exact: true }).click()
    expect((await bindRejected).ok()).toBe(false)
    await expect(bindingToken).toHaveValue('another-rejected-token')
    await bindingToken.fill('accepted-browser-token')
    await dialog.getByRole('button', { name: '验证并绑定', exact: true }).click()
    await expect(dialog).toBeHidden()
  } finally {
    await context.close()
    await new Promise<void>((resolve, reject) => provider.close(error => (error ? reject(error) : resolve())))
  }
})

test('personal and team credential forms retain typed values through rerenders and blur', async ({ browser }) => {
  const adminContext = await browser.newContext()
  const memberContext = await browser.newContext()
  const admin = await adminContext.newPage()
  const member = await memberContext.newPage()
  const suffix = Date.now()
  try {
    await adminContext.addCookies(state.owner.cookies)
    await memberContext.addCookies(state.member.cookies)
    await admin.goto(`${state.base_url}/connectors`)
    await expect(admin.getByRole('button', { name: '添加连接', exact: true })).toBeVisible()
    for (const [plugin, scheme] of [
      ['figma', 'personal_token'],
      ['zendesk', 'api_token']
    ]) {
      await request(admin, '/connectors/auth-configs', 'POST', {
        plugin_id: plugin,
        slug: `${plugin}-input-${suffix}`,
        display_name: `${plugin} input`,
        auth_scheme: scheme,
        secret: {}
      })
    }

    await member.goto(`${state.base_url}/connectors?connection=figma-input-${suffix}&auth_mode=personal_credentials`)
    const personalToken = member.getByRole('dialog').getByLabel('个人访问令牌', { exact: false })
    await personalToken.fill('not-a-real-figma-token')
    await personalToken.press('Tab')
    await expect(personalToken).toHaveValue('not-a-real-figma-token')
    expect(await personalToken.evaluate((input: HTMLInputElement) => input.checkValidity())).toBe(true)

    await admin.goto(`${state.base_url}/connectors?connection=zendesk-input-${suffix}&auth_mode=team_credentials`)
    const dialog = admin.getByRole('dialog')
    const entries = [
      ['Zendesk subdomain', 'example-team'],
      ['Administrator email', 'admin@example.com'],
      ['API token', 'not-a-real-zendesk-token']
    ] as const
    for (const [name, value] of entries) await dialog.getByLabel(name, { exact: false }).fill(value)
    await admin.keyboard.press('Tab')
    for (const [name, value] of entries) {
      const input = dialog.getByLabel(name, { exact: false })
      await expect(input).toHaveValue(value)
      expect(await input.evaluate((element: HTMLInputElement) => element.checkValidity())).toBe(true)
    }
  } finally {
    await adminContext.close()
    await memberContext.close()
  }
})

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
    await dialog.getByText('如何配置平台应用', { exact: true }).click()
    await expect(
      dialog.getByText(
        '在 GitHub 开发者设置中创建 OAuth App，登记下方的回调地址，然后填写 Client ID 和 Client Secret。'
      )
    ).toBeVisible()
    await expect(dialog.getByRole('link', { name: '打开平台开发者设置 ↗' })).toHaveAttribute(
      'href',
      'https://github.com/settings/developers'
    )
    await expect(dialog.getByRole('link', { name: '自动化使用指南 ↗' })).toHaveAttribute(
      'href',
      'https://ankole.agentbull.com/zh-Hans-CN/docs/automation-jobs/'
    )
    await admin.setViewportSize({ width: 390, height: 844 })
    await expect.poll(() => dialog.evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true)
    await dialog.evaluate(element => element.scrollTo({ top: 0 }))
    await admin.screenshot({ path: '/tmp/ankole-connectors-setup-mobile.png', fullPage: true, animations: 'disabled' })
    await dialog.getByRole('button', { name: '保存', exact: true }).scrollIntoViewIfNeeded()
    await expect(dialog.getByRole('button', { name: '保存', exact: true })).toBeInViewport()
    await admin.screenshot({
      path: '/tmp/ankole-connectors-setup-mobile-save.png',
      fullPage: true,
      animations: 'disabled'
    })
    await admin.setViewportSize({ width: 1280, height: 960 })
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
    const personal = member.locator(`#connector-human-${slug}`)
    await expect(personal.getByRole('button', { name: '编辑凭证', exact: true })).toHaveCount(0)
    for (let attempt = 1; attempt <= 2; attempt++) {
      if (attempt > 1) {
        const callback = member.waitForResponse(
          response => new URL(response.url()).pathname === '/oauth/connectors/callback'
        )
        await personal.getByRole('button', { name: '连接个人账户', exact: true }).click()
        await callback
      }
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
    intent.searchParams.set('subject_kind', 'app')
    intent.searchParams.set('scopes', 'repo read:org')
    await admin.goto(intent.href)
    await admin.waitForURL(url => url.searchParams.get('connector_error') === 'oauth_authorization_cancelled')
    expect(new URL(admin.url()).searchParams.get('subject_kind')).toBe('app')
    expect(new URL(admin.url()).searchParams.get('scopes')).toBe('repo read:org')
    expect(requests.at(-1)!.searchParams.get('scope')?.split(' ')).toEqual(expect.arrayContaining(['repo', 'read:org']))
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
    await page.getByRole('option', { name: '飞书 / Lark', exact: true }).click()
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
  test.skip(!state.actions, 'Start the real fixture with POD_BROWSER_ACTIONS=true')
  const provider = await connectorProvider()
  const adminContext = await browser.newContext()
  const memberContext = await browser.newContext()
  const admin = await adminContext.newPage()
  const member = await memberContext.newPage()
  const slug = `calendar-${Date.now()}`
  const calendar = `feishu.cn_${slug}@group.calendar.feishu.cn`
  const authorizations: URL[] = []
  const pageID = state.actions!.page_id
  const jobName = `Personal calendar ${slug}`
  let jobID: number | undefined
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
    await member.goto(state.base_url + pageRoute(pageID))
    await login(member, state.member)
    await expect(member.getByRole('button', { name: '自动化', exact: true })).toBeVisible()
    const { job } = await request<{ job: { id: number } }>(member, `/pages/${pageID}/jobs`, 'POST', {
      action_key: 'capture',
      label: jobName,
      authorization_kind: 'human',
      config: {}
    })
    jobID = job.id
    await member.getByRole('button', { name: '自动化', exact: true }).click()
    await member.getByRole('combobox', { name: '自动化任务', exact: true }).click()
    await member.getByRole('option', { name: jobName, exact: true }).click()
    await member.getByRole('link', { name: '打开外部连接', exact: true }).click()
    expect(new URL(member.url()).searchParams.get('automation_job')).toBe(String(jobID))
    const card = member.locator(`#connector-human-${slug}`)
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
    await expect.poll(() => dialog.evaluate(element => element.contains(document.activeElement))).toBe(true)
    expect(new URL(member.url()).searchParams.get('automation_page')).toBe(pageID)
    expect(new URL(member.url()).searchParams.get('automation_job')).toBe(String(jobID))
    await member.screenshot({
      path: '/tmp/ankole-connectors-product-calendar-draft.png',
      fullPage: true,
      animations: 'disabled'
    })
    await dialog.getByRole('button', { name: '授权并继续', exact: true }).click()
    await expect(dialog.getByText('账户已授权，请确认后添加订阅。')).toBeVisible()
    expect(new URL(member.url()).searchParams.get('automation_page')).toBe(pageID)
    expect(new URL(member.url()).searchParams.get('automation_job')).toBe(String(jobID))
    await expect(dialog.getByLabel('Calendar ID', { exact: true })).toHaveValue(calendar)
    await expect(dialog.getByRole('combobox', { name: '个人账户', exact: true })).toContainText('browser-lark-employee')
    const created = member.waitForResponse(
      response =>
        response.request().method() === 'POST' && new URL(response.url()).pathname.endsWith('/connectors/triggers')
    )
    await dialog.getByRole('button', { name: '添加事件订阅', exact: true }).click()
    expect((await created).ok()).toBe(true)
    await expect(dialog).toBeHidden()
    await expect(member.getByText(`Personal calendar · ${calendar}`, { exact: true })).toBeVisible()
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
      triggers: {
        id: string
        config_ref: string
        scope_key: string
        trigger_type: string
        connected_account_id: string
      }[]
    }>(member, '/connectors/triggers')
    expect(result.triggers.find(item => item.scope_key === calendar)).toMatchObject({
      trigger_type: 'lark_calendar',
      connected_account_id: expect.any(String)
    })
    const subscription = result.triggers.find(item => item.scope_key === calendar)!
    await member
      .getByRole('status')
      .filter({ hasText: '订阅已创建。' })
      .getByRole('link', { name: '返回自动化并选择此来源', exact: true })
      .click()
    await expect(dialog.getByRole('combobox', { name: '自动化任务', exact: true })).toContainText(jobName)
    await expect(dialog.getByRole('combobox', { name: '事件来源', exact: true })).toContainText(calendar)
    await expect(dialog.getByRole('button', { name: '关联事件', exact: true })).toBeEnabled()
    await member.screenshot({
      path: '/tmp/ankole-connectors-automation-return.png',
      fullPage: true,
      animations: 'disabled'
    })
    const initialBindings = await request<{ bindings: { automation_job_id: number }[] }>(
      member,
      `/signal-bindings?config_ref=${encodeURIComponent(subscription.config_ref)}`
    )
    expect(initialBindings.bindings.some(binding => binding.automation_job_id === jobID)).toBe(false)
    await dialog.getByRole('link', { name: '打开外部连接', exact: true }).click()
    const subscriptionCard = member.locator('[data-slot="card"]').filter({
      has: member.getByText(`Personal calendar · ${calendar}`, { exact: true })
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
    await subscriptionCard.getByRole('link', { name: '返回自动化并选择此来源', exact: true }).click()
    await expect(dialog.getByRole('combobox', { name: '自动化任务', exact: true })).toContainText(jobName)
    const unavailableSource = new URL(member.url())
    unavailableSource.searchParams.set('connector_source', 'connector://unavailable/source')
    await member.goto(unavailableSource.href)
    await expect(
      dialog.getByText('此事件来源不可用或其连接已停用。请前往「外部连接」检查，或选择其他来源。')
    ).toBeVisible()
    await expect(dialog.getByRole('button', { name: '关联事件', exact: true })).toHaveCount(0)
    await dialog.getByRole('combobox', { name: '事件来源', exact: true }).click()
    await member
      .getByRole('option', { name: `Personal calendar application · Personal calendar · ${calendar}`, exact: true })
      .click()
    await dialog.getByRole('button', { name: '关联事件', exact: true }).click()
    await expect(dialog.getByRole('button', { name: '已关联', exact: true })).toBeVisible()
    const connected = await request<{ bindings: { automation_job_id: number; enabled: boolean }[] }>(
      member,
      `/signal-bindings?config_ref=${encodeURIComponent(subscription.config_ref)}`
    )
    expect(connected.bindings.filter(binding => binding.enabled).map(binding => binding.automation_job_id)).toEqual([
      jobID
    ])
    await request(member, `/pages/${pageID}/jobs/${jobID}`, 'DELETE')
    jobID = undefined
    await member.reload()
    await expect(
      dialog.getByText('此任务不存在或你已无权访问。你可以在「外部连接」查看订阅，或自行选择其他任务。')
    ).toBeVisible()
    await expect(dialog.getByRole('button', { name: '关联事件', exact: true })).toHaveCount(0)
    await member.goto(
      `${state.base_url}${pageRoute(pageID)}?automation_job=${state.actions!.job_id}&connector_source=${encodeURIComponent(subscription.config_ref)}`
    )
    await expect(dialog.getByText('当前任务仅供查看。关联事件或修改触发规则需要此任务的管理权限。')).toBeVisible()
    await expect(dialog.getByRole('button', { name: '关联事件', exact: true })).toHaveCount(0)
  } finally {
    if (jobID) await request(member, `/pages/${pageID}/jobs/${jobID}`, 'DELETE')
    await adminContext.close()
    await memberContext.close()
    await provider.close()
  }
})
