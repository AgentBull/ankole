import type { Page } from '@playwright/test'
import {
  clipboard,
  expect,
  openDocument,
  reopen,
  replaceDocument,
  selectDocument,
  selectText,
  showSource,
  test
} from './helpers'

const source = 'pm-view:test/webtest-clipboard.ts:'

// Line breaks in the page. The editor DOM can hold an extra trailing <br> that keeps an empty last
// line visible.
async function lineBreaks(page: Page) {
  const source = await (await showSource(page)).inputValue()
  await page.getByRole('button', { name: '关闭 Markdown', exact: true }).click()
  return source.split('<br />').length - 1
}

test.afterEach(async ({ page }, info) => {
  if (info.status !== info.expectedStatus) {
    await info.attach('editor-dom', {
      body: await page.locator('.editor-content').innerHTML(),
      contentType: 'text/html'
    })
  }
})

for (const fixture of [
  { line: 44, name: 'paragraph and rule', html: '<p>hello</p><hr>', blocks: ['P', 'HR'], text: 'hello' },
  { line: 44, name: 'paragraph and bare text', html: '<p>hello</p>bar', blocks: ['P', 'P'], text: 'hellobar' },
  {
    line: 50,
    name: 'list and bare text with a break',
    html: '<ul><li>foo</li></ul>bar<br>baz',
    blocks: ['UL', 'P'],
    text: 'foobarbaz'
  },
  {
    line: 50,
    name: 'list and trailing break before paragraph',
    html: '<ul><li>foo</li></ul>bar<br><p>x</p>',
    blocks: ['UL', 'P', 'P'],
    text: 'foobarx'
  },
  {
    line: 50,
    name: 'orphan list items',
    html: '<li>foo</li><li>bar</li><p>x</p>',
    blocks: ['UL', 'P'],
    text: 'foobarx'
  },
  // HTML layout collapses the leading space after br. The break and marks remain observable.
  {
    line: 60,
    name: 'break inside bold [HTML whitespace adaptation]',
    html: '<p><strong>a<br></strong> b</p>',
    blocks: ['P'],
    text: 'ab'
  }
]) {
  test(`${source}${fixture.line} ${fixture.name}`, async ({ page }) => {
    await openDocument(page, 'Replace me')
    await selectDocument(page)
    await clipboard(page.locator('.editor-content'), 'paste', { 'text/html': fixture.html })
    const body = page.locator('.editor-content')
    await expect(body).toHaveText(fixture.text)
    const tags = () =>
      body.evaluate(element => [...element.children].map(child => (child.querySelector('hr') ? 'HR' : child.tagName)))
    expect(await tags()).toEqual(fixture.blocks)
    if (fixture.html.includes('<br>')) expect(await lineBreaks(page)).toBe(1)
    if (fixture.line === 60) await expect(body.locator('strong')).toHaveText('a')
    await reopen(page)
    expect(await tags()).toEqual(fixture.blocks)
    await expect(body).toHaveText(fixture.text)
    if (fixture.html.includes('<br>')) expect(await lineBreaks(page)).toBe(1)
  })
}

test(`${source}10 copies only the selected rule`, async ({ page }) => {
  await openDocument(page, '> a\n>\n> ---\n\nb')
  await page.locator('.editor-content hr').evaluate(element => {
    element.closest<HTMLElement>('[contenteditable=true]')!.focus()
    const range = document.createRange()
    range.selectNode(element)
    window.getSelection()!.removeAllRanges()
    window.getSelection()!.addRange(range)
    document.dispatchEvent(new Event('selectionchange'))
  })
  const data = await clipboard(page.locator('.editor-content'), 'copy')
  expect(data['text/html']).toContain('<hr')
  expect(data['text/plain']).not.toMatch(/[ab]/)
  await replaceDocument(page, 'Replace me')
  await selectDocument(page)
  await clipboard(page.locator('.editor-content'), 'paste', data)
  await expect(page.locator('.editor-content hr')).toHaveCount(1)
  await expect(page.locator('.editor-content')).not.toContainText('a')
  await expect(page.locator('.editor-content')).not.toContainText('b')
})

// A list item is copied only when the selection covers all of its text, as in Notion. The selection
// ends in the item's second paragraph: the first pasted paragraph joins the text before the caret,
// the second the text after it.
test(`${source}18 partial list text pastes inline [Notion adaptation]`, async ({ page }) => {
  await openDocument(page, '> - foo\n>\n>   bar')
  await selectText(page, 'foo', 2, 'bar', 1)
  const data = await clipboard(page.locator('.editor-content'), 'copy')
  expect(data['text/html']).not.toContain('<li')
  await replaceDocument(page, 'Target here')
  await selectText(page, 'Target here', 7, 'Target here', 7)
  await clipboard(page.locator('.editor-content'), 'paste', data)
  await expect(page.locator('.editor-content')).toHaveText('Target obhere')
  await expect(page.locator('.editor-content > *')).toHaveText(['Target o', 'bhere'])
  await expect(page.locator('.editor-content li')).toHaveCount(0)
  await reopen(page)
})

test(`${source}28 retains nested quote context on copy and paste`, async ({ page }) => {
  await openDocument(page, '> > foo')
  await selectDocument(page)
  const data = await clipboard(page.locator('.editor-content'), 'copy')
  await replaceDocument(page, 'Replace me')
  await selectDocument(page)
  await clipboard(page.locator('.editor-content'), 'paste', data)
  await expect(page.locator('.editor-content blockquote blockquote')).toHaveText('foo')
  await reopen(page)
})

test(`${source}117 parses a table wrapped in fragment comments`, async ({ page }) => {
  await openDocument(page, 'Replace me')
  await selectDocument(page)
  await clipboard(page.locator('.editor-content'), 'paste', {
    'text/html':
      '<html><body><!--StartFragment--><table data-pm-slice="1 1 -2 []"><tbody><tr><td class="PROSEMIRROR_TABLE_TD_CLS" align="left"><p>123</p></td></tr><tr><td class="PROSEMIRROR_TABLE_TD_CLS" align="left"><p>123</p></td></tr></tbody></table><!--EndFragment--></body></html>'
  })
  await expect(page.locator('.editor-content table tr')).toHaveCount(2)
  await expect(page.locator('.editor-content table td')).toHaveText(['123', '123'])
  await reopen(page)
  await expect(page.locator('.editor-content table tr')).toHaveCount(2)
  await expect(page.locator('.editor-content table td')).toHaveText(['123', '123'])
  await expect(page.locator('.editor-content table')).not.toContainText('StartFragment')
})

test(`${source}104 includes table wrappers when a cell is copied`, async ({ page }) => {
  await openDocument(page, 'Replace me')
  await selectDocument(page)
  await clipboard(page.locator('.editor-content'), 'paste', {
    'text/html': '<table><tr><td>A</td><td>B</td></tr></table>'
  })
  await selectText(page, 'A', 0, 'A', 1)
  const data = await clipboard(page.locator('.editor-content'), 'copy')
  expect(data['text/html']).toContain('<table')
  expect(data['text/html']).not.toContain('>B<')
  await replaceDocument(page, 'Replace me')
  await selectDocument(page)
  await clipboard(page.locator('.editor-content'), 'paste', data)
  await expect(page.locator('.editor-content table')).toHaveText('A')
  await reopen(page)
})
