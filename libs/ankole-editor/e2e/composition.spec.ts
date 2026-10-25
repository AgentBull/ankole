import { caret, expect, openDocument, reopen, test } from './helpers'

test('Chromium IME commits composed text between emoji without changing its format', async ({ page, browserName }) => {
  test.skip(browserName !== 'chromium', 'Playwright exposes IME composition through Chromium CDP only.')
  await openDocument(page, '**😀😀**')
  await caret(page.locator('.editor-content strong'), 2)
  const client = await page.context().newCDPSession(page)
  await client.send('Input.imeSetComposition', { text: 'zhong', selectionStart: 5, selectionEnd: 5 })
  await client.send('Input.imeSetComposition', { text: '中文', selectionStart: 2, selectionEnd: 2 })
  await expect(page.getByRole('toolbar', { name: '选区格式' })).toHaveCount(0)
  await client.send('Input.insertText', { text: '中文' })
  await expect(page.locator('.editor-content strong')).toHaveText('😀中文😀')
  await page.keyboard.insertText('X')
  await expect(page.locator('.editor-content strong')).toHaveText('😀中文X😀')
  await reopen(page)
  await expect(page.locator('.editor-content strong')).toHaveText('😀中文X😀')
})

test('Chromium IME on an empty page writes the composed text in place of the hint', async ({ page, browserName }) => {
  test.skip(browserName !== 'chromium', 'Playwright exposes IME composition through Chromium CDP only.')
  await openDocument(page, '')
  const paragraph = page.locator('.editor-content > p')
  await expect(paragraph).toHaveAttribute('data-placeholder', '输入 / 添加 Block，或直接开始写作…')
  await expect(paragraph).toHaveText('')
  await paragraph.click()
  const client = await page.context().newCDPSession(page)
  await client.send('Input.imeSetComposition', { text: 'zhong', selectionStart: 5, selectionEnd: 5 })
  await client.send('Input.imeSetComposition', { text: '中文', selectionStart: 2, selectionEnd: 2 })
  await client.send('Input.insertText', { text: '中文' })
  await expect(paragraph).toHaveText('中文')
  await expect(paragraph).not.toHaveAttribute('data-placeholder')
  await page.keyboard.insertText('X')
  await expect(paragraph).toHaveText('中文X')
  await reopen(page)
  await expect(page.locator('.editor-content > p')).toHaveText('中文X')
})

test('updating a text tile before a native IME range preserves the committed candidate', async ({
  page,
  browserName
}) => {
  test.skip(browserName !== 'chromium', 'Chromium CDP supplies trusted composition events.')
  await page.goto('/')
  await page.evaluate(() => {
    const root = document.createElement('div')
    root.id = 'text-tile-ime'
    Object.assign(window, { textTileCompositionEvents: [] as string[] })
    for (const type of ['compositionstart', 'compositionupdate', 'compositionend']) {
      root.addEventListener(type, event =>
        (window as unknown as { textTileCompositionEvents: string[] }).textTileCompositionEvents.push(
          `${type}:${event.isTrusted}`
        )
      )
    }
    root.contentEditable = 'true'
    root.textContent = '旧术语😀：这里，末尾'
    document.body.append(root)
    root.focus()
    const node = root.firstChild as Text
    const offset = node.data.indexOf('，末尾')
    window.getSelection()!.setBaseAndExtent(node, offset, node, offset)
  })
  const client = await page.context().newCDPSession(page)
  try {
    await client.send('Input.imeSetComposition', { text: 'zhong', selectionStart: 5, selectionEnd: 5 })
    await client.send('Input.imeSetComposition', { text: '中文', selectionStart: 2, selectionEnd: 2 })
    await page.evaluate(async () => {
      const modulePath = '/src/core/editor/tile.ts'
      const { TextTile } = await import(modulePath)
      const node = document.querySelector('#text-tile-ime')!.firstChild as Text
      new TextTile(node.data.replace('旧术语', '接口术语'), node).sync()
    })
    expect(
      await page.evaluate(() =>
        (window as unknown as { textTileCompositionEvents: string[] }).textTileCompositionEvents.filter(value =>
          value.startsWith('compositionend')
        )
      )
    ).toEqual([])
    await client.send('Input.insertText', { text: '中文' })
    await page.keyboard.insertText('继续')
    await expect(page.locator('#text-tile-ime')).toHaveText('接口术语😀：这里中文继续，末尾')
  } finally {
    await client.detach()
  }
})

test('a same-paragraph API edit keeps native composition open and commits its candidate once', async ({
  page,
  browserName
}) => {
  test.skip(browserName !== 'chromium', 'Chromium CDP supplies trusted composition events.')
  await page.goto('/test/core/browser/index.html')
  await page.waitForFunction(() => window.coreTestResults)
  await page.evaluate(async () => {
    const fixturePath = '/test/core/browser/tempview.ts'
    const schemaPath = '/test/core/schema.ts'
    const { tempEditor } = await import(fixturePath)
    const {
      basicBuilders: { doc, p }
    } = await import(schemaPath)
    const editor = tempEditor(doc(p('旧术语😀：这里', 0, '，末尾')))
    const workspace = document.querySelector<HTMLElement>('#workspace')!
    workspace.style.opacity = '1'
    workspace.style.pointerEvents = 'auto'
    editor.focus()
    Object.assign(window, { remoteIMEEditor: editor, remoteIMEEnds: [] as string[] })
    editor.contentDOM.addEventListener('compositionend', (event: Event) => {
      ;(window as unknown as { remoteIMEEnds: string[] }).remoteIMEEnds.push(String(event.isTrusted))
    })
  })
  const client = await page.context().newCDPSession(page)
  try {
    await client.send('Input.imeSetComposition', { text: '中文', selectionStart: 2, selectionEnd: 2 })
    await page.evaluate(async () => {
      const docPath = '/src/core/doc/index.ts'
      const { Leaf } = await import(docPath)
      const editor = (window as unknown as { remoteIMEEditor: { dispatch(spec: unknown): void; flush(): void } })
        .remoteIMEEditor
      editor.dispatch({ changes: { from: 1, to: 4, insert: [Leaf.text('接口术语')] } })
      editor.flush()
    })
    expect(await page.evaluate(() => (window as unknown as { remoteIMEEnds: string[] }).remoteIMEEnds)).toEqual([])
    await client.send('Input.insertText', { text: '中文' })
    await page.keyboard.insertText('继续')
    await expect(page.locator('#workspace p')).toHaveText('接口术语😀：这里中文继续，末尾')
  } finally {
    await client.detach()
  }
})
