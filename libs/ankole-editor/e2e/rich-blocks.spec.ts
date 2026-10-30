import {
  test,
  expect,
  openDocument,
  caret,
  reopen,
  showSource,
  selectDocument,
  clipboard,
  replaceDocument
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

test('external embed edits an iframe URL and renders the actual frame', async ({ page, baseURL }) => {
  await openDocument(page, '<embed href="" />')
  const resource = page.locator('.resource-block')
  await resource.getByLabel('链接地址', { exact: true }).fill(`${baseURL}/resource-preview.html`)
  await resource.getByLabel('标题', { exact: true }).fill('Preview frame')
  await resource.getByRole('button', { name: '保存', exact: true }).click()
  await expect(
    page.frameLocator('iframe[title="Preview frame"]').getByRole('heading', { name: 'Embedded resource' })
  ).toBeVisible()
  await reopen(page)
  await expect(
    page.frameLocator('iframe[title="Preview frame"]').getByRole('heading', { name: 'Embedded resource' })
  ).toBeVisible()
})

test('web card switches four views and keeps metadata when reopened', async ({ page, baseURL }) => {
  await openDocument(page, '<bookmark />')
  const card = page.locator('.resource-block')
  await card.getByLabel('链接地址', { exact: true }).fill(`${baseURL}/resource-preview.html`)
  await card.getByLabel('标题', { exact: true }).fill('Project website')
  await card.getByLabel('描述', { exact: true }).fill('Project description')
  await card.getByRole('button', { name: '保存', exact: true }).click()
  await expect(card).toHaveAttribute('data-view', 'card')
  await expect(card).toContainText('Project description')
  for (const [name, view] of [
    ['链接视图', 'link'],
    ['标题视图', 'title'],
    ['预览视图', 'preview'],
    ['卡片视图', 'card']
  ]) {
    await card.getByRole('button', { name: '视图', exact: true }).click()
    await page.getByRole('menuitem', { name: name!, exact: true }).click()
    await expect(card).toHaveAttribute('data-view', view!)
  }
  await reopen(page)
  await expect(card).toContainText('Project description')
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
  await picture.getByRole('button', { name: '视图', exact: true }).click()
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
  await resource.getByRole('button', { name: '编辑', exact: true }).click()
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
  const source = `<media src="${baseURL}/resource-image.png" title="Picture" view="card" custom="kept" />\n\n<media src="${baseURL}/resource-video.mp4" title="Movie" view="link" />\n\n<bookmark src="${baseURL}/resource-preview.html" title="Site" description="Details" />\n\n<embed href="${baseURL}/resource-preview.html" title="Frame" />`
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
