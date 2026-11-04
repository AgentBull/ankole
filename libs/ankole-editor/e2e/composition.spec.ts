import { caret, expect, expectMarkdown, openDocument, reopen, selectText, test } from './helpers'
import type { Page } from '@playwright/test'
import type { Wordgard } from '../src/core/editor'

type IMEPeerWindow = Window & {
  imePeer: {
    snapshot(): {
      revision: number
      pending: boolean
      confirmed: string
      composing: boolean
      connectedTarget: boolean
      sameTarget: boolean
      starts: boolean[]
      ends: boolean[]
      keydowns: number
      errors: string[]
      drafts: (string | null)[]
      requests: number
      canonical: boolean
      stored: string
    }
    remote(removeHost?: boolean, draw?: boolean): void
    finishCore(cancel: boolean, remoteBeforeEnd?: boolean): void
    releaseReply(): void
    dispose(): void
  }
}

/** Component transport uses the embedding fixture's acknowledgement contract, not a Pod server. */
async function attachIMEPeer(page: Page, holdFirstReply = false) {
  await page.evaluate(async holdFirstReply => {
    const collaborationPath = '/src/editor/page-collaboration.ts'
    const documentPath = '/src/core/doc/index.ts'
    const typesPath = '/src/core/types/index.ts'
    const commandPath = '/src/core/command/index.ts'
    const updatePath = '/src/editor/page-update.ts'
    const { PageCollaboration }: typeof import('../src/editor/page-collaboration') = await import(collaborationPath)
    const { ChangeSet, Leaf }: typeof import('../src/core/doc') = await import(documentPath)
    const { Command, insertText }: typeof import('../src/core/command') = await import(commandPath)
    const { preparePageUpdate, validatedPageSource }: typeof import('../src/editor/page-update') = await import(
      updatePath
    )
    const { Paragraph }: typeof import('../src/core/types') = await import(typesPath)
    const editor = (
      document.querySelector('.editor-content')!.closest('wordgard-editor') as HTMLElement & { wg: Wordgard }
    ).wg
    const initial = editor.state
    let storedDocument = initial.doc
    const log: import('../src/editor/page-collaboration').PageChange[] = []
    let requests = 0
    const release = Promise.withResolvers<void>()
    const starts: boolean[] = [],
      ends: boolean[] = [],
      errors: string[] = [],
      drafts: (string | null)[] = []
    let keydowns = 0,
      pending = false,
      confirmed = '',
      target: Text | null = null
    editor.contentDOM.addEventListener('compositionstart', event => starts.push(event.isTrusted))
    editor.contentDOM.addEventListener('compositionend', event => ends.push(event.isTrusted))
    editor.contentDOM.addEventListener('keydown', event => {
      if (event.keyCode === 229) keydowns++
    })
    const collaboration = new PageCollaboration(editor, 0, {
      clientID: 'ime-component',
      async send(request) {
        storedDocument = ChangeSet.fromJSON(storedDocument.schema, request.changes).apply(storedDocument)
        log.push({ ...request, revision: log.length + 1, kind: 'change' })
        requests++
        if (holdFirstReply && requests === 1) await release.promise
        return { revision: log.length, changes: log.slice(request.base_revision) }
      },
      changed(state) {
        pending = state.pending
        confirmed = state.xml
        if (state.error) errors.push(String(state.error))
      },
      reset(draft) {
        drafts.push(draft)
      },
      sync() {
        errors.push('Unexpected replay request')
      }
    })
    Object.assign(window, {
      imePeer: {
        snapshot: () => ({
          revision: collaboration.currentRevision(),
          pending,
          confirmed,
          composing: editor.composing,
          connectedTarget: !!editor.inputState.composing?.target?.isConnected,
          sameTarget: !!target && editor.inputState.composing?.target === target,
          starts: [...starts],
          ends: [...ends],
          keydowns,
          errors: [...errors],
          drafts: [...drafts],
          requests,
          canonical: !preparePageUpdate(editor.state.update({})).docChanged,
          stored: validatedPageSource(storedDocument).xml
        }),
        remote(removeHost = false, draw = true) {
          target = editor.inputState.composing?.target ?? null
          let after = -1
          storedDocument.iterate((node, pos) => {
            if (node.isPlot && node.inlineContent && node.textContent() === 'After') after = pos + 1
          })
          if (after < 0) throw new Error('Missing remote paragraph')
          const row = storedDocument.resolveNode(0)!
          const changes = ChangeSet.create(
            storedDocument,
            removeHost
              ? { from: row.before, to: row.after, insert: [Paragraph.create([Leaf.text('Remote replacement')])] }
              : { from: after, insert: [Leaf.text('Remote ')] }
          )
          storedDocument = changes.apply(storedDocument)
          log.push({
            revision: log.length + 1,
            kind: 'change',
            client_id: 'peer',
            client_seq: 1,
            changes: changes.toJSON()
          })
          collaboration.receive({ revision: log.length, changes: [...log] })
          if (draw) editor.flush()
        },
        finishCore(cancel: boolean, remoteBeforeEnd = false) {
          // Exercise the core completion boundary without dispatching a DOM compositionend event.
          const host = editor.state.sel.head.parent
          if (!editor.composing) throw new Error('Expected an active composition')
          Command.dispatch(editor, insertText, {
            from: host.start,
            to: host.end,
            insert: cancel ? '' : '中',
            userEvent: 'input.type.compose'
          })
          if (remoteBeforeEnd) (window as unknown as IMEPeerWindow).imePeer.remote()
          editor.flush()
          if (editor.composing) editor.inputState.clearComposition()
          editor.flush()
        },
        releaseReply() {
          release.resolve()
        },
        dispose() {
          release.resolve()
          collaboration.dispose()
        }
      }
    })
  }, holdFirstReply)
}

