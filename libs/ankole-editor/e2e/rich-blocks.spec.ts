import {
  test,
  expect,
  openDocument,
  caret,
  reopen,
  showSource,
  selectDocument,
  clipboard,
  replaceDocument,
  expectMarkdown
} from './helpers'

test('slash aliases insert media and all six heading levels', async ({ page }) => {
  await openDocument(page, 'Start')
  const editor = page.locator('.editor-content')
  for (const query of ['图片', '媒体', 'media', 'picture', 'img']) {
    if (query === '图片') {
      await caret(editor.locator('p').last())
      await page.keyboard.press('Enter')
    }
    await page.keyboard.insertText(`/${query}`)
    await expect(page.getByRole('option', { name: '媒体', exact: true })).toBeVisible()
    await page.keyboard.press('Escape')
    await page.keyboard.press('ControlOrMeta+Backspace')
  }
  await page.keyboard.insertText('/h6')
  await page.getByRole('option', { name: '六级标题', exact: true }).click()
  await page.keyboard.insertText('Small heading')
  await expect(editor.locator('h6')).toContainText('Small heading')
  await reopen(page)
  await expect(editor.locator('h6')).toContainText('Small heading')
})

test('nested heading collapse hides only the section and preserves the saved document', async ({ page }) => {
  await openDocument(page, '# One\n\nBody\n\n## Nested\n\nNested body\n\n# Two\n\nTail')
  const editor = page.locator('.editor-content')
  await editor.locator('h2').getByRole('button', { name: '收起章节' }).click()
  await expect(editor.getByText('Nested body', { exact: true })).toBeHidden()
  await editor.locator('h1').first().getByRole('button', { name: '收起章节' }).click()
  await expect(editor.getByText('Body', { exact: true })).toBeHidden()
  await expect(editor.locator('h2')).toBeHidden()
  await expect(editor.getByText('Tail', { exact: true })).toBeVisible()
  await editor.locator('h1').first().getByRole('button', { name: '展开章节' }).click()
  await expect(editor.locator('h2')).toBeVisible()
  await expect(editor.getByText('Nested body', { exact: true })).toBeHidden()
  await reopen(page)
  await expect(editor.getByText('Nested body', { exact: true })).toBeVisible()
})

test('external embed edits an iframe URL, renders the actual frame, and persists height resizing', async ({
  page,
  baseURL
}) => {
  await openDocument(page, '<embed href="" />')
  const resource = page.locator('.resource-block')
  // Creation mode uses progressive 1-line URL bar without upfront metadata clutter.
  await expect(resource.getByLabel('标题', { exact: true })).toHaveCount(0)
  await resource.getByLabel('链接地址', { exact: true }).fill(`${baseURL}/resource-preview.html`)
  await resource.getByRole('button', { name: '保存', exact: true }).click()
  await expect(
    page.frameLocator('iframe[title="Embedded resource"]').getByRole('heading', { name: 'Embedded resource' })
  ).toBeVisible()

  // Resize handle supports keyboard adjustment and persists height across reopen and undo.
  const handle = resource.getByRole('separator', { name: '拖动或使用上下方向键调整高度', exact: true })
  await handle.focus()
  await page.keyboard.press('Shift+ArrowDown')
  await expect(handle).toHaveAttribute('aria-valuenow', '544')
  await expectMarkdown(page, `<embed height="544" href="${baseURL}/resource-preview.html" title="Embedded resource" />`)
  await reopen(page)
  await expect(resource.locator('iframe')).toHaveCSS('height', '544px')
})

