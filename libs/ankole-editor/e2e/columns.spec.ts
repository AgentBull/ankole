import { caret, clipboard, expect, openDocument, reopen, selectText, test } from './helpers'

const two =
  '<columns>\n  <column>\n    Left\n\n    Left second\n  </column>\n  <column>\n    Right\n  </column>\n</columns>\n\nAfter'

test('whole-block selection crosses columns, nests together and deletes without merging columns', async ({ page }) => {
  await openDocument(page, two.replace('    Right\n', '    Right\n\n    Right second\n'))
  const columns = page.locator('.editor-column')
  const selected = page.locator('.editor-selected-block')
  await caret(columns.first().locator('p').last(), 0)
  await page.keyboard.press('Escape')
  await page.keyboard.press('Shift+ArrowDown')
  await expect(selected).toHaveText(['Left second', 'Right'])
  await page.keyboard.press('Shift+Tab')
  await expect(columns.first().locator('p')).toHaveText(['Left', 'Left second'])
  await expect(columns.last().locator('p')).toHaveText(['Right', 'Right second'])
  await page.keyboard.press('Tab')
  await expect(columns.first().locator('.block-group > p')).toHaveText(['Left', 'Left second', 'Right'])
  await expect(columns.last().locator('p')).toHaveText(['Right second'])
  await expect(selected).toHaveText(['Left second', 'Right'])
  await page.keyboard.press('ControlOrMeta+z')
  await expect(columns.first().locator('p')).toHaveText(['Left', 'Left second'])
  await expect(columns.last().locator('p')).toHaveText(['Right', 'Right second'])
  await expect(selected).toHaveText(['Left second', 'Right'])
  await page.keyboard.press('Backspace')
  await expect(columns.first().locator('p')).toHaveText(['Left'])
  await expect(columns.last().locator('p')).toHaveText(['Right second'])
  await page.keyboard.press('ControlOrMeta+z')
  await expect(selected).toHaveText(['Left second', 'Right'])
  await reopen(page)
  await expect(columns.first().locator('p')).toHaveText(['Left', 'Left second'])
  await expect(columns.last().locator('p')).toHaveText(['Right', 'Right second'])
})

test('vertical text navigation visits every column and extends selections across column boundaries', async ({
  page
}) => {
  await openDocument(page, `Before\n\n${two}`)
  const columns = page.locator('.editor-column')
  const selection = () =>
    page.evaluate(() => {
      const selected = window.getSelection()!
      return {
        anchor: selected.anchorNode?.textContent,
        anchorOffset: selected.anchorOffset,
        focus: selected.focusNode?.textContent,
        focusOffset: selected.focusOffset
      }
    })
  await caret(columns.first().locator('p').last(), 0)
  await page.keyboard.press('ArrowDown')
  await expect.poll(selection).toMatchObject({ focus: 'Right', focusOffset: 0 })
  await page.keyboard.press('ArrowDown')
  await expect.poll(selection).toMatchObject({ focus: 'After', focusOffset: 0 })
  await page.keyboard.press('ArrowUp')
  await expect.poll(selection).toMatchObject({ focus: 'Right', focusOffset: 0 })
  await columns.last().locator('p').click()
  await page.keyboard.press('Home')
  await page.keyboard.press('ArrowUp')
  await expect.poll(selection).toMatchObject({ focus: 'Left second', focusOffset: 11 })
  await columns.last().locator('p').click()
  await page.keyboard.press('Home')
  await page.keyboard.press('Shift+ArrowUp')
  await expect
    .poll(selection)
    .toMatchObject({ anchor: 'Right', anchorOffset: 0, focus: 'Left second', focusOffset: 11 })
  await page.keyboard.press('Shift+ArrowDown')
  await expect.poll(selection).toMatchObject({ anchor: 'Right', anchorOffset: 0, focus: 'Right', focusOffset: 0 })
  await caret(columns.first().locator('p').first(), 0)
  await page.keyboard.press('ArrowUp')
  await expect.poll(selection).toMatchObject({ focus: 'Before', focusOffset: 0 })

  // A line inside a paragraph takes precedence over moving to the next column.
  await caret(columns.first().locator('p').last(), 'end')
  await page.keyboard.press('Shift+Enter')
  await page.keyboard.insertText('Last line')
  await page.keyboard.press('Home')
  await page.keyboard.press('ArrowUp')
  await expect.poll(selection).toMatchObject({ focus: 'Left second', focusOffset: 0 })
  await page.keyboard.press('ArrowDown')
  await expect.poll(selection).toMatchObject({ focus: 'Last line', focusOffset: 0 })
  await page.keyboard.press('ArrowDown')
  await expect.poll(selection).toMatchObject({ focus: 'Right', focusOffset: 0 })
})

