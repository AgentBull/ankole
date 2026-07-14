import { afterAll, describe, expect, it } from 'bun:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const workspaceRoot = mkdtempSync(join(tmpdir(), 'ankole-cdp-'))
process.env.ANKOLE_WORKSPACE_ROOT = workspaceRoot
const browser = await import('../src/tools/browser/cdp')
const { assertSafeBrowserURL } = await import('../src/tools/browser/cdp/utils')
const { CDPClient } = await import('../src/tools/browser/cdp/client')
const { createLocalBrowserContext } = await import('../src/tools/browser/cdp/chromium')
const { attachPage, evaluate } = await import('../src/tools/browser/cdp/page')

afterAll(() => {
  rmSync(workspaceRoot, { force: true, recursive: true })
})

describe('@ankole/agent-computer browser CDP runtime', () => {
  it('uses the exact Chrome DevTools Protocol Id field casing', async () => {
    const messages: Array<{ id: number; method: string; params: Record<string, unknown>; sessionId?: string }> = []
    const server = Bun.serve({
      port: 0,
      fetch(request, server) {
        if (server.upgrade(request)) return
        return new Response('upgrade failed', { status: 400 })
      },
      websocket: {
        message(socket, rawMessage) {
          const message = JSON.parse(String(rawMessage)) as (typeof messages)[number]
          messages.push(message)

          const result =
            message.method === 'Target.createBrowserContext'
              ? { browserContextId: 'context-1' }
              : message.method === 'Target.createTarget'
                ? { targetId: 'target-1' }
                : message.method === 'Target.getTargets'
                  ? {
                      targetInfos: [
                        {
                          targetId: 'target-1',
                          type: 'page',
                          title: '',
                          url: 'about:blank',
                          attached: false,
                          browserContextId: 'context-1'
                        }
                      ]
                    }
                  : message.method === 'Target.attachToTarget'
                    ? { sessionId: 'session-1' }
                    : message.method === 'Page.getFrameTree'
                      ? { frameTree: { frame: { id: 'frame-1' } } }
                      : message.method === 'Runtime.evaluate'
                        ? { result: { type: 'number', value: 2 } }
                        : {}

          socket.send(JSON.stringify({ id: message.id, result }))

          if (message.method === 'Runtime.enable') {
            socket.send(
              JSON.stringify({
                method: 'Runtime.executionContextCreated',
                sessionId: 'session-1',
                params: {
                  context: {
                    id: 42,
                    auxData: { isDefault: true, frameId: 'frame-1' }
                  }
                }
              })
            )
          }
        }
      }
    })
    const connectURL = `ws://127.0.0.1:${server.port}`

    try {
      expect(await createLocalBrowserContext(connectURL)).toEqual({
        browserContextId: 'context-1',
        targetId: 'target-1'
      })

      const cdp = await CDPClient.connect(connectURL)
      try {
        const page = await attachPage(cdp, 'target-1', 'context-1')
        expect(page).toMatchObject({
          targetId: 'target-1',
          sessionId: 'session-1',
          mainFrameId: 'frame-1',
          mainContextId: 42
        })
        expect(await evaluate<number>(cdp, page, '1 + 1')).toBe(2)
      } finally {
        cdp.close()
      }

      expect(messageFor(messages, 'Target.createTarget')).toMatchObject({
        params: { url: 'about:blank', browserContextId: 'context-1' }
      })
      expect(messageFor(messages, 'Target.attachToTarget')).toMatchObject({
        params: { targetId: 'target-1', flatten: true }
      })
      expect(messageFor(messages, 'Runtime.evaluate')).toMatchObject({
        params: { contextId: 42 },
        sessionId: 'session-1'
      })
    } finally {
      server.stop(true)
    }
  })

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

  it('blocks non-public navigation before any browser backend work when SSRF filtering is on', async () => {
    await expect(
      browser.browserNavigate(
        { session: `private-block-${Date.now()}`, url: 'https://10.0.0.8/internal' },
        { ssrfFilter: true }
      )
    ).rejects.toThrow('security.ssrf_filter')

    await expect(
      browser.browserExtractFromSession(
        { session: `private-block-extract-${Date.now()}`, url: 'https://localhost/internal' },
        { ssrfFilter: true }
      )
    ).rejects.toThrow('security.ssrf_filter')
  })

  it('applies SSRF filtering only when enabled', () => {
    expect(() => assertSafeBrowserURL('https://10.0.0.8/internal')).not.toThrow()
    expect(() => assertSafeBrowserURL('https://10.0.0.8/internal', { ssrfFilter: false })).not.toThrow()
    expect(() => assertSafeBrowserURL('https://10.0.0.8/internal', { ssrfFilter: true })).toThrow(
      'security.ssrf_filter'
    )
    expect(() => assertSafeBrowserURL('https://example.com/page', { ssrfFilter: true })).not.toThrow()
    expect(() => assertSafeBrowserURL('https://169.254.169.254/latest', { ssrfFilter: false })).toThrow(
      'cloud metadata'
    )
  })

  it('rejects URLs through the shared kernel classifier, including canonicalized literals', () => {
    // The classification vector matrix lives in the kernel's Rust tests; this
    // proves the guard consumes that classifier, not a local reimplementation.
    const blocked = { ssrfFilter: true }
    for (const url of [
      'https://localhost/x',
      'https://[::1]/x',
      'https://0x7f000001/x',
      'https://[::ffff:10.0.0.1]/x'
    ]) {
      expect(() => assertSafeBrowserURL(url, blocked)).toThrow('security.ssrf_filter')
    }
    expect(() => assertSafeBrowserURL('https://intranet-wiki/x', blocked)).not.toThrow()
    expect(() => assertSafeBrowserURL('https://[fd00:ec2::254]/x')).toThrow('cloud metadata')
    expect(() => assertSafeBrowserURL('ftp://example.com/x')).toThrow('unsupported browser URL protocol: ftp:')
    expect(() => assertSafeBrowserURL('data:text/plain,hi')).not.toThrow()
  })

  it('drives a persistent Chromium session through the CDP engine when available', async () => {
    if (!browser.findChromium()) return

    const session = `chromium-${Date.now()}`
    const options = {}
    const html = [
      '<html><body>',
      '<a href="#models">Models</a>',
      '<section id="models">Model Catalog</section>',
      '<label>Name <input aria-label="Name" /></label>',
      `<button onclick="document.getElementById('result').textContent = 'Hello ' + document.querySelector('input').value">Submit</button>`,
      '<p id="result"></p>',
      '</body></html>'
    ].join('')
    const server = Bun.serve({
      port: 0,
      fetch() {
        return new Response(html, { headers: { 'content-type': 'text/html' } })
      }
    })

    try {
      const ready = await browser.ensureBrowserSession({ session }, options)
      expect(ready.ok).toBe(true)
      expect(ready.backend).toBe('chromium')
      expect(typeof ready.browser_context_id).toBe('string')
      expect(typeof ready.target_id).toBe('string')

      const navigated = await browser.browserNavigate(
        {
          session,
          url: `http://127.0.0.1:${server.port}`
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
      server.stop(true)
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

function messageFor(
  messages: Array<{ method: string; params: Record<string, unknown>; sessionId?: string }>,
  method: string
) {
  return messages.find(message => message.method === method)
}
