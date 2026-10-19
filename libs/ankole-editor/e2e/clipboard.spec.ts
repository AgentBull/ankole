import {
  caret,
  clipboard,
  expect,
  expectMarkdown,
  openDocument,
  reopen,
  replaceDocument,
  selectDocument,
  test
} from './helpers'

const blocks =
  'Before\n\n<embed ref="tasks" />\n\n<callout tone="warning">\n  Keep **this**\n</callout>\n\n<future version="99">\n  Unrecognized content\n</future>\n\nAfter'

test('cut, undo and paste retain an embed, a callout and an unknown element', async ({ page }) => {
  await openDocument(page, blocks)
  const editor = page.getByRole('textbox', { name: '文档编辑器', exact: true })
  const reference = page.locator('.editor-content .embed code')
  await selectDocument(page)
  const data = await clipboard(editor, 'cut')
  // The HTML for other editors holds the reference and the unknown element.
  expect(data['text/html']).toContain('tasks')
  expect(data['text/html']).toContain('Unrecognized content')
  await expect(reference).toHaveCount(0)
  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await expect(reference).toHaveText('tasks')
  await replaceDocument(page, 'Replace me')
  await selectDocument(page)
  await clipboard(editor, 'paste', data)
  await expect(reference).toHaveText('tasks')
  await expect(page.locator('.editor-content .callout strong')).toHaveText('this')
  await expect(page.locator('.editor-content .callout')).toHaveAttribute('data-tone', 'warning')
  await expect(page.locator('.editor-content .unknown-element[data-name="future"]')).toHaveText('Unrecognized content')
  await reopen(page)
  await expect(reference).toHaveText('tasks')
})

test('external rich HTML retains inline formats and table cells after reopening', async ({ page }) => {
  await openDocument(page, 'Replace me')
  await selectDocument(page)
  await clipboard(page.getByRole('textbox', { name: '文档编辑器', exact: true }), 'paste', {
    'text/html':
      '<p><strong>Bold</strong> <u>Underlined</u> <em>Italic</em></p><table><tr><th>Name</th><th>Value</th></tr><tr><td>Alpha</td><td>42</td></tr></table>',
    'text/plain': 'Bold Underlined Italic\nName Value\nAlpha 42'
  })
  await expect(page.locator('.editor-content u')).toHaveText('Underlined')
  await expect(page.locator('.editor-content table')).toContainText('Alpha')
  await reopen(page)
  await expect(page.locator('.editor-content u')).toHaveText('Underlined')
  await expect(page.locator('.editor-content table tr').last().locator('td')).toHaveText(['Alpha', '42'])
})

test('copying part of a formatted paragraph does not copy its neighbors', async ({ page }) => {
  await openDocument(page, 'before **selected** after')
  const text = page.locator('.editor-content strong')
  await text.evaluate(element => {
    element.closest<HTMLElement>('[contenteditable=true]')!.focus()
    const range = document.createRange()
    range.selectNodeContents(element)
    window.getSelection()!.removeAllRanges()
    window.getSelection()!.addRange(range)
    document.dispatchEvent(new Event('selectionchange'))
  })
  const data = await clipboard(page.getByRole('textbox', { name: '文档编辑器', exact: true }), 'copy')
  expect(data['text/plain']).toBe('selected')
  await replaceDocument(page, 'Replace me')
  await selectDocument(page)
  await clipboard(page.getByRole('textbox', { name: '文档编辑器', exact: true }), 'paste', data)
  await expect(page.locator('.editor-content')).toHaveText('selected')
  await expect(page.locator('.editor-content strong')).toHaveText('selected')
})

// Plain text that reads as Markdown pastes as page content, as in Notion. The first block joins the
// paragraph at the caret, as an HTML paste does.
for (const { name, markdown, at, text, expected } of [
  {
    name: 'Markdown blocks',
    markdown: 's\n\nX\n\ne',
    at: ['X', 'end'] as const,
    text: '# Title\n\n- a **b**\n- c',
    expected: 's\n\nXTitle\n\n- a **b**\n- c\n\ne'
  },
  {
    name: 'inline Markdown',
    markdown: 'ab',
    at: ['ab', 1] as const,
    text: '**x** and [link](https://example.com)',
    expected: 'a**x** and [link](https://example.com)b'
  },
  { name: 'plain lines', markdown: 'X', at: ['X', 'end'] as const, text: 'one\ntwo', expected: 'Xone\n\ntwo' },
  {
    name: 'Markdown into a code block, as plain text',
    markdown: '```\ncode\n```',
    at: ['code', 'end'] as const,
    text: '**b**',
    expected: '```\ncode**b**\n```'
  },
  {
    name: 'an unknown element, as plain text',
    markdown: 'X',
    at: ['X', 'end'] as const,
    text: '<widget>w</widget>',
    expected: 'X\\<widget>w\\</widget>'
  }
]) {
  test(`pasting plain text: ${name}`, async ({ page }) => {
    await openDocument(page, markdown)
    await caret(page.locator('.editor-content').getByText(at[0], { exact: true }), at[1])
    await clipboard(page.getByRole('textbox', { name: '文档编辑器', exact: true }), 'paste', { 'text/plain': text })
    await expectMarkdown(page, expected)
  })
}
