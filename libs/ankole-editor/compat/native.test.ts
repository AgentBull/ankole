import { afterAll, beforeAll, beforeEach, expect, test } from 'bun:test'
import { Builder, By, Key, until, type WebDriver } from 'selenium-webdriver'
import firefox from 'selenium-webdriver/firefox'
import { resolve } from 'node:path'
import versions from './browsers.json'
import fixtures from '../upstream/fixtures/slate-editing.json'
import dialect from '../upstream/fixtures/slate-dialect.json'
import { readTextRange, setTextRange } from '../upstream/browser-selection'

const browser = process.env.NATIVE_BROWSER ?? 'firefox-esr'
const url = 'http://127.0.0.1:3147'
let driver: WebDriver | undefined
let server: ReturnType<typeof Bun.spawn> | undefined
const selector = '.editor-content'

beforeAll(async () => {
  try {
    await fetch(url)
    throw new Error('Port 3147 is already in use; native tests require their own server.')
  } catch (error) {
    if ((error as Error).message.includes('already in use')) throw error
  }
  server = Bun.spawn(['bun', 'run', 'preview', '--port', '3147', '--strictPort'], {
    stdout: Bun.file('output/native-vite.log'),
    stderr: Bun.file('output/native-vite-error.log')
  })
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      if ((await fetch(url)).ok) break
    } catch {
      /* Wait for this test server. */
    }
    if (attempt === 99) throw new Error('Native test server did not start')
    await Bun.sleep(100)
  }
  if (browser === 'firefox-esr') {
    const binary =
      process.env.FIREFOX_BINARY ??
      resolve(
        process.platform === 'darwin'
          ? 'output/browsers/FirefoxESR.app/Contents/MacOS/firefox'
          : 'output/browsers/firefox/firefox'
      )
    const service = new firefox.ServiceBuilder(process.env.GECKODRIVER ?? resolve('output/browsers/geckodriver'))
    driver = await new Builder()
      .forBrowser('firefox')
      .setFirefoxService(service)
      .setFirefoxOptions(new firefox.Options().setBinary(binary).addArguments('-headless'))
      .build()
  } else if (browser === 'safari') driver = await new Builder().forBrowser('safari').build()
  else throw new Error(`Unsupported native browser: ${browser}`)
  await driver.manage().window().setRect({ width: 1440, height: 1000 })
  await driver.manage().setTimeouts({ implicit: 5000, pageLoad: 15000, script: 10000 })
  const caps = await driver.getCapabilities()
  const version = caps.get('browserVersion') as string
  console.log(`Native ${caps.get('browserName')}: ${version}`)
  if (browser === 'firefox-esr') expect(Number(version.split('.')[0])).toBe(Number(versions.firefox.split('.')[0]))
  else expect(Number(version.split('.')[0])).toBeGreaterThanOrEqual(17)
  await Bun.write(
    `output/native-${browser}-version.json`,
    JSON.stringify(
      { browser: caps.get('browserName'), version, platform: caps.get('platformName'), at: new Date().toISOString() },
      null,
      2
    )
  )
}, 60_000)

afterAll(async () => {
  try {
    await driver?.quit()
  } finally {
    server?.kill()
    await server?.exited
  }
}, 15_000)

beforeEach(async () => {
  await driver!.get(url)
  await driver!.wait(until.elementLocated(By.css(selector)), 10000)
})

const click = async (name: string) =>
  driver!.findElement(By.xpath(`//button[@aria-label='${name}' or normalize-space(.)='${name}']`)).click()
