import { caret, expect, expectMarkdown, openDocument, reopen, test } from './helpers'

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
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'Only the development server serves source modules'
  )
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
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'Only the development server serves source modules'
  )
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

for (const [label, trigger, selector, expected] of [
  ['bullet', '- ', 'ul > li', '- 你好世界\n- 下一项'],
  ['numbered', '1. ', 'ol > li', '1. 你好世界\n2. 下一项'],
  ['task', '[] ', 'ul > li[data-task="todo"]', '- [ ] 你好世界\n- [ ] 下一项']
] as const) {
  test(`Chromium IME composes, clears Pinyin, and commits Chinese inside an empty ${label} list item`, async ({
    page,
    browserName
  }) => {
    test.skip(browserName !== 'chromium', 'Playwright exposes IME composition through Chromium CDP only.')
    await openDocument(page, '')
    await page.locator('.editor-content > p').click()
    await page.keyboard.type(trigger)
    const items = page.locator(`.editor-content > ${selector}`)
    await expect(items).toHaveCount(1)

    const client = await page.context().newCDPSession(page)
    try {
      // Start Pinyin composition in the empty list item, backspace Pinyin to empty, then re-compose and commit.
      await client.send('Input.imeSetComposition', { text: 'n', selectionStart: 1, selectionEnd: 1 })
      await expect(items).toHaveCount(1)
      await client.send('Input.imeSetComposition', { text: '', selectionStart: 0, selectionEnd: 0 })
      await expect(items).toHaveCount(1)
      await client.send('Input.imeSetComposition', { text: 'nihao', selectionStart: 5, selectionEnd: 5 })
      await client.send('Input.insertText', { text: '你好' })
      await client.send('Input.imeSetComposition', { text: 'shijie', selectionStart: 6, selectionEnd: 6 })
      await client.send('Input.insertText', { text: '世界' })
      await expect(items.nth(0)).toHaveText('你好世界')

      // Splitting into a second empty item also accepts Chinese IME composition.
      await page.keyboard.press('Enter')
      await expect(items).toHaveCount(2)
      await client.send('Input.imeSetComposition', { text: 'xiayixiang', selectionStart: 10, selectionEnd: 10 })
      await client.send('Input.insertText', { text: '下一项' })
      await expect(items.nth(1)).toHaveText('下一项')
      await expectMarkdown(page, expected)
      await reopen(page)
      await expect(page.locator(`.editor-content > ${selector}`)).toHaveText(['你好世界', '下一项'])
    } finally {
      await client.detach()
    }
  })
}

test('canceling an IME composition in an empty list item leaves an empty item and supports subsequent items', async ({
  page,
  browserName
}) => {
  test.skip(browserName !== 'chromium', 'Playwright exposes IME composition through Chromium CDP only.')
  await openDocument(page, '- 第一项\n-')
  const items = page.locator('.editor-content > ul > li')
  await expect(items).toHaveCount(2)
  await items.nth(1).click()
  // Let the editor read the click selection before the IME starts.
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))

  const client = await page.context().newCDPSession(page)
  try {
    await client.send('Input.imeSetComposition', { text: 'ni', selectionStart: 2, selectionEnd: 2 })
    // Empty and end the composition without committing text.
    await client.send('Input.insertText', { text: '' })
    await expectMarkdown(page, '- 第一项\n-')

    // Composing again in the same empty item commits cleanly and undoes in one step.
    await items.nth(1).click()
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
    await client.send('Input.imeSetComposition', { text: 'di er', selectionStart: 5, selectionEnd: 5 })
    await client.send('Input.insertText', { text: '第二项' })
    await expectMarkdown(page, '- 第一项\n- 第二项')
    await items.nth(1).click()
    await page.keyboard.press('ControlOrMeta+z')
    await expectMarkdown(page, '- 第一项\n-')
    await reopen(page)
  } finally {
    await client.detach()
  }
})

test('Escape then ArrowDown from a trailing code block accepts Chinese IME composition in the new paragraph', async ({
  page,
  browserName
}) => {
  test.skip(browserName !== 'chromium', 'Playwright exposes IME composition through Chromium CDP only.')
  await openDocument(page, '```ts\nconst count = 1\n```')
  await caret(page.locator('.editor-code-pre'), 'end')
  await page.keyboard.press('Escape')
  await page.keyboard.press('ArrowDown')
  await expect(page.locator('.editor-selected-block')).toHaveCount(1)
  // A person starts composing after the new paragraph is drawn.
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))

  const client = await page.context().newCDPSession(page)
  try {
    await client.send('Input.imeSetComposition', { text: 'ni hao', selectionStart: 6, selectionEnd: 6 })
    await client.send('Input.insertText', { text: '你好世界' })
    await expectMarkdown(page, '```ts\nconst count = 1\n```\n\n你好世界')
    await reopen(page)
  } finally {
    await client.detach()
  }
})

test('Chromium IME on a selected non-empty paragraph replaces the paragraph with the composed text', async ({
  page,
  browserName
}) => {
  test.skip(browserName !== 'chromium', 'Playwright exposes IME composition through Chromium CDP only.')
  await openDocument(page, '前一\n\n后二')
  await caret(page.locator('.editor-content p').first(), 1)
  await page.keyboard.press('Escape')
  await expect(page.locator('.editor-selected-block')).toHaveCount(1)
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))

  const client = await page.context().newCDPSession(page)
  try {
    // Browsers send keydown 229 before an IME composition starts; CDP composition does not.
    // Shift switches Microsoft Pinyin between Chinese and English with keydown 229 and no composition.
    await client.send('Input.dispatchKeyEvent', {
      type: 'rawKeyDown',
      windowsVirtualKeyCode: 229,
      key: 'Process',
      code: 'ShiftLeft'
    })
    await expect(page.locator('.editor-content p')).toHaveText(['前一', '后二'])
    await expect(page.locator('.editor-selected-block')).toHaveCount(1)
    await client.send('Input.dispatchKeyEvent', {
      type: 'rawKeyDown',
      windowsVirtualKeyCode: 229,
      key: 'Process',
      code: 'KeyZ'
    })
    for (const text of ['z', 'zh', 'zhong']) {
      await client.send('Input.imeSetComposition', { text, selectionStart: text.length, selectionEnd: text.length })
    }
    await client.send('Input.insertText', { text: '中' })
    await expectMarkdown(page, '中\n\n后二')
    await reopen(page)
  } finally {
    await client.detach()
  }
})
