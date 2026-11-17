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

test('each view sizes the block to its visible content between the minimum and the cap', async ({ page }) => {
  await openDocument(page, fence(source))
  const block = page.locator('.mermaid-block')
  await expect(block.locator('.mermaid-preview svg')).toBeVisible({ timeout: 10_000 })
  const height = async () => (await block.boundingBox())!.height
  const view = async (name: string) => {
    await page.locator('[data-mermaid-action="view"]').click()
    await page.getByRole('menuitemradio', { name }).click()
  }
  const both = await height()
  expect(both).toBeLessThan(558)
  await view('仅展示代码')
  // Two source lines take the 120px minimum body under the 36px toolbar and the 1px borders.
  await expect.poll(height).toBe(158)
  await view('仅展示图表')
  await expect.poll(height).toBe(both)

  await view('仅展示代码')
  const pre = block.locator('.mermaid-pre')
  await caret(pre, 'end')
  for (let line = 0; line < 40; line++) {
    await page.keyboard.press('Enter')
    await page.keyboard.type(`N${line}`)
  }
  // Long source stops at the cap and scrolls inside the block.
  await expect.poll(height).toBeLessThanOrEqual(558)
  expect(await pre.evaluate(element => element.scrollHeight > element.clientHeight)).toBe(true)

  // Diagram-only view expands the block height to fit a tall diagram without clipping.
  const tallDiagram = [
    'flowchart TD',
    ...Array.from({ length: 14 }, (_, index) => `  N${index}[Step ${index}] --> N${index + 1}[Step ${index + 1}]`)
  ].join('\n')
  await openDocument(page, `<mermaid view="diagram">\n${fence(tallDiagram)}\n</mermaid>`)
  await expect(block.locator('.mermaid-preview svg')).toBeVisible({ timeout: 10_000 })
  await expect.poll(height).toBeGreaterThan(558)
  expect(await block.locator('.mermaid-preview').evaluate(el => el.scrollHeight <= el.clientHeight)).toBe(true)

  // Wide sequence diagrams scale to fit without wrapping labels into narrow vertical columns.
  const wideSequence = [
    'sequenceDiagram',
    '  autonumber',
    '  participant IM as 客户 / 外部渠道',
    '  participant GW as 事件路由与执行账本',
    '  participant BA as 售后 Business Agent',
    '  participant DB as Base 共享表 + 指标层',
    '  participant MGR as 客服主管 (人工审批)',
    '  participant PAY as 零密钥连接器 / 支付接口',
    '  IM->>GW: 发起 £160 售后退款诉求 (附外部单号)',
    '  GW->>BA: 唯一事件号幂等去重后唤醒会话进程'
  ].join('\n')
  await openDocument(page, `<mermaid view="diagram">\n${fence(wideSequence)}\n</mermaid>`)
  const seqSvg = block.locator('.mermaid-preview svg')
  await expect(seqSvg.locator('text', { hasText: '唯一事件号幂等去重后唤醒会话进程' })).toBeVisible({
    timeout: 10_000
  })
  const fitsHorizontally = await block.locator('.mermaid-preview').evaluate(el => {
    const svg = el.querySelector('svg')
    return (
      Boolean(svg) && el.scrollWidth <= el.clientWidth + 1 && svg!.getBoundingClientRect().width <= el.clientWidth + 1
    )
  })
  expect(fitsHorizontally).toBe(true)
})