const imeSnapshot = (page: Page) => page.evaluate(() => (window as unknown as IMEPeerWindow).imePeer.snapshot())

for (const nested of [false, true]) {
  for (const cancel of [false, true]) {
    test(`a remote text edit preserves ${nested ? 'nested' : 'flat'} column composition through ${cancel ? 'cancel' : 'commit'}`, async ({
      page,
      browserName
    }) => {
      test.skip(
        !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
        'The component loads the production collaboration source module.'
      )
      test.skip(
        browserName !== 'chromium',
        'Chromium CDP supplies trusted composition events; Pod HTTP/WS is covered separately.'
      )
      const source = nested
        ? '<columns>\n<column>\n<columns>\n<column>\nA\n</column>\n<column>\nB\n\nKeep\n</column>\n</columns>\n</column>\n<column>\nC\n</column>\n</columns>\n\nAfter'
        : '<columns>\n<column>\nA\n\nKeep\n</column>\n<column>\nB\n</column>\n</columns>\n\nAfter'
      await openDocument(page, source)
      await attachIMEPeer(page)
      const editor = page.locator('.editor-content')
      const left = (await editor.locator('p').filter({ hasText: /^A$/ }).boundingBox())!
      const right = (await editor
        .locator('p')
        .filter({ hasText: nested ? /^C$/ : /^B$/ })
        .boundingBox())!
      await page.mouse.move(left.x - 65, left.y + 2)
      await page.mouse.down()
      await page.mouse.move(right.x + 80, right.y + right.height - 2, { steps: 16 })
      await page.mouse.up()
      await expect(page.locator('.editor-selected-block')).toHaveText(nested ? ['A', 'B', 'C'] : ['A', 'B'])
      const client = await page.context().newCDPSession(page)
      try {
        await client.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 })
        await expect.poll(async () => (await imeSnapshot(page)).connectedTarget).toBe(true)
        await expect(editor.locator('.editor-columns')).toHaveCount(nested ? 2 : 1)
        await page.evaluate(() => (window as unknown as IMEPeerWindow).imePeer.remote())
        await expect(editor.locator('p').last()).toHaveText('Remote After')
        expect(await imeSnapshot(page)).toMatchObject({
          revision: 1,
          pending: true,
          composing: true,
          sameTarget: true,
          starts: [true],
          ends: [],
          keydowns: 0,
          errors: [],
          drafts: []
        })
        await expect(editor.locator('.editor-columns')).toHaveCount(nested ? 2 : 1)
        await client.send('Input.imeSetComposition', { text: 'zhong', selectionStart: 5, selectionEnd: 5 })
        if (cancel) await client.send('Input.imeSetComposition', { text: '', selectionStart: 0, selectionEnd: 0 })
        else await client.send('Input.insertText', { text: '中' })
        const checkResult = async () => {
          await expect(editor.locator('p')).toHaveText([cancel ? '' : '中', 'Keep', 'Remote After'])
          await expect(editor.locator('.editor-columns')).toHaveCount(nested ? 1 : 0)
          await expect(editor).not.toContainText('zh')
        }
        await checkResult()
        await expect.poll(async () => (await imeSnapshot(page)).pending).toBe(false)
        const completed = await imeSnapshot(page)
        expect(completed).toMatchObject({
          revision: 2,
          composing: false,
          errors: [],
          drafts: []
        })
        // Chromium CDP also marks compositionend untrusted on a plain contenteditable.
        expect(completed.ends).toHaveLength(1)
        const saved = (await imeSnapshot(page)).confirmed
        await editor.focus()
        await page.keyboard.press('ControlOrMeta+z')
        await expect(editor.locator('p')).toHaveText(
          nested ? ['A', 'B', 'Keep', 'C', 'Remote After'] : ['A', 'Keep', 'B', 'Remote After']
        )
        await expect(editor.locator('.editor-columns')).toHaveCount(nested ? 2 : 1)
        await page.keyboard.press('ControlOrMeta+Shift+z')
        await checkResult()
        await expect.poll(async () => (await imeSnapshot(page)).pending).toBe(false)
        expect((await imeSnapshot(page)).confirmed).toBe(saved)
        await page.evaluate(() => (window as unknown as IMEPeerWindow).imePeer.dispose())
        await reopen(page)
        await checkResult()
        await page.reload()
        await checkResult()
      } finally {
        await client.detach()
        await page.evaluate(() => (window as unknown as Partial<IMEPeerWindow>).imePeer?.dispose())
      }
    })
  }
}

