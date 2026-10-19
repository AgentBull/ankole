import { expect, test, caret } from './helpers'

test.beforeEach(async ({ page }) => {
  await page.goto('/playground/embedded.html')
})

test('read-only content stays readable and selectable', async ({ page }) => {
  await page.getByLabel('Source target', { exact: true }).selectOption('first')
  await page.getByLabel('Host source', { exact: true }).fill('# Readable title\n\n<embed ref="tasks" />\n\nAfter')
  await page.getByRole('button', { name: 'Apply source without moving focus', exact: true }).click()
  await expect(page.getByLabel('Source write result', { exact: true })).toHaveText('Applied')
  await page.getByRole('button', { name: 'Toggle read only', exact: true }).click()
  const panel = page.getByTestId('first-editor')
  await expect(panel.locator('.editor-content')).toHaveAttribute('contenteditable', 'false')
  expect(await panel.ariaSnapshot()).toContain('heading "Readable title" [level=1]')
  const text = await panel.locator('h1').evaluate(element => {
    const range = document.createRange()
    range.selectNodeContents(element)
    const selection = window.getSelection()!
    selection.removeAllRanges()
    selection.addRange(range)
    return selection.toString()
  })
  expect(text).toBe('Readable title')
  await expect(panel.locator('.embed code')).toHaveText('tasks')
  await page.getByRole('button', { name: 'Toggle read only', exact: true }).click()
  await expect(panel.locator('.editor-content')).toHaveAttribute('contenteditable', 'true')
})

test('keyboard block actions work with a custom or absent toolbar', async ({ page }) => {
  const editor = page.getByRole('textbox', { name: 'Second document', exact: true })
  for (const mode of ['custom', 'absent']) {
    if (mode === 'absent') await page.getByRole('button', { name: 'Toggle second toolbar', exact: true }).click()
    await caret(editor.locator('p').first())
    await editor.press('ControlOrMeta+/')
    await expect(page.getByRole('menu', { name: 'Block 操作', exact: true })).toBeVisible()
    await page.keyboard.press('Escape')
    await expect(page.getByRole('menu', { name: 'Block 操作', exact: true })).toBeHidden()
    await expect(editor).toBeFocused()
    await page.keyboard.press('ControlOrMeta+d')
    await expect(editor.locator('p')).toHaveCount(mode === 'custom' ? 2 : 3)
  }
})

test('a host write waits for the composition in the editor to end', async ({ page, browserName }) => {
  test.skip(browserName !== 'chromium', 'Playwright exposes IME composition through Chromium CDP only.')
  const editor = page.getByRole('textbox', { name: 'Second document', exact: true })
  const result = page.getByLabel('Source write result', { exact: true })
  const apply = page.getByRole('button', { name: 'Apply source without moving focus', exact: true })
  await page.getByLabel('Host source', { exact: true }).fill('Replaced')
  await caret(editor.locator('p'))
  const client = await page.context().newCDPSession(page)
  await client.send('Input.imeSetComposition', { text: 'zhong', selectionStart: 5, selectionEnd: 5 })
  // A click event alone does not move focus, so the composition stays open.
  await apply.dispatchEvent('click')
  await expect(result).toContainText('输入法')
  await expect(editor).toBeFocused()
  await expect(editor.locator('p')).toContainText('Beta text')
  await client.send('Input.insertText', { text: '中' })
  await apply.dispatchEvent('click')
  await expect(result).toHaveText('Applied')
  await expect(editor.locator('p')).toHaveText('Replaced')
})

test('imported H4 to H6 retain visible heading emphasis', async ({ page }) => {
  await page.getByLabel('Host source', { exact: true }).fill('#### Four\n\n##### Five\n\n###### Six\n\nBody')
  await page.getByRole('button', { name: 'Apply source without moving focus', exact: true }).click()
  const styles = await page
    .getByTestId('second-editor')
    .locator('h4,h5,h6,p')
    .evaluateAll(elements =>
      elements.map(element => {
        const style = getComputedStyle(element)
        return { tag: element.tagName, weight: Number(style.fontWeight), margin: parseFloat(style.marginTop) }
      })
    )
  expect(styles.map(style => style.tag)).toEqual(['H4', 'H5', 'H6', 'P'])
  for (const heading of styles.slice(0, 3)) {
    expect(heading.weight).toBeGreaterThan(styles[3]!.weight)
    expect(heading.margin).toBeGreaterThan(styles[3]!.margin)
  }
})

