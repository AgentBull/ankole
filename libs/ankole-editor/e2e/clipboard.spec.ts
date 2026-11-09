import {
  caret,
  clipboard,
  expect,
  expectMarkdown,
  openDocument,
  reopen,
  replaceDocument,
  selectDocument,
  selectText,
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

test('Word list paragraphs paste as nested bullet and numbered lists', async ({ page }) => {
  const marker = (text: string) =>
    `<![if !supportLists]><span style="mso-list:Ignore">${text}<span style="font:7.0pt">&nbsp;&nbsp;</span></span><![endif]>`
  const item = (list: string, level: number, text: string, body: string) =>
    `<p class=MsoListParagraphCxSpMiddle style="margin-left:${level * 36}pt;mso-list:${list} level${level} lfo1">${marker(text)}${body}</p>`
  await openDocument(page, 'Replace me')
  await selectDocument(page)
  await clipboard(page.getByRole('textbox', { name: '文档编辑器', exact: true }), 'paste', {
    'text/html': [
      '<html xmlns:o="urn:schemas-microsoft-com:office:office"><body lang=ZH-CN>',
      '<p class=MsoNormal>Intro</p>',
      item('l0', 1, '·', 'First <b>bold</b>'),
      item('l0', 2, 'o', 'Nested'),
      item('l0', 1, '·', 'Second'),
      item('l1', 1, '1.', 'Step one'),
      item('l1', 1, '2.', 'Step two'),
      '<p class=MsoNormal>Middle</p>',
      item('l2', 1, '(1)', 'Paren one'),
      item('l2', 1, '(2)', 'Paren two'),
      '<p class=MsoNormal>Han</p>',
      item('l3', 1, '一、', '甲'),
      item('l3', 1, '二、', '乙'),
      '<p class=MsoNormal>Later</p>',
      item('l4', 1, '(4)', 'Four'),
      item('l4', 1, '(5)', 'Five'),
      '<p class=MsoNormal>Outro</p>',
      '</body></html>'
    ].join(''),
    'text/plain': 'Intro\n·  First bold\no  Nested\n·  Second\n1. Step one\n2. Step two\nOutro'
  })
  await expectMarkdown(
    page,
    'Intro\n\n- First **bold**\n  - Nested\n- Second\n\n1. Step one\n2. Step two\n\nMiddle\n\n1. Paren one\n2. Paren two\n\nHan\n\n1. 甲\n2. 乙\n\nLater\n\n4. Four\n5. Five\n\nOutro'
  )
})

test('GitHub task lists with paragraph items paste as task lists', async ({ page }) => {
  const item = (checked: boolean, text: string) =>
    `<li class="task-list-item enabled"><p><input type="checkbox" class="task-list-item-checkbox"${checked ? ' checked' : ''}> ${text}</p></li>`
  await openDocument(page, 'Replace me')
  await selectDocument(page)
  await clipboard(page.getByRole('textbox', { name: '文档编辑器', exact: true }), 'paste', {
    'text/html': `<ul class="contains-task-list">${item(true, 'Done')}${item(false, 'Open')}</ul>`,
    'text/plain': 'Done\nOpen'
  })
  await expectMarkdown(page, '- [x] Done\n- [ ] Open')
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

test('pasting a bare URL links selected text in place and opens the floating link view bar on caret paste', async ({
  page,
  baseURL
}) => {
  const url = `${baseURL}/resource-preview.html`
  await openDocument(page, 'Read guide today')
  await selectText(page, 'Read guide today', 5, 'Read guide today', 10)
  const editor = page.getByRole('textbox', { name: '文档编辑器', exact: true })
  await clipboard(editor, 'paste', { 'text/plain': url })

  const link = page.locator('.editor-content a')
  await expect(link).toHaveText('guide')
  await expect(link).toHaveAttribute('href', url)
  const linkToolbar = page.getByRole('toolbar', { name: '链接', exact: true })
  await expect(linkToolbar).toBeVisible()
  await expect(linkToolbar.getByRole('button', { name: '视图', exact: true })).toContainText('标题视图')

  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await expect(page.locator('.editor-content a')).toHaveCount(0)
  await expectMarkdown(page, 'Read guide today')

  // Pasting a bare URL at an empty caret inserts a link in link view and immediately opens the link bar.
  await openDocument(page, '')
  await editor.click()
  await clipboard(editor, 'paste', { 'text/plain': url })
  await expect(link).toHaveText(url)
  await expect(linkToolbar).toBeVisible()
  await expect(linkToolbar.getByRole('button', { name: '视图', exact: true })).toContainText('链接视图')
})

test('IDE Markdown paste, multi-line VS Code code paste, and iframe snippet paste produce structured blocks', async ({
  page,
  baseURL
}) => {
  const editor = page.getByRole('textbox', { name: '文档编辑器', exact: true })
  await openDocument(page, '')
  await editor.click()

  const md = [
    '# Ankole 生命周期',
    '',
    '配置 `<botId>` 与 <placeholder> 说明：',
    '',
    '- [x] 启动完成',
    '',
    '```mermaid',
    'stateDiagram-v2',
    '  [*] --> Ready',
    '```'
  ].join('\n')

  await clipboard(editor, 'paste', {
    'text/plain': md,
    'text/html':
      '<div style="color:#ccc;background:#1f1f1f;white-space:pre"><div><span># Ankole 生命周期</span></div><br><div><span>配置 `&lt;botId&gt;` 与 &lt;placeholder&gt; 说明：</span></div></div>',
    'vscode-editor-data': JSON.stringify({ version: 1, mode: 'markdown' })
  })

  await expect(page.locator('.editor-content h1')).toHaveText('Ankole 生命周期')
  await expectMarkdown(
    page,
    '# Ankole 生命周期\n\n配置 `<botId>` 与 \\<placeholder> 说明：\n\n- [x] 启动完成\n\n```mermaid\nstateDiagram-v2\n  [*] --> Ready\n```'
  )

  await openDocument(page, '')
  await editor.click()
  await clipboard(editor, 'paste', {
    'text/plain': 'export const Card = () => <section>Hi</section>\nexport default Card\n',
    'text/html':
      '<div style="white-space:pre"><div><span>export const Card = () =&gt; &lt;section&gt;Hi&lt;/section&gt;</span></div></div>',
    'vscode-editor-data': JSON.stringify({ version: 1, mode: 'typescriptreact' })
  })
  await expect(page.locator('.editor-content pre[data-language="tsx"]')).toContainText('export const Card')
  await expectMarkdown(page, '```tsx\nexport const Card = () => <section>Hi</section>\nexport default Card\n```')

  const previewUrl = `${baseURL}/resource-preview.html`
  await openDocument(page, '')
  await editor.click()
  await clipboard(editor, 'paste', {
    'text/plain': `<iframe src="${previewUrl}" height="320" title="Preview demo"></iframe>`
  })
  const embedBlock = page.locator('.editor-content .resource-block[data-kind="embed"][data-view="preview"]')
  await expect(embedBlock).toHaveCount(1)
  await expect(embedBlock.locator('iframe')).toHaveAttribute('src', previewUrl)
  await expectMarkdown(page, `<embed height="320" href="${previewUrl}" title="Preview demo" />`)
})
