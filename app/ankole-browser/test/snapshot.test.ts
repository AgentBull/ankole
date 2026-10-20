import { existsSync } from 'node:fs'
import { describe, expect, test } from 'bun:test'
import { chromium } from 'playwright-core'
import { SnapshotStore } from '../src/browser/snapshot'

const executable =
  process.env.ANKOLE_BROWSER_TEST_CHROMIUM ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

const pageHTML = `<!doctype html><title>Browser test</title>
<button id="confirm">Confirm</button>
<label for="query">Query</label><input id="query" type="search">
<iframe id="child" srcdoc="<button>Inside</button>"></iframe>
<a href="https://example.com/docs">Docs</a>`

describe.skipIf(!existsSync(executable))('Playwright AI snapshot refs', () => {
  test('an unmatched selector times out within the capture deadline and leaves the page usable', async () => {
    const browser = await chromium.launch({ executablePath: executable, headless: true })
    try {
      const page = await browser.newPage()
      await page.setContent(pageHTML)
      const store = new SnapshotStore()
      for (const interactive of [false, true]) {
        await expect(
          store.capture(page, { selector: '#missing', interactive }, page.mainFrame(), Date.now() + 150)
        ).rejects.toMatchObject({ code: 'timeout', retryable: true })
      }
      expect(await store.capture(page, { selector: '#confirm' })).toContain('Confirm')
    } finally {
      await browser.close()
    }
  }, 10_000)

  test('interactive snapshots retain controls after long static text', async () => {
    const browser = await chromium.launch({ executablePath: executable, headless: true })
    try {
      const page = await browser.newPage()
      await page.setContent(`<p>${'Long static paragraph. '.repeat(1100)}</p>
        <button onclick="this.textContent='Confirmed'">Confirm order</button>
        <label>Query<input value="draft"></label>
        <button disabled>Unavailable</button>
        <div style="cursor:pointer" onclick="this.textContent='Custom clicked'">Custom control</div>
        <iframe srcdoc="<button>Inside</button>"></iframe>`)
      await page.frameLocator('iframe').getByRole('button').waitFor()
      const store = new SnapshotStore()

      const full = await store.capture(page)
      expect(full).toContain('[snapshot truncated]')
      expect(full).not.toContain('Confirm order')

      const text = await store.capture(page, { interactive: true })
      expect(text).not.toContain('Long static paragraph')
      expect(text).not.toContain('[snapshot truncated]')
      expect(text).toContain('draft')
      expect(text).toContain('[disabled=true]')

      const confirm = refOnLine(text, 'button', 'Confirm order')
      const custom = refOnLine(text, 'generic', 'Custom control')
      const inside = refOnLine(text, 'button', 'Inside')
      expect(inside.startsWith('f')).toBe(true)
      await (await store.resolve(page, `@${confirm}`)).click()
      expect(await page.getByRole('button', { name: 'Confirmed', exact: true }).count()).toBe(1)
      await (await store.resolve(page, `@${custom}`)).click()
      expect(await page.getByText('Custom clicked', { exact: true }).count()).toBe(1)
      expect(await (await store.resolve(page, `@${inside}`)).innerText()).toBe('Inside')
    } finally {
      await browser.close()
    }
  }, 20_000)

  test('resolves refs from the latest snapshot and rejects a detached ref', async () => {
    const browser = await chromium.launch({
      executablePath: executable,
      headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage']
    })
    try {
      const page = await browser.newPage()
      await page.setContent(pageHTML)
      await page.frameLocator('#child').getByRole('button', { name: 'Inside' }).waitFor()
      const store = new SnapshotStore()
      const text = await store.capture(page, { interactive: true, urls: true })
      const confirm = refOnLine(text, 'button', 'Confirm')
      const search = refOnLine(text, 'searchbox', 'Query')
      const inside = refOnLine(text, 'button', 'Inside')
      expect(text).toContain('/url:')
      expect(inside.startsWith('f')).toBe(true)
      expect(await (await store.resolve(page, `@${search}`)).inputValue()).toBe('')
      expect(await (await store.resolve(page, `@${inside}`)).innerText()).toBe('Inside')
      await expect(store.resolve(page, '@e99999')).rejects.toMatchObject({ code: 'stale_ref' })

      await page.locator('#query').evaluate(element => element.remove())
      await expect(store.resolve(page, `@${search}`)).rejects.toMatchObject({ code: 'stale_ref' })
      expect(await (await store.resolve(page, '#confirm')).innerText()).toBe('Confirm')

      store.clear()
      await expect(store.resolve(page, `@${confirm}`)).rejects.toMatchObject({ code: 'stale_ref' })

      const scoped = await store.capture(page, { selector: '#confirm' })
      expect(scoped).toContain('Confirm')
      expect(scoped).not.toContain('Docs')
      const child = page.frames().find(frame => frame.parentFrame() !== null)
      if (!child) throw new Error('missing child frame')
      const framed = await store.capture(page, { selector: 'button' }, child)
      expect(framed).toContain('Inside')
      expect(framed).not.toContain('Confirm')
      expect(await (await store.resolve(page, `@${refOnLine(framed, 'button', 'Inside')}`)).innerText()).toBe('Inside')

      const compact = await store.capture(page, { compact: true, urls: true })
      expect(compact.split('\n').every(line => !line.startsWith(' '))).toBe(true)
      expect(compact).toContain('/url:')
      const hiddenURLs = await store.capture(page, {})
      expect(hiddenURLs).not.toContain('/url:')
      await store.capture(page, { depth: 1 })
    } finally {
      await browser.close()
    }
  }, 20_000)
})

function refOnLine(snapshot: string, role: string, name: string): string {
  const line = snapshot.split('\n').find(item => item.includes(role) && item.includes(name) && item.includes('[ref='))
  const ref = line?.match(/\[ref=((?:f\d+)?e\d+)\]/)?.[1]
  if (!ref) throw new Error(`missing ${role} ${name} in snapshot:\n${snapshot}`)
  return ref
}
