import { existsSync } from 'node:fs'
import { describe, expect, test } from 'bun:test'
import { chromium } from 'playwright-core'
import { selectByLabelOrValue } from '../src/browser/browser-session'
import { SnapshotStore } from '../src/browser/snapshot'
import { callWebMCPTool, listWebMCPTools } from '../src/browser/webmcp'

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
      const childFull = await store.capture(page, {}, child)
      expect(childFull).toContain('Inside')
      expect(childFull).not.toContain('Confirm')
      expect(childFull).not.toContain('Docs')
      const childInteractive = await store.capture(page, { interactive: true }, child)
      expect(childInteractive).toContain('Inside')
      expect(childInteractive).not.toContain('Confirm')
      expect(await (await store.resolve(page, `@${refOnLine(childInteractive, 'button', 'Inside')}`)).innerText()).toBe(
        'Inside'
      )
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

  test('diff and query filters preserve full ref clickability and surface bottom-of-DOM modals past the 16 KiB budget', async () => {
    const browser = await chromium.launch({ executablePath: executable, headless: true })
    try {
      const page = await browser.newPage()
      const navLinks = Array.from(
        { length: 360 },
        (_, index) => `<a href="#section-${index}" id="nav-${index}">Navigation destination item number ${index}</a>`
      ).join('\n')
      await page.setContent(`<!doctype html><title>Delta snapshot test</title>
        <nav>${navLinks}</nav>
        <button id="menu-trigger" aria-expanded="false" onclick="
          this.setAttribute('aria-expanded', 'true');
          document.getElementById('modal-root').hidden = false;
        ">Account menu</button>
        <div id="modal-root" role="dialog" aria-label="Transfer confirmation" hidden>
          <label>One-time code<input id="otp" value=""></label>
          <button id="confirm-transfer" onclick="this.textContent='Transfer sent'">Confirm transfer</button>
        </div>`)

      const store = new SnapshotStore()
      const baseline = await store.capture(page, { interactive: true })
      // The 360 navigation links exceed the 16 KiB snapshot budget, truncating bottom controls on a full capture.
      expect(baseline).toContain('[snapshot truncated]')
      const firstNavRef = refOnLine(baseline, 'link', 'Navigation destination item number 0')

      // Without changes, --diff emits the compact sentinel instead of repeating 16 KiB of nav links.
      expect(await store.capture(page, { interactive: true, diff: true })).toBe('(no snapshot changes)')

      // Open the modal at the bottom of the DOM (via JS click because baseline truncated past #menu-trigger).
      await page.locator('#menu-trigger').click()

      // Full interactive snapshot still truncates before reaching the modal at the bottom of the DOM:
      const fullAfterModal = await store.capture(page, { interactive: true, query: 'Confirm transfer' })
      expect(fullAfterModal).toContain('Confirm transfer')
      expect(fullAfterModal).not.toContain('Navigation destination item number 0')

      // Because -q did not overwrite the baseline, --diff now reports ONLY the expanded menu button + new modal!
      const delta = await store.capture(page, { interactive: true, diff: true })
      expect(delta).not.toContain('Navigation destination item number 0')
      expect(delta).not.toContain('[snapshot truncated]')
      expect(delta).toContain('[expanded=true]')
      expect(delta).toContain('Confirm transfer')
      expect(delta).toContain('One-time code')

      // Unchanged @eN refs from the top of the page (omitted from delta output) remain live and clickable!
      expect(await (await store.resolve(page, `@${firstNavRef}`)).getAttribute('href')).toBe('#section-0')

      // And newly added modal refs in the delta are immediately actionable:
      const confirmTransferRef = refOnLine(delta, 'button', 'Confirm transfer')
      await (await store.resolve(page, `@${confirmTransferRef}`)).click()
      expect(await page.locator('#confirm-transfer').innerText()).toBe('Transfer sent')

      // Unmatched -q returns a clear sentinel.
      expect(await store.capture(page, { interactive: true, query: 'nonexistent-control-xyz' })).toBe(
        '(no matching snapshot lines)'
      )
    } finally {
      await browser.close()
    }
  }, 20_000)

  test('selectByLabelOrValue isolates ARIA combobox popups from sibling controls and parent frames', async () => {
    const browser = await chromium.launch({ executablePath: executable, headless: true })
    try {
      const page = await browser.newPage()
      await page.setContent(`<!doctype html><title>Frame combobox isolation</title>
        <div id="main-decoy-listbox" role="listbox" onclick="window.__mainDecoyClicked = true">
          <div role="option">ap-northeast-1</div>
        </div>
        <iframe id="combo-frame" srcdoc="
          <!doctype html>
          <div id='preopen-sidebar' role='listbox' onclick='window.__sidebarClicked = true'>
            <div role='option'>ap-northeast-1</div>
          </div>
          <button id='other-owner' role='combobox' aria-expanded='true' aria-controls='owned-by-other'>Other</button>
          <div id='owned-by-other' role='listbox' onclick='window.__otherOwnedClicked = true'>
            <div role='option'>ap-northeast-1</div>
          </div>
          <button id='unowned-combo' role='combobox' aria-expanded='false'>Choose region</button>
          <div id='unowned-popup' role='listbox' hidden></div>
          <script>
            const combo = document.getElementById('unowned-combo');
            const popup = document.getElementById('unowned-popup');
            combo.addEventListener('click', () => {
              combo.setAttribute('aria-expanded', 'true');
              popup.hidden = false;
              setTimeout(() => {
                const opt = document.createElement('div');
                opt.setAttribute('role', 'option');
                opt.textContent = 'ap-northeast-1';
                opt.addEventListener('click', () => {
                  combo.dataset.selected = 'ap-northeast-1';
                  combo.setAttribute('aria-expanded', 'false');
                  popup.hidden = true;
                });
                popup.appendChild(opt);
              }, 60);
            });
          </script>
        "></iframe>`)
      await page.frameLocator('#combo-frame').locator('#unowned-combo').waitFor()
      const childFrame = page.frames().find(frame => frame.parentFrame() !== null)
      if (!childFrame) throw new Error('missing child frame')

      await selectByLabelOrValue(childFrame, childFrame.locator('#unowned-combo'), 'ap-northeast-1', Date.now() + 5_000)

      expect(
        await page.evaluate(() => Boolean((window as unknown as Record<string, unknown>).__mainDecoyClicked))
      ).toBe(false)
      expect(
        await childFrame.evaluate(() => ({
          selected: document.getElementById('unowned-combo')?.dataset.selected,
          sidebarClicked: Boolean((window as unknown as Record<string, unknown>).__sidebarClicked),
          otherOwnedClicked: Boolean((window as unknown as Record<string, unknown>).__otherOwnedClicked)
        }))
      ).toEqual({
        selected: 'ap-northeast-1',
        sidebarClicked: false,
        otherOwnedClicked: false
      })
    } finally {
      await browser.close()
    }
  }, 15_000)

  test('selectByLabelOrValue selects async portal options when aria-haspopup=listbox omits aria-expanded and starts with zero listboxes', async () => {
    const browser = await chromium.launch({ executablePath: executable, headless: true })
    try {
      const page = await browser.newPage()
      await page.setContent(`<!doctype html><title>Async popup listbox</title>
        <button id="async-trigger" aria-haspopup="listbox">Select tier</button>
        <script>
          const btn = document.getElementById('async-trigger');
          btn.addEventListener('click', () => {
            setTimeout(() => {
              const portal = document.createElement('div');
              portal.setAttribute('role', 'listbox');
              setTimeout(() => {
                const opt = document.createElement('div');
                opt.setAttribute('role', 'option');
                opt.textContent = 'Enterprise';
                opt.addEventListener('click', () => {
                  btn.dataset.selected = 'Enterprise';
                  portal.remove();
                });
                portal.appendChild(opt);
              }, 120);
              document.body.appendChild(portal);
            }, 30);
          });
        </script>`)

      await selectByLabelOrValue(page.mainFrame(), page.locator('#async-trigger'), 'Enterprise', Date.now() + 5_000)
      expect(await page.evaluate(() => document.getElementById('async-trigger')?.dataset.selected)).toBe('Enterprise')
    } finally {
      await browser.close()
    }
  }, 15_000)

  test('selectByLabelOrValue resolves <label for> pointing to a non-labelable <div role="combobox"> with nested <input>', async () => {
    const browser = await chromium.launch({ executablePath: executable, headless: true })
    try {
      const page = await browser.newPage()
      await page.setContent(`<!doctype html><title>Label-for combobox</title>
        <label id="region-label" for="region-combo">Deployment region</label>
        <div id="region-combo" role="combobox" aria-expanded="false" aria-controls="region-listbox">
          <input id="region-input" placeholder="Type to filter" autocomplete="off">
        </div>
        <div id="region-listbox" role="listbox" hidden></div>
        <script>
          const combo = document.getElementById('region-combo');
          const input = document.getElementById('region-input');
          const listbox = document.getElementById('region-listbox');
          const regions = ['us-east-1', 'eu-central-1', 'ap-northeast-1'];
          function render(filterText) {
            listbox.innerHTML = '';
            if (!filterText) return;
            for (const region of regions.filter(item => item.includes(filterText.toLowerCase()))) {
              const opt = document.createElement('div');
              opt.setAttribute('role', 'option');
              opt.textContent = region;
              opt.addEventListener('click', () => {
                input.value = region;
                combo.dataset.selected = region;
                combo.setAttribute('aria-expanded', 'false');
                listbox.hidden = true;
              });
              listbox.appendChild(opt);
            }
          }
          combo.addEventListener('click', () => {
            combo.setAttribute('aria-expanded', 'true');
            listbox.hidden = false;
            render(input.value);
          });
          input.addEventListener('input', () => {
            combo.setAttribute('aria-expanded', 'true');
            listbox.hidden = false;
            render(input.value);
          });
        </script>`)

      await selectByLabelOrValue(page.mainFrame(), page.locator('#region-label'), 'eu-central-1', Date.now() + 5_000)
      expect(
        await page.evaluate(() => ({
          selected: document.getElementById('region-combo')?.dataset.selected,
          inputValue: (document.getElementById('region-input') as HTMLInputElement | null)?.value
        }))
      ).toEqual({
        selected: 'eu-central-1',
        inputValue: 'eu-central-1'
      })
    } finally {
      await browser.close()
    }
  }, 15_000)

  test('WebMCP discovers and invokes declarative <form toolname> when navigator.modelContext.getTools() returns []', async () => {
    const browser = await chromium.launch({ executablePath: executable, headless: true })
    try {
      const page = await browser.newPage()
      await page.setContent(`<!doctype html><title>WebMCP coexistence</title>
        <form toolname="create_alert" tooldescription="Create an incident alert" toolautosubmit>
          <input name="service" required toolparamdescription="Service name">
          <select name="severity"><option value="sev2">SEV-2</option><option value="sev1">SEV-1</option></select>
        </form>
        <script>
          document.querySelector('form[toolname="create_alert"]').addEventListener('submit', event => {
            event.preventDefault();
            const data = new FormData(event.target);
            document.title = data.get('service') + ':' + data.get('severity');
          });
          Object.defineProperty(navigator, 'modelContext', {
            configurable: true,
            value: {
              async getTools() { return []; },
              async executeTool() { throw new Error('unexpected imperative executeTool call'); }
            }
          });
        </script>`)

      const listed = await listWebMCPTools(page, page.mainFrame(), Date.now() + 5_000)
      expect(listed).toMatchObject({
        supported: true,
        protocol: 'declarative_dom',
        tools: [
          {
            name: 'create_alert',
            description: 'Create an incident alert',
            annotations: { autosubmit: true }
          }
        ]
      })

      const called = await callWebMCPTool(
        page,
        page.mainFrame(),
        'create_alert',
        { service: 'payments', severity: 'sev1' },
        Date.now() + 5_000
      )
      expect(called).toEqual({
        protocol: 'declarative_dom',
        tool: 'create_alert',
        output: { filled: ['service', 'severity'], autosubmitted: true }
      })
      expect(await page.title()).toBe('payments:sev1')

      // Even when modelContext registers an imperative tool, calling a declarative <form toolname> not in getTools() still dispatches to the form.
      await page.evaluate(() => {
        Object.defineProperty(navigator, 'modelContext', {
          configurable: true,
          value: {
            async getTools() {
              return [{ name: 'ping_status', description: 'Ping status' }]
            },
            async executeTool(tool: { name: string }) {
              if (tool.name === 'ping_status') return { ok: true }
              throw new Error(`No tool named ${tool.name}`)
            }
          }
        })
      })

      const formFallback = await callWebMCPTool(
        page,
        page.mainFrame(),
        'create_alert',
        { service: 'checkout', severity: 'sev2' },
        Date.now() + 5_000
      )
      expect(formFallback).toEqual({
        protocol: 'declarative_dom',
        tool: 'create_alert',
        output: { filled: ['service', 'severity'], autosubmitted: true }
      })
      expect(await page.title()).toBe('checkout:sev2')
    } finally {
      await browser.close()
    }
  }, 15_000)
})

function refOnLine(snapshot: string, role: string, name: string): string {
  const line = snapshot.split('\n').find(item => item.includes(role) && item.includes(name) && item.includes('[ref='))
  const ref = line?.match(/\[ref=((?:f\d+)?e\d+)\]/)?.[1]
  if (!ref) throw new Error(`missing ${role} ${name} in snapshot:\n${snapshot}`)
  return ref
}