test('Backspace and Delete join text across columns and undo restores the removed column', async ({ page }) => {
  await openDocument(page, two)
  const columns = page.locator('.editor-column')
  const paragraphs = page.locator('.editor-content > p')
  await caret(columns.last().locator('p'), 0)
  await page.keyboard.press('Backspace')
  await expect(columns).toHaveCount(0)
  await expect(paragraphs).toHaveText(['Left', 'Left secondRight', 'After'])
  await page.keyboard.press('ControlOrMeta+z')
  await expect(columns.first().locator('p')).toHaveText(['Left', 'Left second'])
  await expect(columns.last().locator('p')).toHaveText(['Right'])
  await caret(columns.first().locator('p').last())
  await page.keyboard.press('Delete')
  await expect(columns).toHaveCount(0)
  await expect(paragraphs).toHaveText(['Left', 'Left secondRight', 'After'])
  await reopen(page)
})

test('insertion creates editable columns, supports keyboard editing and saves the layout', async ({ page }) => {
  await openDocument(page, 'Before\n\n<p />')
  await page.locator('.editor-content > p').last().click()
  await page.keyboard.type('/2 columns')
  await page.getByRole('option', { name: /两栏/ }).click()
  const columns = page.locator('.editor-content .editor-column')
  await expect(columns).toHaveCount(2)
  await page.keyboard.insertText('Left')
  await columns.nth(1).locator('p').click()
  await page.keyboard.insertText('Right')
  const left = (await columns.first().boundingBox())!
  const right = (await columns.last().boundingBox())!
  expect(right.x).toBeGreaterThan(left.x + left.width)
  expect(Math.abs(left.y - right.y)).toBeLessThan(2)
  await page.keyboard.press('Enter')
  await page.keyboard.insertText('Right second')
  await expect(columns.nth(1).locator('p')).toHaveText(['Right', 'Right second'])
  await reopen(page)
  await expect(columns.nth(1).locator('p')).toHaveText(['Right', 'Right second'])
  await page.setViewportSize({ width: 390, height: 844 })
  const mobileLeft = (await columns.first().boundingBox())!
  const mobileRight = (await columns.last().boundingBox())!
  expect(mobileRight.y).toBeGreaterThanOrEqual(mobileLeft.y + mobileLeft.height)
  expect(mobileRight.x).toBe(mobileLeft.x)
})

test('dragging to a side creates columns; dragging back below the row restores one column', async ({ page }) => {
  await openDocument(page, 'Left\n\nRight\n\nAfter')
  await page.locator('.editor-content > p').nth(1).hover()
  const grip = (await page.getByRole('button', { name: 'Block 菜单', exact: true }).boundingBox())!
  const left = (await page.locator('.editor-content > p').first().boundingBox())!
  await page.mouse.move(grip.x + grip.width / 2, grip.y + grip.height / 2)
  await page.mouse.down()
  await page.mouse.move(left.x + left.width - 2, left.y + left.height / 2, { steps: 16 })
  await page.mouse.move(left.x + left.width - 1, left.y + left.height / 2)
  await expect(page.locator('.drag-line')).toHaveCSS('width', '2px')
  await expect(page.locator('.drag-line')).toHaveCSS('opacity', '1')
  await page.mouse.up()
  const columns = page.locator('.editor-column')
  await expect(columns).toHaveText(['Left', 'Right'])
  await columns.nth(1).locator('p').hover()
  const nextGrip = (await page.getByRole('button', { name: 'Block 菜单', exact: true }).boundingBox())!
  const after = (await page.locator('.editor-content > p').last().boundingBox())!
  await page.mouse.move(nextGrip.x + nextGrip.width / 2, nextGrip.y + nextGrip.height / 2)
  await page.mouse.down()
  await page.mouse.move(after.x + 4, after.y + after.height - 1, { steps: 16 })
  await page.mouse.move(after.x + 5, after.y + after.height - 1)
  await page.mouse.up()
  await expect(columns).toHaveCount(0)
  await expect(page.locator('.editor-content > p')).toHaveText(['Left', 'After', 'Right'])
  await page.keyboard.press('ControlOrMeta+z')
  await expect(columns).toHaveText(['Left', 'Right'])
})

