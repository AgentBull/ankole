import { test, expect, openDocument, caret, replaceDocument } from './helpers'

test('a keystroke in a 500-row table takes well under three seconds', async ({ page }) => {
  const rows = Array.from({ length: 500 }, (_, i) => `| r${i} | x | y | z | w |`)
  await openDocument(page, ['| a | b | c | d | e |', '| --- | --- | --- | --- | --- |', ...rows].join('\n'))
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('r3', { exact: true }))
  await expect(page.getByRole('button', { name: '行 1', exact: true })).toBeVisible()
  // Quadratic table menu checks took about 26 s for each key. A developer machine takes well under a second, and a
  // busy CI runner has taken 1.2 s, so the bound still catches that regression without failing on a slow runner.
  const start = Date.now()
  await page.keyboard.type('q')
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  expect(Date.now() - start).toBeLessThan(3000)
  await expect(editor.getByText('r3q', { exact: true })).toBeVisible()
})

test('opening a document with many tables lays it out once for all of them', async ({ page, browser, browserName }) => {
  test.skip(browserName !== 'chromium', 'Chromium records forced layouts with their script stacks in its timeline')
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'Only the development server serves source modules, whose URLs name table-scroll'
  )
  const table = '| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 |'
  await page.goto('/')
  await browser.startTracing(page, {
    categories: [
      'devtools.timeline',
      'disabled-by-default-devtools.timeline',
      'disabled-by-default-devtools.timeline.stack'
    ]
  })
  await replaceDocument(
    page,
    [...Array.from({ length: 24 }, (_, i) => `${table}\n\nParagraph ${i}`), 'Last'].join('\n\n')
  )
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  const trace = JSON.parse((await browser.stopTracing()).toString()) as {
    traceEvents: { name: string; args?: { beginData?: { stackTrace?: { url: string }[] } } }[]
  }
  // Measuring each table right after writing the previous one forced a style and layout pass per table: 49 for 24.
  const forced = trace.traceEvents.filter(
    event =>
      (event.name === 'UpdateLayoutTree' || event.name === 'Layout') &&
      event.args?.beginData?.stackTrace?.some(frame => frame.url.includes('table-scroll'))
  )
  // Measuring the freshly rendered tables always forces one style and layout pass, so finding none would mean the
  // stack attribution above stopped matching rather than that the layouts went away.
  expect(forced.length).toBeGreaterThan(0)
  expect(forced.length).toBeLessThanOrEqual(2)
})

test('cutting a whole document that starts with a table keeps the editor', async ({ page }) => {
  await openDocument(page, '| a | b |\n| --- | --- |\n| 1 | 2 |\n\nAfter')
  const editor = page.locator('.editor-content')
  await caret(editor.getByText('After', { exact: true }))
  // The cut comes before the editor draws the second ⌘A, as with fast real keys.
  await editor.evaluate(element => {
    const mac = /Mac/.test(navigator.platform)
    for (let i = 0; i < 2; i++) {
      element.dispatchEvent(
        new KeyboardEvent('keydown', {
          key: 'a',
          code: 'KeyA',
          metaKey: mac,
          ctrlKey: !mac,
          bubbles: true,
          cancelable: true
        })
      )
    }
    element.dispatchEvent(
      new ClipboardEvent('cut', { clipboardData: new DataTransfer(), bubbles: true, cancelable: true })
    )
  })
  await expect(editor.locator('table')).toHaveCount(0)
  await expect(editor).not.toContainText('After')
  await page.keyboard.type('Again')
  await expect(editor).toContainText('Again')
})
