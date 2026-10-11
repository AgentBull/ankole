import type { Page } from '@playwright/test'
import { caret, expect, expectMarkdown, openDocument, reopen, selectText, test } from './helpers'

const compositions = [
  {
    name: 'affine:tests/blocksuite/e2e/cross-platform/inline/inline-editor.spec.ts:373 Chinese in an empty paragraph',
    markdown: '',
    target: '.editor-content > p',
    candidates: ['n', 'ni', 'nihao', '你好'],
    value: '你好',
    replace: false
  },
  {
    name: 'Japanese candidates in a callout',
    markdown: '<callout tone="info">前後</callout>',
    target: '.editor-content aside p',
    candidates: ['に', 'にほん', '日本'],
    value: '前日本後',
    replace: false
  },
  {
    name: 'Korean syllable composition in a list',
    markdown: '- 前後',
    target: '.editor-content li',
    candidates: ['ㅎ', '하', '한'],
    value: '前한後',
    replace: false
  },
  {
    name: 'composition replaces a selected bold range',
    markdown: '**前seed後**',
    target: '.editor-content strong',
    candidates: ['zhong', '中文'],
    value: '前中文後',
    replace: true
  }
]

for (const scenario of compositions) {
  test(scenario.name, async ({ page, browserName }, info) => {
    test.skip(
      browserName !== 'chromium',
      'CDP composition is available only in Chromium. Native OS IME remains a separate check.'
    )
    await openDocument(page, scenario.markdown)
    const target = page.locator(scenario.target)
    if (!scenario.markdown) await page.locator('.editor-content').click()
    else if (scenario.replace) await selectText(page, '前seed後', 1, '前seed後', 5)
    else await caret(target, 1)
    await page.locator('.editor-content').evaluate(element => {
      const events: unknown[] = []
      Object.assign(window, { inputEventTrace: events })
      for (const type of [
        'compositionstart',
        'compositionupdate',
        'compositionend',
        'beforeinput',
        'input',
        'keydown'
      ]) {
        element.addEventListener(type, event => {
          const input = event as InputEvent
          events.push({
            type,
            data: input.data,
            inputType: input.inputType,
            isComposing: input.isComposing,
            cancelable: event.cancelable,
            trusted: event.isTrusted
          })
        })
      }
    })
    const client = await page.context().newCDPSession(page)
    try {
      for (const text of scenario.candidates) {
        await client.send('Input.imeSetComposition', { text, selectionStart: text.length, selectionEnd: text.length })
      }
      await client.send('Input.insertText', { text: scenario.candidates.at(-1)! })
      await expect(target).toHaveText(scenario.value)
      const events = await page.evaluate(
        () =>
          (
            window as unknown as {
              inputEventTrace: { type: string; inputType?: string; trusted: boolean; cancelable: boolean }[]
            }
          ).inputEventTrace
      )
      expect(events.filter(event => event.type === 'compositionstart')).toHaveLength(1)
      expect(events.filter(event => event.type === 'compositionend')).toHaveLength(1)
      const updates = events.filter(
        event => event.type === 'beforeinput' && event.inputType === 'insertCompositionText'
      )
      expect(updates.length).toBeGreaterThanOrEqual(scenario.candidates.length)
      expect(updates.every(event => event.trusted && !event.cancelable)).toBe(true)
      await page.keyboard.insertText('!')
      await expect(target).toHaveText(scenario.value.replace(/後$/, '!後') + (scenario.value.endsWith('後') ? '' : '!'))
      await reopen(page)
      await expect(target).toContainText(scenario.candidates.at(-1)!)
    } finally {
      const events = await page.evaluate(() => (window as unknown as { inputEventTrace: unknown[] }).inputEventTrace)
      await info.attach('composition-events', {
        body: JSON.stringify(events, null, 2),
        contentType: 'application/json'
      })
      await client.detach()
    }
  })
}

