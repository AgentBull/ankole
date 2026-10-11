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
