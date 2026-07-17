import { afterEach, describe, expect, test } from 'bun:test'
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { createServer, type Server } from 'node:net'
import { dirname, join } from 'node:path'
import { BrowserRouteMaterializer } from '../src/browser-runtime/materializer'
import { BrowserWebFetchAdapter } from '../src/browser-runtime/web-fetch-adapter'

const roots: string[] = []
const previousCLI = process.env.ANKOLE_BROWSER_CLI
const servers: Server[] = []

afterEach(async () => {
  if (previousCLI === undefined) delete process.env.ANKOLE_BROWSER_CLI
  else process.env.ANKOLE_BROWSER_CLI = previousCLI
  await Promise.all(servers.splice(0).map(server => new Promise<void>(resolve => server.close(() => resolve()))))
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

describe('rendered web_fetch browser adapter', () => {
  test('materializes final data-plane env before invoking the CLI', async () => {
    const root = await mkdtemp('/tmp/ankole-browser-web-fetch-')
    roots.push(root)
    const capturePath = join(root, 'capture.json')
    const fakeCLI = join(root, 'fake-ankole-browser')
    await writeFile(
      fakeCLI,
      `#!/usr/bin/env bun
import { readFileSync, writeFileSync } from 'node:fs'
const material = JSON.parse(readFileSync(process.env.ANKOLE_BROWSER_MATERIAL, 'utf8'))
writeFileSync(${JSON.stringify(capturePath)}, JSON.stringify({
  argv: process.argv.slice(2),
  route: process.env.ANKOLE_BROWSER_ROUTE,
  session: process.env.ANKOLE_BROWSER_SESSION,
  socket: process.env.ANKOLE_BROWSER_SOCKET,
  sourceBackend: process.env.BROWSER_BACKEND_JSON,
  material
}))
console.log(JSON.stringify({
  v: 1,
  id: 'fake-fetch',
  ok: true,
  route: material.route_id,
  session: process.env.ANKOLE_BROWSER_SESSION,
  data: { results: [{ url: 'https://example.com', title: 'Example', text: 'rendered' }] },
  warnings: []
}))
`
    )
    await chmod(fakeCLI, 0o755)
    process.env.ANKOLE_BROWSER_CLI = fakeCLI
    const materializer = new BrowserRouteMaterializer({
      root: join(root, 'runtime'),
      socketPath: join(root, 'socket', 'browser.sock'),
      localChromiumExecutable: '/bin/true'
    })

    const result = await new BrowserWebFetchAdapter(materializer).fetch(['https://example.com'], {
      ssrfFilter: true,
      workerEnv: {
        BROWSER_BACKEND_JSON: JSON.stringify({
          kind: 'local_chromium',
          executable: '/bin/true',
          args: ['--final-only']
        })
      }
    })

    const captured = JSON.parse(await readFile(capturePath, 'utf8')) as {
      argv: string[]
      route: string
      session: string
      socket: string
      sourceBackend?: string
      material: {
        route_id: string
        backend: { kind: string; args?: string[] }
      }
    }
    expect(result).toMatchObject({ results: [{ text: 'rendered' }] })
    expect(captured.argv.slice(0, 3)).toEqual(['--json', '--timeout', '300000'])
    expect(captured.route).toBe(captured.material.route_id)
    expect(captured.session).toBe('default')
    expect(captured.socket).toBe(join(root, 'socket', 'browser.sock'))
    expect(captured.sourceBackend).toBeUndefined()
    expect(captured.material.backend).toMatchObject({ kind: 'local_chromium', args: ['--final-only'] })
  })

  test('restores the supervised daemon and retries ephemeral purge after a daemon crash', async () => {
    const root = await mkdtemp('/tmp/ankole-browser-web-fetch-retry-')
    roots.push(root)
    const fakeCLI = join(root, 'fake-ankole-browser')
    await writeFile(
      fakeCLI,
      `#!/usr/bin/env bun
import { readFileSync } from 'node:fs'
const material = JSON.parse(readFileSync(process.env.ANKOLE_BROWSER_MATERIAL, 'utf8'))
console.log(JSON.stringify({
  v: 1,
  id: 'fake-fetch',
  ok: true,
  route: material.route_id,
  session: process.env.ANKOLE_BROWSER_SESSION,
  data: { results: [{ url: 'https://example.com', text: 'rendered' }] },
  warnings: []
}))
`
    )
    await chmod(fakeCLI, 0o755)
    process.env.ANKOLE_BROWSER_CLI = fakeCLI
    const socketPath = join(root, 'socket', 'browser.sock')
    const materializer = new BrowserRouteMaterializer({
      root: join(root, 'runtime'),
      socketPath,
      localChromiumExecutable: '/bin/true'
    })
    let ensureCalls = 0
    let purgeCommand: unknown
    const adapter = new BrowserWebFetchAdapter(materializer, async () => {
      ensureCalls += 1
      const server = createServer(socket => {
        let buffer = ''
        socket.on('data', chunk => {
          buffer += String(chunk)
          const newline = buffer.indexOf('\n')
          if (newline === -1) return
          const request = JSON.parse(buffer.slice(0, newline)) as Record<string, unknown>
          purgeCommand = request.command
          socket.end(
            `${JSON.stringify({
              v: 1,
              id: request.id,
              ok: true,
              route: request.route,
              session: request.session,
              data: { purged: true },
              warnings: []
            })}\n`
          )
        })
      })
      servers.push(server)
      await mkdir(dirname(socketPath), { recursive: true })
      await new Promise<void>((resolve, reject) => {
        server.once('error', reject)
        server.listen(socketPath, () => {
          server.removeListener('error', reject)
          resolve()
        })
      })
    })

    const result = await adapter.fetch(['https://example.com'], { ssrfFilter: true })

    expect(result).toMatchObject({ results: [{ text: 'rendered' }] })
    expect(ensureCalls).toBe(1)
    expect(purgeCommand).toEqual({ name: 'lifecycle', args: { verb: 'purge' } })
  })
})
