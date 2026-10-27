import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startPodCLIBridge } from '../src/cli/pod/pod-cli-bridge'
import { buildApplet, commandFromArgs, initializeApplet } from '../src/cli/pod/pod-cli'
import { requestSocketLineBridge } from '../src/core/socket-line-bridge'
import { jsonBytes, jsonObjectFromBytes } from '../src/fabric/envelope_proto'
import { JSONPassthroughResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { RPCRequester } from '../src/lanes/rpc_lane'
import { FakeDrive } from './support/fake-drive'

describe('Pod Agent CLI', () => {
  it('uses the active Agent turn and converts document Markdown at the Worker boundary', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-cli-'))
    const calls: { method: string; payload: Record<string, unknown>; frame: unknown; retry: unknown }[] = []
    const frame = { run: { session: { session_id: 'conversation:pod' }, signal_id: 'signal' } }
    let forwardedXML = ''
    const rpc = (async (method, payload, suppliedFrame, opts) => {
      calls.push({
        method,
        payload: payload as Record<string, unknown>,
        frame: suppliedFrame,
        retry: opts?.retryOnDisconnect
      })
      const params = jsonObjectFromBytes((payload as { paramsJson: Uint8Array }).paramsJson, 'params')!
      const local = join(root, params.xml_home_relative_path as string)
      if (method === 'pod.read') await writeFile(local, '<page><p>Hello</p></page>')
      else forwardedXML = await readFile(local, 'utf8')
      return create(JSONPassthroughResponseSchema, {
        bodyJson: jsonBytes({ result: { page: { revision: 7 }, content: { xml_file: true } } })
      })
    }) as RPCRequester
    const bridge = startPodCLIBridge({ rpc, frame, drive: new FakeDrive(root).drive(), socketRoot: root })
    try {
      const read = await requestSocketLineBridge(
        bridge.socketPath,
        JSON.stringify({ operation: 'pages.read', params: { id: 'page' }, cwd: root }),
        'bad response'
      )
      expect((read.content as Record<string, unknown>).markdown).toBe('Hello')
      expect((read.content as Record<string, unknown>).content).toBeUndefined()
      await requestSocketLineBridge(
        bridge.socketPath,
        JSON.stringify({
          operation: 'pages.write',
          params: { id: 'page', base_revision: 7, markdown: '# Heading\n' },
          cwd: root
        }),
        'bad response'
      )
      expect(calls.map(call => call.method)).toEqual(['pod.read', 'pod.write'])
      expect(calls[0]!.frame).toEqual(frame)
      expect(calls.map(call => call.retry)).toEqual([true, false])
      const written = jsonObjectFromBytes(calls[1]!.payload.paramsJson as Uint8Array, 'params')!
      expect(written.base_revision).toBe(7)
      expect(forwardedXML).toContain('<h1>Heading</h1>')
      expect(written.xml).toBeUndefined()
      expect(written.markdown).toBeUndefined()
      await expect(
        requestSocketLineBridge(
          bridge.socketPath,
          JSON.stringify({ operation: 'arbitrary.method', params: {}, cwd: root }),
          'bad response'
        )
      ).rejects.toThrow()
    } finally {
      bridge.close()
      await rm(root, { recursive: true, force: true })
    }
  })

  it.each(['new', 'existing empty'])(
    'builds an applet with a ESM provider and host-owned external dependencies (%s directory)',
    async kind => {
      const root = await mkdtemp(join(tmpdir(), 'pod-applet-'))
      try {
        const app = kind === 'new' ? join(root, 'tracker') : root
        await initializeApplet(app)
        await buildApplet(app)
        const js = await readFile(join(app, 'dist/main.js'), 'utf8')
        const html = await readFile(join(app, 'dist/index.html'), 'utf8')
        expect(js).toContain('provider')
        expect(js).toContain('from "@ankole/applet-sdk"')
        expect(js).toContain('__ANKOLE_APPLET_HOST__.mount')
        expect(js).not.toContain('ReactCurrentDispatcher')
        expect(js).not.toContain('jsxDEV')
        expect(js).toContain('react/jsx-runtime')
        expect(html).toContain('./main.js')
        expect(html).toContain('./main.css')
        expect(await readFile(join(app, 'dist/main.css'), 'utf8')).toContain('.ankole-applet')
      } finally {
        await rm(root, { recursive: true, force: true })
      }
    }
  )

  it('builds Worker URL imports through a symlinked workspace', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-applet-symlink-'))
    try {
      const app = join(root, 'app')
      const link = join(root, 'workspace')
      await initializeApplet(app)
      await symlink(app, link)
      await writeFile(join(app, 'src/calculate.worker.ts'), 'self.onmessage = () => postMessage(42)')
      await writeFile(
        join(app, 'src/main.tsx'),
        'import workerURL from "./calculate.worker.ts?url"; export const provider = {workerURL}'
      )
      await buildApplet(link)
      expect(await readFile(join(app, 'dist/main.js'), 'utf8')).toContain('calculate.worker')
      expect(await readFile(join(app, 'dist/calculate.worker.js'), 'utf8')).toContain('postMessage(42)')
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('rebuilds without stale files and keeps both imported and conventional CSS', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-applet-'))
    try {
      await initializeApplet(join(root, 'app'))
      const app = join(root, 'app')
      await writeFile(join(app, 'src/main.tsx'), 'import "./other.css"; export const provider = {}')
      await writeFile(join(app, 'src/other.css'), '.imported { color: red; }')
      await buildApplet(app)
      await writeFile(join(app, 'dist/stale.js'), 'old source')
      await buildApplet(app)
      const css = await readFile(join(app, 'dist/main.css'), 'utf8')
      expect(css).toContain('.imported')
      expect(css).toContain('.ankole-applet')
      expect(await readdir(join(app, 'dist'))).not.toContain('stale.js')
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('publishes JavaScript media imports as files and resolves nested CSS assets', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-applet-assets-'))
    try {
      const app = join(root, 'app')
      await initializeApplet(app)
      await mkdir(join(app, 'src/theme'))
      const bytes = Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jzXcAAAAASUVORK5CYII=',
        'base64'
      )
      await writeFile(join(app, 'src/logo.png'), bytes)
      await writeFile(join(app, 'src/font.woff2'), Buffer.from([0, 255, 17, 128]))
      await writeFile(join(app, 'src/main.tsx'), 'import image from "./logo.png"; export const provider = {image}')
      await writeFile(join(app, 'src/style.css'), '@import "./theme/nested.css";')
      await writeFile(
        join(app, 'src/theme/nested.css'),
        '.logo {background-image: url("../logo.png")} @font-face {font-family: test;src: url("../font.woff2")}'
      )
      await buildApplet(app)
      const js = await readFile(join(app, 'dist/main.js'), 'utf8')
      const css = await readFile(join(app, 'dist/main.css'), 'utf8')
      const assets = await readdir(join(app, 'dist/assets'))
      const image = assets.find(name => name.endsWith('.png'))!
      expect(js).toContain(`./assets/${image}`)
      expect(css).toContain(`data:image/png;base64,${bytes.toString('base64')}`)
      expect(css).toContain('data:font/woff2;base64,AP8RgA==')
      expect(js).not.toContain('data:')
      expect(await readFile(join(app, 'dist/assets', image))).toEqual(bytes)
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it.each([
    '@ankole/uikit/components/button',
    '@ankole/uikit/components/input',
    '@ankole/uikit/components/label',
    '@ankole/applet-sdk/types',
    'react/compiler-runtime',
    'react-dom/server'
  ])('rejects runtime imports the applet host cannot provide: %s', async path => {
    const root = await mkdtemp(join(tmpdir(), 'pod-applet-host-import-'))
    try {
      const app = join(root, 'app')
      await initializeApplet(app)
      await writeFile(
        join(app, 'src/main.tsx'),
        `import {defineApplet} from '@ankole/applet-sdk'
import * as unsupported from ${JSON.stringify(path)}
export const provider = defineApplet(() => <main>{Object.keys(unsupported).length}</main>)`
      )
      await expect(buildApplet(app)).rejects.toThrow(`Unsupported applet host import "${path}"`)
      expect(await Bun.file(join(app, 'dist/index.html')).exists()).toBe(false)
      expect(await Bun.file(join(app, 'dist/main.js')).exists()).toBe(false)
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it.each(['@import "@ankole/uikit/styles.css";', '@import url("@ankole/uikit/styles.css");'])(
    'rejects host stylesheet imports with repair guidance: %s',
    async css => {
      const root = await mkdtemp(join(tmpdir(), 'pod-applet-host-style-'))
      try {
        const app = join(root, 'app')
        await initializeApplet(app)
        await writeFile(join(app, 'src/style.css'), `${css}\n.ankole-applet {padding: 1rem}`)
        await expect(buildApplet(app)).rejects.toThrow('the Pod host already loads those styles')
        expect(await Bun.file(join(app, 'dist/index.html')).exists()).toBe(false)
        expect(await Bun.file(join(app, 'dist/main.css')).exists()).toBe(false)
      } finally {
        await rm(root, { recursive: true, force: true })
      }
    }
  )

  it('keeps root UI exports, exact React modules, and erased SDK type imports working', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-applet-host-exports-'))
    try {
      const app = join(root, 'app')
      await initializeApplet(app)
      await writeFile(
        join(app, 'src/main.tsx'),
        `import 'react'
import 'react/jsx-runtime'
import 'react/jsx-dev-runtime'
import 'react-dom'
import 'react-dom/client'
import { Button, Input, Label } from '@ankole/uikit'
import { defineApplet } from '@ankole/applet-sdk'
import type { TableSchema } from '@ankole/applet-sdk/types'
import type { Routes } from '@ankole/applet-sdk/server'
const schema: TableSchema | null = null
const routes: Routes = {}
function App() {return <main><Label>Order</Label><Input/><Button>Save</Button></main>}
export const provider = defineApplet(App)`
      )
      await buildApplet(app)
      const js = await readFile(join(app, 'dist/main.js'), 'utf8')
      const imports = [...new Set(new Bun.Transpiler({ loader: 'js' }).scanImports(js).map(item => item.path))].sort()
      expect(imports).toEqual(
        [
          '@ankole/applet-sdk',
          '@ankole/uikit',
          'react',
          'react-dom',
          'react-dom/client',
          'react/jsx-dev-runtime',
          'react/jsx-runtime'
        ].sort()
      )
      expect(js).toContain('provider')
      expect(js).not.toContain('@ankole/uikit/components/')
      expect(js).not.toContain('@ankole/applet-sdk/types')
      expect(js).not.toContain('@ankole/applet-sdk/server')
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it.each(['dependencies', 'devDependencies', 'peerDependencies'])(
    'rejects host-only Ankole packages in applet %s before building',
    async group => {
      const root = await mkdtemp(join(tmpdir(), 'pod-applet-package-'))
      try {
        await initializeApplet(root)
        for (const name of ['@ankole/applet-sdk', '@ankole/uikit']) {
          await writeFile(join(root, 'package.json'), JSON.stringify({ [group]: { [name]: '*' } }))
          await expect(buildApplet(root)).rejects.toThrow(`Remove ${name} from package.json ${group}`)
          expect(await Bun.file(join(root, 'dist/index.html')).exists()).toBe(false)
        }
      } finally {
        await rm(root, { recursive: true, force: true })
      }
    }
  )

  it('bundles third-party React subpaths while keeping Ankole subpaths restricted', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-applet-dependency-'))
    try {
      await initializeApplet(root)
      await mkdir(join(root, 'node_modules/widget'), { recursive: true })
      await mkdir(join(root, 'node_modules/react'), { recursive: true })
      await writeFile(join(root, 'node_modules/widget/package.json'), '{"name":"widget","main":"index.js"}')
      await writeFile(
        join(root, 'node_modules/react/package.json'),
        '{"name":"react","exports":{"./compiler-runtime":"./compiler-runtime.js"}}'
      )
      await writeFile(join(root, 'node_modules/react/compiler-runtime.js'), 'export const compiled = "compiler-loaded"')
      await writeFile(join(root, 'node_modules/widget/index.js'), 'export {compiled} from "react/compiler-runtime"')
      await writeFile(join(root, 'src/main.tsx'), 'import {compiled} from "widget"; export const provider={compiled}')
      await buildApplet(root)
      expect(await readFile(join(root, 'dist/main.js'), 'utf8')).toContain('compiler-loaded')
      await writeFile(join(root, 'node_modules/widget/index.js'), 'export * from "@ankole/uikit/components/button"')
      await expect(buildApplet(root)).rejects.toThrow(
        'Unsupported applet host import "@ankole/uikit/components/button"'
      )
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('parses page sharing JSON and flags and forwards the write without retries', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-sharing-cli-'))
    const params = {
      sharing_version: 'v1',
      inherit_permissions: false,
      grants: [{ principal_uid: 'member', role: 'view' }]
    }
    const calls: unknown[] = []
    const rpc = (async (method, payload, _frame, options) => {
      calls.push({
        method,
        payload: jsonObjectFromBytes((payload as { paramsJson: Uint8Array }).paramsJson, 'params'),
        retry: options?.retryOnDisconnect
      })
      return create(JSONPassthroughResponseSchema, { bodyJson: jsonBytes({ result: { id: 'page' } }) })
    }) as RPCRequester
    const bridge = startPodCLIBridge({ rpc, drive: new FakeDrive(root).drive(), socketRoot: root })
    try {
      const json = await commandFromArgs(['page', 'set-sharing', 'page', JSON.stringify(params)], root)
      const flags = await commandFromArgs(
        [
          'page',
          'set-sharing',
          'page',
          '--sharing-version',
          'v1',
          '--inherit-permissions',
          'false',
          '--grants',
          JSON.stringify(params.grants)
        ],
        root
      )
      expect(flags).toEqual(json)
      await requestSocketLineBridge(bridge.socketPath, JSON.stringify(flags), 'invalid sharing response')
      expect(calls).toEqual([{ method: 'pod.write', payload: { ...params, id: 'page' }, retry: false }])
      await expect(
        commandFromArgs(['page', 'set-sharing', 'page', '--inherit-permissions', 'maybe'], root)
      ).rejects.toThrow('true or false')
    } finally {
      bridge.close()
      await rm(root, { recursive: true, force: true })
    }
  })

  it('checks publication source boundaries and removes its temporary drive staging on success and failure', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-cli-'))
    const outside = await mkdtemp(join(tmpdir(), 'pod-cli-outside-'))
    const files = new FakeDrive(root)
    const frame = { run: { session: { session_id: 'conversation:pod' }, signal_id: 'signal' } }
    let rejected = false
    let calls = 0
    const rpc = (async method => {
      expect(String(method)).toBe('pod.write')
      calls++
      expect(files.paths('_pod/applets/page').length).toBeGreaterThan(0)
      if (rejected) throw new Error('revision conflict')
      return create(JSONPassthroughResponseSchema, { bodyJson: jsonBytes({ result: { revision: 1 } }) })
    }) as RPCRequester
    const bridge = startPodCLIBridge({ rpc, frame, drive: files.drive(), socketRoot: root })
    const publish = (directory: string) =>
      requestSocketLineBridge(
        bridge.socketPath,
        JSON.stringify({
          operation: 'applets.publish',
          params: { id: 'page', base_revision: 0 },
          cwd: root,
          publish_directory: directory
        }),
        'invalid response'
      )
    try {
      await expect(publish(outside)).rejects.toThrow('inside the Agent Home')
      expect(calls).toBe(0)
      await mkdir(join(root, 'app/src'), { recursive: true })
      await mkdir(join(root, 'app/dist'), { recursive: true })
      await writeFile(join(root, 'app/src/main.tsx'), 'export const provider = {}')
      await writeFile(join(root, 'app/dist/index.html'), '<html></html>')
      expect(await publish('app')).toEqual({ revision: 1 })
      expect(files.paths('_pod/applets/page')).toEqual([])
      rejected = true
      await expect(publish('app')).rejects.toThrow('revision conflict')
      expect(files.paths('_pod/applets/page')).toEqual([])
    } finally {
      bridge.close()
      await rm(root, { recursive: true, force: true })
      await rm(outside, { recursive: true, force: true })
    }
  })

  it('bundles optional backend dependencies as ESM, erases server types, and removes the old backend', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-backend-'))
    try {
      const app = join(root, 'app')
      await initializeApplet(app)
      await mkdir(join(app, 'src/server'))
      await writeFile(join(app, 'src/server/total.ts'), 'export const total = (a: number, b: number) => a + b')
      await writeFile(
        join(app, 'src/server/main.ts'),
        `import type { Routes } from '@ankole/applet-sdk/server'
import { total } from './total'
export default { 'POST /total': async ({ body }) => ({total: total(body.a, body.b)}) } satisfies Routes`
      )
      const built = await buildApplet(app)
      expect(built.files).toContain('server/main.js')
      const server = await readFile(join(app, 'server/main.js'), 'utf8')
      expect(new Bun.Transpiler({ loader: 'js' }).scanImports(server)).toEqual([])
      expect(server).not.toContain('require(')
      const routes = (await import(join(app, 'server/main.js'))).default
      expect(await routes['POST /total']({ body: { a: 2, b: 3 } })).toEqual({ total: 5 })
      await rm(join(app, 'src/server/main.ts'))
      expect((await buildApplet(app)).files).not.toContain('server/main.js')
      expect(await Bun.file(join(app, 'server/main.js')).exists()).toBe(false)
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('keeps Node builtins external in the backend ESM', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-backend-node-'))
    try {
      const app = join(root, 'app')
      await initializeApplet(app)
      await mkdir(join(app, 'src/server'))
      await writeFile(
        join(app, 'src/server/main.ts'),
        `import { readFileSync } from 'node:fs'; export default {'GET /': () => readFileSync('/secret')}`
      )
      await buildApplet(app)
      const source = await Bun.file(join(app, 'server/main.js')).text()
      expect(source).toContain('node:fs')
      expect(new Bun.Transpiler({ loader: 'js' }).scanImports(source).map(item => item.path)).toEqual(['node:fs'])
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('does not publish a frontend-only replacement after its backend build failed', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-backend-failed-publish-'))
    const files = new FakeDrive(root)
    const frame = { run: { session: { session_id: 'conversation:pod' }, signal_id: 'signal' } }
    let calls = 0
    const rpc = (async () => {
      calls++
      return create(JSONPassthroughResponseSchema, { bodyJson: jsonBytes({ result: { revision: 1 } }) })
    }) as RPCRequester
    const bridge = startPodCLIBridge({ rpc, frame, drive: files.drive(), socketRoot: root })
    try {
      const app = join(root, 'app')
      await initializeApplet(app)
      await mkdir(join(app, 'src/server'))
      await writeFile(
        join(app, 'src/server/main.ts'),
        `import { missing } from './missing-module'; export default {'GET /': () => missing()}`
      )
      await expect(buildApplet(app)).rejects.toThrow('Applet backend build failed')
      // Frontend compilation finished before the backend failure. Its presence must not permit publication.
      expect(await Bun.file(join(app, 'dist/index.html')).exists()).toBe(true)
      expect(await Bun.file(join(app, 'server/main.js')).exists()).toBe(false)
      const publish = await commandFromArgs(['applet', 'publish', 'app', '{"id":"page","base_revision":0}'], root)
      await expect(requestSocketLineBridge(bridge.socketPath, JSON.stringify(publish), 'invalid')).rejects.toThrow(
        'Applet backend has not been built'
      )
      expect(calls).toBe(0)
      expect(files.paths('_pod/applets/page')).toEqual([])
    } finally {
      bridge.close()
      await rm(root, { recursive: true, force: true })
    }
  })

  it('publishes optional backend bytes in the same manifest and preserves route call status, logs and active turn', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-backend-bridge-'))
    const files = new FakeDrive(root)
    const frame = { run: { session: { session_id: 'conversation:pod' }, signal_id: 'signal' } }
    const rpc = (async (method, payload, suppliedFrame, options) => {
      expect(String(method)).toBe('pod.write')
      expect(suppliedFrame as unknown).toEqual(frame)
      expect(options?.retryOnDisconnect).toBe(false)
      const operation = (payload as { operation: string }).operation
      const params = jsonObjectFromBytes((payload as { paramsJson: Uint8Array }).paramsJson, 'params')!
      if (operation === 'applets.publish') {
        expect((params.files as { path: string }[]).map(file => file.path).sort()).toEqual([
          'dist/index.html',
          'server/main.js',
          'src/main.tsx',
          'src/server/main.ts'
        ])
        return create(JSONPassthroughResponseSchema, {
          bodyJson: jsonBytes({ result: { revision: 1, routes: ['GET /orders/:id'] } })
        })
      }
      expect(operation).toBe('applets.call')
      expect(params).toEqual({
        id: 'page',
        method: 'POST',
        path: '/orders/a%2Fb',
        query: { tag: ['one', 'two'] },
        body: { note: 'Keep' }
      })
      return create(JSONPassthroughResponseSchema, {
        bodyJson: jsonBytes({
          result: {
            status: 409,
            body: { error: { code: 'conflict', details: { current: 2 } } },
            logs: [{ level: 'info', message: 'checked' }]
          }
        })
      })
    }) as RPCRequester
    const bridge = startPodCLIBridge({ rpc, frame, drive: files.drive(), socketRoot: root })
    try {
      await mkdir(join(root, 'app/src/server'), { recursive: true })
      await mkdir(join(root, 'app/dist'), { recursive: true })
      await mkdir(join(root, 'app/server'), { recursive: true })
      for (const path of ['src/main.tsx', 'src/server/main.ts', 'dist/index.html', 'server/main.js']) {
        await writeFile(join(root, 'app', path), path)
      }
      const publish = await commandFromArgs(['applet', 'publish', 'app', '{"id":"page","base_revision":0}'], root)
      expect(await requestSocketLineBridge(bridge.socketPath, JSON.stringify(publish), 'invalid')).toEqual({
        revision: 1,
        routes: ['GET /orders/:id']
      })
      expect(files.paths('_pod/applets/page')).toEqual([])
      const call = await commandFromArgs(
        [
          'applet',
          'call',
          JSON.stringify({
            id: 'page',
            method: 'POST',
            path: '/orders/a%2Fb',
            query: { tag: ['one', 'two'] },
            body: { note: 'Keep' }
          })
        ],
        root
      )
      expect(await requestSocketLineBridge(bridge.socketPath, JSON.stringify(call), 'invalid')).toEqual({
        status: 409,
        body: { error: { code: 'conflict', details: { current: 2 } } },
        logs: [{ level: 'info', message: 'checked' }]
      })
    } finally {
      bridge.close()
      await rm(root, { recursive: true, force: true })
    }
  })

  it('rejects a nonempty directory without changing its files', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-applet-'))
    try {
      await writeFile(join(root, 'notes.txt'), 'Keep this work.\n')
      await expect(initializeApplet(root)).rejects.toThrow('Applet directory must be empty')
      expect(await readdir(root)).toEqual(['notes.txt'])
      expect(await readFile(join(root, 'notes.txt'), 'utf8')).toBe('Keep this work.\n')
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })
})
