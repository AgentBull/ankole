import { test, expect, clipboard, caret } from './helpers'

const id = '019a2b00-0000-7000-8000-000000000001'

test.beforeEach(async ({ page }) => {
  await page.goto('/playground/embedded.html')
  await page.getByRole('button', { name: 'Apply comment to first', exact: true }).click()
})

test('same-editor cut moves the anchor once while copy and repeated paste carry content', async ({ page }) => {
  const first = page.getByRole('textbox', { name: 'First document', exact: true })
  await caret(first.locator('p').first(), 0)
  await first.press('ControlOrMeta+a')
  const copied = await clipboard(first, 'copy')
  expect(JSON.stringify(copied)).not.toContain(id)
  const cut = await clipboard(first, 'cut')
  await expect(first.locator('[data-comment-ids]')).toHaveCount(0)
  expect(JSON.stringify(cut)).not.toContain(id)
  await caret(first.locator('p').last())
  await clipboard(first, 'paste', cut)
  await expect(first.locator('[data-comment-ids]')).toHaveText('Anchored text')
  await expect(first.locator('p').last()).toContainText('DestinationAnchored text')
  await clipboard(first, 'paste', cut)
  await expect(first.locator('[data-comment-ids]')).toHaveCount(1)
  await expect(first.locator('p').last()).toContainText('DestinationAnchored textAnchored text')
})

test('cutting a whole code block preserves its native anchor once', async ({ page }) => {
  await page.getByRole('button', { name: 'Apply code comment to first', exact: true }).click()
  const first = page.getByTestId('first-editor').locator('.editor-content')
  await caret(first.locator('pre'))
  // Escape selects the complete current block, including its code container.
  await first.press('Escape')
  await expect(first.locator('.editor-code-block')).toHaveClass(/editor-selected-block/)
  const cut = await clipboard(first, 'cut')
  expect(JSON.stringify(cut)).not.toContain(id)
  await expect(first.locator('pre')).toHaveCount(0)
  await clipboard(first, 'paste', cut)
  await expect(first.locator('pre')).toHaveText('ab\n  cd')
  await expect(first.locator('[data-comment-ids]')).toHaveText(['b\n  c'])
  await expect(first.locator('[data-comment-ids]')).toHaveAttribute('data-comment-ids', id)
})

test('resolved anchors redraw without changing content; overlapping open threads remain clickable', async ({
  page
}) => {
  const first = page.getByTestId('first-editor').locator('.editor-content')
  await page.getByRole('button', { name: 'Toggle comment resolved', exact: true }).click()
  await expect(first.locator('.editor-comment-anchor')).toHaveCount(0)
  await expect(first.locator('p').first()).toHaveText('Anchored text')
  await page.getByRole('button', { name: 'Toggle comment resolved', exact: true }).click()
  await expect(first.locator('[data-comment-ids]')).toHaveAttribute('data-comment-ids', id)
  await page.getByRole('button', { name: 'Apply overlapping comments', exact: true }).click()
  await first.locator('[data-comment-ids]').click()
  const second = '019a2b00-0000-7000-8000-000000000002'
  await expect(page.getByLabel('Comment event', { exact: true })).toHaveText(`${id} ${second}`)
  await page.getByRole('button', { name: 'Toggle comment resolved', exact: true }).click()
  await first.locator('[data-comment-ids]').click()
  await expect(page.getByLabel('Comment event', { exact: true })).toHaveText(second)
})

