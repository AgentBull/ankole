import { clipboard, expect, openDocument, reopen, selectDocument, selectText, test } from './helpers'

// Based on the DOM ambiguity discussed in Medium Engineering's 2014 article.
// These are local regression fixtures, not copied tests from that article.
for (const html of [
  '<p><strong><em>one</em></strong></p>',
  '<p><i><b>one</b></i></p>',
  '<p><span style="font-weight:bold;font-style:italic">one</span></p>',
  '<div><b><span></span><i>o<span>n</span>e</i><span></span></b></div>'
]) {
  test(`equivalent DOM imports, edits and reopens with the same character formats: ${html}`, async ({ page }) => {
    await openDocument(page, 'Replace me')
    await selectDocument(page)
    const body = page.locator('.editor-content')
    await clipboard(body, 'paste', { 'text/html': html })
    await expect(body).toHaveText('one')
    await selectText(page, 'one', 1, 'one', 2)
    await page.keyboard.insertText('X')
    for (const rebuilt of [false, true]) {
      if (rebuilt) await reopen(page)
      await expect(body).toHaveText('oXe')
      const characters = await body.evaluate(element => {
        const result: { character: string; bold: boolean; italic: boolean }[] = []
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
        while (walker.nextNode()) {
          const node = walker.currentNode as Text
          const style = getComputedStyle(node.parentElement!)
          for (const character of node.data) {
            result.push({ character, bold: Number(style.fontWeight) >= 600, italic: style.fontStyle === 'italic' })
          }
        }
        return result
      })
      expect(characters).toEqual([...'oXe'].map(character => ({ character, bold: true, italic: true })))
    }
  })
}