async function document(markdown: string) {
  await click('Markdown')
  const input = await driver!.findElement(By.css('textarea[aria-label="Markdown 源码"]'))
  await input.clear()
  await input.sendKeys(markdown)
  await click('应用修改')
  await driver!.findElement(By.css('button[aria-label="关闭 Markdown"]')).click()
}
// The editor draws a change in the next animation frame. Reads of the page wait for it.
async function drawn() {
  await driver!.executeAsyncScript(function (done: () => void) {
    requestAnimationFrame(() => done())
  })
}
async function text(css = selector) {
  await drawn()
  return driver!.findElement(By.css(css)).getText()
}
async function reopen() {
  await click('Markdown')
  await click('往返验证')
  await driver!.wait(until.elementTextContains(await driver!.findElement(By.css('.notice')), '往返一致'), 5000)
  await driver!.findElement(By.css('button[aria-label="关闭 Markdown"]')).click()
}
async function caret(css = `${selector} > p`, offset?: number) {
  await driver!.executeScript(
    function (css: string, offset: number | undefined) {
      const element = window.document.querySelector(css)!
      const walker = window.document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
      let text: Text | null = null
      while (walker.nextNode()) text = walker.currentNode as Text
      const selection = window.getSelection()!
      ;(element.closest('[contenteditable="true"]') as HTMLElement).focus()
      selection.setBaseAndExtent(text!, offset ?? text!.length, text!, offset ?? text!.length)
      window.document.dispatchEvent(new Event('selectionchange'))
    },
    css,
    offset
  )
}

test('native typing, splitting, Unicode, undo and Markdown reopen', async () => {
  await document('Before')
  await caret()
  await driver!.actions().sendKeys(' 😀中文', Key.ENTER, 'After').perform()
  expect(await text()).toContain('Before 😀中文')
  expect(await text(`${selector} > p:last-child`)).toBe('After')
  await click('撤销')
  expect(await text()).not.toContain('After')
  await click('重做')
  expect(await text()).toContain('After')
  await reopen()
  expect(await text()).toContain('Before 😀中文')
  expect(await text()).toContain('After')
}, 30_000)

test('native XML source retains attributes, empty paragraphs and unknown mixed content', async () => {
  await document('Before XML')
  await click('Markdown')
  await click('XML 格式')
  const input = await driver!.findElement(By.css('textarea[aria-label="XML 源码"]'))
  await input.clear()
  await input.sendKeys('<page><p/><p source="manual">XML 中文</p><widget>before<part x="0"/>after</widget></page>')
  await click('应用修改')
  const source = await input.getAttribute('value')
  expect(source).toBe('<page><p /><p source="manual">XML 中文</p><widget>before<part x="0" />after</widget></page>')
  await click('关闭 XML')
  await drawn()
  expect(await driver!.findElements(By.css(`${selector} > p`))).toHaveLength(2)
  await click('撤销')
  expect(await text()).toBe('Before XML')
  await click('重做')
  await click('Markdown')
  await click('往返验证')
  await driver!.wait(until.elementTextContains(await driver!.findElement(By.css('.notice')), '往返一致'), 5000)
  expect(await driver!.findElement(By.css('textarea[aria-label="XML 源码"]')).getAttribute('value')).toBe(source)
  await click('关闭 XML')
}, 30_000)

test('native list selection and Enter keep nested continuation order', async () => {
  await document('- outer\n  - child\n\n  tail\n- next')
  await caret(`${selector} li:last-child`)
  await driver!.actions().sendKeys(Key.ENTER, 'added').perform()
  expect(await text()).toContain('added')
  await reopen()
  const value = await text()
  expect(value.indexOf('outer')).toBeLessThan(value.indexOf('child'))
  expect(value.indexOf('child')).toBeLessThan(value.indexOf('tail'))
  expect(value).toContain('added')
}, 30_000)

test('native selected callout text deletion retains attributes', async () => {
  await document('<callout tone="info">Text</callout>')
  await caret(`${selector} aside p`, 0)
  await driver!.actions().keyDown(Key.SHIFT).sendKeys(Key.END).keyUp(Key.SHIFT).sendKeys(Key.BACK_SPACE).perform()
  expect(await text(`${selector} aside`)).toBe('')
  expect(await driver!.findElement(By.css(`${selector} aside`)).getAttribute('data-tone')).toBe('info')
  await driver!.actions().sendKeys('新的内容').perform()
  await reopen()
  expect(await text(`${selector} aside`)).toBe('新的内容')
}, 30_000)