test('webpage link and card switch seamlessly across link, title, card, and embed preview views', async ({
  page,
  baseURL
}) => {
  const targetUrl = `${baseURL}/resource-preview.html`
  await openDocument(page, '<embed href="" view="card" />')
  const card = page.locator('.resource-block')
  await card.getByLabel('链接地址', { exact: true }).fill(targetUrl)
  await card.getByRole('button', { name: '保存', exact: true }).click()
  await expect(card).toHaveAttribute('data-kind', 'embed')
  await expect(card).toHaveAttribute('data-view', 'card')

  await card.hover()
  const cardToolbar = page.getByRole('toolbar', { name: '网页卡片', exact: true })
  await cardToolbar.getByRole('button', { name: '编辑', exact: true }).click()
  await card.getByLabel('标题', { exact: true }).fill('Project website')
  await card.getByLabel('描述', { exact: true }).fill('Project description')
  await card.getByRole('button', { name: '保存', exact: true }).click()
  await expect(card).toContainText('Project description')

  // Card (`<embed href="..." view="card" />`) -> Link view (inline `<a>` with raw URL + floating link bar)
  await cardToolbar.getByRole('button', { name: '视图', exact: true }).click()
  await page.getByRole('menuitem', { name: '链接视图', exact: true }).click()
  const inlineLink = page.locator('.editor-content p a')
  await expect(inlineLink).toHaveText(targetUrl)
  const linkToolbar = page.getByRole('toolbar', { name: '链接', exact: true })
  await expect(linkToolbar).toBeVisible()
  await expect(linkToolbar.getByRole('button', { name: '视图', exact: true })).toContainText('链接视图')

  // Link view -> Title view (fetches HTML `<title>` "Embedded resource")
  await linkToolbar.getByRole('button', { name: '视图', exact: true }).click()
  await page.getByRole('menuitem', { name: '标题视图', exact: true }).click()
  await expect(inlineLink).toHaveText('Embedded resource')
  await expect(linkToolbar.getByRole('button', { name: '视图', exact: true })).toContainText('标题视图')

  // Title view -> Preview view (`<embed href="..." title="..." />` block)
  await linkToolbar.getByRole('button', { name: '视图', exact: true }).click()
  await page.getByRole('menuitem', { name: '预览视图', exact: true }).click()
  await expect(card).toHaveAttribute('data-kind', 'embed')
  await expect(card).toHaveAttribute('data-view', 'preview')
  await expect(card.locator('.resource-summary')).toHaveCount(0)
  // The switch leaves the caret after the block instead of selecting it, so the block toolbar follows the pointer.
  await expect(page.locator('.editor-selected-block')).toHaveCount(0)
  await card.hover()
  const embedToolbar = page.getByRole('toolbar', { name: '嵌入', exact: true })
  await expect(embedToolbar.getByRole('button', { name: '刷新预览', exact: true })).toBeVisible()
  await expect(
    page.frameLocator('iframe[title="Embedded resource"]').getByRole('heading', { name: 'Embedded resource' })
  ).toBeVisible()
  // The inline link was the whole document, so the switch adds an empty paragraph after the block for the caret.
  await expectMarkdown(page, `<embed href="${targetUrl}" title="Embedded resource" />\n\n<p />`)

  // Preview view -> Card view (mutates `view="card"` on the same `<embed>` node and unfurls description + cover image)
  await embedToolbar.getByRole('button', { name: '视图', exact: true }).click()
  await page.getByRole('menuitem', { name: '卡片视图', exact: true }).click()
  await expect(card).toHaveAttribute('data-kind', 'embed')
  await expect(card).toHaveAttribute('data-view', 'card')
  await expect(card).toContainText("This page runs inside the document's iframe.")
  await expect(card.locator('img.resource-cover')).toBeVisible()

  await reopen(page)
  await expect(card).toContainText("This page runs inside the document's iframe.")
})

test('rich-text URL paste auto-links at caret, selection toolbar switches link view, and changing embed URL clears stale metadata', async ({
  page,
  baseURL
}) => {
  const previewUrl = `${baseURL}/resource-preview.html`
  await openDocument(page, '')
  const editor = page.getByRole('textbox', { name: '文档编辑器', exact: true })
  await editor.click()

  // Pasting a bare URL copied from VS Code / chat apps (div + span syntax-highlight HTML wrapper) auto-links cleanly.
  await clipboard(editor, 'paste', {
    'text/plain': previewUrl,
    'text/html': `<meta charset="utf-8"><div style="color:#d4d4d4;background-color:#1e1e1e"><span style="color:#ce9178">${previewUrl}</span></div>`
  })
  const link = page.locator('.editor-content p a')
  await expect(link).toHaveAttribute('href', previewUrl)
  await expect(link).toHaveText(previewUrl)

  // Selecting the whole link exposes the view switcher directly inside SelectionToolbar.
  await page.keyboard.press('ControlOrMeta+a')
  const selectionToolbar = page.getByRole('toolbar', { name: '选区格式', exact: true })
  await expect(selectionToolbar).toBeVisible()
  await expect(selectionToolbar.getByRole('button', { name: '视图', exact: true })).toContainText('链接视图')
  await selectionToolbar.getByRole('button', { name: '视图', exact: true }).click()
  await page.getByRole('menuitem', { name: '卡片视图', exact: true }).click()

  const card = page.locator('.resource-block')
  await expect(card).toHaveAttribute('data-kind', 'embed')
  await expect(card).toHaveAttribute('data-view', 'card')
  await expect(card).toContainText('Embedded resource')
  await expect(card).toContainText("This page runs inside the document's iframe.")

  // Changing the URL on an existing card clears stale title/description/cover and normalizes bare domains.
  const cardToolbar = page.getByRole('toolbar', { name: '网页卡片', exact: true })
  await cardToolbar.getByRole('button', { name: '编辑', exact: true }).click()
  await card.getByLabel('链接地址', { exact: true }).fill('example.com/fresh-page')
  await card.getByRole('button', { name: '保存', exact: true }).click()
  await expect(card).toContainText('https://example.com/fresh-page')
  await expect(card).not.toContainText('Embedded resource')
  await expect(card).not.toContainText("This page runs inside the document's iframe.")
  await expectMarkdown(page, '<embed href="https://example.com/fresh-page" view="card" />\n\n<p />')
})

