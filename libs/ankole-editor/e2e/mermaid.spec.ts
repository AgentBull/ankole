import { caret, clipboard, expect, expectMarkdown, openDocument, reopen, test } from './helpers'

const source = 'flowchart TD\n  A[开始] --> B{是否继续?}'
const fence = (value: string) => `\`\`\`mermaid\n${value}\n\`\`\``
const taggedFence = (tag: string, value: string) =>
  `${tag}\n  \`\`\`mermaid\n${value
    .split('\n')
    .map(line => `  ${line}`)
    .join('\n')}\n  \`\`\`\n</mermaid>`

test('renders a Mermaid fence and updates the preview while editing', async ({ page }) => {
  await openDocument(page, fence(source))
  const block = page.locator('.mermaid-block')
  const pre = block.locator('.mermaid-pre')
  await expect(block).toHaveAttribute('data-view', 'both')
  await expect(block).toHaveAttribute('data-theme', 'auto')
  await expect(block.locator('.mermaid-preview svg')).toBeVisible({ timeout: 10_000 })
  await expect(block.locator('.mermaid-gutter')).toHaveText(/1\s*2/)

  await caret(pre, 'end')
  await page.keyboard.press('Enter')
  await page.keyboard.type('  B -->|是| C[处理]')
  await expect(block.locator('.mermaid-gutter')).toHaveText(/1\s*2\s*3/)
  await expectMarkdown(page, fence(`${source}\n  B -->|是| C[处理]`))
})

test('view and theme menus persist their choices', async ({ page }) => {
  await openDocument(page, fence(source))
  const block = page.locator('.mermaid-block')
  await page.locator('[data-mermaid-action="view"]').click()
  await page.getByRole('menuitemradio', { name: '仅展示图表' }).click()
  await expect(block).toHaveAttribute('data-view', 'diagram')
  await expect(block.locator('.mermaid-pre')).toBeHidden()
  await expect(block.locator('.mermaid-preview svg')).toBeVisible()

  await page.locator('[data-mermaid-action="theme"]').click()
  await page.getByRole('menuitemradio', { name: '深色' }).click()
  await expect(block).toHaveAttribute('data-theme', 'dark')

  await reopen(page)
  await expect(block).toHaveAttribute('data-view', 'diagram')
  await expect(block).toHaveAttribute('data-theme', 'dark')
  await expectMarkdown(page, taggedFence('<mermaid theme="dark" view="diagram">', source))

  await page.locator('[data-mermaid-action="view"]').click()
  await page.getByRole('menuitemradio', { name: '展示代码和图表' }).click()
  await page.locator('[data-mermaid-action="theme"]').click()
  await page.getByRole('menuitemradio', { name: '跟随主题' }).click()
  await expectMarkdown(page, fence(source))
})

test('templates replace the source in one step', async ({ page }) => {
  await openDocument(page, fence(source))
  await page.locator('[data-mermaid-action="template"]').click()
  await page.getByRole('menuitem', { name: '条件判断' }).click()
  await expect(page.locator('.mermaid-pre')).toContainText('是否继续')
  await expect(page.locator('.mermaid-preview svg')).toBeVisible()
  await expectMarkdown(
    page,
    fence('flowchart TD\n  A[开始] --> B{是否继续?}\n  B -->|是| C[处理]\n  B -->|否| D[结束]')
  )
})

test('the expanded diagram opens and closes with Escape', async ({ page }) => {
  await openDocument(page, fence(source))
  await page.locator('[data-mermaid-action="expand"]').click()
  await expect(page.locator('.mermaid-expanded')).toBeVisible()
  await expect(page.locator('.mermaid-expanded-close')).toBeFocused()
  await expect(page.locator('.mermaid-expanded-preview svg').first()).toBeVisible()
  await page.keyboard.press('Escape')
  await expect(page.locator('.mermaid-expanded')).toHaveCount(0)
})

