import { state, login } from './fixtures'
import { expect, test, type Page } from '@playwright/test'
import { pageRoute } from './routes'

async function identity(page: Page) {
  return page.evaluate(async () => {
    const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)!.content
    const result = await fetch('/api/v2/browser/session', {
      headers: {
        'x-ankole-authentication': meta('ankole-authentication'),
        'x-ankole-pod': meta('ankole-pod')
      }
    })
    if (!result.ok) throw new Error(`Pinned identity: ${result.status}`)
    return result.json() as Promise<{ principalUID: string }>
  })
}

test('real password logins share two Pod accounts while the chooser preserves each open document identity', async ({
  browser
}) => {
  const context = await browser.newContext()
  const first = await context.newPage()
  const second = await context.newPage()
  try {
    const original = state.base_url + pageRoute(state.report_id)
    await first.goto(original)
    await login(first, state.owner)
    await expect(first).toHaveURL(original)
    await expect(first.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    expect((await identity(first)).principalUID).toBe(state.owner.uid)

    const other = state.other_pod.base_url + pageRoute(state.other_pod.page_id)
    await second.goto(other)
    await login(second, state.other_pod)
    await expect(second).toHaveURL(other)
    await expect(second.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    expect((await identity(second)).principalUID).toBe(state.other_pod.uid)
    expect((await identity(first)).principalUID).toBe(state.owner.uid)

    const cookies = await context.cookies(state.base_url)
    expect(cookies.filter(cookie => cookie.name.startsWith('_ankole-auth-'))).toHaveLength(2)
    expect(cookies.every(cookie => cookie.domain === '.ankole.localhost')).toBe(true)
    expect((await context.cookies(state.other_pod.base_url)).map(cookie => cookie.name).sort()).toEqual(
      cookies.map(cookie => cookie.name).sort()
    )

    await first.getByRole('button', { name: /^账户菜单/ }).click()
    await first.getByRole('menuitem', { name: '切换或添加账户', exact: true }).click()
    await expect(first).toHaveURL(url => url.pathname === '/sessions/new' && url.searchParams.has('flow'))
    await first.getByRole('button', { name: /^Browser owner ·/ }).click()
    await expect(first).toHaveURL(original)
    await expect(first.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    expect((await identity(first)).principalUID).toBe(state.owner.uid)
    expect((await identity(second)).principalUID).toBe(state.other_pod.uid)
  } finally {
    await context.close()
  }
})

test('the normal chooser switches between two real accounts in one Pod without changing another open document', async ({
  browser
}) => {
  const context = await browser.newContext()
  const first = await context.newPage()
  const second = await context.newPage()
  try {
    const original = state.base_url + pageRoute(state.report_id)
    await first.goto(original)
    await login(first, state.owner)
    await expect(first).toHaveURL(original)
    await expect(first.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    expect((await identity(first)).principalUID).toBe(state.owner.uid)

    await second.goto(original)
    await second.getByRole('button', { name: /^账户菜单/ }).click()
    await second.getByRole('menuitem', { name: '切换或添加账户', exact: true }).click()
    await login(second, state.member)
    await expect(second).toHaveURL(original)
    await expect(second.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    expect((await identity(second)).principalUID).toBe(state.member.uid)
    expect((await identity(first)).principalUID).toBe(state.owner.uid)

    await first.getByRole('button', { name: /^账户菜单/ }).click()
    await first.getByRole('menuitem', { name: '切换或添加账户', exact: true }).click()
    await expect(first.getByRole('button', { name: /^Browser member ·/ })).toBeVisible()
    await first.getByRole('button', { name: /^Browser owner ·/ }).click()
    await expect(first).toHaveURL(original)
    await expect(first.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    expect((await identity(first)).principalUID).toBe(state.owner.uid)
    expect((await identity(second)).principalUID).toBe(state.member.uid)
  } finally {
    await context.close()
  }
})

test('the sidebar account menu lists each proved organization and opens another one as its account', async ({
  browser
}) => {
  const context = await browser.newContext()
  const first = await context.newPage()
  const second = await context.newPage()
  try {
    const original = state.base_url + pageRoute(state.report_id)
    await first.goto(original)
    await login(first, state.owner)
    await expect(first.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()
    await second.goto(state.other_pod.base_url + pageRoute(state.other_pod.page_id))
    await login(second, state.other_pod)
    await expect(second.getByRole('textbox', { name: '页面标题', exact: true })).toBeVisible()

    await first.getByRole('button', { name: /^账户菜单/ }).click()
    const menu = first.getByRole('menu')
    await expect(menu.locator('[role="menuitem"][aria-current="true"]')).toHaveText(/Browser owner/)
    const other = menu.getByRole('menuitem', { name: /Other workspace owner/ })
    await expect(other).toBeVisible()
    await expect(menu.getByRole('menuitemradio', { name: '浅色', exact: true })).toBeVisible()
    await expect(menu.getByRole('menuitem', { name: /^退出 .*Browser owner/ })).toBeVisible()
    await other.click()
    await expect(first).toHaveURL(url => url.origin === new URL(state.other_pod.base_url).origin)
    await expect(first.getByRole('button', { name: /^账户菜单/ })).toBeVisible()
    expect((await identity(first)).principalUID).toBe(state.other_pod.uid)
  } finally {
    await context.close()
  }
})