for (const beforeInput of [false, true]) {
  test(`${beforeInput ? 'non-cancelable beforeinput' : 'input without beforeinput'} reconciles a browser text replacement`, async ({
    page
  }) => {
    await openDocument(page, '**Espana**')
    const target = page.locator('.editor-content strong')
    await caret(target)
    // Model the DOM mutation made by dictation, spellcheck or an IME. Dispatching
    // events alone cannot cause the browser's native editing default action.
    await target.evaluate((element, beforeInput) => {
      const editor = element.closest('[contenteditable="true"]')!
      const text = element.firstChild as Text
      if (beforeInput) {
        const event = new InputEvent('beforeinput', {
          inputType: 'insertReplacementText',
          data: 'España',
          bubbles: true,
          cancelable: false
        })
        Object.defineProperty(event, 'getTargetRanges', {
          value: () => [
            new StaticRange({ startContainer: text, startOffset: 0, endContainer: text, endOffset: text.length })
          ]
        })
        editor.dispatchEvent(event)
      }
      text.replaceData(0, text.length, 'España')
      window.getSelection()!.setBaseAndExtent(text, 6, text, 6)
      editor.dispatchEvent(
        new InputEvent('input', { inputType: 'insertReplacementText', data: 'España', bubbles: true })
      )
    }, beforeInput)
    await expect(target).toHaveText('España')
    await page.keyboard.insertText('!')
    await expect(target).toHaveText('España!')
    await reopen(page)
    await expect(target).toHaveText('España!')
  })
}

test('a cancelled composition retains surrounding text and supports the next input', async ({ page, browserName }) => {
  test.skip(browserName !== 'chromium', 'CDP composition is available only in Chromium.')
  await openDocument(page, '**前後**')
  const target = page.locator('.editor-content strong')
  await caret(target, 1)
  const client = await page.context().newCDPSession(page)
  await client.send('Input.imeSetComposition', { text: '候选', selectionStart: 2, selectionEnd: 2 })
  await client.send('Input.imeSetComposition', { text: '', selectionStart: 0, selectionEnd: 0 })
  await expect(target).toHaveText('前後')
  await page.keyboard.insertText('X')
  await expect(target).toHaveText('前X後')
  await reopen(page)
  await expect(target).toHaveText('前X後')
  await client.detach()
})

test('RTL and LTR text keep logical selection bounds when a reverse range is replaced', async ({ page }) => {
  await openDocument(page, 'abc אבג xyz')
  await selectText(page, 'abc אבג xyz', 7, 'abc אבג xyz', 4)
  await page.keyboard.insertText('مرحبا')
  await expect(page.locator('.editor-content > p')).toHaveText('abc مرحبا xyz')
  await reopen(page)
  await expect(page.locator('.editor-content > p')).toHaveText('abc مرحبا xyz')
})

// A synthetic event runs only the editor's beforeinput handler. It has no browser default action.
async function beforeInput(
  page: Page,
  init: {
    inputType: string
    data?: string
    text?: string
    cancelable?: boolean
    at?: [string, number]
    target?: [string, number, string, number]
    selectionTarget?: boolean
  }
) {
  return page.locator('.editor-content').evaluate((element, init) => {
    const event = new InputEvent('beforeinput', {
      inputType: init.inputType,
      data: init.data ?? null,
      bubbles: true,
      cancelable: init.cancelable ?? true
    })
    // Chromium drops legacy IME types from synthetic events. Keep the replay's type.
    if (event.inputType !== init.inputType) Object.defineProperty(event, 'inputType', { value: init.inputType })
    if (init.text !== undefined) {
      const dataTransfer = new DataTransfer()
      dataTransfer.setData('text/plain', init.text)
      // WebKit ignores dataTransfer in the event constructor.
      Object.defineProperty(event, 'dataTransfer', { value: dataTransfer })
    }
    if (init.selectionTarget) {
      const selected = window.getSelection()!.getRangeAt(0)
      const range = new StaticRange({
        startContainer: selected.startContainer,
        startOffset: selected.startOffset,
        endContainer: selected.endContainer,
        endOffset: selected.endOffset
      })
      Object.defineProperty(event, 'getTargetRanges', { value: () => [range] })
    } else if (init.at || init.target) {
      const [startText, startOffset, endText, endOffset] = init.target ?? [
        init.at![0],
        init.at![1],
        init.at![0],
        init.at![1]
      ]
      const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
      const texts: Text[] = []
      while (walker.nextNode()) texts.push(walker.currentNode as Text)
      const start = texts.find(text => text.data === startText)
      const end = texts.find(text => text.data === endText)
      if (!start || !end) throw new Error('The target text is missing')
      const range = new StaticRange({
        startContainer: start,
        startOffset,
        endContainer: end,
        endOffset
      })
      Object.defineProperty(event, 'getTargetRanges', { value: () => [range] })
    }
    element.dispatchEvent(event)
    return event.defaultPrevented
  }, init)
}