test('the slash menu inserts an empty Mermaid block ready for typing', async ({ page }) => {
  await openDocument(page, 'Start')
  await caret(page.locator('.editor-content > p'))
  await page.keyboard.press('Enter')
  await page.keyboard.type('/mermaid')
  await page.getByRole('option', { name: /Mermaid/ }).click()
  const block = page.locator('.mermaid-block')
  await expect(block).toBeVisible()
  await expect(block.locator('.mermaid-placeholder')).toBeVisible()
  await page.keyboard.type('flowchart LR')
  await page.keyboard.press('Enter')
  await page.keyboard.type('  A[输入] --> B[输出]')
  await expect(block.locator('.mermaid-preview svg')).toBeVisible({ timeout: 10_000 })
  await expect(block.locator('.mermaid-gutter')).toHaveText(/1\s*2/)
  await expectMarkdown(page, `Start\n\n${fence('flowchart LR\n  A[输入] --> B[输出]')}\n\n<p />`)
})

test('a late mount cannot replace a newer preview layer', async ({ page }) => {
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'Only the development server serves source modules'
  )
  await page.goto('/')
  const modulePath = new URL('../src/blocks/mermaid/preview.ts', import.meta.url).pathname
  const result = await page.evaluate(async path => {
    const { MermaidPreview } = await import(new URL(`/@fs${path}`, location.origin).href)
    const root = document.createElement('div')
    document.body.append(root)
    const calls: { source: string; resolve: () => void }[] = []
    const mount = (host: HTMLElement, source: string) =>
      new Promise<any>(resolve => {
        const value = document.createElement('div')
        value.textContent = source
        host.append(value)
        calls.push({
          source,
          resolve: () =>
            resolve({
              source,
              error: undefined,
              destroy() {
                value.remove()
              },
              update(next: string) {
                value.textContent = next
              }
            })
        })
      })
    const preview = new MermaidPreview(root, false, mount)
    preview.setSource('old')
    await new Promise(resolve => setTimeout(resolve, 120))
    const first = root.textContent
    preview.setSource('new')
    await new Promise(resolve => setTimeout(resolve, 120))
    calls[0]!.resolve()
    await new Promise(resolve => setTimeout(resolve, 50))
    const afterLate = root.textContent
    calls[1]?.resolve()
    await new Promise(resolve => setTimeout(resolve, 50))
    preview.destroy()
    root.remove()
    return { first, afterLate, final: root.textContent, calls: calls.map(call => call.source) }
  }, modulePath)
  expect(result.first).toBe('old')
  expect(result.calls).toEqual(['old', 'new'])
  expect(result.afterLate).toBe('new')
  expect(result.final).toBe('')
})

test('formatting keys do not leave hidden marks in Mermaid source', async ({ page }) => {
  await openDocument(page, fence(source))
  const block = page.locator('.mermaid-block')
  await caret(block.locator('.mermaid-pre'), 0)
  await page.keyboard.press('ControlOrMeta+a')
  await page.keyboard.press('ControlOrMeta+b')
  await expect(block.locator('strong')).toHaveCount(0)
  await expectMarkdown(page, fence(source))
})

test('formatting pasted into Mermaid source is removed', async ({ page }) => {
  await openDocument(page, fence('flowchart LR'))
  const block = page.locator('.mermaid-block')
  const pre = block.locator('.mermaid-pre')
  await caret(pre, 0)
  await page.keyboard.press('ControlOrMeta+a')
  await clipboard(pre, 'paste', { 'text/html': '<strong>flowchart LR</strong>', 'text/plain': 'flowchart LR' })
  await expect(block.locator('strong')).toHaveCount(0)
  await expectMarkdown(page, fence('flowchart LR'))
})