for (const cancel of [false, true]) {
  test(`a delayed reply preserves one undo step after core composition ${cancel ? 'cancel' : 'commit'}`, async ({
    page,
    browserName
  }) => {
    test.skip(
      !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
      'The component loads the production collaboration source module.'
    )
    test.skip(browserName !== 'chromium', 'Chromium CDP starts composition; core completion is not an OS IME claim.')
    await openDocument(
      page,
      'Before\n\n<columns>\n<column>\nA\n\nKeep\n</column>\n<column>\nB\n</column>\n</columns>\n\nAfter'
    )
    await attachIMEPeer(page, true)
    const editor = page.locator('.editor-content')
    await caret(editor.locator('p').first(), 0)
    await page.keyboard.insertText('Local ')
    await expect.poll(async () => (await imeSnapshot(page)).requests).toBe(1)
    const left = (await editor.locator('p').filter({ hasText: /^A$/ }).boundingBox())!
    const right = (await editor.locator('p').filter({ hasText: /^B$/ }).boundingBox())!
    await page.mouse.move(left.x - 65, left.y + 2)
    await page.mouse.down()
    await page.mouse.move(right.x + 80, right.y + right.height - 2, { steps: 16 })
    await page.mouse.up()
    await expect(page.locator('.editor-selected-block')).toHaveText(['A', 'B'])
    const client = await page.context().newCDPSession(page)
    try {
      await client.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 })
      await expect.poll(async () => (await imeSnapshot(page)).connectedTarget).toBe(true)
      await page.evaluate(() => (window as unknown as IMEPeerWindow).imePeer.remote())
      await expect(editor.locator('p').last()).toHaveText('Remote After')
      expect(await imeSnapshot(page)).toMatchObject({
        revision: 2,
        requests: 1,
        composing: true,
        sameTarget: true,
        ends: []
      })
      await page.evaluate(cancel => (window as unknown as IMEPeerWindow).imePeer.finishCore(cancel), cancel)
      expect(await imeSnapshot(page)).toMatchObject({
        composing: false,
        requests: 1,
        ends: [],
        canonical: true,
        errors: [],
        drafts: []
      })
      await expect(editor.locator('.editor-columns')).toHaveCount(0)
      const checkResult = async (extra = '') => {
        await expect(editor.locator('p')).toHaveText([
          'Local Before',
          (cancel ? '' : '中') + extra,
          'Keep',
          'Remote After'
        ])
        await expect(editor.locator('.editor-columns')).toHaveCount(0)
        await expect(editor).not.toContainText('zh')
      }
      if (cancel) await editor.locator('p').nth(1).click()
      else await caret(editor.locator('p').nth(1))
      // The old reply still occupies the transport slot beyond the existing 500ms history group window.
      await page.waitForTimeout(600)
      await page.keyboard.insertText('X')
      await checkResult('X')
      await page.keyboard.press('ControlOrMeta+z')
      await checkResult()
      expect(await imeSnapshot(page)).toMatchObject({ requests: 1, ends: [], pending: true })
      await page.evaluate(() => (window as unknown as IMEPeerWindow).imePeer.releaseReply())
      await expect.poll(async () => (await imeSnapshot(page)).pending).toBe(false)
      const saved = (await imeSnapshot(page)).confirmed
      expect(await imeSnapshot(page)).toMatchObject({ canonical: true, stored: saved, errors: [], drafts: [] })
      await editor.focus()
      await page.keyboard.press('ControlOrMeta+z')
      await expect(editor.locator('p')).toHaveText(['Local Before', 'A', 'Keep', 'B', 'Remote After'])
      await expect(editor.locator('.editor-columns')).toHaveCount(1)
      await page.keyboard.press('ControlOrMeta+Shift+z')
      await checkResult()
      await expect.poll(async () => (await imeSnapshot(page)).pending).toBe(false)
      expect(await imeSnapshot(page)).toMatchObject({
        canonical: true,
        confirmed: saved,
        stored: saved,
        errors: [],
        drafts: []
      })
      await page.evaluate(() => (window as unknown as IMEPeerWindow).imePeer.dispose())
      await reopen(page)
      await checkResult()
      await page.reload()
      await checkResult()
    } finally {
      await client.detach()
      await page.evaluate(() => (window as unknown as Partial<IMEPeerWindow>).imePeer?.dispose())
    }
  })
}

test('normalizing a core composition preserves a later empty composition and its undo history', async ({
  page,
  browserName
}) => {
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'The component loads the production collaboration source module.'
  )
  test.skip(
    browserName !== 'chromium',
    'Chromium CDP starts composition; core completion and the empty DOM lifecycle are component checks.'
  )
  await openDocument(page, '**base**\n\n- <p />')
  await attachIMEPeer(page)
  const editor = page.locator('.editor-content')
  await selectText(page, 'base', 0, 'base', 4)
  const client = await page.context().newCDPSession(page)
  try {
    await client.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 })
    await expect.poll(async () => (await imeSnapshot(page)).connectedTarget).toBe(true)
    const neededCorrection = await page.evaluate(async () => {
      const docPath = '/src/core/doc/index.ts'
      const typesPath = '/src/core/types/index.ts'
      const updatePath = '/src/editor/page-update.ts'
      const { Leaf }: typeof import('../src/core/doc') = await import(docPath)
      const { Strong }: typeof import('../src/core/types') = await import(typesPath)
      const { preparePageUpdate }: typeof import('../src/editor/page-update') = await import(updatePath)
      const view = (
        document.querySelector('.editor-content')!.closest('wordgard-editor') as HTMLElement & { wg: Wordgard }
      ).wg
      const host = view.state.sel.head.parent
      // Submit marked preedit through the editor API before the core completion normalizes its trailing space.
      view.dispatch({
        changes: { from: host.start, to: host.end, insert: [Leaf.text('中 ', [Strong])] },
        selection: { anchor: host.start + 2 },
        userEvent: 'input.type.compose'
      })
      const neededCorrection = preparePageUpdate(view.state.update({})).docChanged
      view.flush()
      if (view.composing) view.inputState.clearComposition()
      view.flush()
      return neededCorrection
    })
    expect(neededCorrection).toBe(true)
    await expect.poll(async () => (await imeSnapshot(page)).pending).toBe(false)
    await expect(editor.locator('strong')).toHaveText('中')
    await expect(editor.locator('li > p')).toHaveCount(1)
    const saved = (await imeSnapshot(page)).confirmed
    expect(await imeSnapshot(page)).toMatchObject({ canonical: true, composing: false, errors: [], drafts: [] })

    await editor.locator('li > p').click()
    await page.evaluate(() => {
      const content = document.querySelector('.editor-content')!
      // CDP cannot start a zero-input composition, so exercise the DOM lifecycle without changing text.
      content.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true, data: '' }))
      content.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '' }))
    })
    await expect(editor.locator('li > p')).toHaveCount(1)
    await expect.poll(async () => (await imeSnapshot(page)).pending).toBe(false)
    expect((await imeSnapshot(page)).confirmed).toBe(saved)
    await page.keyboard.press('ControlOrMeta+z')
    await expect(editor.locator('strong')).toHaveText('base')
    await expect(editor.locator('li > p')).toHaveCount(1)
    await page.keyboard.press('ControlOrMeta+Shift+z')
    await expect(editor.locator('strong')).toHaveText('中')
    await expect(editor.locator('li > p')).toHaveCount(1)
    await expect.poll(async () => (await imeSnapshot(page)).pending).toBe(false)
    expect((await imeSnapshot(page)).confirmed).toBe(saved)
    await page.evaluate(() => (window as unknown as IMEPeerWindow).imePeer.dispose())
    await expectMarkdown(page, '**中**&#x20;\n\n- <p />')
    await reopen(page)
    await expect(editor.locator('li > p')).toHaveCount(1)
  } finally {
    await client.detach()
    await page.evaluate(() => (window as unknown as Partial<IMEPeerWindow>).imePeer?.dispose())
  }
})

