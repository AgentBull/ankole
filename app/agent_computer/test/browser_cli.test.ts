import { afterAll, describe, expect, it } from 'bun:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const workspaceRoot = mkdtempSync(join(tmpdir(), 'ankole-browser-'))
const cli = new URL('../src/browser_cli.ts', import.meta.url).pathname

afterAll(() => {
  rmSync(workspaceRoot, { force: true, recursive: true })
})

describe('@ankole/agent-computer browser CLI', () => {
  it('reports local Chromium by default and still supports helper scripts', () => {
    const doctor = runBrowser(['doctor'])
    expect(doctor.backend).toBe('chromium')
    expect(doctor.capture_dir).toBe('/workspace/temp/browser')
    expect('chromium_path' in doctor).toBe(true)

    const script = "print('browser-run-ok')"
    const ran = runBrowser(['run', '--script', script])
    expect(ran.exit_code).toBe(0)
    expect(String(ran.stdout)).toContain('browser-run-ok')
  })

  it('validates and redacts remote CDP endpoint config in doctor output', () => {
    const doctor = runBrowser(['doctor'], {
      ANKOLE_REMOTE_BROWSER_CDP_CONFIG_JSON: JSON.stringify({
        adapter: 'cdp_endpoint',
        endpoint_url: 'wss://USER:PASS@brd.superproxy.io:9222',
        headers: { Authorization: 'Bearer cf-token' },
        connect_timeout_ms: 30_000
      })
    })

    expect(doctor.ok).toBe(true)
    expect(doctor.backend).toBe('remote_cdp')
    expect(doctor.adapter).toBe('cdp_endpoint')
    const output = JSON.stringify(doctor)
    expect(output).not.toContain('USER:PASS')
    expect(output).not.toContain('cf-token')
    expect(output).toContain('[redacted]')
  })

  it('validates remote CDP session request config in doctor output', () => {
    const doctor = runBrowser(['doctor'], {
      ANKOLE_REMOTE_BROWSER_CDP_CONFIG_JSON: JSON.stringify({
        adapter: 'cdp_session_request',
        request: {
          url: 'http://rayobrowse.lan:3000/connect?headless=true&os=windows',
          method: 'GET',
          response: { type: 'json', path: ['webSocketDebuggerUrl'] }
        }
      })
    })

    expect(doctor.ok).toBe(true)
    expect(doctor.backend).toBe('remote_cdp')
    expect(doctor.adapter).toBe('cdp_session_request')
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
            webSocketDebuggerUrl: `ws://127.0.0.1:${server.port}/devtools/browser/mock`
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
    const remoteEnv = {
      ANKOLE_REMOTE_BROWSER_CDP_CONFIG_JSON: JSON.stringify({
        adapter: 'cdp_endpoint',
        endpoint_url: `http://127.0.0.1:${server.port}`,
        headers: { Authorization: token }
      })
    }
    const launch = Bun.spawn(['bun', cli, '--json', 'launch', '--session', session], {
      env: browserEnv(remoteEnv),
      stdout: 'pipe',
      stderr: 'pipe'
    })

    try {
      const ready = await readJsonLine(launch.stdout)
      expect(ready.ok).toBe(true)
      expect(ready.backend).toBe('remote_cdp')
      expect(JSON.stringify(ready)).not.toContain(token)

      const status = await runBrowserAsync(['status', '--session', session], remoteEnv)
      expect(status.ok).toBe(true)
      expect(status.backend).toBe('remote_cdp')
      expect(status.browser).toBe('FakeCDP/1.0')
    } finally {
      launch.kill()
      await launch.exited
      server.stop(true)
    }
  })

  it('blocks cloud metadata endpoint navigation before any browser backend work', () => {
    const result = runBrowserRaw(['navigate', '--url', 'http://169.254.169.254/latest/meta-data'])
    expect(result.exitCode).toBe(1)
    const parsed = JSON.parse(result.stdout)
    expect(parsed.ok).toBe(false)
    expect(String(parsed.error)).toContain('cloud metadata')
  })

  it('drives a persistent Chromium session through the in-process CDP engine when available', async () => {
    const doctor = runBrowser(['doctor'])
    if (typeof doctor.chromium_path !== 'string' || doctor.chromium_path.length === 0) return

    const session = `chromium-${Date.now()}`
    process.env.ANKOLE_WORKSPACE_ROOT = workspaceRoot
    const browser = await import('../src/browser_cdp')
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
    const doctor = runBrowser(['doctor'])
    if (typeof doctor.chromium_path !== 'string' || doctor.chromium_path.length === 0) return

    process.env.ANKOLE_WORKSPACE_ROOT = workspaceRoot
    const browser = await import('../src/browser_cdp')
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

function runBrowser(args: string[], extraEnv: Record<string, string> = {}): Record<string, unknown> {
  const result = runBrowserRaw(args, extraEnv)
  expect(result.exitCode, result.stderr).toBe(0)
  return JSON.parse(result.stdout)
}

function runBrowserRaw(
  args: string[],
  extraEnv: Record<string, string> = {}
): { exitCode: number | null; stdout: string; stderr: string } {
  const result = Bun.spawnSync(['bun', cli, '--json', ...args], {
    env: browserEnv(extraEnv),
    stdout: 'pipe',
    stderr: 'pipe'
  })
  return {
    exitCode: result.exitCode,
    stdout: Buffer.from(result.stdout).toString('utf8'),
    stderr: Buffer.from(result.stderr).toString('utf8')
  }
}

async function runBrowserAsync(
  args: string[],
  extraEnv: Record<string, string> = {}
): Promise<Record<string, unknown>> {
  const result = Bun.spawn(['bun', cli, '--json', ...args], {
    env: browserEnv(extraEnv),
    stdout: 'pipe',
    stderr: 'pipe'
  })
  const [exitCode, stdout, stderr] = await Promise.all([
    result.exited,
    new Response(result.stdout).text(),
    new Response(result.stderr).text()
  ])
  expect(exitCode, stderr).toBe(0)
  return JSON.parse(stdout)
}

function browserEnv(extra: Record<string, string> = {}): Record<string, string> {
  return {
    ...process.env,
    ...extra,
    ANKOLE_WORKSPACE_ROOT: workspaceRoot
  }
}

function refFor(snapshot: string, role: string, name: string): string {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return snapshot.match(new RegExp(`\\[(e\\d+)\\] ${role} "${escaped}"`))?.[1] ?? ''
}

async function readJsonLine(stream: ReadableStream<Uint8Array> | null): Promise<Record<string, unknown>> {
  if (!stream) throw new Error('missing stdout stream')
  const reader = stream.getReader()
  let buffer = ''
  const deadline = Date.now() + 10_000
  try {
    while (Date.now() < deadline) {
      const remaining = Math.max(1, deadline - Date.now())
      const timeout = new Promise<ReadableStreamReadResult<Uint8Array>>(resolve =>
        setTimeout(() => resolve({ done: true, value: undefined }), remaining)
      )
      const chunk = await Promise.race([reader.read(), timeout])
      if (chunk.done) break
      buffer += Buffer.from(chunk.value).toString('utf8')
      const line = buffer.split(/\r?\n/).find(candidate => candidate.trim().startsWith('{'))
      if (line) return JSON.parse(line)
    }
  } finally {
    reader.releaseLock()
  }
  throw new Error(`timed out waiting for JSON line: ${buffer}`)
}