test('historyUndo and historyRedo from the Edit menu undo and redo typing', async ({ page }) => {
  await openDocument(page, 'abc')
  const paragraph = page.locator('.editor-content > p')
  await caret(paragraph)
  await page.keyboard.type('XYZ')
  await expect(paragraph).toHaveText('abcXYZ')
  expect(await beforeInput(page, { inputType: 'historyUndo' })).toBe(true)
  await expect(paragraph).toHaveText('abc')
  expect(await beforeInput(page, { inputType: 'historyRedo' })).toBe(true)
  await expectMarkdown(page, 'abcXYZ')
})

for (const [inputType, markdown] of [
  ['formatBold', '**hello** world'],
  ['formatItalic', '*hello* world'],
  ['formatUnderline', '<u>hello</u> world'],
  ['formatStrikeThrough', '~~hello~~ world']
] as const) {
  test(`${inputType} from a menu formats the selection`, async ({ page }) => {
    await openDocument(page, 'hello world')
    await selectText(page, 'hello world', 0, 'hello world', 5)
    expect(await beforeInput(page, { inputType })).toBe(true)
    await expectMarkdown(page, markdown)
  })
}

test('a cancelable insertReplacementText replaces text across two paragraphs', async ({ page }) => {
  await openDocument(page, 'hello\n\nworld')
  await selectText(page, 'hello', 0, 'world', 5)
  expect(await beforeInput(page, { inputType: 'insertReplacementText', text: 'one\ntwo' })).toBe(true)
  await expectMarkdown(page, 'one\n\ntwo')
})

test('a non-cancelable insertReplacementText across two paragraphs keeps the browser result', async ({ page }) => {
  await openDocument(page, 'hello\n\nworld')
  await selectText(page, 'hello', 0, 'world', 5)
  await page.locator('.editor-content').evaluate(element => {
    const [first, second] = [...element.querySelectorAll('p')].map(paragraph => {
      const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT)
      return walker.nextNode() as Text
    }) as [Text, Text]
    const dataTransfer = new DataTransfer()
    dataTransfer.setData('text/plain', 'one\ntwo')
    const event = new InputEvent('beforeinput', {
      inputType: 'insertReplacementText',
      bubbles: true,
      cancelable: false
    })
    Object.defineProperty(event, 'dataTransfer', { value: dataTransfer })
    Object.defineProperty(event, 'getTargetRanges', {
      value: () => [new StaticRange({ startContainer: first, startOffset: 0, endContainer: second, endOffset: 5 })]
    })
    element.dispatchEvent(event)
    // Model a browser that keeps both paragraphs and changes their text.
    first.data = 'one'
    second.data = 'two'
    window.getSelection()!.setBaseAndExtent(second, 3, second, 3)
    const input = new InputEvent('input', { inputType: 'insertReplacementText', bubbles: true })
    Object.defineProperty(input, 'dataTransfer', { value: dataTransfer })
    element.dispatchEvent(input)
  })
  await page.keyboard.insertText('!')
  await expectMarkdown(page, 'one\n\ntwo!')
})

