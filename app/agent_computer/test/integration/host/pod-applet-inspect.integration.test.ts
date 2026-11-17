import { expect, test } from 'bun:test'
import { access, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { BrowserDaemonServer } from '../../../../ankole-browser/src/daemon/server'
import { inspectApplet } from '../../../src/cli/pod/pod-applet-inspect'

test('Applet diagnostic snapshots expose browser exceptions and denied writes in a fresh profile', async () => {
  const executable =
    process.env.ANKOLE_BROWSER_TEST_CHROMIUM ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
  await access(executable)
  const root = await mkdtemp('/tmp/applet-inspect-')
  const daemon = new BrowserDaemonServer(join(root, 'browser.sock'))
  const server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    fetch(request) {
      if (new URL(request.url).pathname === '/write') {
        return Response.json({ code: 'diagnostic_read_only' }, { status: 403 })
      }
      return new Response(
        `<!doctype html><body>Orders overview<script>
        window.__ANKOLE_APPLET_DIAGNOSTIC__ = {mounted:true,runtimeErrors:['route render failed']};
        console.error('visible console failure');
        fetch('/write', {method:'POST'});
        setTimeout(()=>{throw new Error('unhandled render failure')}, 0);
      </script>`,
        { headers: { 'content-type': 'text/html' } }
      )
    }
  })
  const env = {
    ANKOLE_BROWSER_SOCKET: process.env.ANKOLE_BROWSER_SOCKET,
    ANKOLE_BROWSER_ROUTE: process.env.ANKOLE_BROWSER_ROUTE,
    ANKOLE_BROWSER_MATERIAL: process.env.ANKOLE_BROWSER_MATERIAL,
    ANKOLE_BROWSER_ARTIFACT_ROOT: process.env.ANKOLE_BROWSER_ARTIFACT_ROOT
  }
  try {
    const material = {
      protocol_version: 1,
      route_id: 'br_interactive0000000001',
      data_root: join(root, 'interactive'),
      artifact_root: join(root, 'artifacts'),
      immutable_fingerprint: 'test',
      material_generation: 0,
      profile: { mode: 'persistent_user_data_dir', seed_path: join(root, 'does-not-exist') },
      backend: { kind: 'local_chromium', executable, args: [] },
      navigation: { ssrf_filter: true, allow_file_urls: false },
      idle_ttl_ms: 60000
    }
    const path = join(root, 'material.json')
    await writeFile(path, JSON.stringify(material))
    Object.assign(process.env, {
      ANKOLE_BROWSER_SOCKET: daemon.socketPath,
      ANKOLE_BROWSER_ROUTE: material.route_id,
      ANKOLE_BROWSER_MATERIAL: path,
      ANKOLE_BROWSER_ARTIFACT_ROOT: material.artifact_root
    })
    await daemon.listen()
    const screenshot = join(root, 'diagnostic.png')
    const result = await inspectApplet({ url: server.url.href }, { waitMs: 200, screenshot })
    expect(result.mounted).toBe(true)
    expect(result.text).toContain('Orders overview')
    expect(result.runtimeErrors).toContain('route render failed')
    expect(JSON.stringify(result.runtimeErrors)).toContain('unhandled render failure')
    expect(JSON.stringify(result.consoleErrors)).toContain('visible console failure')
    expect(result.failedRequests).toContainEqual(expect.objectContaining({ method: 'POST', status: 403 }))
    expect((await readFile(screenshot)).subarray(1, 4).toString()).toBe('PNG')
  } finally {
    for (const [key, value] of Object.entries(env)) {
      if (value === undefined) delete process.env[key]
      else process.env[key] = value
    }
    await daemon.close()
    server.stop(true)
    await rm(root, { recursive: true, force: true })
  }
}, 30000)