test('toolbar actions target the clicked Mermaid block after typing when multiple default blocks exist', async ({
  page
}) => {
  await openDocument(page, `${fence('flowchart TD\n  A --> B')}\n\n${fence('flowchart LR\n  X --> Y')}`)
  const blocks = page.locator('.mermaid-block')
  const second = blocks.nth(1)

  await caret(second.locator('.mermaid-pre'), 'end')
  await page.keyboard.press('Enter')
  await page.keyboard.type('  Y --> Z')
  await second.locator('[data-mermaid-action="view"]').click()
  await page.getByRole('menuitemradio', { name: '仅展示图表' }).click()

  await expect(blocks.nth(0)).toHaveAttribute('data-view', 'both')
  await expect(second).toHaveAttribute('data-view', 'diagram')
  await expectMarkdown(
    page,
    `${fence('flowchart TD\n  A --> B')}\n\n${taggedFence('<mermaid view="diagram">', 'flowchart LR\n  X --> Y\n  Y --> Z')}`
  )
})

test('the Mermaid extension renders in a standalone Wordgard view and reuses empty placeholders across edits', async ({
  page
}) => {
  test.skip(
    !!process.env.E2E_CONSUMER_ROOT || process.env.E2E_PREVIEW === '1',
    'Only the development server serves source modules'
  )
  await openDocument(page, `Paragraph\n\n\`\`\`mermaid\n\`\`\``)
  const placeholder = page.locator('.mermaid-placeholder')
  await expect(placeholder).toBeVisible()
  await placeholder.evaluate(
    el => ((window as unknown as { __mermaidPlaceholder?: Element }).__mermaidPlaceholder = el)
  )
  await caret(page.locator('.editor-content > p'), 'end')
  await page.keyboard.type(' updated')
  const samePlaceholder = await placeholder.evaluate(
    el => (window as unknown as { __mermaidPlaceholder?: Element }).__mermaidPlaceholder === el
  )
  expect(samePlaceholder).toBe(true)

  const corePath = new URL('../src/core/editor/index.ts', import.meta.url).pathname
  const extPath = new URL('../src/editor/extension.ts', import.meta.url).pathname
  const standalone = await page.evaluate(
    async ({ core, ext }) => {
      const { Wordgard } = await import(new URL(`/@fs${core}`, location.origin).href)
      const { editorExtension, initialState } = await import(new URL(`/@fs${ext}`, location.origin).href)
      const host = document.createElement('div')
      document.body.append(host)
      const wg = Wordgard.create({
        state: initialState('```mermaid\nflowchart TD\n  A --> B\n```', [editorExtension()]),
        parent: host
      })
      const gutter = host.querySelector('.mermaid-gutter')?.textContent ?? ''
      await new Promise(resolve => setTimeout(resolve, 400))
      const hasSvg = Boolean(host.querySelector('.mermaid-preview svg'))
      wg.dom.remove()
      host.remove()
      return { gutter, hasSvg }
    },
    { core: corePath, ext: extPath }
  )
  expect(standalone.gutter).toBe('1\n2')
  expect(standalone.hasSvg).toBe(true)
})