test('a remote edit before core cancellation cleans an empty list and preserves later composition history', async ({
  page,
  browserName
}) => {
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'The component loads the production collaboration source module.'
  )
  test.skip(browserName !== 'chromium', 'Chromium CDP starts composition; core completion is not an OS IME claim.')
  await openDocument(page, '- first\n-\n\nAfter')
  await attachIMEPeer(page)
  const editor = page.locator('.editor-content')
  const emptyItem = editor.locator('li').nth(1)
  await emptyItem.click()
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  const client = await page.context().newCDPSession(page)
  try {
    await client.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 })
    await expect.poll(async () => (await imeSnapshot(page)).connectedTarget).toBe(true)
    await page.evaluate(() => (window as unknown as IMEPeerWindow).imePeer.finishCore(true, true))
    await expect(editor.locator('p').last()).toHaveText('Remote After')
    await expect(emptyItem.locator('p')).toHaveCount(0)
    await expect.poll(async () => (await imeSnapshot(page)).pending).toBe(false)
    expect(await imeSnapshot(page)).toMatchObject({ composing: false, canonical: true, errors: [], drafts: [] })
    await expectMarkdown(page, '- first\n-\n\nRemote After')

    await emptyItem.click()
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
    await client.send('Input.imeSetComposition', { text: 'zhong', selectionStart: 5, selectionEnd: 5 })
    await client.send('Input.insertText', { text: '中' })
    await expect(emptyItem).toHaveText('中')
    await page.keyboard.press('ControlOrMeta+z')
    await expect(emptyItem).toHaveText('')
    await expect(emptyItem.locator('p')).toHaveCount(0)
    await page.keyboard.press('ControlOrMeta+Shift+z')
    await expect(emptyItem).toHaveText('中')
    await expect.poll(async () => (await imeSnapshot(page)).pending).toBe(false)
    await page.evaluate(() => (window as unknown as IMEPeerWindow).imePeer.dispose())
    await expectMarkdown(page, '- first\n- 中\n\nRemote After')
    await reopen(page)
    await expect(editor.locator('li')).toHaveText(['first', '中'])
  } finally {
    await client.detach()
    await page.evaluate(() => (window as unknown as Partial<IMEPeerWindow>).imePeer?.dispose())
  }
})

test('a real composing column deletion retains its draft through the collaboration reset', async ({
  page,
  browserName
}) => {
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'The component loads the production collaboration source module.'
  )
  test.skip(
    browserName !== 'chromium',
    'Chromium CDP supplies trusted composition events; Pod HTTP/WS is covered separately.'
  )
  await openDocument(page, '<columns>\n<column>\nA\n\nKeep\n</column>\n<column>\nB\n</column>\n</columns>\n\nAfter')
  await attachIMEPeer(page)
  const editor = page.locator('.editor-content')
  await caret(editor.locator('p').first(), 1)
  await page.keyboard.press('Escape')
  const client = await page.context().newCDPSession(page)
  try {
    await client.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 })
    await expect.poll(async () => (await imeSnapshot(page)).connectedTarget).toBe(true)
    await page.evaluate(() => (window as unknown as IMEPeerWindow).imePeer.remote(true))
    const state = await imeSnapshot(page)
    expect(state.drafts).toHaveLength(1)
    expect(state.drafts[0]).toContain('zh')
    expect(state.drafts[0]).toContain('Keep')
    expect(state.errors).toEqual([])
  } finally {
    await client.detach()
    await page.evaluate(() => (window as unknown as IMEPeerWindow).imePeer.dispose())
  }
})

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
  await openDocument(page, '')
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

