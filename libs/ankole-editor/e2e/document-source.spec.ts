import { readFile } from 'node:fs/promises'
import { caret, clipboard, expect, openDocument, selectDocument, showSource, test } from './helpers'

test('XML source applies attributes and unknown trees, survives undo, download and reload', async ({ page }) => {
  await openDocument(page, 'Before')
  await showSource(page)
  await page.getByRole('button', { name: 'XML 格式', exact: true }).click()
  const source = page.getByRole('textbox', { name: 'XML 源码' })
  const xml =
    '<page><p/><p source="manual" align="center">hello</p><widget __proto__="own">before<part x="0"/>after</widget></page>'
  await source.fill(xml)
  await page.getByRole('button', { name: '应用修改', exact: true }).click()
  await expect(page.locator('.notice')).toContainText('XML 已应用')
  const canonical = await source.inputValue()
  const independent = await page.evaluate(xml => {
    const doc = new DOMParser().parseFromString(xml, 'application/xml')
    const widget = doc.querySelector('widget')!
    return {
      errors: doc.querySelectorAll('parsererror').length,
      paragraphs: doc.querySelectorAll('p').length,
      own: widget.getAttribute('__proto__'),
      order: [...widget.childNodes].map(node => (node.nodeType === Node.TEXT_NODE ? node.nodeValue : node.nodeName))
    }
  }, canonical)
  expect(independent).toEqual({ errors: 0, paragraphs: 2, own: 'own', order: ['before', 'part', 'after'] })
  await page.getByRole('button', { name: '关闭 XML', exact: true }).click()
  await expect(page.locator('.editor-content > p')).toHaveCount(2)
  await expect(page.locator('.editor-content > p').nth(1)).toHaveCSS('text-align', 'center')
  await page.getByRole('button', { name: '撤销', exact: true }).click()
  await expect(page.locator('.editor-content')).toHaveText('Before')
  await page.getByRole('button', { name: '重做', exact: true }).click()
  await page.getByRole('button', { name: 'Markdown', exact: true }).click()
  await expect(source).toHaveValue(canonical)
  await page.getByRole('button', { name: '往返验证', exact: true }).click()
  await expect(page.locator('.notice')).toContainText('往返一致')
  const downloadEvent = page.waitForEvent('download')
  await page.getByRole('button', { name: '导出', exact: true }).click()
  const file = await downloadEvent
  expect(file.suggestedFilename()).toBe('block-lab.xml')
  expect(await readFile((await file.path())!, 'utf8')).toBe(canonical)
  await expect(page.locator('.save-state')).toContainText('已保存')
  await page.reload()
  await showSource(page)
  await page.getByRole('button', { name: 'XML 格式', exact: true }).click()
  await expect(page.getByRole('textbox', { name: 'XML 源码' })).toHaveValue(canonical)
})

test('invalid XML and duplicate Markdown attributes keep the draft and last valid page', async ({ page }) => {
  await openDocument(page, 'Keep this')
  await showSource(page)
  await page.getByRole('button', { name: 'XML 格式', exact: true }).click()
  const source = page.getByRole('textbox', { name: 'XML 源码' })
  await source.fill('<page><p source="a" source="b">invalid</p></page>')
  await page.getByRole('button', { name: '应用修改', exact: true }).click()
  await expect(page.locator('.notice')).toContainText('无法应用')
  await expect(source).toHaveValue('<page><p source="a" source="b">invalid</p></page>')
  await expect(page.locator('.editor-content')).toHaveText('Keep this')
  await page.getByRole('button', { name: '放弃修改', exact: true }).click()
  await page.getByRole('button', { name: 'Markdown 格式', exact: true }).click()
  const md = page.getByRole('textbox', { name: 'Markdown 源码' })
  await md.fill('<p source="a" source="b">text</p>')
  await page.getByRole('button', { name: '应用修改', exact: true }).click()
  await expect(page.locator('.notice')).toContainText('重复属性')
  await expect(page.locator('.editor-content')).toHaveText('Keep this')
})

test('source composition keeps its buffer and disables apply, discard and format switching', async ({ page }) => {
  await openDocument(page, 'Keep this')
  const source = await showSource(page)
  await source.fill('候选文字')
  await source.dispatchEvent('compositionstart', { data: '', bubbles: true })
  await source.dispatchEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 229, isComposing: true, bubbles: true })
  await source.dispatchEvent('keydown', {
    key: 'Escape',
    code: 'Escape',
    keyCode: 229,
    isComposing: true,
    bubbles: true
  })
  await expect(page.getByRole('button', { name: '应用修改', exact: true })).toBeDisabled()
  await expect(page.getByRole('button', { name: '放弃修改', exact: true })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'XML 格式', exact: true })).toBeDisabled()
  await expect(source).toHaveValue('候选文字')
  await expect(page.locator('.editor-content')).toHaveText('Keep this')
  await source.dispatchEvent('compositionend', { data: '候选文字', bubbles: true })
  await page.getByRole('button', { name: '应用修改', exact: true }).click()
  await expect(page.locator('.editor-content')).toHaveText('候选文字')
})