test('public React entry keeps two documents, history and host styles independent', async ({ page }) => {
  const first = page.getByRole('textbox', { name: 'First document', exact: true })
  const second = page.getByRole('textbox', { name: 'Second document', exact: true })
  await expect(first).toContainText('Alpha text')
  await expect(second).toContainText('Beta text')
  const hostSize = await page.getByTestId('host-heading').evaluate(node => getComputedStyle(node).fontSize)
  const editorSize = await first.locator('h1').evaluate(node => getComputedStyle(node).fontSize)
  expect(hostSize).not.toBe(editorSize)
  expect(await page.evaluate(() => localStorage.length)).toBe(0)
  await caret(second.locator('p'))
  await second.press('ControlOrMeta+a')
  await page.getByRole('button', { name: 'Host bold', exact: true }).click()
  await expect(page.getByLabel('Second Markdown', { exact: true })).toContainText('**Beta text**')
  await expect(page.getByLabel('First Markdown', { exact: true })).not.toContainText('**')
  await page.getByRole('button', { name: 'Undo second', exact: true }).click()
  await expect(page.getByLabel('Second Markdown', { exact: true })).not.toContainText('**')
  await page.getByRole('button', { name: 'Apply XML to second', exact: true }).click()
  await expect(second.locator('.callout')).toContainText('Applied XML')
  await expect(first.locator('p')).toHaveText('Alpha text')
})

test('host rerenders keep edits and use the latest callbacks without recreating the editor', async ({ page }) => {
  const first = page.getByRole('textbox', { name: 'First document', exact: true })
  await expect(first).toContainText('Alpha text')
  const lifecycle = await page.getByLabel('Lifecycle', { exact: true }).textContent()
  await caret(first.locator('p'))
  await first.pressSequentially(' before')
  await page.getByRole('button', { name: 'Rerender host', exact: true }).click()
  await expect(first).toContainText('Alpha text before')
  await expect(first).not.toContainText('New initial')
  await expect(page.getByLabel('Lifecycle', { exact: true })).toHaveText(lifecycle!)
  await caret(first.locator('p'))
  await first.pressSequentially(' after')
  await expect(page.getByLabel('Observed host render', { exact: true })).toHaveText('1')
  await expect(page.getByLabel('First Markdown', { exact: true })).toContainText('Alpha text before after')
  await page.getByRole('button', { name: 'Toggle read only', exact: true }).click()
  await expect(page.getByTestId('first-editor').locator('.editor-content')).toHaveAttribute('contenteditable', 'false')
  await page.getByRole('button', { name: 'Toggle read only', exact: true }).click()
  await expect(first).toHaveAttribute('contenteditable', 'true')
  await expect(first).toContainText('Alpha text before after')
})

