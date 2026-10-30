import { expectMarkdown, caret, expect, openDocument, reopen, test } from './helpers'

test('a code block shows Kirari tokens and changes language from its toolbar', async ({ page }) => {
  await openDocument(page, '```js\nconst answer = 42\n```')
  const pre = page.locator('.editor-code-pre')
  await expect(pre.locator('.kirari-keyword').first()).toHaveText('const')
  await expect(pre.locator('.kirari-number')).toHaveText('42')
  await expect(page.locator('.editor-code-language')).toHaveText('JavaScript')

  await page.locator('.editor-code-language').click()
  const search = page.locator('.code-language-search input')
  await expect(search).toBeFocused()
  await search.fill('python')
  await page.getByRole('option', { name: 'Python' }).click()
  await expect(page.locator('.editor-code-language')).toHaveText('Python')
  await expect(pre).toHaveAttribute('data-language', 'python')

  await reopen(page)
  await expect(page.locator('.editor-code-language')).toHaveText('Python')
  await page.locator('.editor-code-language').click()
  await page.locator('.code-language-search input').fill('plain')
  await page.getByRole('option', { name: 'Plain Text' }).click()
  await expect(page.locator('.editor-code-language')).toHaveText('Plain Text')
  await expectMarkdown(page, '```\nconst answer = 42\n```')
})

test('the code toolbar toggles wrapping and keeps it across a reload', async ({ page }) => {
  await openDocument(page, '```js\nconst answer = 42\n```')
  const block = page.locator('.editor-code-block')
  await expect(block).toHaveAttribute('data-wrap', 'false')
  await page.locator('.editor-code-wrap').click()
  await expect(block).toHaveAttribute('data-wrap', 'true')
  await expect(page.locator('.editor-code-wrap')).toHaveAttribute('aria-pressed', 'true')

  await reopen(page)
  await expect(block).toHaveAttribute('data-wrap', 'true')
  await page.locator('.editor-code-wrap').click()
  await expect(block).toHaveAttribute('data-wrap', 'false')
})

test('the code toolbar copies the literal source', async ({ page, context, browserName }) => {
  test.skip(browserName !== 'chromium', 'Clipboard permissions are available in Chromium here')
  await context.grantPermissions(['clipboard-read', 'clipboard-write'])
  await openDocument(page, '```js\nconst answer = 42\n```')
  await page.locator('.editor-code-copy').click()
  await expect(page.locator('.editor-code-copy')).toHaveText('已复制')
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('const answer = 42')
})

test('a formula block renders Temml MathML and edits its LaTeX inline', async ({ page }) => {
  await openDocument(page, '$$\nE = mc^2\n$$')
  const block = page.locator('.math-block')
  await expect(block.locator('math')).toBeVisible()
  await expect(block).toHaveAttribute('data-math', 'E = mc^2')

  await block.click()
  const editor = page.locator('.math-editor')
  const input = editor.locator('input')
  await expect(editor).toBeVisible()
  await expect(input).toBeFocused()
  await expect(input).toHaveValue('E = mc^2')

  await input.fill('$')
  await expect(editor).toHaveAttribute('data-invalid', 'true')
  await expect(editor.locator('.math-editor-header')).toHaveText('无效公式')
  await expect(block).toHaveAttribute('data-math', '$')
  await page.keyboard.press('Escape')
  await expect(editor).toHaveCount(0)

  await block.click()
  await input.fill('a^2 + b^2 = c^2')
  await expect(editor).not.toHaveAttribute('data-invalid', 'true')
  await page.keyboard.press('Escape')
  await expect(block.locator('math')).toBeVisible()
  await expectMarkdown(page, '$$\na^2 + b^2 = c^2\n$$')
})