test('native floating toolbar retains keyboard selection through formatting and link editing', async () => {
  await document('Alpha Beta')
  await caret(`${selector} > p`, 6)
  await driver!.actions().keyDown(Key.SHIFT).sendKeys(Key.END).keyUp(Key.SHIFT).perform()
  await driver!.wait(until.elementLocated(By.css('[role="toolbar"][aria-label="选区格式"]')), 5000)
  await click('粗体')
  expect(await text(`${selector} strong`)).toBe('Beta')
  await click('链接')
  const input = await driver!.findElement(By.css('input[aria-label="链接地址"]'))
  await input.sendKeys('https://example.com/native')
  await click('应用链接')
  expect(await text(`${selector} a strong`)).toBe('Beta')
  await reopen()
  expect(await driver!.findElement(By.css(`${selector} a`)).getAttribute('href')).toBe('https://example.com/native')
  expect(await text(`${selector} a strong`)).toBe('Beta')
}, 30_000)

test('native block menu duplicates and deletes with undo', async () => {
  await document('First\n\nSecond')
  await caret(`${selector} > p:first-child`)
  await click('当前 Block 菜单')
  await driver!.findElement(By.xpath('//*[@role="menuitem" and contains(normalize-space(.), "创建副本")]')).click()
  const paragraphs = async () => {
    await drawn()
    return driver!.executeScript<string[]>(function () {
      return [...window.document.querySelectorAll('.editor-content > p')].map(element => element.textContent!)
    })
  }
  expect(await paragraphs()).toEqual(['First', 'First', 'Second'])
  await click('当前 Block 菜单')
  await driver!.findElement(By.xpath('//*[@role="menuitem" and normalize-space(.)="删除 Block"]')).click()
  expect(await paragraphs()).toEqual(['First', 'Second'])
  await click('撤销')
  expect(await paragraphs()).toEqual(['First', 'First', 'Second'])
  await reopen()
  expect(await paragraphs()).toEqual(['First', 'First', 'Second'])
}, 30_000)

for (const fixture of fixtures) {
  test(`native ${fixture.id}`, async () => {
    await document('Replace me')
    const body = await driver!.findElement(By.css(selector))
    await body.click()
    const modifier = process.platform === 'darwin' ? Key.COMMAND : Key.CONTROL
    await driver!.actions().keyDown(modifier).sendKeys('a', 'a').keyUp(modifier).perform()
    // The editor draws the paste in the next animation frame; the script returns after it.
    await driver!.executeAsyncScript(
      function (element: HTMLElement, paragraphs: string[], done: () => void) {
        const escape = (text: string) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
        const event = new ClipboardEvent('paste', {
          clipboardData: new DataTransfer(),
          bubbles: true,
          cancelable: true
        })
        // Firefox creates its own data store for a constructed ClipboardEvent.
        event.clipboardData!.setData('text/html', paragraphs.map(text => `<p>${escape(text)}</p>`).join(''))
        element.dispatchEvent(event)
        requestAnimationFrame(() => done())
      },
      body,
      fixture.input.paragraphs
    )
    expect(
      await driver!.executeScript<string[]>(function (element: HTMLElement) {
        return [...element.children].map(node => node.textContent!)
      }, body)
    ).toEqual(fixture.input.paragraphs)
    await driver!.executeScript(setTextRange, body, fixture.input)
    if (fixture.text !== undefined) await driver!.actions().sendKeys(fixture.text).perform()
    else {
      for (let index = 0; index < fixture.count; index++) {
        await driver!
          .actions()
          .sendKeys(fixture.key === 'Delete' ? Key.DELETE : Key.BACK_SPACE)
          .perform()
      }
    }
    const output = (dialect as Record<string, { output: typeof fixture.output }>)[fixture.id]?.output ?? fixture.output
    await drawn()
    const paragraphs = () =>
      driver!.executeScript<string[]>(function (element: HTMLElement) {
        return [...element.children].map(node => node.textContent!)
      }, body)
    expect(await paragraphs()).toEqual(output.paragraphs)
    expect(await driver!.executeScript<ReturnType<typeof readTextRange>>(readTextRange, body)).toEqual({
      anchor: output.anchor,
      focus: output.focus
    })
    await reopen()
    const rebuilt = await driver!.findElement(By.css(selector))
    expect(
      await driver!.executeScript<string[]>(function (element: HTMLElement) {
        return [...element.children].map(node => node.textContent!)
      }, rebuilt)
    ).toEqual(output.paragraphs)
  }, 30_000)
}