test('deleteContentForward deletes one character, as the Delete key does', async ({ page }) => {
  await openDocument(page, 'hello world')
  await caret(page.locator('.editor-content > p'), 0)
  expect(await beforeInput(page, { inputType: 'deleteContentForward' })).toBe(true)
  await expectMarkdown(page, 'ello world')
})

test('deleteContentBackward from a soft keyboard follows the Backspace rules at a block start', async ({ page }) => {
  await openDocument(page, '- a\n- hello')
  await caret(page.locator('.editor-content').getByText('hello', { exact: true }), 0)
  expect(await beforeInput(page, { inputType: 'deleteContentBackward' })).toBe(true)
  await expectMarkdown(page, '- a\n\nhello')
})

test('deleteByCut removes a selection across paragraphs', async ({ page }) => {
  await openDocument(page, 'hello\n\nworld')
  await selectText(page, 'hello', 2, 'world', 3)
  expect(await beforeInput(page, { inputType: 'deleteByCut' })).toBe(true)
  await expectMarkdown(page, 'held')
})

test('deleteByDrag and insertFromDrop move the dragged text to the drop point', async ({ page }) => {
  await openDocument(page, 'alpha beta gamma')
  await selectText(page, 'alpha beta gamma', 0, 'alpha beta gamma', 5)
  expect(await beforeInput(page, { inputType: 'deleteByDrag' })).toBe(true)
  expect(await beforeInput(page, { inputType: 'insertFromDrop', text: 'alpha', at: [' beta gamma', 11] })).toBe(true)
  await expectMarkdown(page, '&#x20;beta gammaalpha')
})

// Synthetic events prove the DOM range adapter and real dispatch. They do not prove that a native
// browser or soft keyboard emits a target range different from its current selection.
for (const inputType of [
  'deleteByCut',
  'deleteByDrag',
  'deleteByComposition',
  'deleteContentBackward',
  'deleteContentForward'
]) {
  test(`${inputType} keeps a callout when its target range differs from the selection`, async ({ page }) => {
    const markdown = 'before\n\n<callout data-key="keep" tone="info">\n  hello\n\n  - world\n</callout>\n\ntail'
    const deleted = 'before\n\n<callout data-key="keep" tone="info">\n  <p />\n</callout>\n\ntail'
    await openDocument(page, markdown)
    await caret(page.locator('.editor-content > p').last(), 2)
    expect(await beforeInput(page, { inputType, target: ['hello', 0, 'world', 5] })).toBe(true)
    await expectMarkdown(page, deleted)
    await page.locator('.editor-content').press('ControlOrMeta+z')
    await expectMarkdown(page, markdown)
  })
}

for (const inputType of ['deleteByCut', 'deleteByDrag', 'deleteContentBackward', 'deleteContentForward']) {
  test(`${inputType} empties all selected cells when its target is the DOM selection`, async ({ page }) => {
    const markdown = '| Name  | Value |\n| :---- | ----: |\n| Alpha |    42 |\n\nafter'
    await openDocument(page, markdown)
    await selectText(page, 'Alpha', 2, '42', 1)
    await expect(page.locator('.wg-selected-cell')).toHaveCount(2)
    await beforeInput(page, { inputType, selectionTarget: true })
    const cells = page.locator('.editor-content td')
    await expect(cells).toHaveCount(2)
    await expect(cells.nth(0)).toHaveText('')
    await expect(cells.nth(1)).toHaveText('')
    await expect(cells.nth(0)).toHaveCSS('text-align', 'left')
    await expect(cells.nth(1)).toHaveCSS('text-align', 'right')
    await page.locator('.editor-content').press('ControlOrMeta+z')
    await expectMarkdown(page, markdown)
  })
}

