import { expect, test } from '@playwright/test'
import { state, request } from './fixtures'
import { pageRoute } from './routes'

test('a server append and same-paragraph terminology patch preserve trusted Chromium IME and its caret', async ({
  browser,
  browserName
}, info) => {
  test.skip(browserName !== 'chromium', 'Chromium CDP supplies trusted composition events.')
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  const client = await context.newCDPSession(page)
  let id: string | undefined
  try {
    await page.goto(state.base_url + pageRoute(state.report_id))
    const created = await request<{ page: { id: string } }>(page, '/pages', 'POST', {
      type: 'doc',
      title: 'Concurrent IME requirement'
    })
    id = created.page.id
    const first = '<p>产品说明😀。</p>'
    const old = '旧术语😀：产品经理在此输入，末尾。'
    const replacement = '接口术语😀：产品经理在此输入，末尾。'
    const initial = `<page>${first}<p>${old}</p></page>`
    const seeded = await request<{ page: { revision: number } }>(page, `/pages/${id}/content`, 'PUT', {
      base_revision: 0,
      xml: initial
    })
    await page.goto(state.base_url + pageRoute(id))
    const editor = page.locator('.editor-content')
    const paragraph = editor.locator(':scope > p').nth(1)
    await expect(paragraph).toHaveText(old)
    await paragraph.evaluate(element => {
      const root = element.closest('.editor-content') as HTMLElement
      root.focus()
      const text = element.firstChild as Text
      const position = text.data.indexOf('，末尾')
      window.getSelection()!.setBaseAndExtent(text, position, text, position)
      const probe = {
        paragraph: element,
        text: null as Node | null,
        events: [] as { type: string; trusted: boolean }[]
      }
      Object.assign(window, { podIMEProbe: probe })
      for (const type of ['compositionstart', 'compositionupdate', 'compositionend']) {
        root.addEventListener(type, event => probe.events.push({ type, trusted: event.isTrusted }))
      }
      document.dispatchEvent(new Event('selectionchange'))
    })
    await client.send('Input.imeSetComposition', { text: 'zhong', selectionStart: 5, selectionEnd: 5 })
    await client.send('Input.imeSetComposition', { text: '中文', selectionStart: 2, selectionEnd: 2 })
    await expect(paragraph).toContainText('中文')
    await paragraph.evaluate(() => {
      const probe = (window as unknown as { podIMEProbe: { text: Node | null } }).podIMEProbe
      probe.text = window.getSelection()!.focusNode
    })
    const appended = `<page>${first}<p>${old}</p><h2>接口规范</h2><p>POST /评价 😀</p></page>`
    const append = await request<{ page: { revision: number } }>(page, `/pages/${id}/content`, 'PUT', {
      base_revision: seeded.page.revision,
      xml: appended
    })
    await expect(editor.locator('h2')).toHaveText('接口规范')
    await request(page, `/pages/${id}/content`, 'PUT', {
      base_revision: append.page.revision,
      xml: appended.replace(old, replacement)
    })
    await expect(paragraph).toHaveText(replacement.replace('，末尾', '中文，末尾'))
    const during = await paragraph.evaluate(element => {
      const probe = (
        window as unknown as {
          podIMEProbe: { paragraph: Element; text: Node; events: { type: string; trusted: boolean }[] }
        }
      ).podIMEProbe
      const selected = window.getSelection()!
      const beforeCaret = document.createRange()
      beforeCaret.selectNodeContents(element)
      beforeCaret.setEnd(selected.focusNode!, selected.focusOffset)
      return {
        sameParagraph: element === probe.paragraph,
        sameCompositionNode: selected.focusNode === probe.text && probe.text.isConnected,
        caretPrefix: beforeCaret.toString(),
        events: probe.events
      }
    })
    expect(during.sameParagraph).toBe(true)
    expect(during.sameCompositionNode).toBe(true)
    expect(during.caretPrefix).toBe(`${replacement.split('，末尾')[0]}中文`)
    expect(during.events.filter(event => event.type === 'compositionstart')).toHaveLength(1)
    expect(during.events.filter(event => event.type === 'compositionend')).toHaveLength(0)
    expect(during.events.every(event => event.trusted)).toBe(true)
    await client.send('Input.insertText', { text: '中文' })
    await page.keyboard.insertText('继续')
    const expected = replacement.replace('，末尾', '中文继续，末尾')
    await expect(paragraph).toHaveText(expected)
    await expect
      .poll(async () => (await request<{ content: { content: string } }>(page, `/pages/${id}`)).content.content)
      .toBe(`<page>${first}<p>${expected}</p><h2>接口规范</h2><p>POST /评价 😀</p></page>`)
    await info.attach('trusted-ime-during-remote-edits.json', {
      body: JSON.stringify(during, null, 2),
      contentType: 'application/json'
    })
    await page.reload()
    await expect(page.locator('.editor-content > p').nth(1)).toHaveText(expected)
  } finally {
    await client.detach()
    if (id) await request(page, `/pages/${id}`, 'DELETE')
    await context.close()
  }
})
