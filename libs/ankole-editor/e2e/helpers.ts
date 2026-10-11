import { expect, test as base, type Locator, type Page } from '@playwright/test'

export const test = base.extend<{ browserErrors: void }>({
  browserErrors: [
    async ({ page, browser }, use, info) => {
      info.annotations.push({ type: 'browser-version', description: browser.version() })
      if (info.project.name === 'chromium126') expect(browser.version()).toMatch(/^126\./)
      const errors: string[] = []
      page.on('pageerror', error => errors.push(error.message))
      page.on('console', message => {
        if (message.type() === 'error') errors.push(message.text())
      })
      await use()
      expect(errors, 'Browser errors').toEqual([])
    },
    { auto: true }
  ]
})
export { expect }

// These events exercise browser clipboard handlers, not the operating system clipboard. A paste
// event from a script has no `beforeinput` after it: the editor handles the paste event itself. The
// helper returns after the editor draws the change.
export async function clipboard(target: Locator, type: 'copy' | 'cut' | 'paste', values: Record<string, string> = {}) {
  return target.evaluate(
    async (element, { type, values }) => {
      const event = new ClipboardEvent(type, { clipboardData: new DataTransfer(), bubbles: true, cancelable: true })
      // Firefox creates its own data store for a constructed ClipboardEvent.
      const data = event.clipboardData!
      for (const [mime, value] of Object.entries(values)) data.setData(mime, value)
      element.dispatchEvent(event)
      const result = Object.fromEntries([...data.types].map(mime => [mime, data.getData(mime)]))
      // The editor draws in an animation frame.
      await new Promise(resolve => requestAnimationFrame(resolve))
      return result
    },
    { type, values }
  )
}

export async function selectText(
  page: Page,
  anchorText: string,
  anchorOffset: number,
  focusText: string,
  focusOffset: number
) {
  await page.locator('.editor-content').evaluate(
    (element, { anchorText, anchorOffset, focusText, focusOffset }) => {
      const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
      const texts: Text[] = []
      while (walker.nextNode()) texts.push(walker.currentNode as Text)
      const anchor = texts.find(node => node.data === anchorText)
      const focus = texts.find(node => node.data === focusText)
      if (!anchor || !focus) throw new Error('Selection text is missing')
      ;(element as HTMLElement).focus()
      window.getSelection()!.setBaseAndExtent(anchor, anchorOffset, focus, focusOffset)
      document.dispatchEvent(new Event('selectionchange'))
    },
    { anchorText, anchorOffset, focusText, focusOffset }
  )
}

export async function showSource(page: Page) {
  const source = page.getByRole('textbox', { name: 'Markdown 源码' })
  if (!(await source.isVisible())) await page.getByRole('button', { name: 'Markdown', exact: true }).click()
  return source
}

export async function replaceDocument(page: Page, markdown: string) {
  const source = await showSource(page)
  // The same source makes no draft to apply.
  if ((await source.inputValue()) !== markdown) {
    await source.fill(markdown)
    await page.getByRole('button', { name: '应用修改', exact: true }).click()
    await expect(page.locator('.notice')).toContainText('Markdown 已应用')
  }
  await page.getByRole('button', { name: '关闭 Markdown', exact: true }).click()
}

export async function openDocument(page: Page, markdown: string) {
  await page.goto('/')
  await replaceDocument(page, markdown)
}

// The source panel shows the Markdown that the page saves.
export async function expectMarkdown(page: Page, markdown: string) {
  await expect(await showSource(page)).toHaveValue(markdown)
  await page.getByRole('button', { name: '关闭 Markdown', exact: true }).click()
}

export async function reopen(page: Page) {
  await showSource(page)
  await page.getByRole('button', { name: '往返验证', exact: true }).click()
  await expect(page.locator('.notice')).toContainText('往返一致')
  await page.getByRole('button', { name: '关闭 Markdown', exact: true }).click()
}

// The DOM selection is set directly, without editor commands.
export async function caret(target: Locator, offset: number | 'end' = 'end') {
  await target.evaluate((element, offset) => {
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
    const texts: Text[] = []
    while (walker.nextNode()) texts.push(walker.currentNode as Text)
    const text = offset === 'end' ? texts.at(-1) : texts[0]
    if (!text) throw new Error('The caret target has no text')
    const range = document.createRange()
    range.setStart(text, offset === 'end' ? text.length : offset)
    range.collapse(true)
    const editor = element.closest<HTMLElement>('[contenteditable="true"]')
    editor?.focus()
    window.getSelection()!.removeAllRanges()
    window.getSelection()!.addRange(range)
    document.dispatchEvent(new Event('selectionchange'))
  }, offset)
}

export async function selectDocument(page: Page) {
  const editor = page.getByRole('textbox', { name: '文档编辑器', exact: true })
  await editor.focus()
  await editor.press('ControlOrMeta+a')
  // The first ⌘A selects the text of the current block, the second the document.
  await editor.press('ControlOrMeta+a')
}