test('pasting into a selected Mermaid block updates its source and keeps its block attributes, while whole-block copy still replaces', async ({
  page
}) => {
  await openDocument(page, `Intro\n\n${taggedFence('<mermaid theme="dark">', 'flowchart LR\n  X --> Y')}\n\nOutro`)
  const editor = page.getByRole('textbox', { name: '文档编辑器', exact: true })
  const block = page.locator('.mermaid-block')

  // Escape selects the Mermaid block as a whole block; pasting rich external HTML + text replaces its source.
  await caret(block.locator('.mermaid-pre'), 'end')
  await page.keyboard.press('Escape')
  await expect(block).toHaveClass(/editor-selected-block/)
  await clipboard(editor, 'paste', {
    'text/html': '<div style="color:#d4d4d4"><span>flowchart TD</span><br><span>  A[Start] --&gt; B[End]</span></div>',
    'text/plain': 'flowchart TD\n  A[Start] --> B[End]'
  })
  await expect(block).toHaveCount(1)
  await expect(block).toHaveAttribute('data-theme', 'dark')
  await expectMarkdown(
    page,
    `Intro\n\n${taggedFence('<mermaid theme="dark">', 'flowchart TD\n  A[Start] --> B[End]')}\n\nOutro`
  )

  // Duplicating with Mod+D selects the new Mermaid block; pasting updates the duplicate's source in place.
  await caret(block.locator('.mermaid-pre'), 'end')
  await editor.press('ControlOrMeta+d')
  const second = page.locator('.mermaid-block').nth(1)
  await expect(second).toHaveClass(/editor-selected-block/)
  await clipboard(editor, 'paste', { 'text/plain': 'flowchart LR\n  M --> N' })
  await expectMarkdown(
    page,
    `Intro\n\n${taggedFence('<mermaid theme="dark">', 'flowchart TD\n  A[Start] --> B[End]')}\n\n${taggedFence('<mermaid theme="dark">', 'flowchart LR\n  M --> N')}\n\nOutro`
  )

  // Switching the second block to diagram-only view and clicking its preview selects it as a whole block for paste.
  await second.locator('[data-mermaid-action="view"]').click()
  await page.getByRole('menuitemradio', { name: '仅展示图表' }).click()
  await expect(second).toHaveAttribute('data-view', 'diagram')
  await caret(page.locator('.editor-content > p').first(), 'end')
  await second.locator('.mermaid-preview').click()
  await expect(second).toHaveClass(/editor-selected-block/)
  await clipboard(editor, 'paste', { 'text/plain': 'flowchart TD\n  P --> Q' })
  await expect(second).toHaveClass(/editor-selected-block/)
  await expectMarkdown(
    page,
    `Intro\n\n${taggedFence('<mermaid theme="dark">', 'flowchart TD\n  A[Start] --> B[End]')}\n\n${taggedFence('<mermaid theme="dark" view="diagram">', 'flowchart TD\n  P --> Q')}\n\nOutro`
  )

  // Whole-block copy inside the editor still replaces the selected Mermaid block.
  await caret(page.locator('.editor-content > p').first(), 0)
  await editor.press('Escape')
  const copiedBlock = await clipboard(editor, 'copy')
  await second.locator('.mermaid-preview').click()
  await clipboard(editor, 'paste', copiedBlock)
  await expect(page.locator('.mermaid-block')).toHaveCount(1)
  await expectMarkdown(
    page,
    `Intro\n\n${taggedFence('<mermaid theme="dark">', 'flowchart TD\n  A[Start] --> B[End]')}\n\nIntro\n\nOutro`
  )
})

test('Mod+A and paste inside an empty Mermaid block keeps neighbors and never turns the Mermaid block into a paragraph', async ({
  page
}) => {
  await openDocument(page, 'Before\n\n```mermaid\n```\n\nAfter')
  const editor = page.getByRole('textbox', { name: '文档编辑器', exact: true })
  const pre = page.locator('.mermaid-block .mermaid-pre')

  await pre.click()
  await editor.press('ControlOrMeta+a')
  await clipboard(editor, 'paste', {
    'text/html': '<p>flowchart TD</p><p>  A --&gt; B</p>',
    'text/plain': 'flowchart TD\n  A --> B'
  })
  await expect(page.locator('.mermaid-block')).toHaveCount(1)
  await expectMarkdown(page, `Before\n\n${fence('flowchart TD\n  A --> B')}\n\nAfter`)

  // Even when an empty Mermaid block is the sole block on the page and Mod+A is pressed twice, paste enters Mermaid.
  await openDocument(page, '```mermaid\n```')
  await page.locator('.mermaid-block .mermaid-pre').click()
  await editor.press('ControlOrMeta+a')
  await editor.press('ControlOrMeta+a')
  await clipboard(editor, 'paste', { 'text/plain': 'flowchart LR\n  Solo --> Node' })
  await expect(page.locator('.mermaid-block')).toHaveCount(1)
  await expectMarkdown(page, fence('flowchart LR\n  Solo --> Node'))
})