test('moving a composing caret through page whitespace preserves an untouched source list paragraph', async ({
  page,
  browserName
}) => {
  test.skip(browserName !== 'chromium', 'Chromium CDP drives this component check without an OS IME.')
  await openDocument(page, 'base\n\n- <p />')
  const editor = page.locator('.editor-content')
  const body = editor.locator(':scope > p')
  const sourceParagraph = editor.locator(':scope > ul > li > p')
  const caretState = () =>
    editor.evaluate(element => {
      const view = (element.closest('wordgard-editor') as HTMLElement & { wg: Wordgard }).wg
      const paragraph = view.state.sel.head.parent
      return {
        composing: view.composing,
        inSourceParagraph:
          view.state.selection.isCursor &&
          paragraph.node.name === 'Paragraph' &&
          !paragraph.node.content.length &&
          paragraph.parent?.node.name === 'ListItem'
      }
    })
  await caret(body, 'end')
  const client = await page.context().newCDPSession(page)
  try {
    await client.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 })
    await expect(body).toHaveText('basezh')
    await expect.poll(async () => (await caretState()).composing).toBe(true)
    const bounds = (await editor.boundingBox())!
    const empty = (await sourceParagraph.boundingBox())!
    // The page's whitespace gesture moves the caret and lets the core end composition.
    await page.mouse.click(bounds.x - 8, empty.y + empty.height / 2)
    await expect(sourceParagraph).toHaveCount(1)
    await expect(sourceParagraph).toHaveText('')
    await expect.poll(caretState).toEqual({ composing: false, inSourceParagraph: true })
    await expect(body).toHaveText('basezh')

    await page.keyboard.press('ControlOrMeta+z')
    await expect(body).toHaveText('base')
    await expect(sourceParagraph).toHaveCount(1)
    await page.keyboard.press('ControlOrMeta+Shift+z')
    await expect(body).toHaveText('basezh')
    await expect(sourceParagraph).toHaveCount(1)
    await expect(sourceParagraph).toHaveText('')
    await expect.poll(caretState).toEqual({ composing: false, inSourceParagraph: true })
    await expectMarkdown(page, 'basezh\n\n- <p />')
    await reopen(page)
    await expect(sourceParagraph).toHaveCount(1)
  } finally {
    await client.detach()
  }
})

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
    // Preparing the selected block and receiving its first preedit remain one undo event.
    await page.waitForTimeout(750)
    for (const text of ['z', 'zh', 'zhong']) {
      await client.send('Input.imeSetComposition', { text, selectionStart: text.length, selectionEnd: text.length })
    }
    await client.send('Input.insertText', { text: '中' })
    await expectMarkdown(page, '中\n\n后二')
    await page.locator('.editor-content').focus()
    await page.keyboard.press('ControlOrMeta+z')
    await expectMarkdown(page, '前一\n\n后二')
    await page.locator('.editor-content').focus()
    await page.keyboard.press('ControlOrMeta+Shift+z')
    await expectMarkdown(page, '中\n\n后二')
    await reopen(page)
  } finally {
    await client.detach()
  }
})

for (const scenario of [
  { name: 'paragraph', source: '<p>Left</p>', selector: 'p', type: 'Paragraph', detachedFor: 0, focusAfterDraw: false },
  {
    name: 'code block',
    source: '<pre lang="ts">Left</pre>',
    selector: 'pre',
    type: 'CodeBlock',
    detachedFor: 750,
    focusAfterDraw: true
  }
]) {
  test(`reconnecting a composing ${scenario.name} completes its old input before subsequent typing and saving`, async ({
    page,
    browserName
  }) => {
    test.skip(browserName !== 'chromium', 'Chromium CDP supplies browser composition without an OS IME.')
    test.skip(
      !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
      'This component loads production source modules.'
    )
    await page.goto('/playground/embedded.html')
    await expect(page.getByRole('textbox', { name: 'Second document', exact: true })).toBeVisible()
    await page.evaluate(async source => {
      const core = '/src/core/editor/index.ts'
      const extension = '/src/editor/extension.ts'
      const { Wordgard }: typeof import('../src/core/editor') = await import(core)
      const { initialState, editorExtension }: typeof import('../src/editor/extension') = await import(extension)
      const view = Wordgard.create({
        state: initialState(source, [editorExtension(), Wordgard.contentAttributes.of({ class: 'editor-content' })])
      })
      document.body.replaceChildren(view.dom)
      view.focus()
    }, `<columns>\n<column>\n${scenario.source}\n</column>\n<column>\nRight\n</column>\n</columns>\n\nAfter`)
    await attachIMEPeer(page)
    const editor = page.locator('.editor-content')
    const host = editor.locator(scenario.selector).first()
    const caretState = () =>
      editor.evaluate(element => {
        const view = (element.closest('wordgard-editor') as HTMLElement & { wg: Wordgard }).wg
        const selection = window.getSelection()
        return {
          type: view.state.sel.head.parent.node.name,
          offset: view.state.selection.head - view.state.sel.head.parent.start,
          domOffset:
            selection?.focusNode && view.contentDOM.contains(selection.focusNode)
              ? view.posAtDOM(selection.focusNode, selection.focusOffset) - view.state.sel.head.parent.start
              : null
        }
      })
    await selectText(page, 'Left', 1, 'Right', 2)
    const client = await page.context().newCDPSession(page)
    try {
      await client.send('Input.imeSetComposition', { text: 'zh', selectionStart: 2, selectionEnd: 2 })
      await expect(host).toHaveText('Lzhght')
      const detached = await editor.evaluate(
        async (element, { delay, focusAfterDraw }) => {
          const view = (element.closest('wordgard-editor') as HTMLElement & { wg: Wordgard }).wg
          const parent = view.dom.parentNode!
          const peer = (window as unknown as IMEPeerWindow).imePeer
          peer.remote(false, false)
          view.dom.remove()
          if (delay) await new Promise(resolve => setTimeout(resolve, delay))
          const snapshot = peer.snapshot()
          parent.appendChild(view.dom)
          if (focusAfterDraw) {
            await new Promise(requestAnimationFrame)
            if (view.composing || !view.contentDOM.textContent?.includes('Remote After')) {
              throw new Error('Reconnection did not draw accepted remote input and complete composition automatically')
            }
          }
          view.focus()
          return snapshot
        },
        { delay: scenario.detachedFor, focusAfterDraw: scenario.focusAfterDraw }
      )
      expect(detached).toMatchObject({ composing: true, pending: true, requests: 0, errors: [], drafts: [] })
      expect(detached.stored).toContain('<p>Remote After</p>')
      await expect.poll(async () => (await imeSnapshot(page)).pending).toBe(false)
      expect(await imeSnapshot(page)).toMatchObject({ composing: false, canonical: true, errors: [], drafts: [] })
      await expect(editor.locator('.editor-columns')).toHaveCount(0)
      await expect(host).toHaveText('Lzhght')
      await expect.poll(caretState).toEqual({ type: scenario.type, offset: 3, domOffset: 3 })
      await client.send('Input.insertText', { text: '继续' })
      await expect(host).toHaveText('Lzh继续ght')
      await expect.poll(async () => (await imeSnapshot(page)).stored).toContain('Lzh继续ght')
      await page.waitForTimeout(750)
      await client.send('Input.imeSetComposition', { text: 'ni', selectionStart: 2, selectionEnd: 2 })
      await client.send('Input.insertText', { text: '你' })
      await expect(host).toHaveText('Lzh继续你ght')
      await page.keyboard.press('ControlOrMeta+z')
      await expect(host).toHaveText('Lzh继续ght')
      await expect(editor.locator('p').last()).toHaveText('Remote After')
      await page.keyboard.press('ControlOrMeta+Shift+z')
      await expect(host).toHaveText('Lzh继续你ght')
      await expect.poll(async () => (await imeSnapshot(page)).pending).toBe(false)
      expect(await imeSnapshot(page)).toMatchObject({ composing: false, canonical: true, errors: [], drafts: [] })
      await page.evaluate(async () => {
        const peer = (window as unknown as IMEPeerWindow).imePeer
        const source = peer.snapshot().stored
        peer.dispose()
        const core = '/src/core/editor/index.ts'
        const extension = '/src/editor/extension.ts'
        const xml = '/src/document/xml.ts'
        const { Wordgard }: typeof import('../src/core/editor') = await import(core)
        const { initialState, editorExtension }: typeof import('../src/editor/extension') = await import(extension)
        const { parseXml }: typeof import('../src/document/xml') = await import(xml)
        const view = Wordgard.create({
          state: initialState(parseXml(source), [
            editorExtension(),
            Wordgard.contentAttributes.of({ class: 'editor-content' })
          ])
        })
        document.querySelector('wordgard-editor')!.replaceWith(view.dom)
      })
      await expect(host).toHaveText('Lzh继续你ght')
      await expect(editor.locator('p').last()).toHaveText('Remote After')
    } finally {
      await page.evaluate(() => (window as unknown as IMEPeerWindow).imePeer.dispose())
      await client.detach()
    }
  })
}