test('hovering an inline link shows the Feishu-style link bar and supports editing link text and unlinking', async ({
  page,
  baseURL
}) => {
  const targetUrl = `${baseURL}/resource-preview.html`
  await openDocument(page, `${targetUrl}\n\nSecond paragraph`)
  await caret(page.locator('.editor-content > p').nth(1), 'end')
  const linkToolbar = page.getByRole('toolbar', { name: '链接', exact: true })
  await expect(linkToolbar).toBeHidden()

  const link = page.locator('.editor-content > p').first().locator('a')
  await link.hover()
  await expect(linkToolbar).toBeVisible()
  await expect(linkToolbar.getByRole('button', { name: '打开链接', exact: true })).toHaveText(targetUrl)

  await linkToolbar.getByRole('button', { name: '编辑链接', exact: true }).click()
  const dialog = page.getByRole('dialog', { name: '编辑链接', exact: true })
  await dialog.getByRole('textbox', { name: '链接文本', exact: true }).fill('Custom Title')
  await dialog.getByRole('button', { name: '应用链接', exact: true }).click()
  await expect(link).toHaveText('Custom Title')

  await link.hover()
  await expect(linkToolbar.getByRole('button', { name: '视图', exact: true })).toContainText('标题视图')
  await linkToolbar.getByRole('button', { name: '移除链接', exact: true }).click()
  await expect(page.locator('.editor-content a')).toHaveCount(0)
  await expect(page.locator('.editor-content > p').first()).toHaveText('Custom Title')
})

test('media renders real images and playable videos and preserves view changes', async ({ page, baseURL }) => {
  await openDocument(
    page,
    `<media src="${baseURL}/resource-image.png" title="Picture" kind="image" />\n\n<media src="${baseURL}/resource-video.mp4" title="Movie" kind="video" />`
  )
  const picture = page.locator('.resource-block').first()
  await expect(picture.getByRole('img', { name: 'Picture' })).toBeVisible()
  await expect.poll(() => picture.locator('img').evaluate(image => (image as HTMLImageElement).naturalWidth)).toBe(160)
  const video = page.locator('video')
  await expect.poll(() => video.evaluate(element => (element as HTMLVideoElement).readyState)).toBeGreaterThanOrEqual(1)
  await video.evaluate(element => {
    const video = element as HTMLVideoElement
    video.muted = true
    return video.play()
  })
  await expect.poll(() => video.evaluate(element => (element as HTMLVideoElement).currentTime)).toBeGreaterThan(0)
  await picture.hover()
  await page
    .getByRole('toolbar', { name: '媒体', exact: true })
    .getByRole('button', { name: '视图', exact: true })
    .click()
  await page.getByRole('menuitem', { name: '链接视图', exact: true }).click()
  await expect(picture).toHaveAttribute('data-view', 'link')
  await expect(picture.locator('img')).toHaveCount(0)
  await reopen(page)
  await expect(picture).toHaveAttribute('data-view', 'link')
  await expect(page.locator('video')).toHaveAttribute('src', `${baseURL}/resource-video.mp4`)
})

test('invalid external addresses stay editable without creating an iframe', async ({ page }) => {
  await openDocument(page, '<embed href="" />')
  await page.getByLabel('链接地址', { exact: true }).fill('javascript:alert(1)')
  await page.getByRole('button', { name: '保存', exact: true }).click()
  await expect(page.getByRole('alert')).toBeVisible()
  await expect(page.locator('iframe')).toHaveCount(0)
  await expect(page.getByLabel('链接地址', { exact: true })).toHaveValue('javascript:alert(1)')
})