test('the slash menu inserts an empty formula block and opens its editor', async ({ page }) => {
  await openDocument(page, 'Start')
  await caret(page.locator('.editor-content > p'))
  await page.keyboard.press('Enter')
  await page.keyboard.type('/latex')
  await page.getByRole('option', { name: /公式/ }).click()
  const editor = page.locator('.math-editor')
  await expect(editor).toBeVisible()
  await expect(page.locator('.math-block')).toHaveAttribute('data-math', '')
  await page.locator('.math-editor input').fill('E = mc^2')
  await page.keyboard.press('Escape')
  await expect(page.locator('.math-block math')).toBeVisible()
  await expectMarkdown(page, 'Start\n\n$$\nE = mc^2\n$$\n\n<p />')
})

test('editing a formula keeps its extension attributes', async ({ page }) => {
  await openDocument(page, '<math source="x">E=mc^2</math>')
  await page.locator('.math-block').click()
  await page.locator('.math-editor input').fill('a=b')
  await page.keyboard.press('Escape')
  await expectMarkdown(page, '<math source="x">\n  $$\n  a=b\n  $$\n</math>')
  await reopen(page)
  await expect(page.locator('.math-block')).toHaveAttribute('data-math', 'a=b')
  await expectMarkdown(page, '<math source="x">\n  $$\n  a=b\n  $$\n</math>')
})

test('an unknown language opens the picker without pretending to be Plain Text', async ({ page }) => {
  await openDocument(page, '```unknown-language\nconst answer = 42\n```')
  await expect(page.locator('.editor-code-language')).toHaveText('unknown-language')
  await page.locator('.editor-code-language').click()
  const plain = page.getByRole('option', { name: 'Plain Text' })
  await expect(plain).toBeVisible()
  await expect(plain.locator('.code-language-check')).toHaveCount(0)
  await expect(page.locator('.code-language-check')).toHaveCount(0)
})

test('plain code blocks mark Plain Text in the picker and target the clicked block after typing', async ({ page }) => {
  await openDocument(page, '```\nfirst\n```\n\n```\nsecond\n```')
  const blocks = page.locator('.editor-code-block')
  const second = blocks.nth(1)

  await caret(second.locator('.editor-code-pre'), 'end')
  await page.keyboard.type('!')
  await second.locator('.editor-code-wrap').click()
  await expect(blocks.nth(0)).toHaveAttribute('data-wrap', 'false')
  await expect(second).toHaveAttribute('data-wrap', 'true')

  await second.locator('.editor-code-language').click()
  const plain = page.getByRole('option', { name: 'Plain Text' })
  await expect(plain.locator('.code-language-check')).toHaveCount(1)
  await page.locator('.code-language-search input').fill('js')
  await page.getByRole('option', { name: 'JavaScript' }).click()
  await expect(blocks.nth(0).locator('.editor-code-language')).toHaveText('Plain Text')
  await expect(second.locator('.editor-code-language')).toHaveText('JavaScript')
  await expectMarkdown(page, '```\nfirst\n```\n\n<pre lang="javascript" wrap="true">\n  ```\n  second!\n  ```\n</pre>')
})