for (const scenario of [
  { name: 'paragraph', source: '前一\n\n后二', selected: 1, expected: '中\n\n后二' },
  { name: 'heading', source: '# 前一\n\n后二', selector: 'h1', selected: 1, expected: '中\n\n后二' },
  {
    name: 'canceled heading',
    source: '# 前一\n\n后二',
    selector: 'h1',
    selected: 1,
    text: '',
    expected: '<p />\n\n后二'
  },
  {
    name: 'list item with children',
    source: '- 前一\n  - 子项\n- 保留\n\n后二',
    selected: 1,
    expected: '- 中\n- 保留\n\n后二'
  },
  {
    name: 'canceled list item with children',
    source: '- 前一\n  - 子项\n- 保留\n\n后二',
    selected: 1,
    text: '',
    expected: '-\n- 保留\n\n后二'
  },
  { name: 'paragraphs', source: '前一\n\n中间\n\n后二', selected: 2, expected: '中\n\n后二' },
  { name: 'formatted paragraph', source: '**前一**\n\n后二', selected: 1, expected: '中\n\n后二' },
  {
    name: 'paragraph with attributes',
    source: '<p data-key="selected">前一</p>\n\n后二',
    selected: 1,
    expected: '中\n\n后二'
  }
]) {
  test(`a composition without a preceding keydown replaces selected ${scenario.name}`, async ({
    page,
    browserName
  }) => {
    test.skip(browserName !== 'chromium', 'Chromium CDP drives the browser composition path without OS input.')
    await openDocument(page, scenario.source)
    await caret(
      page
        .locator('.editor-content')
        .locator(scenario.selector ?? 'p')
        .first(),
      1
    )
    await page.keyboard.press('Escape')
    for (let index = 1; index < scenario.selected; index++) await page.keyboard.press('Shift+ArrowDown')
    await expect(page.locator('.editor-selected-block')).toHaveCount(scenario.selected)
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))

    const client = await page.context().newCDPSession(page)
    try {
      // CDP supplies no keydown. This covers the fallback without claiming to reproduce an OS IME.
      for (const text of ['z', 'zh', 'zhong']) {
        await client.send('Input.imeSetComposition', { text, selectionStart: text.length, selectionEnd: text.length })
      }
      await client.send('Input.insertText', { text: scenario.text ?? '中' })
      await expectMarkdown(page, scenario.expected)
      await page.locator('.editor-content').focus()
      await page.keyboard.press('ControlOrMeta+z')
      await expectMarkdown(page, scenario.source)
      await page.locator('.editor-content').focus()
      await page.keyboard.press('ControlOrMeta+Shift+z')
      await expectMarkdown(page, scenario.expected)
      await reopen(page)
    } finally {
      await client.detach()
    }
  })
}

test('canceling a composition without a preceding keydown leaves a selected paragraph ready for typing', async ({
  page,
  browserName
}) => {
  test.skip(browserName !== 'chromium', 'Chromium CDP drives the browser composition path without OS input.')
  await openDocument(page, '前一\n\n后二')
  await caret(page.locator('.editor-content p').first(), 1)
  await page.keyboard.press('Escape')
  await expect(page.locator('.editor-selected-block')).toHaveCount(1)
  const client = await page.context().newCDPSession(page)
  try {
    await client.send('Input.imeSetComposition', { text: 'zhong', selectionStart: 5, selectionEnd: 5 })
    await client.send('Input.imeSetComposition', { text: '', selectionStart: 0, selectionEnd: 0 })
    await expect(page.locator('.editor-content p')).toHaveText(['', '后二'])
    await page.keyboard.insertText('继续')
    await expectMarkdown(page, '继续\n\n后二')
    await reopen(page)
  } finally {
    await client.detach()
  }
})