test('deleting input events keep read-only block boundaries unchanged', async ({ page }) => {
  await page.goto('/playground/embedded.html')
  await page.getByLabel('Source target', { exact: true }).selectOption('first')
  await page.getByLabel('Host source', { exact: true }).fill('hello\n\nworld')
  await page.getByRole('button', { name: 'Apply source without moving focus', exact: true }).click()
  await expect(page.getByLabel('Source write result', { exact: true })).toHaveText('Applied')
  await page.getByRole('button', { name: 'Toggle read only', exact: true }).click()
  const editor = page.getByTestId('first-editor').locator('.editor-content')
  await expect(editor).toHaveAttribute('contenteditable', 'false')
  for (const inputType of ['deleteContentForward', 'deleteContentBackward', 'deleteHardLineForward']) {
    const prevented = await editor.evaluate((element, inputType) => {
      const paragraphs = element.querySelectorAll('p')
      const backward = inputType === 'deleteContentBackward'
      const text = paragraphs[backward ? 1 : 0]!.firstChild as Text
      window.getSelection()!.setBaseAndExtent(text, backward ? 0 : text.length, text, backward ? 0 : text.length)
      const event = new InputEvent('beforeinput', { inputType, bubbles: true, cancelable: true })
      element.dispatchEvent(event)
      return event.defaultPrevented
    }, inputType)
    expect(prevented).toBe(true)
    await expect(editor.locator('p')).toHaveText(['hello', 'world'])
  }
  await expect(page.getByLabel('First Markdown', { exact: true })).toHaveText('hello\n\nworld')
})

test('insertParagraph keeps a read-only heading unchanged', async ({ page }) => {
  await page.goto('/playground/embedded.html')
  await page.getByLabel('Source target', { exact: true }).selectOption('first')
  await page.getByLabel('Host source', { exact: true }).fill('## hello')
  await page.getByRole('button', { name: 'Apply source without moving focus', exact: true }).click()
  await expect(page.getByLabel('Source write result', { exact: true })).toHaveText('Applied')
  await page.getByRole('button', { name: 'Toggle read only', exact: true }).click()
  const editor = page.getByTestId('first-editor').locator('.editor-content')
  await expect(editor).toHaveAttribute('contenteditable', 'false')
  const prevented = await editor.evaluate(element => {
    const text = element.querySelector('h2')!.firstChild as Text
    window.getSelection()!.setBaseAndExtent(text, 2, text, 2)
    const event = new InputEvent('beforeinput', { inputType: 'insertParagraph', bubbles: true, cancelable: true })
    element.dispatchEvent(event)
    return event.defaultPrevented
  })
  expect(prevented).toBe(true)
  await expect(editor.locator('h2')).toHaveText('hello')
  await expect(editor.locator('p')).toHaveCount(0)
  await expect(page.getByLabel('First Markdown', { exact: true })).toHaveText('## hello')
})

test('replacement input events keep a read-only document unchanged', async ({ page }) => {
  await page.goto('/playground/embedded.html')
  await page.getByLabel('Source target', { exact: true }).selectOption('first')
  await page.getByLabel('Host source', { exact: true }).fill('hello')
  await page.getByRole('button', { name: 'Apply source without moving focus', exact: true }).click()
  await expect(page.getByLabel('Source write result', { exact: true })).toHaveText('Applied')
  await page.getByRole('button', { name: 'Toggle read only', exact: true }).click()
  const editor = page.getByTestId('first-editor').locator('.editor-content')
  await expect(editor).toHaveAttribute('contenteditable', 'false')
  for (const inputType of [
    'insertReplacementText',
    'insertFromYank',
    'insertText',
    'insertFromPaste',
    'insertCompositionText',
    'insertFromComposition',
    'deleteCompositionText',
    'historyUndo',
    'historyRedo',
    'formatBold'
  ]) {
    const prevented = await editor.evaluate((element, inputType) => {
      const text = element.querySelector('p')!.firstChild as Text
      window.getSelection()!.setBaseAndExtent(text, 0, text, text.length)
      const event = new InputEvent('beforeinput', { inputType, data: 'changed', bubbles: true, cancelable: true })
      element.dispatchEvent(event)
      return event.defaultPrevented
    }, inputType)
    expect(prevented).toBe(true)
    await expect(editor.locator('p')).toHaveText('hello')
  }
  await expect(page.getByLabel('First Markdown', { exact: true })).toHaveText('hello')
  // Read-only input does not prevent the host from writing the page through PageSession.
  await page.getByLabel('Host source', { exact: true }).fill('Host write')
  await page.getByRole('button', { name: 'Apply source without moving focus', exact: true }).click()
  await expect(editor.locator('p')).toHaveText('Host write')
  await expect(editor).toHaveAttribute('contenteditable', 'false')
})