test('readonly anchors open threads and selected text offers only asking an Agent and comment creation', async ({
  page
}) => {
  const first = page.getByTestId('first-editor').locator('.editor-content')
  await page.getByRole('button', { name: 'Toggle read only', exact: true }).click()
  await first.locator('[data-comment-ids]').click()
  await expect(page.getByLabel('Comment event', { exact: true })).toHaveText(id)
  await first.evaluate(element => {
    const text = element.querySelector('p')!.firstChild!.firstChild!
    ;(element as HTMLElement).focus()
    window.getSelection()!.setBaseAndExtent(text, 0, text, 8)
    document.dispatchEvent(new Event('selectionchange'))
  })
  const toolbar = page.getByRole('toolbar', { name: '选区格式', exact: true })
  await expect(toolbar).toBeVisible()
  await expect(toolbar.getByRole('button')).toHaveCount(2)
  await toolbar.getByRole('button', { name: '评论', exact: true }).click()
  await expect(page.getByLabel('Comment event', { exact: true })).toHaveText('{"from":1,"to":9,"quote":"Anchored"}')
  await expect(first.locator('[data-comment-ids]')).toHaveText('Anchored text')
})

test('source Markdown edits keep current anchors without exposing IDs', async ({ page }) => {
  await page.getByLabel('Source target', { exact: true }).selectOption('first')
  await page.getByLabel('Host source', { exact: true }).fill('Anchored text\n\nUpdated')
  await page.getByRole('button', { name: 'Apply source without moving focus', exact: true }).click()
  const first = page.getByTestId('first-editor').locator('.editor-content')
  await expect(first.locator('[data-comment-ids]')).toHaveText('Anchored text')
  await expect(first.locator('p').last()).toHaveText('Updated')
  await expect(page.getByLabel('First Markdown', { exact: true })).toHaveText('Anchored text\n\nUpdated')
})

test('comment creation reads a native selection made before the editor next draws', async ({ page }) => {
  const first = page.getByTestId('first-editor').locator('.editor-content')
  await caret(first.locator('p').first(), 0)
  await first.press('ControlOrMeta+a')
  const button = page
    .getByRole('toolbar', { name: '选区格式', exact: true })
    .getByRole('button', { name: '评论', exact: true })
  await expect(button).toBeVisible()
  await first.evaluate(element => {
    const text = element.querySelector('p:last-child')!.firstChild!
    window.getSelection()!.setBaseAndExtent(text, 0, text, text.textContent!.length)
    document.dispatchEvent(new Event('selectionchange'))
    // Keep selectionchange and the toolbar action in the same browser task.
    document.querySelector<HTMLButtonElement>('.selection-toolbar button[aria-label="评论"]')!.click()
  })
  await expect(page.getByLabel('Comment event', { exact: true })).toHaveText(
    '{"from":16,"to":27,"quote":"Destination"}'
  )
})

test('the same text can be selected again to start an overlapping discussion', async ({ page }) => {
  const first = page.getByTestId('first-editor').locator('.editor-content')
  for (let attempt = 0; attempt < 2; attempt++) {
    await caret(first.locator('p').first(), 0)
    await first.press('ControlOrMeta+a')
    const toolbar = page.getByRole('toolbar', { name: '选区格式', exact: true })
    await expect(toolbar).toBeVisible()
    await toolbar.getByRole('button', { name: '评论', exact: true }).click()
    await expect(page.getByLabel('Comment event', { exact: true })).toHaveText(
      '{"from":1,"to":14,"quote":"Anchored text"}'
    )
  }
})

test('code snippet selection uses the same comment action and preserves code whitespace', async ({ page }) => {
  await page.getByRole('button', { name: 'Apply code comment to first', exact: true }).click()
  const first = page.getByTestId('first-editor').locator('.editor-content')
  await expect(first.locator('pre')).toHaveText('ab\n  cd')
  await first.evaluate(element => {
    const walker = document.createTreeWalker(element.querySelector('pre')!, NodeFilter.SHOW_TEXT)
    const texts: Text[] = []
    while (walker.nextNode()) texts.push(walker.currentNode as Text)
    ;(element as HTMLElement).focus()
    window.getSelection()!.setBaseAndExtent(texts[0]!, 0, texts.at(-1)!, texts.at(-1)!.length)
    document.dispatchEvent(new Event('selectionchange'))
  })
  const toolbar = page.getByRole('toolbar', { name: '选区格式', exact: true })
  await expect(toolbar.getByRole('button')).toHaveCount(2)
  await toolbar.getByRole('button', { name: '评论', exact: true }).click()
  await expect(page.getByLabel('Comment event', { exact: true })).toHaveText('{"from":1,"to":8,"quote":"ab\\n  cd"}')
  await expect(page.getByLabel('First Markdown', { exact: true })).toHaveText('```ts\nab\n  cd\n```')
  await caret(first.locator('pre'))
  await first.pressSequentially('!')
  await expect(first.locator('pre')).toHaveText('ab\n  cd!')
  await expect(first.locator('[data-comment-ids]').first()).toHaveAttribute('data-comment-ids', id)
})