test('the formula input reads document source directly across preceding, remote, and guarded edits', async ({
  page
}) => {
  await openDocument(page, 'Intro\n\n$$\na + b\n$$')
  const block = page.locator('.math-block')
  await block.click()
  const input = page.locator('.math-editor input')
  await expect(input).toBeFocused()
  await expect(input).toHaveValue('a + b')

  // Collapse selection into the middle of the formula, then insert text before the formula block.
  await input.evaluate((el: HTMLInputElement) => el.setSelectionRange(2, 2))
  await page.evaluate(async () => {
    const mod = '/src/core/doc/index.ts'
    const { Leaf } = await import(/* @vite-ignore */ mod)
    const wg = (document.querySelector('.editor-view') as unknown as { wg: any }).wg
    wg.dispatch({ changes: { from: 1, insert: [Leaf.text('Prefix ')] } })
    wg.flush()
  })
  await expect(input).toBeFocused()
  expect(await input.evaluate((el: HTMLInputElement) => ({ start: el.selectionStart, end: el.selectionEnd }))).toEqual({
    start: 2,
    end: 2
  })

  // Typing in the middle keeps the caret in place rather than jumping to the end.
  await page.keyboard.type('c + ')
  await expect(input).toHaveValue('a c + + b')
  expect(await input.evaluate((el: HTMLInputElement) => ({ start: el.selectionStart, end: el.selectionEnd }))).toEqual({
    start: 6,
    end: 6
  })

  // A remote replacement at the same block position updates the open input immediately.
  await page.evaluate(async () => {
    const mod = '/src/blocks/math/index.ts'
    const { mathEditorField, mathSourceChange } = await import(/* @vite-ignore */ mod)
    const wg = (document.querySelector('.editor-view') as unknown as { wg: any }).wg
    const pos = wg.state.field(mathEditorField)
    wg.dispatch(mathSourceChange(wg.state, pos, 'x^2 + y^2')!)
    wg.flush()
  })
  await expect(input).toHaveValue('x^2 + y^2')
  await input.evaluate((el: HTMLInputElement) => el.setSelectionRange(el.value.length, el.value.length))
  await page.keyboard.type(' = z^2')
  await expect(input).toHaveValue('x^2 + y^2 = z^2')

  // A transaction rejected by transactionGuard does not let the input drift from the document.
  await page.evaluate(async () => {
    const coreMod = '/src/core/editor/index.ts'
    const stateMod = '/src/core/state/index.ts'
    const { Wordgard } = await import(/* @vite-ignore */ coreMod)
    const { GardState } = await import(/* @vite-ignore */ stateMod)
    const wg = (document.querySelector('.editor-view') as unknown as { wg: any }).wg
    wg.dispatch({
      effects: GardState.appendConfig.of(
        Wordgard.transactionGuard.of((trs: readonly any[]) => {
          if (trs.some(tr => tr.docChanged)) throw new Error('guarded')
        })
      )
    })
    wg.flush()
  })
  await page.keyboard.type('!')
  await expect(page.getByRole('alert')).toHaveText('guarded')
  await expect(input).toHaveValue('x^2 + y^2 = z^2')
  await expect(block).toHaveAttribute('data-math', 'x^2 + y^2 = z^2')
})

test('the formula panel moves when the formula block grows', async ({ page }) => {
  await openDocument(page, '$$\nE=mc^2\n$$')
  await page.locator('.math-block').click()
  const editor = page.locator('.math-editor')
  const before = (await editor.boundingBox())!.y
  await page.locator('.math-editor input').fill('\\frac{\\frac{a}{b}}{\\frac{c}{d}}')
  await expect.poll(async () => (await editor.boundingBox())!.y).toBeGreaterThan(before)
})

test('Escape and ArrowDown leave a trailing code or formula block and create a writable block below', async ({
  page
}) => {
  await openDocument(page, '```js\nconst answer = 42\n```')
  await caret(page.locator('.editor-code-pre'), 'end')
  await page.keyboard.press('Escape')
  await expect(page.locator('.editor-selected-block')).toHaveCount(1)
  await page.keyboard.press('ArrowDown')
  await page.keyboard.type('Next paragraph')
  await expectMarkdown(page, '```js\nconst answer = 42\n```\n\nNext paragraph')

  await caret(page.locator('.editor-code-pre'), 5)
  await page.keyboard.press('Shift+Enter')
  await page.keyboard.type('Middle paragraph')
  await expectMarkdown(page, '```js\nconst answer = 42\n```\n\nMiddle paragraph\n\nNext paragraph')

  await openDocument(page, '$$\nE = mc^2\n$$')
  await page.locator('.math-block').click()
  await page.locator('.math-editor input').fill('x + y = z')
  await page.keyboard.press('Enter')
  await expect(page.locator('.math-editor')).toHaveCount(0)
  await expect(page.locator('.editor-selected-block')).toHaveCount(1)
  await page.keyboard.press('ArrowDown')
  await page.keyboard.type('After formula')
  await expectMarkdown(page, '$$\nx + y = z\n$$\n\nAfter formula')
})
