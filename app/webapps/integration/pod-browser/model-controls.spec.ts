import { state, request } from './fixtures'
import { expect, test, type Page } from '@playwright/test'
import { conversationRoute } from './routes'

async function choose(page: Page, option: string | RegExp) {
  const trigger = page.getByRole('combobox', { name: '模型', exact: true })
  await trigger.click()
  await expect(trigger).toHaveAttribute('aria-expanded', 'true')
  const id = await trigger.getAttribute('aria-controls')
  if (!id) throw new Error('Model picker has no controlled popup')
  await page
    .locator(`[id=${JSON.stringify(id)}]`)
    .getByRole('option', { name: option })
    .click()
  await expect(trigger).toHaveAttribute('aria-expanded', 'false')
}

test('a model choice reaches the first real input, survives reload and a failed change preserves the draft', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  let conversationID: string | undefined
  try {
    await page.goto('/')
    await choose(page, /^careful/)
    const input = page.getByRole('textbox', { name: '消息', exact: true })
    await input.fill('Model preference browser story')
    const accepted = page.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === '/.internal-apis/pod/conversations'
    )
    await page.getByRole('button', { name: '发送消息', exact: true }).click()
    const response = await accepted
    expect(response.status()).toBe(200)
    expect(response.request().postDataJSON().modelProfile).toBe('careful')
    conversationID = (await response.json()).conversation.id
    await expect(page).toHaveURL(state.base_url + conversationRoute(conversationID!))
    await page.reload()
    const picker = page.getByRole('combobox', { name: '模型', exact: true })
    await expect(picker).toHaveText('careful')
    await input.fill('Keep this unsent draft after a failed model change')
    const endpoint = `**/.internal-apis/pod/conversations/${conversationID}/model-profile`
    await page.route(endpoint, route =>
      route.request().method() === 'PUT'
        ? route.fulfill({ status: 503, json: { error: 'temporary failure' } })
        : route.continue()
    )
    await choose(page, '跟随 Agent 默认')
    await expect(page.getByRole('group', { name: '模型', exact: true }).getByRole('alert')).toBeVisible()
    await expect(picker).toHaveText('careful')
    await expect(input).toHaveValue('Keep this unsent draft after a failed model change')
    await page.unroute(endpoint)
    let releaseSave!: () => void
    let saveStarted!: () => void
    const saving = new Promise<void>(resolve => {
      saveStarted = resolve
    })
    const release = new Promise<void>(resolve => {
      releaseSave = resolve
    })
    await page.route(endpoint, async route => {
      if (route.request().method() === 'PUT') {
        saveStarted()
        await release
      }
      await route.continue()
    })
    let followups = 0
    page.on('request', request => {
      if (
        request.method() === 'POST' &&
        new URL(request.url()).pathname === `/.internal-apis/pod/conversations/${conversationID}/messages`
      ) {
        followups++
      }
    })
    try {
      await choose(page, '跟随 Agent 默认')
      await saving
      const send = page.getByRole('button', { name: '发送消息', exact: true })
      const stop = page.getByRole('button', { name: '停止回复', exact: true })
      await expect(send).toBeDisabled()
      await expect(input).toBeEnabled()
      await expect(stop).toBeEnabled()
      await input.fill('Continue editing while the model preference is saving')
      await input.press('Enter')
      expect(followups).toBe(0)
      await expect(input).toHaveValue('Continue editing while the model preference is saving')
      const stopped = page.waitForResponse(
        response =>
          response.request().method() === 'POST' &&
          new URL(response.url()).pathname === `/.internal-apis/pod/conversations/${conversationID}/queue` &&
          response.request().postDataJSON().action === 'stop'
      )
      await stop.click()
      expect((await stopped).status()).toBe(200)
      await expect(input).toBeEnabled()
      await expect(send).toBeDisabled()
      expect(followups).toBe(0)
    } finally {
      releaseSave()
    }
    await expect(picker).toHaveText('跟随 Agent 默认')
    await expect(input).toHaveValue('Continue editing while the model preference is saving')
    await expect(page.getByRole('button', { name: '发送消息', exact: true })).toBeEnabled()
    await page.unroute(endpoint)
    await page.reload()
    await expect(picker).toHaveText('跟随 Agent 默认')
    expect(
      (await request<{ profile: string | null }>(page, `/conversations/${conversationID}/model-profile`)).profile
    ).toBeNull()
  } finally {
    await context.close()
  }
})