test('dragging a paragraph keeps its anchor and duplicating it does not duplicate the discussion', async ({ page }) => {
  const panel = page.getByTestId('first-editor')
  const editor = panel.locator('.editor-content')
  const paragraphs = editor.locator('p')
  await paragraphs.first().hover()
  const grip = panel.getByRole('button', { name: 'Block 菜单', exact: true })
  await expect(grip).toBeVisible()
  const from = (await grip.boundingBox())!
  const to = (await paragraphs.last().boundingBox())!
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2)
  await page.mouse.down()
  await page.mouse.move(to.x + 10, to.y + to.height - 2, { steps: 12 })
  await page.mouse.move(to.x + 12, to.y + to.height - 1)
  await expect(panel.locator('.drag-line')).toHaveCSS('opacity', '1')
  await page.mouse.up()
  await expect(paragraphs).toHaveText(['Destination', 'Anchored text'])
  await expect(paragraphs.last().locator('[data-comment-ids]')).toHaveAttribute('data-comment-ids', id)
  await editor.press('ControlOrMeta+d')
  await expect(paragraphs).toHaveText(['Destination', 'Anchored text', 'Anchored text'])
  await expect(editor.locator('[data-comment-ids]')).toHaveCount(1)
})

test('asking an Agent hands the selected text to the host and leaves the document unchanged', async ({ page }) => {
  const first = page.getByTestId('first-editor').locator('.editor-content')
  const before = await page.getByLabel('First Markdown', { exact: true }).textContent()
  await first.evaluate(element => {
    const text = element.querySelector('p')!.firstChild!.firstChild!
    ;(element as HTMLElement).focus()
    window.getSelection()!.setBaseAndExtent(text, 0, text, 8)
    document.dispatchEvent(new Event('selectionchange'))
  })
  const toolbar = page.getByRole('toolbar', { name: '选区格式', exact: true })
  await toolbar.getByRole('button', { name: '问 Agent', exact: true }).click()
  await expect(page.getByLabel('Agent event', { exact: true })).toHaveText('{"from":1,"to":9,"quote":"Anchored"}')
  await expect(toolbar).toBeHidden()
  await expect(page.getByLabel('First Markdown', { exact: true })).toHaveText(before!)
})

test('a same-editor cut pasted over selected cells fills the first cell and empties the others', async ({ page }) => {
  const first = page.getByRole('textbox', { name: 'First document', exact: true })
  await caret(first.locator('p').last())
  await clipboard(first, 'paste', {
    'text/html':
      '<table><tr><th>h</th><th>i</th></tr><tr><td>c1</td><td>c2</td></tr><tr><td>d1</td><td>d2</td></tr></table>'
  })
  await caret(first.locator('[data-comment-ids]'), 0)
  await first.press('Escape')
  const cut = await clipboard(first, 'cut')
  await caret(first.getByText('c1', { exact: true }))
  await first.press('Escape')
  await first.press('Shift+ArrowRight')
  await expect(first.locator('.wg-selected-cell')).toHaveCount(2)
  await clipboard(first, 'paste', cut)
  await expect(first.locator('tr').nth(1).locator('td')).toHaveText(['Anchored text', ''])
  await expect(first.locator('td [data-comment-ids]')).toHaveText('Anchored text')
})