for (const scenario of [
  {
    name: 'code block',
    source: '<pre lang="ts">Left</pre>',
    selector: 'pre',
    type: 'CodeBlock'
  },
  {
    name: 'heading',
    source: '<h2 data-key="kept">Left</h2>',
    selector: 'h2',
    type: 'Heading'
  }
]) {
  test(`a composition across columns keeps its ${scenario.name} caret and accepts continued typing`, async ({
    page,
    browserName
  }) => {
    test.skip(browserName !== 'chromium', 'Chromium CDP drives trusted composition events without an OS IME.')
    const source = `<columns>\n<column>\n${scenario.source}\n</column>\n<column>\nRight\n</column>\n</columns>`
    await openDocument(page, source)
    const editor = page.locator('.editor-content')
    const host = editor.locator(scenario.selector)
    const hostMarks = () =>
      editor.evaluate((element, type) => {
        const view = (element.closest('wordgard-editor') as HTMLElement & { wg: Wordgard }).wg
        let marks: unknown = null
        view.state.doc.iterate(node => {
          if (node.name === type) marks = node.marks.map(mark => ({ name: mark.name, value: mark.value }))
        })
        return marks
      }, scenario.type)
    const initialMarks = await hostMarks()
    const caretState = () =>
      editor.evaluate(element => {
        const view = (element.closest('wordgard-editor') as HTMLElement & { wg: Wordgard }).wg
        const block = view.state.sel.head.parent
        return { composing: view.composing, type: block.node.name, offset: view.state.selection.head - block.start }
      })
    const committed = async (text: string) => {
      await expect(editor.locator('.editor-columns')).toHaveCount(0)
      await expect(host).toHaveText(text)
      await expect.poll(hostMarks).toEqual(initialMarks)
    }
    await selectText(page, 'Left', 1, 'Right', 2)
    const client = await page.context().newCDPSession(page)
    try {
      for (const text of ['z', 'zh']) {
        await client.send('Input.imeSetComposition', { text, selectionStart: text.length, selectionEnd: text.length })
      }
      await expect(host).toHaveText('Lzhght')
      await client.send('Input.insertText', { text: '中' })
      await committed('L中ght')
      await expect.poll(caretState).toEqual({ composing: false, type: scenario.type, offset: 2 })
      await editor.focus()
      await page.keyboard.press('ControlOrMeta+z')
      await expect(editor.locator('.editor-column')).toHaveCount(2)
      await expect(host).toHaveText('Left')
      await expect(editor.locator('p')).toHaveText('Right')
      await page.keyboard.press('ControlOrMeta+Shift+z')
      await committed('L中ght')
      await expect.poll(caretState).toEqual({ composing: false, type: scenario.type, offset: 2 })
      await client.send('Input.insertText', { text: '继续' })
      await committed('L中继续ght')
      await reopen(page)
      await page.reload()
      await committed('L中继续ght')
    } finally {
      await client.detach()
    }
  })
}

for (const { keepRight, cancel } of [
  { keepRight: true, cancel: false },
  { keepRight: false, cancel: false },
  { keepRight: false, cancel: true }
]) {
  test(`${cancel ? 'canceling' : 'committing'} a composition without a preceding keydown replaces disconnected selected paragraphs ${keepRight ? 'across columns' : 'while unwrapping a column'}`, async ({
    page,
    browserName
  }) => {
    test.skip(browserName !== 'chromium', 'Chromium CDP drives the browser composition path without OS input.')
    const source = `<columns>\n<column>\nLeft\n\nLeft second\n</column>\n<column>\nRight${keepRight ? '\n\nRight second' : ''}\n</column>\n</columns>\n\nAfter`
    await openDocument(page, source)
    const columns = page.locator('.editor-column')
    const left = (await columns.first().locator('p').first().boundingBox())!
    const right = (await columns.last().locator('p').first().boundingBox())!
    await page.mouse.move(left.x - 65, left.y + 2)
    await page.mouse.down()
    await page.mouse.move(right.x + 80, right.y + right.height - 2, { steps: 16 })
    await page.mouse.up()
    await expect(page.locator('.editor-selected-block')).toHaveText(['Left', 'Right'])
    const client = await page.context().newCDPSession(page)
    try {
      for (const text of ['z', 'zh', 'zhong']) {
        await client.send('Input.imeSetComposition', { text, selectionStart: text.length, selectionEnd: text.length })
      }
      if (cancel) await client.send('Input.imeSetComposition', { text: '', selectionStart: 0, selectionEnd: 0 })
      else await client.send('Input.insertText', { text: '中' })
      const expected = cancel ? '' : '中'
      const checkResult = async () => {
        if (keepRight) {
          await expect(columns.first().locator('p')).toHaveText([expected, 'Left second'])
          await expect(columns.last().locator('p')).toHaveText(['Right second'])
          await expect(page.locator('.editor-content > p')).toHaveText(['After'])
        } else {
          await expect(columns).toHaveCount(0)
          await expect(page.locator('.editor-content > p')).toHaveText([expected, 'Left second', 'After'])
        }
      }
      await checkResult()
      await page.locator('.editor-content').focus()
      await page.keyboard.press('ControlOrMeta+z')
      await expect(columns.first().locator('p')).toHaveText(['Left', 'Left second'])
      await expect(columns.last().locator('p')).toHaveText(keepRight ? ['Right', 'Right second'] : ['Right'])
      await page.keyboard.press('ControlOrMeta+Shift+z')
      await checkResult()
      await reopen(page)
    } finally {
      await client.detach()
    }
  })
}

