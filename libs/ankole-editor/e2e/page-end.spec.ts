import { expect, expectMarkdown, openDocument, test } from './helpers'

// SPEC §7.5 Page-end click: a click below a last block that cannot take the caret adds a paragraph.
for (const [name, markdown, expected] of [
  ['a table', '| a | b |\n| - | - |\n| c | d |', '| a | b |\n| - | - |\n| c | d |\n\nx'],
  ['a quote', '> quote', '> quote\n\nx'],
  ['a callout', '<callout tone="info">c</callout>', '<callout tone="info">\n  c\n</callout>\n\nx'],
  ['a database reference', 'a\n\n<database ref="t" />', 'a\n\n<database ref="t" />\n\nx'],
  ['a divider', 'a\n\n---', 'a\n\n---\n\nx'],
  ['a paragraph', 'a\n\nlast', 'a\n\nlastx'],
  ['a list', '- one\n- two', '- one\n- twox']
] as const) {
  test(`a click below ${name} at the page end puts the caret in ${expected.endsWith('\n\nx') ? 'a new paragraph' : 'that block'}`, async ({
    page
  }) => {
    await openDocument(page, markdown)
    const box = (await page.locator('.editor-content').boundingBox())!
    await page.mouse.click(box.x + 40, box.y + box.height - 20)
    await expect(page.locator('.editor-content')).toBeFocused()
    await page.keyboard.type('x')
    await expectMarkdown(page, expected)
  })
}
