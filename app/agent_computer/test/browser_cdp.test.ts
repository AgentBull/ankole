import { afterAll, describe, expect, it } from 'bun:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const workspaceRoot = mkdtempSync(join(tmpdir(), 'ankole-cdp-'))
process.env.ANKOLE_WORKSPACE_ROOT = workspaceRoot
const browser = await import('../src/tools/browser/cdp')

afterAll(() => {
  rmSync(workspaceRoot, { force: true, recursive: true })
})

describe('@ankole/agent-computer browser CDP runtime', () => {
  it('passes configured headers to remote CDP discovery and websocket connections', async () => {
    const token = 'Bearer remote-cdp-token'
    const server = Bun.serve<{ headers: Headers }>({
      port: 0,
      fetch(request, server) {
        const url = new URL(request.url)
        if (request.headers.get('authorization') !== token) {
          return new Response('missing authorization', { status: 401 })
        }

        if (url.pathname === '/json/version') {
          return Response.json({
            ['webSocketDebuggerUrl']: `ws://127.0.0.1:${server.port}/devtools/browser/mock`
          })
        }

        if (url.pathname === '/devtools/browser/mock') {
          if (server.upgrade(request, { data: { headers: request.headers } })) return
          return new Response('upgrade failed', { status: 400 })
        }

        return new Response('not found', { status: 404 })
      },
      websocket: {
        message(socket, rawMessage) {
          const message = JSON.parse(String(rawMessage)) as { id: number; method: string }
          if (message.method === 'Browser.getVersion') {
            socket.send(JSON.stringify({ id: message.id, result: { product: 'FakeCDP/1.0' } }))
          }
        }
      }
    })

    const session = `remote-cdp-${Date.now()}`
    const options = {
      workspaceRoot,
      remoteCDPConfig: {
        adapter: 'cdp_endpoint',
        endpoint_url: `http://127.0.0.1:${server.port}`,
        headers: { Authorization: token }
      }
    } as const

    try {
      const ready = await browser.ensureBrowserSession({ session }, options)
      expect(ready.ok).toBe(true)
      expect(ready.backend).toBe('remote_cdp')
      expect(JSON.stringify(ready)).not.toContain(token)

      const status = await browser.browserStatus({ session }, options)
      expect(status.ok).toBe(true)
      expect(status.backend).toBe('remote_cdp')
      expect(status.browser).toBe('FakeCDP/1.0')
    } finally {
      await browser.releaseBrowserSession({ session }, options)
      server.stop(true)
    }
  })

  it('blocks cloud metadata endpoint navigation before any browser backend work', async () => {
    await expect(
      browser.browserNavigate({
        session: `metadata-block-${Date.now()}`,
        url: 'http://169.254.169.254/latest/meta-data'
      })
    ).rejects.toThrow('cloud metadata')
  })

  it('drives a persistent Chromium session through the CDP engine when available', async () => {
    if (!browser.findChromium()) return

    const session = `chromium-${Date.now()}`
    const options = {}

    try {
      const ready = await browser.ensureBrowserSession({ session }, options)
      expect(ready.ok).toBe(true)
      expect(ready.backend).toBe('chromium')
      expect(typeof ready.browser_context_id).toBe('string')
      expect(typeof ready.target_id).toBe('string')

      const html = [
        '<html><body>',
        '<a href="#models">Models</a>',
        '<section id="models">Model Catalog</section>',
        '<label>Name <input aria-label="Name" /></label>',
        `<button onclick="document.getElementById('result').textContent = 'Hello ' + document.querySelector('input').value">Submit</button>`,
        '<p id="result"></p>',
        '</body></html>'
      ].join('')
      const navigated = await browser.browserNavigate(
        {
          session,
          url: `data:text/html,${encodeURIComponent(html)}`
        },
        options
      )
      const linkRef = refFor(String(navigated.snapshot), 'link', 'Models')
      expect(linkRef).toBeTruthy()

      const linked = await browser.browserClick({ session, ref: linkRef }, options)
      expect(String(linked.snapshot)).toContain('#models')

      const inputRef = refFor(String(linked.snapshot), 'textbox', 'Name')
      expect(inputRef).toBeTruthy()

      const typed = await browser.browserType({ session, ref: inputRef, text: 'Alice' }, options)
      const buttonRef = refFor(String(typed.snapshot), 'button', 'Submit')
      expect(buttonRef).toBeTruthy()

      const clicked = await browser.browserClick({ session, ref: buttonRef }, options)
      expect(String(clicked.snapshot)).toContain('Hello Alice')

      const found = await browser.browserFindInSession({ session, query: 'Hello', contextLines: 1 }, options)
      expect(String(found.text)).toContain('Hello Alice')

      const screenshot = await browser.browserScreenshot({ session }, options)
      expect(screenshot.ok).toBe(true)
      expect(typeof screenshot.screenshot_path).toBe('string')
    } finally {
      await browser.releaseBrowserSession({ session }, options)
    }
  }, 30_000)

  it('reuses the Chromium process while isolating sessions with BrowserContext', async () => {
    if (!browser.findChromium()) return

    const sessionA = `chromium-context-a-${Date.now()}`
    const sessionB = `chromium-context-b-${Date.now()}`
    const server = Bun.serve({
      port: 0,
      fetch(request) {
        const url = new URL(request.url)
        const setValue = url.searchParams.get('set')
        const html = [
          '<html><body><p id="value"></p><script>',
          setValue ? `localStorage.setItem('browser-test-value', ${JSON.stringify(setValue)});` : '',
          "document.getElementById('value').textContent = 'value=' + (localStorage.getItem('browser-test-value') || 'empty');",
          '</script></body></html>'
        ].join('')
        return new Response(html, { headers: { 'content-type': 'text/html' } })
      }
    })
    const url = `http://127.0.0.1:${server.port}/`

    try {
      const readyA = await browser.ensureBrowserSession({ session: sessionA })
      const readyB = await browser.ensureBrowserSession({ session: sessionB })

      expect(readyA.backend).toBe('chromium')
      expect(readyB.backend).toBe('chromium')
      expect(readyA.pid).toBe(readyB.pid)
      expect(readyA.browser_context_id).not.toBe(readyB.browser_context_id)

      const setA = await browser.browserNavigate({ session: sessionA, url: `${url}?set=alpha` })
      expect(String(setA.snapshot)).toContain('value=alpha')

      const readB = await browser.browserNavigate({ session: sessionB, url })
      expect(String(readB.snapshot)).toContain('value=empty')

      const readA = await browser.browserNavigate({ session: sessionA, url })
      expect(String(readA.snapshot)).toContain('value=alpha')
    } finally {
      await browser.releaseBrowserSession({ session: sessionA })
      await browser.releaseBrowserSession({ session: sessionB })
      server.stop(true)
    }
  }, 30_000)
})

function refFor(snapshot: string, role: string, name: string): string {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return snapshot.match(new RegExp(`\\[(e\\d+)\\] ${role} "${escaped}"`))?.[1] ?? ''
}