test('templates appear only when source is empty and replace it in one step', async ({ page }) => {
  await openDocument(page, '```mermaid\n```')
  const templateButton = page.locator('[data-mermaid-action="template"]')
  await expect(templateButton).toBeVisible()
  await templateButton.click()
  await page.getByRole('menuitem', { name: '条件判断' }).click()
  await expect(page.locator('.mermaid-pre')).toContainText('是否继续')
  await expect(page.locator('.mermaid-preview svg')).toBeVisible()
  await expect(templateButton).toBeHidden()
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

test('expanded Mermaid and Infographic previews export materialized standalone SVGs', async ({ page }) => {
  const { readFile } = await import('node:fs/promises')
  const diagramDoc = [
    fence('flowchart TD\n  accTitle: Literal var(--x, keep) and url(https://example.com)\n  A[开始] --> B[完成]'),
    [
      '```infographic',
      'infographic sequence-timeline-simple',
      'data',
      '  title Roadmap',
      '  sequences',
      '    - label Q1',
      '      desc Ship',
      '```'
    ].join('\n')
  ].join('\n\n')

  await openDocument(page, diagramDoc)
  const blocks = page.locator('.mermaid-block')
  await expect(blocks).toHaveCount(2)
  await expect(blocks.nth(0).locator('.mermaid-preview svg')).toBeVisible({ timeout: 10_000 })
  await expect(blocks.nth(1).locator('.mermaid-preview svg')).toHaveCount(1, { timeout: 10_000 })

  await blocks.nth(0).locator('[data-mermaid-action="expand"]').click()
  const preview = page.locator('.mermaid-expanded-preview')
  await expect(preview.locator('svg').first()).toBeVisible()
  await preview.evaluate(el => el.style.setProperty('--pele-radius', '6px'))

  const mermaidDownload = page.waitForEvent('download')
  await page.locator('.mermaid-expanded-export', { hasText: 'SVG' }).click()
  const mermaidFile = await mermaidDownload
  expect(mermaidFile.suggestedFilename()).toBe('ankole-diagram.svg')
  const mermaidSvg = await readFile((await mermaidFile.path())!, 'utf8')
  expect(mermaidSvg).toContain('xmlns="http://www.w3.org/2000/svg"')
  expect(mermaidSvg).toContain('>Literal var(--x, keep) and url(https://example.com)</title>')
  expect(mermaidSvg).toContain('rx="6"')
  expect(mermaidSvg.replace(/<title\b[^>]*>[\s\S]*?<\/title>/g, '')).not.toContain('var(--')
  await page.keyboard.press('Escape')
  await expect(page.locator('.mermaid-expanded')).toHaveCount(0)

  await blocks.nth(1).locator('[data-mermaid-action="expand"]').click()
  await expect(preview.locator('svg').first()).toHaveCount(1, { timeout: 10_000 })
  const infographicDownload = page.waitForEvent('download')
  await page.locator('.mermaid-expanded-export', { hasText: 'SVG' }).click()
  const infographicFile = await infographicDownload
  expect(infographicFile.suggestedFilename()).toBe('ankole-infographic.svg')
  const infographicSvg = await readFile((await infographicFile.path())!, 'utf8')
  expect(infographicSvg).toContain('xmlns="http://www.w3.org/2000/svg"')
  expect(infographicSvg).toContain('Roadmap')
  expect(infographicSvg).not.toContain('var(--')
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

  const standalone = await page.evaluate(async () => {
    const core = '/src/core/editor/index.ts'
    const state = '/src/core/state/index.ts'
    const phrases = '/src/editor/phrases.ts'
    const ext = '/src/editor/extension.ts'
    const { Wordgard }: typeof import('../src/core/editor') = await import(core)
    const { GardState }: typeof import('../src/core/state') = await import(state)
    const { editorPhrases }: typeof import('../src/editor/phrases') = await import(phrases)
    const { editorExtension, initialState }: typeof import('../src/editor/extension') = await import(ext)
    const locale = GardState.Compartment.define()
    const host = document.createElement('div')
    document.body.append(host)
    const wg = Wordgard.create({
      state: initialState(
        [
          '```mermaid\nflowchart TD\n  A --> B\n```',
          '```infographic\ninfographic compare-swot\n```',
          '```mermaid\n```'
        ].join('\n\n'),
        [locale.of([]), editorExtension()]
      ),
      parent: host
    })
    const gutter = host.querySelector('.mermaid-gutter')?.textContent ?? ''
    await new Promise(resolve => setTimeout(resolve, 400))
    const hasSvg = Boolean(host.querySelector('.mermaid-preview svg'))
    // Rebuilding toolbars via label reconfiguration without docChanged preserves template button visibility.
    wg.dispatch({ effects: locale.reconfigure(editorPhrases.translatePartial({ mermaid_template: '套用模板' })) })
    wg.flush()
    const templateButtons = [...host.querySelectorAll<HTMLButtonElement>('.mermaid-toolbar-template')].map(btn => ({
      text: btn.textContent,
      hidden: btn.hidden
    }))
    wg.dom.remove()
    host.remove()
    return { gutter, hasSvg, templateButtons }
  })
  expect(standalone.gutter).toBe('1\n2')
  expect(standalone.hasSvg).toBe(true)
  expect(standalone.templateButtons).toEqual([
    { text: '套用模板', hidden: true },
    { text: '套用模板', hidden: true },
    { text: '套用模板', hidden: false }
  ])
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
      const anchor = texts.find(node => node.data.startsWith('Anchored'))!
      const focus = texts.find(node => node.data.endsWith('Destination'))!
      ;(element as HTMLElement).focus()
      window.getSelection()!.setBaseAndExtent(anchor, 0, focus, focus.data.length)
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
  await block.locator('[data-mermaid-action="template"]').click()
  await page.getByRole('menuitem', { name: '横向流程' }).click()
  await expect(block.locator('[data-mermaid-action="template"]')).toBeHidden()
  await editor.press('Enter')
  await page.keyboard.type('  C --> D')
  await expectMarkdown(page, `Intro\n\n${fence('flowchart LR\n  A[输入] --> B[处理] --> C[输出]\n  C --> D')}`)

  await caret(block.locator('.mermaid-pre'), 'end')
  await page.keyboard.press('ControlOrMeta+a')
  await page.keyboard.press('Backspace')
  await expect(block.locator('[data-mermaid-action="template"]')).toBeVisible()

  await caret(page.locator('.editor-content > p').first(), 'end')
  await block.hover()
  await block.locator('.mermaid-toolbar').click({ position: { x: 16, y: 18 } })
  await clipboard(editor, 'paste', { 'text/plain': 'flowchart LR\n  T --> U' })
  await expectMarkdown(page, `Intro\n\n${fence('flowchart LR\n  T --> U')}`)
})
