import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startPodCLIBridge } from '../src/cli/pod/pod-cli-bridge'
import { buildApplet, commandFromArgs, initializeApplet } from '../src/cli/pod/pod-cli'
import { requestSocketLineBridge } from '../src/core/socket-line-bridge'
import { jsonBytes, jsonObjectFromBytes } from '../src/fabric/envelope-proto'
import { JSONPassthroughResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import { RPCRejectedError, type RPCRequester } from '../src/lanes/rpc-lane'
import type { RPCRequestInit } from '../src/lanes/rpc-contract'
import { FakeDrive } from './support/fake-drive'
import { AGENT_UID, isRootWorker } from '../src/common/agent-user'
import { agentProcessArgv } from '../src/core/execution/process-group'

const respond = (result: unknown) => create(JSONPassthroughResponseSchema, { bodyJson: jsonBytes({ result }) })

describe('Pod incremental and source commands', () => {
  it('transfers append fragments and applies exact Markdown patches with the original revision', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-edit-'))
    const frame = { run: { session: { session_id: 'conversation:pod' }, signal_id: 'signal' } }
    const writes: { operation: string; revision: unknown; markdown: string }[] = []
    let markdown = 'Old name 🧑‍💻\n\nRepeated Repeated'
    const rpc = (async (_method, raw, actualFrame) => {
      const payload = raw as RPCRequestInit<'pod.read'>
      expect(actualFrame as unknown).toEqual(frame)
      const params = jsonObjectFromBytes(payload.paramsJson as Uint8Array, 'params')!
      const local = join(root, params.markdown_home_relative_path as string)
      if (payload.operation === 'pages.read') await writeFile(local, markdown)
      else {
        writes.push({
          operation: payload.operation!,
          revision: params.base_revision,
          markdown: await readFile(local, 'utf8')
        })
      }
      return respond({ page: { revision: 7 }, content: { markdown_file: true } })
    }) as RPCRequester
    const bridge = startPodCLIBridge({
      rpc,
      frame,
      drive: new FakeDrive(root).drive(),
      socketRoot: root
    })
    const command = (operation: string, params: Record<string, unknown>) =>
      requestSocketLineBridge(
        bridge.socketPath,
        JSON.stringify({ operation, params: { id: 'page', base_revision: 7, ...params }, cwd: root }),
        'invalid'
      )
    try {
      await command('pages.append', { markdown: '## API\n\nAppended' })
      await command('pages.patch', { edits: [{ old_text: 'Old name', new_text: 'New name' }] })
      expect(writes).toEqual([
        { operation: 'pages.append', revision: 7, markdown: '## API\n\nAppended' },
        { operation: 'pages.write', revision: 7, markdown: 'New name 🧑‍💻\n\nRepeated Repeated' }
      ])
      await expect(command('pages.patch', { edits: [{ old_text: 'Repeated', new_text: 'X' }] })).rejects.toThrow(
        'more than once'
      )
      await expect(command('pages.patch', { edits: [{ old_text: 'Missing', new_text: 'X' }] })).rejects.toThrow(
        'did not match'
      )
      await expect(
        command('pages.patch', { base_revision: 6, edits: [{ old_text: 'Repeated', new_text: 'New' }] })
      ).rejects.toThrow('revision changed')
      await expect(
        command('pages.patch', { base_revision: 6, edits: [{ old_text: 'Missing', new_text: 'New' }] })
      ).rejects.toThrow('revision changed')
      expect(writes).toHaveLength(2)
      await command('pages.patch', { base_revision: 6, edits: [{ old_text: 'Old name', new_text: 'Rebased name' }] })
      expect(writes[2]).toEqual({
        operation: 'pages.write',
        revision: 7,
        markdown: 'Rebased name 🧑‍💻\n\nRepeated Repeated'
      })
      markdown = 'Repeated Repeated'
      await command('pages.patch', { edits: [{ old_text: 'Repeated', new_text: '$&', replace_all: true }] })
      expect(writes[3]!.markdown).toBe('$& $&')
      expect(await readdir(join(root, '.ankole/pod-content'))).toEqual([])
    } finally {
      bridge.close()
      await rm(root, { recursive: true, force: true })
    }
  })

  it('automatically rereads and rebases pages.patch on revision_conflict up to 3 retries while keeping pages.write strict', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-patch-rebase-'))
    const frame = { run: { session: { session_id: 'conversation:pod' }, signal_id: 'signal' } }
    let serverRevision = 10
    let serverMarkdown = '# Shared Doc\n\nSection A: alpha\n\nSection B: beta\n'
    let conflictsToInject = 2
    const writeAttempts: { operation: string; baseRevision: unknown; markdown: string }[] = []

    const rpc = (async (method, raw) => {
      const payload = raw as RPCRequestInit<'pod.read'>
      const params = jsonObjectFromBytes(payload.paramsJson as Uint8Array, 'params')!
      const local = join(root, params.markdown_home_relative_path as string)
      if (method === 'pod.read') {
        await writeFile(local, serverMarkdown)
        return respond({ page: { revision: serverRevision, type: 'doc' }, content: { markdown_file: true } })
      }
      const nextMarkdown = await readFile(local, 'utf8')
      writeAttempts.push({
        operation: payload.operation!,
        baseRevision: params.base_revision,
        markdown: nextMarkdown
      })
      if (conflictsToInject > 0) {
        conflictsToInject -= 1
        serverRevision += 1
        serverMarkdown = `${serverMarkdown}\nCollab note rev ${serverRevision}\n`
        throw new RPCRejectedError('pod.write', {
          code: 'revision_conflict',
          message: 'revision_conflict',
          details: { revision: serverRevision }
        })
      }
      if (params.base_revision !== serverRevision) {
        throw new RPCRejectedError('pod.write', {
          code: 'revision_conflict',
          message: 'revision_conflict',
          details: { revision: serverRevision }
        })
      }
      serverRevision += 1
      serverMarkdown = nextMarkdown
      return respond({ page: { revision: serverRevision } })
    }) as RPCRequester

    const bridge = startPodCLIBridge({
      rpc,
      frame,
      drive: new FakeDrive(root).drive(),
      socketRoot: root
    })
    try {
      // 1. Concurrent collaborator edits advance rev 10 -> 11 -> 12 while Section A still matches uniquely.
      const patched = await requestSocketLineBridge(
        bridge.socketPath,
        JSON.stringify({
          operation: 'pages.patch',
          params: {
            id: 'page-1',
            base_revision: 10,
            edits: [{ old_text: 'Section A: alpha', new_text: 'Section A: updated' }]
          },
          cwd: root
        }),
        'invalid'
      )
      expect(patched).toEqual({ page: { revision: 13 } })
      expect(writeAttempts.map(a => a.baseRevision)).toEqual([10, 11, 12])
      expect(serverMarkdown).toContain('Section A: updated')
      expect(serverMarkdown).toContain('Collab note rev 11')
      expect(serverMarkdown).toContain('Collab note rev 12')

      // 2. If collaborator change duplicates or removes old_text, rebase stops immediately without guessing.
      conflictsToInject = 0
      const startWrites = writeAttempts.length
      let conflictTriggered = false
      const conflictBridge = startPodCLIBridge({
        rpc: (async (method, raw) => {
          const payload = raw as RPCRequestInit<'pod.read'>
          const params = jsonObjectFromBytes(payload.paramsJson as Uint8Array, 'params')!
          const local = join(root, params.markdown_home_relative_path as string)
          if (method === 'pod.read') {
            const md = conflictTriggered
              ? '# Shared Doc\n\nSection B: beta\n\nSection B: beta\n'
              : '# Shared Doc\n\nSection B: beta\n'
            await writeFile(local, md)
            return respond({
              page: { revision: conflictTriggered ? 21 : 20, type: 'doc' },
              content: { markdown_file: true }
            })
          }
          conflictTriggered = true
          throw new RPCRejectedError('pod.write', {
            code: 'revision_conflict',
            message: 'revision_conflict',
            details: { revision: 21 }
          })
        }) as RPCRequester,
        frame,
        drive: new FakeDrive(root).drive(),
        socketRoot: root
      })
      try {
        await expect(
          requestSocketLineBridge(
            conflictBridge.socketPath,
            JSON.stringify({
              operation: 'pages.patch',
              params: {
                id: 'page-2',
                base_revision: 20,
                edits: [{ old_text: 'Section B: beta', new_text: 'Section B: gamma' }]
              },
              cwd: root
            }),
            'invalid'
          )
        ).rejects.toThrow('revision_conflict')
      } finally {
        conflictBridge.close()
      }
      expect(writeAttempts).toHaveLength(startWrites)

      // 3. pages.write remains strict and never auto-overwrites on revision_conflict.
      conflictsToInject = 1
      await expect(
        requestSocketLineBridge(
          bridge.socketPath,
          JSON.stringify({
            operation: 'pages.write',
            params: { id: 'page-1', base_revision: 13, markdown: '# Overwrite attempt\n' },
            cwd: root
          }),
          'invalid'
        )
      ).rejects.toThrow('revision_conflict')
      expect(writeAttempts).toHaveLength(startWrites + 1)
    } finally {
      bridge.close()
      await rm(root, { recursive: true, force: true })
    }
  })

  it('builds explicit worker entries and dynamic ESM chunks without renaming their relative URLs', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-worker-'))
    try {
      await initializeApplet(root)
      await writeFile(
        join(root, 'src/main.tsx'),
        `export const provider={
        load:()=>import('./details'),
        worker:()=>new Worker(new URL('./calculate.worker.js',import.meta.url),{type:'module'})};`
      )
      await writeFile(join(root, 'src/details.ts'), 'import "./details.css"; export const value = 42')
      await writeFile(join(root, 'src/details.css'), '.details {color: teal}')
      await writeFile(join(root, 'src/calculate.worker.ts'), 'const value: number = 42; postMessage(value)')
      const result = await buildApplet(root)
      expect(result.files).toContain('dist/calculate.worker.js')
      const main = await readFile(join(root, 'dist/main.js'), 'utf8')
      expect(main).toContain('./calculate.worker.js')
      expect(main).toMatch(/import\("\.\/chunks\//)
      const worker = await readFile(join(root, 'dist/calculate.worker.js'), 'utf8')
      expect(worker).toContain('postMessage')
      expect(worker).not.toContain(': number')
      const html = await readFile(join(root, 'dist/index.html'), 'utf8')
      const stylesheets = result.files.filter(path => path.endsWith('.css'))
      expect(stylesheets.length).toBeGreaterThan(1)
      for (const path of stylesheets) expect(html).toContain(`href="./${path.slice('dist/'.length)}"`)
      await writeFile(
        join(root, 'src/main.tsx'),
        `export const provider={worker:()=>new Worker(new URL('./calculate.worker.ts',import.meta.url),{type:'module'})}`
      )
      await expect(buildApplet(root)).rejects.toThrow('Import the Worker URL with ?url')
      expect(await Bun.file(join(root, 'dist/main.js')).exists()).toBe(false)
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('builds an imported WASM URL that fetch and WebAssembly can execute', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-wasm-'))
    try {
      await initializeApplet(root)
      const bytes = Buffer.from(
        '0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b',
        'hex'
      )
      await writeFile(join(root, 'src/add.wasm'), bytes)
      await writeFile(
        join(root, 'src/main.tsx'),
        `import wasmURL from './add.wasm'; export const provider={load:async()=>WebAssembly.instantiate(await(await fetch(wasmURL)).arrayBuffer())}`
      )
      await buildApplet(root)
      const child = Bun.spawn(
        [
          'bun',
          '-e',
          `globalThis.window=globalThis;globalThis.parent={__ANKOLE_APPLET_HOST__:{mount(){}}};
const {provider}=await import(${JSON.stringify(join(root, 'dist/main.js'))});
const wasm=await provider.load();console.log(wasm.instance.exports.add(2,3));`
        ],
        { stdout: 'pipe', stderr: 'pipe' }
      )
      const [code, stdout, stderr] = await Promise.all([
        child.exited,
        new Response(child.stdout).text(),
        new Response(child.stderr).text()
      ])
      expect(stderr).toBe('')
      expect(code).toBe(0)
      expect(stdout.trim()).toBe('5')
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('starts a compiled Worker from a nested dynamically loaded module', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-nested-worker-'))
    try {
      await initializeApplet(root)
      await mkdir(join(root, 'src/charts/nested'), { recursive: true })
      await writeFile(
        join(root, 'src/main.tsx'),
        `export const provider={load:()=>import('./charts/nested/controller')}`
      )
      await writeFile(
        join(root, 'src/charts/nested/controller.ts'),
        `import workerURL from './calculate.worker.ts?url';
export const run=()=>new Worker(new URL(workerURL,import.meta.url),{type:'module'});`
      )
      await writeFile(
        join(root, 'src/charts/nested/add.wasm'),
        Buffer.from('0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b', 'hex')
      )
      await writeFile(
        join(root, 'src/charts/nested/calculate.worker.ts'),
        `import wasmURL from './add.wasm';
const value: number = 42;
const module=await WebAssembly.instantiate(await(await fetch(wasmURL)).arrayBuffer());
postMessage(value+(module.instance.exports.add as (a:number,b:number)=>number)(2,3));`
      )
      await buildApplet(root)
      const child = Bun.spawn(
        [
          'bun',
          '-e',
          `globalThis.window=globalThis;globalThis.parent={__ANKOLE_APPLET_HOST__:{mount(){}}};
const {provider}=await import(${JSON.stringify(join(root, 'dist/main.js'))});
const {run}=await provider.load();
const worker=run();
worker.onerror=error=>{console.error(error);process.exit(1)};
worker.onmessage=event=>{console.log(event.data);worker.terminate()};`
        ],
        { stdout: 'pipe', stderr: 'pipe' }
      )
      const [code, stdout, stderr] = await Promise.all([
        child.exited,
        new Response(child.stdout).text(),
        new Response(child.stderr).text()
      ])
      expect(stderr).toBe('')
      expect(code).toBe(0)
      expect(stdout.trim()).toBe('47')
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('pulls immutable source and configuration, skips package lifecycle scripts, and rejects changed bytes', async () => {
    const root = await mkdtemp(join(tmpdir(), 'pod-pull-'))
    const outside = await mkdtemp(join(tmpdir(), 'pod-pull-outside-'))
    const files = new FakeDrive(root)
    files.put('pages/page/src/main.tsx', 'export const provider = {}')
    files.put('pages/page/src/components/ui/Button.tsx', 'export const Button = () => null')
    files.put('pages/page/applet.env.json', '{"WEBHOOK":"https://example.com/hook"}')
    files.put(
      'pages/page/package.json',
      JSON.stringify({ name: 'pulled-applet', scripts: { postinstall: 'touch executed' } })
    )
    let invalidDigest = false
    const rpc = (async (_method, raw) => {
      const payload = raw as RPCRequestInit<'pod.read'>
      if (payload.operation === 'files.download') {
        const params = jsonObjectFromBytes(payload.paramsJson!, 'params')!
        const file = files.files.get(`pages/page/${params.path}`)!
        if (params.sha256 !== file.sha256) throw new Error('Applet publication changed; pull again')
        await writeFile(join(root, params.home_relative_path as string), file.content)
        return respond({ file: { object_id: file.objectId } })
      }
      expect(payload.operation).toBe('files.manifest')
      return respond({
        revision: 4,
        files: files.paths().map(path => ({
          path: path.slice('pages/page/'.length),
          sha256: invalidDigest ? '0'.repeat(64) : files.files.get(path)!.sha256
        }))
      })
    }) as RPCRequester
    const bridge = startPodCLIBridge({
      rpc,
      frame: { run: { session: { session_id: 'conversation:pod' }, signal_id: 'signal' } },
      drive: files.drive(),
      socketRoot: root
    })
    const pull = async (directory: string) =>
      requestSocketLineBridge(
        bridge.socketPath,
        JSON.stringify(await commandFromArgs(['applet', 'pull', directory, '{"id":"page"}'], root)),
        'invalid'
      )
    try {
      const pulled = await pull('app')
      expect(pulled.revision).toBe(4)
      expect(await readFile(join(root, 'app/src/main.tsx'), 'utf8')).toBe('export const provider = {}')
      expect(await readFile(join(root, 'app/applet.env.json'), 'utf8')).toContain('WEBHOOK')
      if (isRootWorker()) {
        expect((await stat(join(root, 'app'))).uid).toBe(AGENT_UID)
        const read = Bun.spawnSync(agentProcessArgv(['/bin/cat', join(root, 'app/src/main.tsx')]))
        expect(read.exitCode, read.stderr.toString()).toBe(0)
        expect(read.stdout.toString()).toBe('export const provider = {}')
        const create = Bun.spawnSync(
          agentProcessArgv(['/usr/bin/touch', join(root, 'app/src/components/NewComponent.tsx')])
        )
        expect(create.exitCode, create.stderr.toString()).toBe(0)
      }
      expect(await Bun.file(join(root, 'app/executed')).exists()).toBe(false)
      const outsideUID = (await stat(outside)).uid
      await expect(pull(join(outside, 'app'))).rejects.toThrow('inside the Agent Home')
      expect((await stat(outside)).uid).toBe(outsideUID)
      expect(await readdir(outside)).toEqual([])
      await expect(pull('app')).rejects.toThrow('must be empty')
      await mkdir(join(root, 'empty'))
      await pull('empty')
      expect(await Bun.file(join(root, 'empty/src/main.tsx')).exists()).toBe(true)
      invalidDigest = true
      await expect(pull('changed')).rejects.toThrow('publication changed')
      expect(await Bun.file(join(root, 'changed/src/main.tsx')).exists()).toBe(false)
      expect((await readdir(root)).filter(name => name.startsWith('.ankole-pull-'))).toEqual([])
    } finally {
      bridge.close()
      await rm(root, { recursive: true, force: true })
      await rm(outside, { recursive: true, force: true })
    }
  })
})