test('menus, selection overlays and cleanup belong to the active instance', async ({ page }) => {
  const first = page.getByRole('textbox', { name: 'First document', exact: true })
  const second = page.getByRole('textbox', { name: 'Second document', exact: true })
  for (const target of [first, second]) {
    await caret(target.locator('p'))
    await target.press('Enter')
    await target.pressSequentially('/h1')
    await expect(page.getByRole('listbox', { name: '插入 Block' })).toBeVisible()
    await expect(page.locator('.slash-menu')).toHaveCount(1)
    await target.press('Enter')
    await target.pressSequentially(target === first ? 'One heading' : 'Two heading')
  }
  await expect(first.locator('h1').last()).toHaveText('One heading')
  await expect(second.locator('h1').last()).toHaveText('Two heading')
  await page.getByTestId('first-editor').evaluate(element => {
    element.style.marginTop = '240px'
  })
  await caret(second.locator('p'))
  await second.press('ControlOrMeta+a')
  const toolbar = page.getByRole('toolbar', { name: '选区格式' })
  await expect(toolbar).toBeVisible()
  const rect = await toolbar.boundingBox()
  const selection = await page.evaluate(() => {
    const rect = window.getSelection()!.getRangeAt(0).getBoundingClientRect()
    return { center: rect.x + rect.width / 2, top: rect.top }
  })
  expect(Math.abs(rect!.x + rect!.width / 2 - selection.center)).toBeLessThan(2)
  expect(rect!.y + rect!.height).toBeLessThanOrEqual(selection.top)
  const before = JSON.parse((await page.getByLabel('Lifecycle', { exact: true }).textContent())!)
  await page.getByRole('button', { name: 'Toggle first editor', exact: true }).click()
  await expect(first).toHaveCount(0)
  await expect
    .poll(async () => JSON.parse((await page.getByLabel('Lifecycle', { exact: true }).textContent())!).disposed)
    .toBe(before.disposed + 1)
  await caret(second.locator('p'))
  await second.pressSequentially(' still works')
  await expect(page.getByLabel('Second Markdown', { exact: true })).toContainText('Beta text still works')
  await page.getByRole('button', { name: 'Toggle first editor', exact: true }).click()
  await expect(first).toContainText('Alpha text')
  await expect(second).toContainText('Beta text still works')
})

test('public host and collaboration APIs keep image metadata, embeds and undo', async ({ page }) => {
  await page.getByLabel('Host source', { exact: true }).fill('<embed ref="tasks" />\n\nBefore')
  await page.getByRole('button', { name: 'Apply source without moving focus', exact: true }).click()
  const panel = page.getByTestId('second-editor')
  await expect(panel.locator('.embed[data-host="mounted"] code')).toHaveText('tasks')
  await caret(panel.locator('p'))
  await page.getByRole('button', { name: 'Insert image', exact: true }).click()
  const image = panel.locator('img')
  await expect(image).toHaveAttribute('src', /^data:image/)
  await expect(image).toHaveAttribute('alt', 'Image description')
  await expect(image).toHaveAttribute('title', 'Image title')
  await expect
    .poll(async () => JSON.parse((await page.getByLabel('Host collaboration', { exact: true }).textContent())!).pending)
    .toBe(false)
  await expect(page.getByLabel('Second Markdown', { exact: true })).toContainText('ankole:asset/image')
  await page.getByRole('button', { name: 'Undo second', exact: true }).click()
  await expect(image).toHaveCount(0)
  await expect(panel.locator('.embed[data-host="mounted"] code')).toHaveText('tasks')
})

test('an oversized edit is rejected before state changes and later edits still save', async ({ page }) => {
  await page.getByLabel('Host source', { exact: true }).fill('Before')
  await page.getByRole('button', { name: 'Apply source without moving focus', exact: true }).click()
  const editor = page.getByRole('textbox', { name: 'Second document', exact: true })
  await expect
    .poll(async () => JSON.parse((await page.getByLabel('Host collaboration', { exact: true }).textContent())!).pending)
    .toBe(false)
  const before = await page.getByLabel('Host collaboration', { exact: true }).textContent()
  await caret(editor.locator('p'))
  await page.getByRole('button', { name: 'Insert oversized image', exact: true }).click()
  await expect(page.getByTestId('second-editor').getByRole('alert')).toContainText('UTF-16')
  await expect(editor.locator('img')).toHaveCount(0)
  await expect(editor.locator('p')).toHaveText('Before')
  await expect(page.getByLabel('Host collaboration', { exact: true })).toHaveText(before!)
  await caret(editor.locator('p'))
  await editor.pressSequentially(' after')
  await expect(page.getByLabel('Second Markdown', { exact: true })).toHaveText('Before after')
  await expect(page.getByTestId('second-editor').getByRole('alert')).toHaveCount(0)
  await expect
    .poll(
      async () => JSON.parse((await page.getByLabel('Host collaboration', { exact: true }).textContent())!).revision
    )
    .toBeGreaterThan(JSON.parse(before!).revision)
  await page.getByRole('button', { name: 'Undo second', exact: true }).click()
  await expect(editor.locator('p')).toHaveText('Before')
})