test('callout icon and color save with nested text; table row and column controls edit cells', async ({ page }) => {
  await openDocument(page, '<callout>Important</callout>\n\n| Name | Value |\n| - | - |\n| A | 1 |')
  await page.getByRole('button', { name: '高亮块样式' }).click()
  await page.getByRole('button', { name: '绿色', exact: true }).click()
  await page.getByRole('textbox', { name: '图标', exact: true }).fill('📌')
  await page.keyboard.press('Escape')
  await expect(page.locator('.callout')).toHaveAttribute('data-tone', 'success')
  await expect(page.locator('.callout-icon')).toHaveText('📌')
  await caret(page.locator('td').first())
  await page.getByRole('button', { name: '行', exact: true }).click()
  await page.getByRole('menuitem', { name: '在下方插入行', exact: true }).click()
  await expect(page.locator('.editor-content tr')).toHaveCount(3)
  await page.getByRole('button', { name: '列', exact: true }).click()
  await page.getByRole('menuitem', { name: '在右侧插入列', exact: true }).click()
  await expect(page.locator('.editor-content tr').first().locator('th')).toHaveCount(3)
  await reopen(page)
  const source = await showSource(page)
  expect(await source.inputValue()).toContain('tone="success"')
})

test('replacing an uploaded image address infers video and clears obsolete upload metadata', async ({
  page,
  baseURL
}) => {
  await openDocument(
    page,
    `<media src="${baseURL}/resource-image.png" mime="image/png" size="100" kind="image" title="Media" />`
  )
  const resource = page.locator('.resource-block')
  await resource.hover()
  await page
    .getByRole('toolbar', { name: '媒体', exact: true })
    .getByRole('button', { name: '编辑', exact: true })
    .click()
  await resource.getByLabel('链接地址', { exact: true }).fill(`${baseURL}/resource-video.mp4`)
  await resource.getByRole('button', { name: '保存', exact: true }).click()
  await expect(resource.locator('img')).toHaveCount(0)
  await expect
    .poll(() => resource.locator('video').evaluate(element => (element as HTMLVideoElement).readyState))
    .toBeGreaterThanOrEqual(1)
  const source = await showSource(page)
  expect(await source.inputValue()).not.toMatch(/mime=|size=|kind=/)
  await reopen(page)
  await expect(resource.locator('video')).toHaveAttribute('src', `${baseURL}/resource-video.mp4`)
})

test('resource copies provide portable images, links and plain text while internal paste retains metadata', async ({
  page,
  baseURL
}) => {
  const source = `<media src="${baseURL}/resource-image.png" title="Picture" view="card" custom="kept" />\n\n<media src="${baseURL}/resource-video.mp4" title="Movie" view="link" />\n\n<embed href="${baseURL}/resource-preview.html" view="card" title="Site" description="Details" />\n\n<embed href="${baseURL}/resource-preview.html" title="Frame" />`
  await openDocument(page, source)
  const original = await (await showSource(page)).inputValue()
  await page.getByRole('button', { name: '关闭 Markdown', exact: true }).click()
  const editor = page.getByRole('textbox', { name: '文档编辑器', exact: true })
  await selectDocument(page)
  const copied = await clipboard(editor, 'copy')
  expect(copied['text/plain']).toBe(
    `Picture (${baseURL}/resource-image.png)\nMovie (${baseURL}/resource-video.mp4)\nSite (${baseURL}/resource-preview.html)\nFrame (${baseURL}/resource-preview.html)`
  )
  const portable = await page.evaluate(html => {
    const doc = new DOMParser().parseFromString(html, 'text/html')
    return {
      images: Array.from(doc.querySelectorAll('img')).map(node => [node.getAttribute('src'), node.getAttribute('alt')]),
      links: Array.from(doc.querySelectorAll('a')).map(node => [node.getAttribute('href'), node.textContent])
    }
  }, copied['text/html']!)
  expect(portable.images).toEqual([[`${baseURL}/resource-image.png`, 'Picture']])
  expect(portable.links).toEqual([
    [`${baseURL}/resource-video.mp4`, 'Movie'],
    [`${baseURL}/resource-preview.html`, 'Site'],
    [`${baseURL}/resource-preview.html`, 'Frame']
  ])
  await replaceDocument(page, 'Replace')
  await selectDocument(page)
  await clipboard(editor, 'paste', copied)
  await expect(await showSource(page)).toHaveValue(original)
})

test('submitting an internal ankole:page address inside an embed URL bar converts it into an inline page mention', async ({
  page
}) => {
  const pageId = '019a2b00-0000-7000-8000-000000000001'
  await openDocument(page, '<embed href="" />')
  const embedBlock = page.locator('.resource-block')
  await embedBlock.getByLabel('链接地址', { exact: true }).fill(`ankole:page/${pageId}`)
  await embedBlock.getByRole('button', { name: '保存', exact: true }).click()
  await expect(embedBlock).toHaveCount(0)
  await expectMarkdown(page, `<p><mention page="${pageId}" /></p>`)
})

