import { expect, test, caret, clipboard } from './helpers'

test.beforeEach(async ({ page }) => {
  await page.goto('/playground/embedded.html')
})

test('inline @ and ＠ triggers keep editor focus, switch tabs, suppress email false positives, and commit atomic mention chips', async ({
  page
}) => {
  const editor = page.getByRole('textbox', { name: 'First document', exact: true })
  const markdown = page.getByLabel('First Markdown', { exact: true })

  await caret(editor.locator('p').last())
  await page.keyboard.press('Enter')

  // Typing @ on an empty left-aligned paragraph mounts the inline ghost placeholder and opens the picker without stealing focus.
  await page.keyboard.type('@')
  await expect(editor).toBeFocused()
  await expect(editor.locator('[data-mention-placeholder="搜索页面或主体…"]')).toHaveCount(1)

  const menu = page.locator('.mention-menu')
  await expect(menu).toBeVisible()
  const tabs = menu.getByRole('tab')
  await expect(tabs).toHaveText(['全部', '页面', '主体'])
  await expect(tabs.nth(0)).toHaveAttribute('aria-selected', 'true')
  await expect(menu.locator('.mention-group-label')).toHaveText(['页面', '主体'])

  // Clicking a group header switches to that category tab while keeping focus in the editor.
  await menu.locator('.mention-group-label', { hasText: '主体' }).click()
  await expect(tabs.nth(2)).toHaveAttribute('aria-selected', 'true')
  await expect(menu.locator('.mention-group-label')).toHaveCount(0)
  await page.keyboard.press('Tab')
  await expect(tabs.nth(0)).toHaveAttribute('aria-selected', 'true')

  // Tab switches category tabs while keeping focus in the editor.
  await page.keyboard.press('Tab')
  await expect(tabs.nth(1)).toHaveAttribute('aria-selected', 'true')
  await expect(menu.getByRole('option')).toHaveCount(2)
  await page.keyboard.press('Tab')
  await expect(tabs.nth(2)).toHaveAttribute('aria-selected', 'true')
  await expect(menu.getByRole('option')).toHaveCount(2)
  await page.keyboard.press('Shift+Tab')
  await page.keyboard.press('Shift+Tab')
  await expect(tabs.nth(0)).toHaveAttribute('aria-selected', 'true')

  // Typing query characters removes the ghost placeholder immediately and highlights matched substring.
  await page.keyboard.type('Road')
  await expect(editor.locator('[data-mention-placeholder]')).toHaveCount(0)
  await expect(menu.locator('mark.mention-match')).toHaveText('Road')
  await page.keyboard.press('Enter')
  await expect(menu).toHaveCount(0)
  await expect(editor.locator('[data-mention-page="019a2b00-0000-7000-8000-000000000101"]')).toHaveText(
    'Product Roadmap'
  )

  // Clicking a committed page mention invokes host.openPage.
  await editor.locator('[data-mention-page="019a2b00-0000-7000-8000-000000000101"] a').click()
  await expect(page.getByLabel('Opened page', { exact: true })).toHaveText('019a2b00-0000-7000-8000-000000000101')

  // Adjacent CJK + fullwidth ＠ triggers mention and single-click commits immediately (no two-step button).
  await caret(editor.locator('p').first())
  await page.keyboard.press('Enter')
  await page.keyboard.type('，由＠Research')
  await expect(menu).toBeVisible()
  await menu.getByRole('option').first().click()
  await expect(menu).toHaveCount(0)
  await expect(editor.locator('[data-mention-principal="agt_research_001"]')).toHaveText('@Research Agent')

  // Email addresses do not open the mention menu.
  await page.keyboard.type(' contact boris@agentbull.com')
  await expect(menu).toHaveCount(0)

  await expect(editor).toContainText('boris@agentbull.com')
  await expect(markdown).toContainText('<mention page="019a2b00-0000-7000-8000-000000000101" />')
  await expect(markdown).toContainText('<mention principal="agt_research_001" />')
})

test('slash menu /提及 converts to @ and atomic Backspace + Undo round-trips cleanly, while bare internal URL paste creates a page mention', async ({
  page
}) => {
  const editor = page.getByRole('textbox', { name: 'First document', exact: true })
  const markdown = page.getByLabel('First Markdown', { exact: true })

  await caret(editor.locator('p').last())
  await page.keyboard.press('Enter')
  await page.keyboard.type('/提及')
  const slash = page.locator('.slash-menu')
  await expect(slash).toBeVisible()
  await page.keyboard.press('Enter')

  const menu = page.locator('.mention-menu')
  await expect(menu).toBeVisible()
  await page.keyboard.type('Alice')
  await page.keyboard.press('Enter')
  await expect(editor.locator('[data-mention-principal="usr_alice_001"]')).toHaveCount(1)

  // Atomic 1-step Backspace deletes the whole chip, and Undo restores it in 1 step.
  await page.keyboard.press('Backspace')
  await expect(editor.locator('[data-mention-principal="usr_alice_001"]')).toHaveCount(0)
  await page.keyboard.press('ControlOrMeta+z')
  await expect(editor.locator('[data-mention-principal="usr_alice_001"]')).toHaveCount(1)

  // Pasting a bare internal page URL converts into a <mention page="..." /> chip.
  await page.keyboard.type(' ')
  await clipboard(editor, 'paste', { 'text/plain': 'https://ankole.test/p/019a2b00-0000-7000-8000-000000000102' })
  await expect(editor.locator('[data-mention-page="019a2b00-0000-7000-8000-000000000102"]')).toHaveText('季度复盘报告')
  await expect(markdown).toContainText('<mention page="019a2b00-0000-7000-8000-000000000102" />')
})
