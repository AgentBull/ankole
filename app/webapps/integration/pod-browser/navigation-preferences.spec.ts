import { readFileSync } from 'node:fs'
import { expect, test, type BrowserContext, type Page } from '@playwright/test'
import { pageRoute } from './routes'

type Identity = { uid: string; email: string; password: string; cookies: Parameters<BrowserContext['addCookies']>[0] }
const state = JSON.parse(readFileSync(process.env.POD_BROWSER_STATE_PATH!, 'utf8')) as {
  base_url: string
  report_id: string
  owner: Identity
  member: Identity
}
const space = (page: Page) => page.getByRole('region', { name: '空间', exact: true })
const rootToggle = (page: Page) => space(page).getByRole('button', { name: '空间', exact: true })
const privateToggle = (page: Page) =>
  page.getByRole('region', { name: 'Private', exact: true }).getByRole('button', { name: 'Private', exact: true })

async function request<T>(page: Page, path: string, method = 'GET', body?: unknown): Promise<T> {
  return page.evaluate(
    async ({ path, method, body }) => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)!.content
      const response = await fetch(`/.internal-apis/pod${path}`, {
        method,
        headers: {
          'content-type': 'application/json',
          'x-ankole-authentication': meta('ankole-authentication'),
          'x-ankole-pod': meta('ankole-pod'),
          'x-csrf-token': meta('csrf-token')
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
      })
      if (!response.ok) throw new Error(`${method} ${path}: ${response.status}`)
      return response.status === 204 ? null : response.json()
    },
    { path, method, body }
  )
}

async function create(page: Page, title: string, attrs: Record<string, unknown> = {}) {
  const result = await request<{ page: { id: string } }>(page, '/pages', 'POST', { type: 'doc', title, ...attrs })
  return result.page.id
}

async function identity(page: Page) {
  return page.evaluate(async () => {
    const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)!.content
    const response = await fetch('/.internal-apis/session', {
      headers: {
        'x-ankole-authentication': meta('ankole-authentication'),
        'x-ankole-pod': meta('ankole-pod')
      }
    })
    if (!response.ok) throw new Error(`Pinned identity: ${response.status}`)
    return (await response.json()).principalUID as string
  })
}

test('root folding retains branches and reload restores the first visible navigation without expanding it', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const created: string[] = []
  try {
    await page.goto(pageRoute(state.report_id))
    const title = `Navigation branch ${crypto.randomUUID()}`
    const parent = await create(page, title)
    created.push(parent)
    const childTitle = `Navigation child ${crypto.randomUUID()}`
    await create(page, childTitle, { parent_id: parent })
    const privatePage = await create(page, 'Navigation private destination', { private_owner_uid: state.owner.uid })
    created.push(privatePage)
    await page.goto(pageRoute(privatePage))
    const branch = space(page).getByRole('button', { name: title, exact: true })
    await expect(space(page).getByRole('link', { name: childTitle, exact: true })).toBeVisible()
    await branch.click()
    await expect(branch).toHaveAttribute('aria-expanded', 'false')
    await rootToggle(page).click()
    await rootToggle(page).click()
    await expect(branch).toHaveAttribute('aria-expanded', 'false')
    await expect(space(page).getByRole('link', { name: childTitle, exact: true })).toHaveCount(0)
    await rootToggle(page).click()
    await page.addInitScript(() => {
      const observed = window as Window & { __spaceExpansion?: string[] }
      observed.__spaceExpansion = []
      new MutationObserver(records => {
        const button = document.querySelector('section[aria-label="空间"] button[aria-label="空间"]')
        if (!button) return
        observed.__spaceExpansion!.push(button.getAttribute('aria-expanded')!)
        for (const record of records) {
          if (record.target === button && record.attributeName === 'aria-expanded' && record.oldValue === 'true') {
            observed.__spaceExpansion!.push('true')
          }
        }
      }).observe(document, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['aria-expanded'],
        attributeOldValue: true
      })
    })
    await page.reload()
    await expect(rootToggle(page)).toHaveAttribute('aria-expanded', 'false')
    await expect(page.getByRole('textbox', { name: '页面标题', exact: true })).toHaveValue(
      'Navigation private destination'
    )
    const seen = await page.evaluate(() => (window as Window & { __spaceExpansion?: string[] }).__spaceExpansion!)
    expect(seen).toContain('false')
    expect(seen).not.toContain('true')
    const sameIdentity = await context.newPage()
    await sameIdentity.goto(pageRoute(privatePage))
    await expect(rootToggle(sameIdentity)).toHaveAttribute('aria-expanded', 'false')
    await rootToggle(sameIdentity).click()
    await expect(rootToggle(page)).toHaveAttribute('aria-expanded', 'true')
    await expect(branch).toHaveAttribute('aria-expanded', 'false')
  } finally {
    for (const id of created.reverse()) await request(page, `/pages/${id}`, 'DELETE').catch(() => {})
    await context.close()
  }
})