test('a read-only browser text replacement is redrawn from the document', async ({ page }) => {
  await page.goto('/playground/embedded.html')
  await page.getByLabel('Source target', { exact: true }).selectOption('first')
  await page.getByLabel('Host source', { exact: true }).fill('hello')
  await page.getByRole('button', { name: 'Apply source without moving focus', exact: true }).click()
  await expect(page.getByLabel('Source write result', { exact: true })).toHaveText('Applied')
  await page.getByRole('button', { name: 'Toggle read only', exact: true }).click()
  const editor = page.getByTestId('first-editor').locator('.editor-content')
  await expect(editor).toHaveAttribute('contenteditable', 'false')
  await editor.evaluate(element => {
    const text = element.querySelector('p')!.firstChild as Text
    const event = new InputEvent('beforeinput', {
      inputType: 'insertReplacementText',
      data: 'changed',
      bubbles: true,
      cancelable: false
    })
    Object.defineProperty(event, 'getTargetRanges', {
      value: () => [
        new StaticRange({ startContainer: text, startOffset: 0, endContainer: text, endOffset: text.length })
      ]
    })
    element.dispatchEvent(event)
    // Model the DOM mutation of a replacement that cannot be canceled.
    text.data = 'changed'
    element.dispatchEvent(new InputEvent('input', { inputType: 'insertReplacementText', bubbles: true }))
  })
  await expect(editor.locator('p')).toHaveText('hello')
  await expect(page.getByLabel('First Markdown', { exact: true })).toHaveText('hello')
})

test('a native drag moves the selected text', async ({ page, browserName }) => {
  test.skip(browserName !== 'firefox', 'Playwright drags selected text only in Firefox.')
  await openDocument(page, 'alpha beta gamma')
  await selectText(page, 'alpha beta gamma', 0, 'alpha beta gamma', 5)
  const box = (await page.locator('.editor-content > p').boundingBox())!
  await page.mouse.move(box.x + 12, box.y + box.height / 2)
  await page.mouse.down()
  await page.mouse.move(box.x + box.width - 5, box.y + box.height / 2, { steps: 8 })
  await page.mouse.up()
  await expectMarkdown(page, '&#x20;beta gammaalpha')
})

// Input Events Level 2 types that the editor does not support. The value is the event data.
const unsupported: Record<string, string | undefined> = {
  deleteEntireSoftLine: undefined,
  formatBackColor: 'rgb(255, 255, 0)',
  formatFontColor: 'rgb(255, 0, 0)',
  formatFontName: 'serif',
  formatIndent: undefined,
  formatJustifyCenter: undefined,
  formatJustifyFull: undefined,
  formatJustifyLeft: undefined,
  formatJustifyRight: undefined,
  formatOutdent: undefined,
  formatRemove: undefined,
  formatSetBlockTextDirection: 'rtl',
  formatSetInlineTextDirection: 'rtl',
  formatSubscript: undefined,
  formatSuperscript: undefined,
  insertHorizontalRule: undefined,
  insertLink: 'https://example.com',
  insertOrderedList: undefined,
  insertUnorderedList: undefined
}

test('unsupported input types are cancelled and leave the page unchanged', async ({ page }) => {
  await openDocument(page, 'hello world')
  await selectText(page, 'hello world', 0, 'hello world', 5)
  for (const [inputType, data] of Object.entries(unsupported)) {
    expect(await beforeInput(page, { inputType, data }), inputType).toBe(true)
  }
  await expectMarkdown(page, 'hello world')
})