test('the callout icon field writes only the committed IME candidate', async ({ page, browserName }) => {
  test.skip(browserName !== 'chromium', 'Playwright exposes IME composition through Chromium CDP only.')
  await openDocument(page, '<callout icon="💡">Important</callout>')
  await page.getByRole('button', { name: '高亮块样式' }).click()
  const icon = page.getByRole('textbox', { name: '图标', exact: true })
  await icon.selectText()
  const client = await page.context().newCDPSession(page)
  try {
    await client.send('Input.imeSetComposition', { text: 'xing', selectionStart: 4, selectionEnd: 4 })
    await expect(icon).toHaveValue('xing')
    await expect(page.locator('.callout-icon')).toHaveText('💡')
    await icon.evaluate(input =>
      input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', isComposing: true, bubbles: true }))
    )
    await expect(icon).toBeVisible()
    await client.send('Input.insertText', { text: '星' })
    await expect(page.locator('.callout-icon')).toHaveText('星')
  } finally {
    await client.detach()
  }
  await page.keyboard.press('Escape')
  await expect(icon).toBeHidden()
  await expectMarkdown(page, '<callout icon="星">\n  Important\n</callout>')
})

test('resource blocks complete a keyboard-first insert, IME guard, card selection, Shift+Enter, Space, and Escape loop', async ({
  page,
  baseURL
}) => {
  await openDocument(page, '')
  const editor = page.getByRole('textbox', { name: '文档编辑器', exact: true })
  await editor.click()
  await page.keyboard.type('/embed')
  await page.getByRole('option', { name: /嵌入/ }).first().click()

  const resource = page.locator('.resource-block')
  const address = resource.getByLabel('链接地址', { exact: true })
  await expect(address).toBeFocused()

  for (const key of ['Enter', 'Escape']) {
    await address.evaluate((input, pressed) => {
      input.dispatchEvent(
        new KeyboardEvent('keydown', { key: pressed, keyCode: 229, isComposing: true, bubbles: true, cancelable: true })
      )
    }, key)
    await expect(address).toBeFocused()
    await expect(resource.getByRole('alert')).toHaveCount(0)
  }

  await address.fill(`${baseURL}/resource-preview.html`)
  await address.press('Enter')
  await expect(resource.locator('form.resource-form')).toHaveCount(0)
  await expect(editor).toBeFocused()

  // Undoing the initial URL save reopens the compact URL creation bar rather than stranding an empty block; redo restores it.
  await page.keyboard.press('ControlOrMeta+z')
  await expect(resource.locator('form.resource-form-compact')).toBeVisible()
  await page.getByRole('button', { name: '重做', exact: true }).click()
  await expect(resource.locator('form.resource-form')).toHaveCount(0)
  await editor.focus()

  await page.keyboard.insertText('After embed')
  await expectMarkdown(
    page,
    `<embed href="${baseURL}/resource-preview.html" title="Embedded resource" />\n\nAfter embed`
  )

  await resource.locator('.resource-resize-handle').click()
  await expect(page.locator('.editor-selected-block')).toHaveCount(1)
  await expect(editor).toBeFocused()

  await page.keyboard.press('Shift+Enter')
  await page.keyboard.insertText('Before embed')
  await expectMarkdown(
    page,
    `Before embed\n\n<embed href="${baseURL}/resource-preview.html" title="Embedded resource" />\n\nAfter embed`
  )

  await resource.locator('.resource-resize-handle').click()
  await expect(page.locator('.editor-selected-block')).toHaveCount(1)
  await page.keyboard.press('Space')
  await expect(address).toBeFocused()
  await address.fill('https://discarded.example.com')
  await address.press('Escape')
  await expect(resource.locator('form.resource-form')).toHaveCount(0)
  await expect(resource.locator('iframe')).toHaveAttribute('src', `${baseURL}/resource-preview.html`)
  await expect(page.locator('.editor-selected-block')).toHaveCount(1)
  await expect(editor).toBeFocused()

  await page.keyboard.press('ControlOrMeta+Enter')
  await expect(address).toBeFocused()
  await expect(address).toHaveValue(`${baseURL}/resource-preview.html`)
  await resource.getByLabel('标题', { exact: true }).fill('Preview frame')
  await address.press('Enter')
  await expect(page.locator('.editor-selected-block')).toHaveCount(1)
  await expect(editor).toBeFocused()
  await expectMarkdown(
    page,
    `Before embed\n\n<embed href="${baseURL}/resource-preview.html" title="Preview frame" />\n\nAfter embed`
  )
})
