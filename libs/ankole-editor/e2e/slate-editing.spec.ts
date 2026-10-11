import fixtures from '../upstream/fixtures/slate-editing.json' with { type: 'json' }
import dialect from '../upstream/fixtures/slate-dialect.json' with { type: 'json' }
import { clipboard, expect, openDocument, reopen, selectDocument, test } from './helpers'
import { readTextRange, setTextRange } from '../upstream/browser-selection'

for (const fixture of fixtures) {
  test(fixture.id, async ({ page }) => {
    const output = (dialect as Record<string, { output: typeof fixture.output }>)[fixture.id]?.output ?? fixture.output
    await openDocument(page, 'Replace me')
    await selectDocument(page)
    const escape = (text: string) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
    const body = page.locator('.editor-content')
    await clipboard(body, 'paste', {
      'text/html': fixture.input.paragraphs.map(text => `<p>${escape(text)}</p>`).join('')
    })
    await expect(body.locator(':scope > p')).toHaveText(fixture.input.paragraphs)
    await body.evaluate(setTextRange, fixture.input)
    if (fixture.text !== undefined) await page.keyboard.insertText(fixture.text)
    else for (let index = 0; index < fixture.count; index++) await page.keyboard.press(fixture.key!)
    await expect(body.locator(':scope > p')).toHaveText(output.paragraphs)
    const selection = await body.evaluate(readTextRange)
    expect(selection).toEqual({ anchor: output.anchor, focus: output.focus })
    await reopen(page)
    expect(await body.locator(':scope > p').allTextContents()).toEqual(output.paragraphs)
  })
}
