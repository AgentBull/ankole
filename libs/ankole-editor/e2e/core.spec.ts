import type { Page } from '@playwright/test'
import { expect, test } from './helpers'

// This upstream test expects a fixed character offset when the target x is a glyph midpoint.
// WebKit selects the other side of the midpoint with its default proportional font.
const knownFailures: Record<string, string[]> = {
  webkit: ['moveVertically > can move between paragraphs']
}

// The core's browser tests (test/core/browser) run in the page and publish their results.
test('core browser tests pass', async ({ page, browserName }) => {
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'Only the development server serves the test page'
  )
  await page.goto('/test/core/browser/index.html')
  const results = (await (await page.waitForFunction(() => window.coreTestResults)).jsonValue()) ?? []
  const failed = results.filter(result => result.error)
  const unexpected = failed
    .filter(({ scope, name }) => !knownFailures[browserName]?.includes([...scope, name].join(' > ')))
    .map(({ scope, name, error }) => `${[...scope, name].join(' > ')}\n${error}`)
  expect(unexpected).toEqual([])
  expect(failed.map(({ scope, name }) => [...scope, name].join(' > '))).toEqual(knownFailures[browserName] ?? [])
  expect(results.length).toBeGreaterThan(100)
})

test('clicking consecutive and trailing empty code lines edits that line', async ({ page }) => {
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'Only the development server serves the test page'
  )
  await page.goto('/test/core/browser/index.html')
  await page.waitForFunction(() => window.coreTestResults)
  for (const { name, pos, expected } of [
    { name: 'consecutive', pos: 3, expected: 'a<br>X<br>b<br><br>' },
    { name: 'trailing', pos: 6, expected: 'a<br><br>b<br>X' }
  ]) {
    await test.step(name, async () => {
      const point = await page.evaluate(async pos => {
        const fixturePath = '/test/core/browser/tempview.ts'
        const schemaPath = '/test/core/schema.ts'
        const { tempEditor } = await import(fixturePath)
        const { basicBuilders, builder, basicSchema } = await import(schemaPath)
        const { pre, br } = basicBuilders
        const editor = tempEditor(builder(basicSchema)(pre('a', br, br, 'b', br)))
        document.querySelector<HTMLElement>('#workspace')!.style.opacity = '1'
        editor.dom.style.pointerEvents = 'auto'
        const rect = editor.coordsAtPos(pos, -1)
        return { x: rect.left + 20, y: (rect.top + rect.bottom) / 2 }
      }, pos)
      await page.mouse.click(point.x, point.y)
      await page.keyboard.type('X')
      await expect(page.locator('#workspace pre')).toHaveJSProperty('innerHTML', expected)
    })
  }
})

async function guardedNativeEditor(page: Page) {
  await page.goto('/test/core/browser/index.html')
  await page.waitForFunction(() => window.coreTestResults)
  await page.evaluate(async () => {
    const editorPath = '/src/core/editor/index.ts'
    const extensionPath = '/src/editor/extension.ts'
    const { Wordgard } = await import(editorPath)
    const { editorExtension, initialState } = await import(extensionPath)
    const parent = document.querySelector<HTMLElement>('#workspace')!
    parent.replaceChildren()
    parent.style.opacity = '1'
    parent.style.pointerEvents = 'auto'
    const editor = Wordgard.create({
      parent,
      state: initialState('Before', [
        editorExtension(),
        Wordgard.transactionGuard.of((transactions: { newDoc: { textContent(): string } }[]) => {
          if (transactions.at(-1)!.newDoc.textContent().includes('X')) throw new Error('Rejected test edit')
        }),
        Wordgard.exceptionSink.of(() => {})
      ])
    })
    Object.assign(window, { guardedEditor: editor })
    editor.focus()
  })
  return page.locator('#workspace [contenteditable="true"]')
}

test('rejected native typing restores DOM input tracking and accepts later typing', async ({ page }) => {
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'Only the development server serves the test page'
  )
  const editor = await guardedNativeEditor(page)
  await editor.press('End')
  await editor.pressSequentially('X')
  await expect(editor.locator('p')).toHaveText('Before')
  await expect
    .poll(() =>
      page.evaluate(() => {
        const editor = (
          window as unknown as {
            guardedEditor: { state: { doc: unknown }; inputState: { domDoc: { eq(document: unknown): boolean } } }
          }
        ).guardedEditor
        return editor.inputState.domDoc.eq(editor.state.doc)
      })
    )
    .toBe(true)
  await editor.pressSequentially(' after')
  await expect(editor.locator('p')).toHaveText('Before after')
})

test('a rejected native composition restores the accepted document and can resume editing', async ({
  page,
  browserName
}) => {
  test.skip(browserName !== 'chromium', 'CDP composition is available only in Chromium.')
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'Only the development server serves the test page'
  )
  const editor = await guardedNativeEditor(page)
  await editor.press('End')
  const client = await page.context().newCDPSession(page)
  try {
    await client.send('Input.imeSetComposition', { text: 'X', selectionStart: 1, selectionEnd: 1 })
    await expect(editor.locator('p')).toHaveText('Before')
    await expect
      .poll(() =>
        page.evaluate(() => (window as unknown as { guardedEditor: { composing: boolean } }).guardedEditor.composing)
      )
      .toBe(false)
    await editor.pressSequentially(' after')
    await expect(editor.locator('p')).toHaveText('Before after')
    await editor.press('ControlOrMeta+z')
    await expect(editor.locator('p')).toHaveText('Before')
  } finally {
    await client.detach()
  }
})