test('same-editor cut of multi-paragraph commented text pastes into a Mermaid block with comment anchors intact', async ({
  page
}) => {
  const commentId = '019a2b00-0000-7000-8000-000000000001'
  await page.goto('/playground/embedded.html')
  await page.getByRole('button', { name: 'Apply comment to first', exact: true }).click()
  const first = page.getByRole('textbox', { name: 'First document', exact: true })
  await expect(first.locator('[data-comment-ids]')).toHaveAttribute('data-comment-ids', commentId)

  await caret(first.locator('p').last(), 'end')
  await first.press('Enter')
  await page.keyboard.type('/mermaid')
  await page.getByRole('option', { name: /Mermaid/ }).click()
  const mermaidBlock = first.locator('.mermaid-block')
  await expect(mermaidBlock).toBeVisible()

  const selectInFirst = async () => {
    await first.evaluate(element => {
      const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
      const texts: Text[] = []
      while (walker.nextNode()) texts.push(walker.currentNode as Text)
      const anchor = texts.find(node => node.data === 'Anchored text')!
      const focus = texts.find(node => node.data === 'Destination')!
      ;(element as HTMLElement).focus()
      window.getSelection()!.setBaseAndExtent(anchor, 0, focus, 11)
      document.dispatchEvent(new Event('selectionchange'))
    })
  }

  await selectInFirst()
  const cut = await clipboard(first, 'cut')
  await expect(first.locator('[data-comment-ids]')).toHaveCount(0)

  // Pasting at a caret inside the Mermaid source preserves both the Mermaid block and the comment anchor.
  await mermaidBlock.locator('.mermaid-pre').click()
  await clipboard(first, 'paste', cut)
  await expect(mermaidBlock).toHaveCount(1)
  await expect(mermaidBlock.locator('.mermaid-pre br')).toHaveCount(1)
  await expect(mermaidBlock.locator('[data-comment-ids]')).toHaveText('Anchored text')
  await expect(mermaidBlock.locator('[data-comment-ids]')).toHaveAttribute('data-comment-ids', commentId)
  await expect(page.getByLabel('First Markdown', { exact: true })).toContainText(
    '```mermaid\nAnchored text\nDestination\n```'
  )

  // Cutting from inside the Mermaid source and pasting onto a whole-block-selected Mermaid block also keeps both.
  await selectInFirst()
  const cutAgain = await clipboard(first, 'cut')
  await first.press('Escape')
  await expect(mermaidBlock).toHaveClass(/editor-selected-block/)
  await clipboard(first, 'paste', cutAgain)
  await expect(mermaidBlock).toHaveCount(1)
  await expect(mermaidBlock.locator('.mermaid-pre br')).toHaveCount(1)
  await expect(mermaidBlock.locator('[data-comment-ids]')).toHaveText('Anchored text')
  await expect(mermaidBlock.locator('[data-comment-ids]')).toHaveAttribute('data-comment-ids', commentId)
  await expect(page.getByLabel('First Markdown', { exact: true })).toContainText(
    '```mermaid\nAnchored text\nDestination\n```'
  )
})

test('clicking the Mermaid toolbar or choosing a template focuses the Mermaid block for immediate paste and typing', async ({
  page
}) => {
  await openDocument(page, 'Intro\n\n```mermaid\n```')
  const editor = page.getByRole('textbox', { name: '文档编辑器', exact: true })
  const block = page.locator('.mermaid-block')

  await caret(page.locator('.editor-content > p').first(), 'end')
  await block.hover()
  await block.locator('.mermaid-toolbar').click({ position: { x: 16, y: 18 } })
  await clipboard(editor, 'paste', { 'text/plain': 'flowchart LR\n  T --> U' })
  await expectMarkdown(page, `Intro\n\n${fence('flowchart LR\n  T --> U')}`)

  await caret(page.locator('.editor-content > p').first(), 'end')
  await block.locator('[data-mermaid-action="template"]').click()
  await page.getByRole('menuitem', { name: '横向流程' }).click()
  await editor.press('Enter')
  await page.keyboard.type('  C --> D')
  await expectMarkdown(page, `Intro\n\n${fence('flowchart LR\n  A[输入] --> B[处理] --> C[输出]\n  C --> D')}`)
})
