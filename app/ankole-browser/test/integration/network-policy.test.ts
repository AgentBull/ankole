import { afterEach, describe, expect, test } from 'bun:test'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { connectLocalChromium, type LocalChromiumHandle } from '../../src/browser/local-chromium'
import type { BrowserMaterial } from '../../src/protocol'

const executable =
  process.env.ANKOLE_BROWSER_TEST_CHROMIUM ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const roots: string[] = []
const browsers: LocalChromiumHandle[] = []

afterEach(async () => {
  await Promise.all(browsers.splice(0).map(browser => browser.stop()))
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

async function startBrowser(ssrfFilter: boolean) {
  const root = await mkdtemp('/tmp/ankole-browser-network-')
  roots.push(root)
  const material: BrowserMaterial = {
    protocol_version: 1,
    route_id: 'br_network00000001',
    data_root: join(root, 'data'),
    artifact_root: join(root, 'artifacts'),
    immutable_fingerprint: 'sha256:network',
    material_generation: 0,
    profile: { mode: 'persistent_user_data_dir' },
    backend: { kind: 'local_chromium', executable, args: [] },
    navigation: { ssrf_filter: ssrfFilter, allow_file_urls: false },
    idle_ttl_ms: 60_000
  }
  const handle = await connectLocalChromium(material, 'default')
  browsers.push(handle)
  return { handle, material }
}

async function browser(ssrfFilter: boolean) {
  const { handle } = await startBrowser(ssrfFilter)
  return await handle.browser.contexts()[0]!.newPage()
}

describe.skipIf(process.env.ANKOLE_BROWSER_INTEGRATION !== '1')('native browser connection policy', () => {
  test('the proxy blocks loopback even when no Playwright route guard is installed', async () => {
    let requests = 0
    const server = Bun.serve({
      hostname: '127.0.0.1',
      port: 0,
      fetch: () => {
        requests += 1
        return new Response('must not reach this server')
      }
    })
    try {
      const page = await browser(true)
      await expect(page.goto(server.url.href, { timeout: 5_000 })).rejects.toThrow()
      expect(requests).toBe(0)
      const isolated = await page.context().newPage()
      await isolated.goto('data:text/html,<title>isolated page</title>')
      const result = await isolated.evaluate(async url => {
        try {
          await fetch(url)
          return 'allowed'
        } catch {
          return 'blocked'
        }
      }, server.url.href)
      expect(result).toBe('blocked')
      expect(requests).toBe(0)
    } finally {
      server.stop(true)
    }
  }, 15_000)

  test('intranet HTTP and WebSockets work, while redirected and child metadata requests fail', async () => {
    const hosts: string[] = []
    const server = Bun.serve({
      hostname: '127.0.0.1',
      port: 0,
      fetch(request, server) {
        hosts.push(request.headers.get('host') ?? '')
        const url = new URL(request.url)
        if (url.pathname === '/ws' && server.upgrade(request)) return undefined
        if (url.pathname === '/redirect') return Response.redirect('http://metadata/blocked', 302)
        return new Response('<!doctype html><title>intranet</title>', { headers: { 'content-type': 'text/html' } })
      },
      websocket: {
        message(socket, message) {
          socket.send(message)
        }
      }
    })
    try {
      const page = await browser(false)
      const origin = `http://localhost:${server.port}`
      await page.goto(origin, { timeout: 5_000 })
      expect(await page.title()).toBe('intranet')
      expect(hosts).toContain(`localhost:${server.port}`)
      expect(
        await page.evaluate(
          url =>
            new Promise<string>((resolve, reject) => {
              const socket = new WebSocket(url)
              socket.onopen = () => socket.send('through checked TCP')
              socket.onmessage = event => {
                socket.close()
                resolve(String(event.data))
              }
              socket.onerror = () => reject(new Error('WebSocket failed'))
            }),
          `ws://localhost:${server.port}/ws`
        )
      ).toBe('through checked TCP')
      expect(
        await page.evaluate(() =>
          fetch('http://metadata/child').then(
            () => 'allowed',
            () => 'blocked'
          )
        )
      ).toBe('blocked')
      const failedFrame = page.waitForEvent('requestfailed', {
        predicate: request => request.url() === 'http://metadata/frame',
        timeout: 5_000
      })
      await page.evaluate(() => {
        const frame = document.createElement('iframe')
        frame.src = 'http://metadata/frame'
        document.body.append(frame)
      })
      expect((await failedFrame).failure()?.errorText).toContain('SOCKS')
      await expect(page.goto(`${origin}/redirect`, { timeout: 5_000 })).rejects.toThrow()
    } finally {
      server.stop(true)
    }
  }, 15_000)

  test.each(['legacy metadata', 'changed network policy'])(
    'restarts %s with the saved profile',
    async mode => {
      const { handle, material } = await startBrowser(false)
      await handle.browser.contexts()[0]!.addCookies([
        {
          url: 'http://localhost/',
          name: 'login',
          value: 'retained',
          expires: Math.floor(Date.now() / 1000) + 3600
        }
      ])
      await handle.browser.close()
      const path = join(material.data_root, 'sessions/default/live.json')
      if (mode === 'legacy metadata') {
        const metadata = JSON.parse(await readFile(path, 'utf8'))
        delete metadata.proxy_port
        delete metadata.ssrf_filter
        await writeFile(path, JSON.stringify(metadata))
      } else {
        material.navigation.ssrf_filter = true
      }
      const restored = await connectLocalChromium(material, 'default')
      browsers.push(restored)
      expect(restored.pid).not.toBe(handle.pid)
      expect(await restored.browser.contexts()[0]!.cookies('http://localhost/')).toContainEqual(
        expect.objectContaining({ name: 'login', value: 'retained' })
      )
      const metadata = JSON.parse(await readFile(path, 'utf8'))
      expect(metadata.proxy_port).toBeGreaterThan(0)
      expect(metadata.ssrf_filter).toBe(material.navigation.ssrf_filter)
    },
    15_000
  )
})