test('column resizing previews, cancels, commits as one undo step and persists', async ({ page }) => {
  await openDocument(page, two)
  const columns = page.locator('.editor-column')
  const before = (await columns.first().boundingBox())!.width
  const separator = page.getByRole('separator', { name: '调整列宽' })
  const box = (await separator.boundingBox())!
  await page.mouse.move(box.x + 6, box.y + 15)
  await page.mouse.down()
  await page.mouse.move(box.x + 86, box.y + 15, { steps: 10 })
  await expect.poll(async () => (await columns.first().boundingBox())!.width).toBeGreaterThan(before + 60)
  await expect.poll(async () => (await separator.boundingBox())!.x).toBeGreaterThan(box.x + 60)
  await page.keyboard.press('Escape')
  await page.mouse.up()
  await expect.poll(async () => (await columns.first().boundingBox())!.width).toBeCloseTo(before, 0)
  await page.mouse.move(box.x + 6, box.y + 15)
  await page.mouse.down()
  await page.mouse.move(box.x + 86, box.y + 15, { steps: 10 })
  await page.mouse.up()
  await expect(columns.first()).toHaveAttribute('data-column-width', /\d+/)
  const resized = (await columns.first().boundingBox())!.width
  await reopen(page)
  expect((await columns.first().boundingBox())!.width).toBeCloseTo(resized, 0)
  await separator.focus()
  await page.keyboard.press('ArrowLeft')
  await expect.poll(async () => (await columns.first().boundingBox())!.width).toBeLessThan(resized)
  await page.keyboard.press('ControlOrMeta+z')
  await expect.poll(async () => (await columns.first().boundingBox())!.width).toBeCloseTo(resized, 0)
  await page.keyboard.press('ControlOrMeta+Shift+z')
  await expect.poll(async () => (await columns.first().boundingBox())!.width).toBeLessThan(resized)
})

test('menus and clipboard inside columns target their own block', async ({ page }) => {
  await openDocument(page, two)
  const columns = page.locator('.editor-column')
  await caret(columns.last().locator('p'))
  await page.keyboard.press('ControlOrMeta+/')
  await page.getByRole('menuitem', { name: '创建副本', exact: true }).click()
  await expect(columns.last().locator('p')).toHaveText(['Right', 'Right'])
  await page.keyboard.press('Backspace')
  await expect(columns.last().locator('p')).toHaveText(['Right'])
  await page.keyboard.press('ControlOrMeta+Home')
  await page.keyboard.press('Escape')
  await page.keyboard.press('ControlOrMeta+a')
  const copied = await clipboard(page.locator('.editor-content'), 'copy')
  expect(copied['text/html']).toContain('editor-columns')
  await reopen(page)
})

test('a marquee across columns excludes untouched blocks when copying, cutting and pasting', async ({ page }) => {
  await openDocument(page, two.replace('    Right\n', '    Right\n\n    Right second\n'))
  const body = page.locator('.editor-content')
  const columns = page.locator('.editor-column')
  const choose = async () => {
    const left = (await columns.first().locator('p').first().boundingBox())!
    const right = (await columns.last().locator('p').first().boundingBox())!
    await page.mouse.move(left.x - 65, left.y + 2)
    await page.mouse.down()
    await page.mouse.move(right.x + 80, right.y + right.height - 2, { steps: 16 })
    await page.mouse.up()
    await expect(page.locator('.editor-selected-block')).toHaveText(['Left', 'Right'])
  }
  await choose()
  const copied = await clipboard(body, 'cut')
  expect(copied['text/plain']).toContain('Left')
  expect(copied['text/plain']).toContain('Right')
  expect(copied['text/plain']).not.toContain('second')
  await expect(columns).toHaveText(['Left second', 'Right second'])
  await page.keyboard.press('ControlOrMeta+z')
  await expect(columns.first().locator('p')).toHaveText(['Left', 'Left second'])
  await expect(columns.last().locator('p')).toHaveText(['Right', 'Right second'])
  await choose()
  await clipboard(body, 'paste', { 'text/plain': 'Replacement' })
  await expect(columns.first().locator('p')).toHaveText(['Replacement', 'Left second'])
  await expect(columns.last().locator('p')).toHaveText(['Right second'])
  await reopen(page)
})

test('a text range into the next column joins its text, keeps both columns and undoes in steps', async ({ page }) => {
  await openDocument(page, two.replace('    Right\n', '    Right\n\n    Right second\n'))
  const columns = page.locator('.editor-column')
  await selectText(page, 'Left second', 4, 'Right', 2)
  await page.keyboard.press('Backspace')
  await expect(columns.first().locator('p')).toHaveText(['Left', 'Leftght'])
  await expect(columns.last().locator('p')).toHaveText(['Right second'])
  await page.keyboard.press('Enter')
  await expect(columns.first().locator('p')).toHaveText(['Left', 'Left', 'ght'])
  await page.keyboard.press('ControlOrMeta+z')
  await expect(columns.first().locator('p')).toHaveText(['Left', 'Leftght'])
  await page.keyboard.press('ControlOrMeta+z')
  await expect(columns.first().locator('p')).toHaveText(['Left', 'Left second'])
  await expect(columns.last().locator('p')).toHaveText(['Right', 'Right second'])
  await reopen(page)
})