test('a source line break shows as a space and attributes survive browser clipboard edits', async ({ page }) => {
  await openDocument(page, '<p source="manual">first\nsecond</p>')
  const body = page.locator('.editor-content')
  await expect(body.locator('br')).toHaveCount(0)
  await expect(body).toHaveText('first second')
  await selectDocument(page)
  const copied = await clipboard(body, 'copy')
  await clipboard(body, 'paste', copied)
  await caret(body.locator('p'), 'end')
  await page.keyboard.insertText('!')
  await showSource(page)
  await page.getByRole('button', { name: 'XML 格式', exact: true }).click()
  await expect(page.getByRole('textbox', { name: 'XML 源码' })).toHaveValue(
    '<page><p source="manual">first second!</p></page>'
  )
})

test('opens XML files by extension and derives Markdown from the applied page', async ({ page }) => {
  await openDocument(page, 'Old page')
  await showSource(page)
  await page.locator('input[type=file]').setInputFiles({
    name: 'page.xml',
    mimeType: 'application/xml',
    buffer: Buffer.from('<page><h2>Imported</h2><p note="0">body</p></page>')
  })
  await expect(page.getByRole('textbox', { name: 'XML 源码' })).toBeVisible()
  await page.getByRole('button', { name: '应用修改', exact: true }).click()
  await page.getByRole('button', { name: 'Markdown 格式', exact: true }).click()
  await expect(page.getByRole('textbox', { name: 'Markdown 源码' })).toHaveValue('## Imported\n\n<p note="0">body</p>')
})

test('list conversion keeps paragraph attributes through typing and a source reopen', async ({ page }) => {
  await openDocument(page, '<p source="manual">hello</p>')
  await caret(page.locator('.editor-content > p'), 'end')
  await page.keyboard.press('ControlOrMeta+/')
  await page.getByRole('menuitem', { name: '转换为', exact: true }).hover()
  await page.getByRole('menuitem', { name: /项目列表/ }).click()
  await caret(page.locator('.editor-content li p'), 'end')
  await page.keyboard.insertText('!')
  await expect(page.locator('.editor-content li')).toHaveText(['hello!'])
  await showSource(page)
  await page.getByRole('button', { name: 'XML 格式', exact: true }).click()
  await expect(page.getByRole('textbox', { name: 'XML 源码' })).toHaveValue(
    '<page><ul><li><p source="manual">hello!</p></li></ul></page>'
  )
  await page.getByRole('button', { name: '往返验证', exact: true }).click()
  await expect(page.locator('.notice')).toContainText('往返一致')
  await page.getByRole('button', { name: '关闭 XML', exact: true }).click()
  await caret(page.locator('.editor-content li p'), 'end')
  await page.keyboard.press('Enter')
  await page.keyboard.insertText('next')
  await expect(page.locator('.editor-content li')).toHaveText(['hello!', 'next'])
  for (const offset of [3, 2, 1, 0]) {
    await page.keyboard.press('ArrowLeft')
    await expect.poll(() => page.evaluate(() => window.getSelection()?.anchorOffset)).toBe(offset)
  }
  await page.keyboard.press('Backspace')
  await expect(page.locator('.editor-content')).toContainText('hello!')
  await expect(page.locator('.editor-content')).toContainText('next')
  await showSource(page)
  await expect(page.getByRole('textbox', { name: 'XML 源码' })).toHaveValue(/source="manual"/)
})

test('recovers invalid local source without replacing the stored bytes', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('ankole.block-lab.markdown.v2', '<callout>\nnot closed'))
  await page.goto('/')
  await expect(page.getByRole('textbox', { name: 'Markdown 源码' })).toHaveValue('<callout>\nnot closed')
  await expect(page.locator('.notice')).toContainText('本地存档需要修复')
  expect(await page.evaluate(() => localStorage.getItem('ankole.block-lab.markdown.v2'))).toBe('<callout>\nnot closed')
  await page.getByRole('textbox', { name: 'Markdown 源码' }).fill('<callout>\nrepaired\n</callout>')
  await page.getByRole('button', { name: '应用修改', exact: true }).click()
  await expect(page.locator('.notice')).toContainText('Markdown 已应用')
  await expect(page.locator('.callout')).toContainText('repaired')
})