test('navigation stays with each real document identity and stored branches cannot restore revoked pages', async ({
  browser
}) => {
  const context = await browser.newContext({ baseURL: state.base_url })
  await context.addCookies(state.owner.cookies)
  const owner = await context.newPage()
  const member = await context.newPage()
  let parent: string | undefined
  try {
    await owner.goto(pageRoute(state.report_id))
    const title = `Navigation access ${crypto.randomUUID()}`
    parent = await create(owner, title)
    await create(owner, 'Navigation access child', { parent_id: parent })
    await rootToggle(owner).click()
    await expect(rootToggle(owner)).toHaveAttribute('aria-expanded', 'false')
    await member.goto(pageRoute(state.report_id))
    await expect(rootToggle(member)).toHaveAttribute('aria-expanded', 'false')
    await member.getByRole('link', { name: '切换账号', exact: true }).click()
    await member.getByRole('textbox', { name: '邮箱', exact: true }).fill(state.member.email)
    await member.getByLabel('密码', { exact: true }).fill(state.member.password)
    const loggedIn = member.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname === '/.internal-apis/sessions/local-password'
    )
    await member.getByRole('button', { name: '登录', exact: true }).click()
    expect((await loggedIn).status()).toBe(200)
    await expect(member).toHaveURL(state.base_url + pageRoute(state.report_id))
    expect(await identity(member)).toBe(state.member.uid)
    expect(await identity(owner)).toBe(state.owner.uid)
    await expect(rootToggle(member)).toHaveAttribute('aria-expanded', 'true')
    const branch = space(member).getByRole('button', { name: title, exact: true })
    await branch.click()
    await privateToggle(member).click()
    await expect(privateToggle(member)).toHaveAttribute('aria-expanded', 'false')
    await expect(privateToggle(owner)).toHaveAttribute('aria-expanded', 'true')
    await expect(rootToggle(owner)).toHaveAttribute('aria-expanded', 'false')
    const baseline = await request<{ sharing_version: string }>(owner, `/pages/${parent}/sharing`)
    await request(owner, `/pages/${parent}/sharing`, 'PUT', {
      inherit_permissions: false,
      grants: [],
      sharing_version: baseline.sharing_version
    })
    await member.reload()
    await expect(member.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    await expect(privateToggle(member)).toHaveAttribute('aria-expanded', 'false')
    await expect(space(member).getByRole('link', { name: title, exact: true })).toHaveCount(0)
    await owner.getByRole('link', { name: '切换账号', exact: true }).click()
    await owner.getByRole('button', { name: /^Browser owner ·/ }).click()
    await expect(owner).toHaveURL(state.base_url + pageRoute(state.report_id))
    await expect(rootToggle(owner)).toHaveAttribute('aria-expanded', 'false')
    await expect(privateToggle(owner)).toHaveAttribute('aria-expanded', 'true')
    expect(await identity(owner)).toBe(state.owner.uid)
    expect(await identity(member)).toBe(state.member.uid)
  } finally {
    if (parent) await request(owner, `/pages/${parent}`, 'DELETE').catch(() => {})
    await context.close()
  }
})