for (const cancel of [false, true]) {
  test(`${cancel ? 'canceling' : 'committing'} a composition cleans an outer column while its nested row stays intact`, async ({
    page,
    browserName
  }) => {
    test.skip(browserName !== 'chromium', 'Chromium CDP drives trusted composition events without an OS IME.')
    const source =
      '<columns>\n<column>\n<columns>\n<column>\nA\n</column>\n<column>\nB\n\nKeep\n</column>\n</columns>\n</column>\n<column>\nC\n</column>\n</columns>\n\nAfter'
    await openDocument(page, source)
    const editor = page.locator('.editor-content')
    const a = (await editor.locator('p').filter({ hasText: /^A$/ }).boundingBox())!
    const c = (await editor.locator('p').filter({ hasText: /^C$/ }).boundingBox())!
    await page.mouse.move(a.x - 65, a.y + 2)
    await page.mouse.down()
    await page.mouse.move(c.x + 80, c.y + c.height - 2, { steps: 16 })
    await page.mouse.up()
    await expect(page.locator('.editor-selected-block')).toHaveText(['A', 'B', 'C'])
    const client = await page.context().newCDPSession(page)
    try {
      for (const text of ['z', 'zh', 'zhong']) {
        await client.send('Input.imeSetComposition', { text, selectionStart: text.length, selectionEnd: text.length })
      }
      await expect(editor.locator('.editor-columns')).toHaveCount(2)
      if (cancel) await client.send('Input.imeSetComposition', { text: '', selectionStart: 0, selectionEnd: 0 })
      else await client.send('Input.insertText', { text: '中' })
      const checkResult = async () => {
        await expect(editor.locator('.editor-columns')).toHaveCount(1)
        await expect(editor.locator('.editor-column')).toHaveCount(2)
        await expect(editor.locator('p')).toHaveText([cancel ? '' : '中', 'Keep', 'After'])
        await expect(editor.locator(':scope > .editor-columns > .editor-column')).toHaveCount(2)
      }
      await checkResult()
      await editor.focus()
      await page.keyboard.press('ControlOrMeta+z')
      await expect(editor.locator('.editor-columns')).toHaveCount(2)
      await expect(editor.locator('p')).toHaveText(['A', 'B', 'Keep', 'C', 'After'])
      await page.keyboard.press('ControlOrMeta+Shift+z')
      await checkResult()
      await reopen(page)
      await checkResult()
      await page.reload()
      await checkResult()
    } finally {
      await client.detach()
    }
  })
}

for (const inputType of ['deleteContentBackward', 'deleteContentForward', 'insertReplacementText', 'insertFromYank']) {
  for (const cancelWithoutInput of [false, true]) {
    test(`${inputType} uses the whole block selection${cancelWithoutInput ? ' after composition cancels without preedit' : ''}`, async ({
      page
    }) => {
      const deleting = inputType.startsWith('delete')
      await openDocument(page, deleting ? '前一\n\n中间\n\n后二' : '前一\n\n中间')
      await caret(page.locator('.editor-content p').first(), 1)
      await page.keyboard.press('Escape')
      await page.keyboard.press('Shift+ArrowDown')
      await expect(page.locator('.editor-selected-block')).toHaveCount(2)
      if (cancelWithoutInput) {
        await page.locator('.editor-content').evaluate(element => {
          element.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }))
          element.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true }))
        })
      }
      await page.locator('.editor-content').evaluate((element, inputType) => {
        const range = document.getSelection()!.getRangeAt(0).cloneRange()
        const event = new InputEvent('beforeinput', { inputType, data: '中', bubbles: true, cancelable: true })
        Object.defineProperty(event, 'getTargetRanges', {
          value: () => [
            new StaticRange({
              startContainer: range.startContainer,
              startOffset: range.startOffset,
              endContainer: range.endContainer,
              endOffset: range.endOffset
            })
          ]
        })
        element.dispatchEvent(event)
        // This is a browser-handler replay, not an OS soft-keyboard test. Apply the native delete
        // only when the handler allows it, then deliver its input event with the same real range.
        if (!event.defaultPrevented) {
          if (!inputType.startsWith('delete')) throw new Error('Replacement input must be handled by the editor')
          range.deleteContents()
          document.getSelection()!.removeAllRanges()
          document.getSelection()!.addRange(range)
          element.dispatchEvent(new InputEvent('input', { inputType, bubbles: true }))
        }
      }, inputType)
      await expect(page.locator('.editor-content p')).toHaveText(deleting ? ['后二'] : ['中'])
      await reopen(page)
    })
  }
}

test('an explicit smaller deletion range stays local inside a whole-block selection', async ({ page }) => {
  await openDocument(page, '前一\n\n中间\n\n后二')
  await caret(page.locator('.editor-content p').first(), 1)
  await page.keyboard.press('Escape')
  await page.keyboard.press('Shift+ArrowDown')
  await expect(page.locator('.editor-selected-block')).toHaveCount(2)
  await page.locator('.editor-content').evaluate(element => {
    const text = element.querySelector('p')!.firstChild!
    const range = document.createRange()
    range.setStart(text, 0)
    range.setEnd(text, 1)
    const event = new InputEvent('beforeinput', { inputType: 'deleteContentBackward', bubbles: true, cancelable: true })
    Object.defineProperty(event, 'getTargetRanges', {
      value: () => [new StaticRange({ startContainer: text, startOffset: 0, endContainer: text, endOffset: 1 })]
    })
    element.dispatchEvent(event)
    if (!event.defaultPrevented) {
      range.deleteContents()
      document.getSelection()!.removeAllRanges()
      document.getSelection()!.addRange(range)
      element.dispatchEvent(new InputEvent('input', { inputType: 'deleteContentBackward', bubbles: true }))
    }
  })
  await expect(page.locator('.editor-content p')).toHaveText(['一', '中间', '后二'])
  await reopen(page)
})
